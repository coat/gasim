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

/// Builds a stream that loads `programs` when executed by node `root` from
/// its port `root_port`, into `buffer`. Uses `gpa` for scratch space.
pub fn stream(
    gpa: Allocator,
    layout: Chip.Layout,
    root: u16,
    root_port: Direction,
    programs: []const assembler.Program,
    buffer: []Word,
) (Allocator.Error || error{ NoSuchNode, StreamTooLong })![]Word {
    const count = layout.count();
    const root_index = layout.index(root) orelse return error.NoSuchNode;

    const program_of = try gpa.alloc(?*const assembler.Program, count);
    defer gpa.free(program_of);
    @memset(program_of, null);
    for (programs) |*program| program_of[layout.index(program.node) orelse return error.NoSuchNode] = program;

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
        if (program_of[node] != null) needed[node] = true;
        if (needed[node]) needed[parent[node].?] = true;
    }

    var builder: Builder = .{ .layout = layout, .root_port = root_port, .parent = parent, .program_of = program_of, .needed = needed, .buffer = buffer };
    if (needed[root_index]) {
        try builder.emit(.load, root_index);
        try builder.emit(.start, root_index);
    }
    return buffer[0..builder.len];
}

/// The most words a stream that loads `programs` onto `layout` can take,
/// to size the buffer for `stream`
pub fn maxLen(layout: Chip.Layout, programs: []const assembler.Program) usize {
    // a jump to start each node and one to load it, and the headers that
    // copy its streams to it, plus each program and the header that loads it
    var len = layout.count() * (2 + 2 * 5);
    for (programs) |program| len += 5 + program.len;
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
    program_of: []const ?*const assembler.Program,
    needed: []const bool,
    buffer: []Word,
    len: usize = 0,

    const Pass = enum { load, start };

    /// Emits a pass of the stream for the tree under node `i`
    fn emit(self: *Builder, pass: Pass, i: u16) error{StreamTooLong}!void {
        const program = self.program_of[i];
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

        switch (pass) {
            .load => if (program) |p| if (p.len > 0) {
                // copy the program into RAM through A
                const words = try self.reserve(5 + p.len);
                words[0..5].* = copyLoop(.@"a!", .@"!+", 0, p.len);
                @memcpy(words[5..], p.ram[0..p.len]);
            },
            .start => try self.jump(if (program) |p| @as(u9, @bitCast(p.entry)) else port.multiport(self.layout.neighbourPorts(i))),
        }
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
    const words = try stream(std.testing.allocator, .ga144, 1, .up, assembled, &buffer);

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
    var feeder: Chip.Feeder = .{ .words = try stream(std.testing.allocator, .ga144, 1, .up, assembled, &buffer) };
    try chip.attachFeeder(&feeder, 1, .up);
    try chip.run();

    try std.testing.expectEqual(feeder.words.len, feeder.next);
    // node 001 received the value with its program, not as boot code
    try std.testing.expectEqual(5, chip.node(1).?.data_stack.t);
    try std.testing.expectEqualSlices(Word, assembled[1].ram[0..assembled[1].len], chip.node(1).?.mem[0..assembled[1].len]);
}

test "boot node 001 from ROM" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try ga144.testRom(&roms);

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
    var feeder: Chip.Feeder = .{ .words = try stream(std.testing.allocator, .ga144, 1, .up, assembled, &buffer) };
    try chip.attachFeeder(&feeder, 1, .up);

    var input_buffer: [16]u8 = undefined;
    var input = try Console.testInput(&input_buffer, "boot me");
    var output_buffer: [16]u8 = undefined;
    var output: Io.Writer = .fixed(&output_buffer);
    var console: Console = .{ .io = std.testing.io, .input = &input, .output = &output };
    try chip.attachConsole(&console, 0, .up);

    try chip.run();
    try std.testing.expectEqualStrings("BOOT ME", output.buffered());
}

test maxLen {
    // full programs along a row, each loaded through the one before
    var programs: [3]assembler.Program = undefined;
    for (&programs, 0..) |*program, i| program.* = .{ .node = @intCast(i), .ram = @splat(0), .len = 64, .entry = .{ .io = false, .rom = false, .local = 0 } };
    const layout: Chip.Layout = .{ .rows = 1, .columns = 3 };
    const buffer = try std.testing.allocator.alloc(Word, maxLen(layout, &programs));
    defer std.testing.allocator.free(buffer);
    _ = try stream(std.testing.allocator, layout, 1, .up, &programs, buffer);
}

test "nothing to boot" {
    var buffer: [8]Word = undefined;
    try std.testing.expectEqual(0, (try stream(std.testing.allocator, .ga144, 1, .up, &.{}, &buffer)).len);
    try std.testing.expectError(error.NoSuchNode, stream(std.testing.allocator, .ga144, 18, .up, &.{}, &buffer));
    try std.testing.expectError(error.StreamTooLong, stream(std.testing.allocator, .ga144, 1, .up, &.{.{ .node = 717, .ram = @splat(0), .len = 64, .entry = .{ .io = false, .rom = false, .local = 0 } }}, &buffer));
}

const assembler = @import("assembler.zig");
const Console = @import("Console.zig");
const ga144 = @import("ga144.zig");
const Chip = @import("Chip.zig");
const f18 = @import("f18.zig");
const Address = f18.Address;
const Instruction = f18.Instruction;
const Word = f18.Word;
const Opcode = @import("opcodes.zig").Opcode;
const port = @import("port.zig");
const Direction = port.Direction;
const Port = port.Port;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
