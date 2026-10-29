//! Boot streams load programs into a chip through its comm ports, as one
//! GA144 boots another through the SERDES port of node 001.
//!
//! A boot stream is code for a node to execute straight from a port. It
//! spreads along a tree of nodes rooted at the node it enters, in two passes.
//! The first loads every node: each node copies the streams for its children
//! to them, then loads its own program. The second starts them the same way,
//! children before their parents. Nodes without a program go back to waiting
//! on all their ports, as warm does.
//!
//! While booting, a node executes only from the port facing its parent. So a
//! node that has started can write to its parent, or any other node still
//! booting, without its words being taken for boot code: the write waits
//! until the other node's program reads it.
//!
//! What each node is loaded with, and how it starts, is given by a
//! descriptor, as arrayForth 3's boot descriptors describe nodes.

/// What to load into a node's RAM from the programs saved in bins, what to
/// set its registers and stacks to, and where to start it
pub const Descriptor = struct {
    node: u16,
    /// parts of RAM to load, in order, so later ones overwrite earlier ones
    loads: [3]Load = undefined,
    load_count: u2 = 0,
    a: ?Word = null,
    b: ?Word = null,
    io: ?Word = null,
    /// values to push onto the data stack, the last on top
    stack: [10]Word = undefined,
    stack_len: u4 = 0,
    /// values to push onto the return stack, the last on top
    return_stack: [9]Word = undefined,
    return_stack_len: u4 = 0,
    p: u10,

    pub const Load = struct {
        bin: u32,
        /// where the words are in the bin, and where they go in RAM
        source: u6 = 0,
        destination: u6 = 0,
        len: u7 = 64,
    };

    /// Writes what the descriptor does, a line each, such as
    ///
    ///     boot node 107
    ///       load bin 1614
    ///       B 115
    ///       stack 08a00
    ///       P 017
    pub fn format(self: Descriptor, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("boot node {d:0>3}\n", .{self.node});
        for (self.loads[0..self.load_count]) |load| if (load.len == 64) {
            try writer.print("  load bin {d}\n", .{load.bin});
        } else {
            try writer.print("  load {d} words from {x:0>2} of bin {d} to {x:0>2}\n", .{ load.len, load.source, load.bin, load.destination });
        };
        if (self.io) |io| try writer.print("  IO {x:0>5}\n", .{@as(u18, @bitCast(io))});
        if (self.a) |a| try writer.print("  A {x:0>3}\n", .{@as(u18, @bitCast(a))});
        if (self.b) |b| try writer.print("  B {x:0>3}\n", .{@as(u18, @bitCast(b))});
        try writeValues(writer, "return stack", self.return_stack[0..self.return_stack_len]);
        try writeValues(writer, "stack", self.stack[0..self.stack_len]);
        try writer.print("  P {x:0>3}\n", .{self.p});
    }

    fn writeValues(writer: *Io.Writer, name: []const u8, values: []const Word) Io.Writer.Error!void {
        if (values.len == 0) return;
        try writer.print("  {s}", .{name});
        for (values) |value| try writer.print(" {x:0>5}", .{@as(u18, @bitCast(value))});
        try writer.writeByte('\n');
    }

    /// loads a program from its bin, and starts it at its entry
    pub fn ofProgram(program: Program) Descriptor {
        var descriptor: Descriptor = .{ .node = program.node, .p = @as(u9, @bitCast(program.entry)) };
        descriptor.loads[0] = .{ .bin = program.bin orelse program.node, .len = program.len };
        descriptor.load_count = 1;
        return descriptor;
    }
};

/// the program saved in a bin, where a program without a bin is in its
/// node's own
pub fn findBin(programs: []const Program, bin: u32) ?*const Program {
    for (programs) |*program| if ((program.bin orelse program.node) == bin) return program;
    return null;
}

/// Builds a stream that sets up nodes as `descriptors` say, loading RAM from
/// `programs`, when executed by node `root` from its port `root_port`, into
/// `buffer`. Uses `gpa` for scratch space.
pub fn stream(
    gpa: Allocator,
    layout: Chip.Layout,
    root: u16,
    root_port: Direction,
    descriptors: []const Descriptor,
    programs: []const Program,
    buffer: []Word,
) (Allocator.Error || error{ NoSuchNode, NoSuchBin, StreamTooLong })![]Word {
    const count = layout.count();
    const root_index = layout.index(root) orelse return error.NoSuchNode;

    const descriptor_of = try gpa.alloc(?*const Descriptor, count);
    defer gpa.free(descriptor_of);
    @memset(descriptor_of, null);
    for (descriptors) |*descriptor| {
        descriptor_of[layout.index(descriptor.node) orelse return error.NoSuchNode] = descriptor;
        for (descriptor.loads[0..descriptor.load_count]) |load| _ = findBin(programs, load.bin) orelse return error.NoSuchBin;
    }

    // a breadth first tree, so streams take the shortest path to each node
    const parent = try gpa.alloc(?u16, count);
    defer gpa.free(parent);
    @memset(parent, null);
    const queue = try gpa.alloc(u16, count);
    defer gpa.free(queue);
    parent[root_index] = root_index;
    queue[0] = root_index;
    var head: usize = 0;
    var tail: usize = 1;
    while (head < tail) : (head += 1) {
        const i = queue[head];
        for (directions) |direction| {
            const child = layout.neighbour(i, direction) orelse continue;
            if (parent[child] != null) continue;
            parent[child] = i;
            queue[tail] = child;
            tail += 1;
        }
    }

    // the nodes whose trees have a program, children before their parents
    const needed = try gpa.alloc(bool, count);
    defer gpa.free(needed);
    @memset(needed, false);
    var i = tail;
    while (i > 0) {
        i -= 1;
        const node = queue[i];
        if (descriptor_of[node] != null) needed[node] = true;
        if (needed[node]) needed[parent[node].?] = true;
    }

    var builder: Builder = .{ .layout = layout, .root_port = root_port, .parent = parent, .descriptor_of = descriptor_of, .programs = programs, .needed = needed, .buffer = buffer };
    if (needed[root_index]) {
        try builder.emit(.load, root_index);
        try builder.emit(.start, root_index);
    }
    return buffer[0..builder.len];
}

/// The most words a stream that sets up `descriptors` on `layout` can take,
/// to size the buffer for `stream`
pub fn maxLen(layout: Chip.Layout, descriptors: []const Descriptor) usize {
    // a jump to start each node and one to load it, and the headers that
    // copy its streams to it, plus each load with the header that loads it,
    // and the words that set registers and push onto stacks
    var len = layout.count() * (2 + 2 * 5);
    for (descriptors) |descriptor| {
        for (descriptor.loads[0..descriptor.load_count]) |load| len += 5 + load.len;
        len += 4 + 2 + 2 + 2 * (descriptor.stack_len + descriptor.return_stack_len);
    }
    return len;
}

const directions = [_]Direction{ .right, .down, .left, .up };

/// Code that sets a register with `set` to `target`, then stores the `count`
/// words that follow it with `store`
fn copyLoop(set: Opcode, store: Opcode, target: u9, count: usize) [5]Word {
    return .{
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = set, .slot_2 = .@"@p", .slot_3 = 7 }),
        target,
        @bitCast(@as(u18, @intCast(count - 1))),
        Instruction.encode(.{ .slot_0 = .@">r", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = store, .slot_2 = .unext, .slot_3 = 7 }),
    };
}

const Builder = struct {
    layout: Chip.Layout,
    root_port: Direction,
    parent: []const ?u16,
    descriptor_of: []const ?*const Descriptor,
    programs: []const Program,
    needed: []const bool,
    buffer: []Word,
    len: usize = 0,

    const Pass = enum { load, start };

    /// Emits a pass of the stream for the tree under node `i`
    fn emit(self: *Builder, pass: Pass, i: u16) error{StreamTooLong}!void {
        const descriptor = self.descriptor_of[i];
        // execute only from the port facing the parent from now on
        if (pass == .load) try self.jump(port.multiport(.initOne(self.parentPort(i))));

        for (directions) |direction| {
            const child = self.layout.neighbour(i, direction) orelse continue;
            if (self.parent[child] != i or !self.needed[child]) continue;

            const header = self.len;
            _ = try self.reserve(5);
            try self.emit(pass, child);
            // copy the child's stream to it through B
            const size = self.len - header - 5;
            if (size > 0x40000) return error.StreamTooLong;
            self.buffer[header..][0..5].* = copyLoop(.@"b!", .@"!b", port.multiport(.initOne(direction)), size);
        }

        const d = descriptor orelse {
            if (pass == .start) try self.jump(port.multiport(self.layout.neighbourPorts(i)));
            return;
        };
        switch (pass) {
            // copy each load into RAM through A
            .load => for (d.loads[0..d.load_count]) |load| if (load.len > 0) {
                const program = findBin(self.programs, load.bin).?;
                const words = try self.reserve(5 + load.len);
                words[0..5].* = copyLoop(.@"a!", .@"!+", load.destination, load.len);
                @memcpy(words[5..], program.ram[load.source..][0..load.len]);
            },
            .start => {
                if (d.io) |io| {
                    try self.literal(.@"b!", Computer.io_address);
                    try self.literal(.@"!b", io);
                }
                if (d.a) |a| try self.literal(.@"a!", a);
                if (d.b) |b| try self.literal(.@"b!", b);
                for (d.return_stack[0..d.return_stack_len]) |value| try self.literal(.@">r", value);
                for (d.stack[0..d.stack_len]) |value| try self.literal(.@".", value);
                try self.jump(d.p);
            },
        }
    }

    /// code that fetches a literal with @p and then runs `opcode`
    fn literal(self: *Builder, opcode: Opcode, value: Word) error{StreamTooLong}!void {
        const words = try self.reserve(2);
        words[0] = Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = opcode, .slot_2 = .@".", .slot_3 = 7 });
        words[1] = value;
    }

    fn reserve(self: *Builder, n: usize) error{StreamTooLong}![]Word {
        if (self.buffer.len - self.len < n) return error.StreamTooLong;
        defer self.len += n;
        return self.buffer[self.len..][0..n];
    }

    fn jump(self: *Builder, destination: u10) error{StreamTooLong}!void {
        const words = try self.reserve(1);
        words[0] = Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }, 0, destination);
    }

    /// the port of node `i` facing its parent, or the port the stream enters
    fn parentPort(self: Builder, i: u16) Direction {
        const parent = self.parent[i].?;
        if (parent == i) return self.root_port;
        for (directions) |direction| if (self.layout.neighbour(i, direction) == parent) return direction;
        unreachable;
    }
};

test "boot stream loads programs through the array" {
    // each program waits on a port once it starts: node 000 on its
    // unconnected left port, and node 102 on node 101, which waits too
    const source =
        \\ node 000 dup dup : main 7 left b! @b
        \\ node 102 : main left b! @b
    ;
    var programs: [2]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);

    var buffer: [1024]Word = undefined;
    var descriptors: [2]Descriptor = undefined;
    const words = try stream(std.testing.allocator, .ga144, 1, .up, ofPrograms(assembled, &descriptors), assembled, &buffer);

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var feeder: Chip.Feeder = .{ .words = words };
    try chip.attachFeeder(&feeder, 1, .up);
    try chip.run();
    try std.testing.expectEqual(words.len, feeder.next);

    for (assembled) |program| {
        const n = chip.node(program.node).?;
        try std.testing.expectEqualSlices(Word, program.ram[0..program.len], n.mem[0..program.len]);
    }
    // node 000 started at main, after its first word
    try std.testing.expectEqual(Address.fromWord(5), chip.node(0).?.p.address);
    try std.testing.expectEqual(7, chip.node(0).?.data_stack.t);
    try std.testing.expectEqual(Address.fromWord(2), chip.node(102).?.p.address);

    // nodes on the way without programs went back to waiting on their ports
    try std.testing.expectEqual(Address.fromWord(0x1b5), chip.node(1).?.p.address);
    try std.testing.expectEqual(Address.fromWord(0x1a5), chip.node(101).?.p.address);
}

test "nodes that start early cannot write into a booting node's stream" {
    // node 000 starts before its parent 001 and writes to it straight away
    const source =
        \\ node 000 : main right b! 5 !b left b! @b
        \\ node 001 : main right b! @b left b! @b
    ;
    var programs: [2]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);
    var buffer: [256]Word = undefined;

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var descriptors: [2]Descriptor = undefined;
    var feeder: Chip.Feeder = .{ .words = try stream(std.testing.allocator, .ga144, 1, .up, ofPrograms(assembled, &descriptors), assembled, &buffer) };
    try chip.attachFeeder(&feeder, 1, .up);
    try chip.run();

    try std.testing.expectEqual(feeder.words.len, feeder.next);
    // node 001 received the value with its program, not as boot code
    try std.testing.expectEqual(5, chip.node(1).?.data_stack.t);
    try std.testing.expectEqualSlices(Word, assembled[1].ram[0..assembled[1].len], chip.node(1).?.mem[0..assembled[1].len]);
}

test "boot node 001 from ROM" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    try chip.loadRom(parsed);

    var programs: [2]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    // node 000 passes input to node 001 to upcase, as in examples/upcase.ga
    const source =
        \\ node 000 : main right a! up b! begin @b ! @ !b again
        \\ node 001 : main right b! begin @b upcase !b again
        \\ : upcase dup -97 + -if drop ; then -26 + -if drop -32 + ; then drop ;
    ;
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);
    var buffer: [256]Word = undefined;
    var descriptors: [2]Descriptor = undefined;
    var feeder: Chip.Feeder = .{ .words = try stream(std.testing.allocator, .ga144, 1, .up, ofPrograms(assembled, &descriptors), assembled, &buffer) };
    try chip.attachFeeder(&feeder, 1, .up);

    var input_buffer: [16]u8 = undefined;
    var input = try Console.testInput(&input_buffer, "boot me");
    var output_buffer: [16]u8 = undefined;
    var output: Io.Writer = .fixed(&output_buffer);
    var console: Console = .{ .input = .{ .io = std.testing.io, .queue = &input }, .output = &output };
    try chip.attachConsole(&console, 0, .up);

    try chip.run();
    try std.testing.expectEqualStrings("BOOT ME", output.buffered());
}

test "descriptors load parts of RAM, set registers and push onto stacks" {
    const source =
        \\ node 000 : main dup drop ;  5 , 6 , 7 ,
        \\ node 102 : main over ;
    ;
    var programs: [2]Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);

    // each node starts executing from its left port, where nothing comes,
    // so it waits as it was set up
    var descriptors: [2]Descriptor = .{
        .{ .node = 0, .a = 0x123, .b = 0x1d5, .io = 0x15555, .p = 0x175 },
        .{ .node = 102, .p = 0x175 },
    };
    descriptors[0].loads[0..2].* = .{ .{ .bin = 0, .source = 1, .destination = 10, .len = 3 }, .{ .bin = 102, .destination = 20, .len = 1 } };
    descriptors[0].load_count = 2;
    descriptors[0].stack[0..3].* = .{ 1, 2, 3 };
    descriptors[0].stack_len = 3;
    descriptors[0].return_stack[0..2].* = .{ 4, 5 };
    descriptors[0].return_stack_len = 2;
    descriptors[1].loads[0] = .{ .bin = 102 };
    descriptors[1].load_count = 1;

    var buffer: [512]Word = undefined;
    var feeder: Chip.Feeder = .{ .words = try stream(std.testing.allocator, .ga144, 1, .up, &descriptors, assembled, &buffer) };
    var booted: Chip = try .init(std.testing.allocator, .ga144);
    defer booted.deinit(std.testing.allocator);
    try booted.attachFeeder(&feeder, 1, .up);
    try booted.run();
    try std.testing.expectEqual(feeder.words.len, feeder.next);

    // and the same as setting them up without a stream
    var set_up: Chip = try .init(std.testing.allocator, .ga144);
    defer set_up.deinit(std.testing.allocator);
    for (descriptors) |descriptor| try set_up.setUp(descriptor, assembled);

    for (descriptors) |descriptor| {
        const n = booted.node(descriptor.node).?;
        const expected = set_up.node(descriptor.node).?;
        try std.testing.expectEqualSlices(Word, expected.mem[0..64], n.mem[0..64]);
        try std.testing.expectEqual(expected.p, n.p);
        // a stream uses A and B to load nodes, unless they are set
        if (descriptor.a != null) try std.testing.expectEqual(expected.a, n.a);
        if (descriptor.b != null) try std.testing.expectEqual(expected.b, n.b);
        try std.testing.expectEqual(expected.io, n.io);
        for (0..descriptor.stack_len) |_| try std.testing.expectEqual(expected.data_stack.pop(), n.data_stack.pop());
        for (0..descriptor.return_stack_len) |_| try std.testing.expectEqual(expected.return_stack.pop(), n.return_stack.pop());
    }
    const n = set_up.node(0).?;
    try std.testing.expectEqualSlices(Word, assembled[0].ram[1..4], n.mem[10..13]);
    try std.testing.expectEqual(assembled[1].ram[0], n.mem[20]);
    try std.testing.expectEqual(0x123, n.a);
}

test "Descriptor.format" {
    var descriptor: Descriptor = .{ .node = 7, .b = 0x115, .p = 0x17 };
    descriptor.loads[0..2].* = .{ .{ .bin = 1614 }, .{ .bin = 1600, .source = 1, .destination = 2, .len = 3 } };
    descriptor.load_count = 2;
    descriptor.stack[0] = 0x8a00;
    descriptor.stack_len = 1;
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writer.print("{f}", .{descriptor});
    try std.testing.expectEqualStrings(
        \\boot node 007
        \\  load bin 1614
        \\  load 3 words from 01 of bin 1600 to 02
        \\  B 115
        \\  stack 08a00
        \\  P 017
        \\
    , writer.buffered());
}

test maxLen {
    // full programs along a row, each loaded through the one before
    var programs: [3]assembler.Program = undefined;
    for (&programs, 0..) |*program, i| program.* = .{ .node = @intCast(i), .ram = @splat(0), .len = 64, .entry = .{ .io = false, .rom = false, .local = 0 } };
    const layout: Chip.Layout = .{ .rows = 1, .columns = 3 };
    var descriptors: [3]Descriptor = undefined;
    const buffer = try std.testing.allocator.alloc(Word, maxLen(layout, ofPrograms(&programs, &descriptors)));
    defer std.testing.allocator.free(buffer);
    _ = try stream(std.testing.allocator, layout, 1, .up, &descriptors, &programs, buffer);
}

test "nothing to boot" {
    var buffer: [8]Word = undefined;
    try std.testing.expectEqual(0, (try stream(std.testing.allocator, .ga144, 1, .up, &.{}, &.{}, &buffer)).len);
    try std.testing.expectError(error.NoSuchNode, stream(std.testing.allocator, .ga144, 18, .up, &.{}, &.{}, &buffer));
    const program: Program = .{ .node = 717, .ram = @splat(0), .len = 64, .entry = .{ .io = false, .rom = false, .local = 0 } };
    try std.testing.expectError(error.StreamTooLong, stream(std.testing.allocator, .ga144, 1, .up, &.{.ofProgram(program)}, &.{program}, &buffer));
    // a load from a bin that was not saved
    try std.testing.expectError(error.NoSuchBin, stream(std.testing.allocator, .ga144, 1, .up, &.{.ofProgram(program)}, &.{}, &buffer));
}

fn ofPrograms(programs: []const Program, buffer: []Descriptor) []Descriptor {
    for (programs, buffer[0..programs.len]) |program, *descriptor| descriptor.* = .ofProgram(program);
    return buffer[0..programs.len];
}

const assembler = @import("assembler.zig");
const Program = assembler.Program;
const Console = @import("Console.zig");
const ga144 = @import("ga144.zig");
const testRom = @import("rom.zig").testRom;
const Chip = @import("Chip.zig");
const f18 = @import("f18.zig");
const Address = f18.Address;
const Computer = f18.Computer;
const Instruction = f18.Instruction;
const Word = f18.Word;
const Opcode = @import("opcodes.zig").Opcode;
const port = @import("port.zig");
const Direction = port.Direction;
const Port = port.Port;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
