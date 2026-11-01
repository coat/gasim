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
//!
//! An async boot stream is for node 708's ROM, which receives it on a pin
//! from a UART (see `asyncStream`). It is made of frames, each storing words
//! into the node's RAM or writing them to a port, for a neighbour to
//! execute, and then jumping: to read another frame, or to start.

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
    const root_index = layout.index(root) orelse return error.NoSuchNode;
    var tree: Tree = try .init(gpa, layout, root_index, descriptors, programs);
    defer tree.deinit(gpa);

    var builder: Builder = .{ .layout = layout, .root_port = root_port, .tree = tree, .programs = programs, .buffer = buffer };
    if (tree.needed[root_index]) {
        try builder.emit(.load, root_index);
        try builder.emit(.start, root_index);
    }
    return buffer[0..builder.len];
}

/// where `ser-exec` is in node 708's ROM, which reads a frame of an async
/// boot stream: a frame that jumps here is followed by another
pub const read_frame: u10 = 0xae;

/// Builds an async boot stream that sets up nodes as `descriptors` say,
/// loading RAM from `programs`, for the ROM of node `root` to receive, into
/// `buffer`. Uses `gpa` for scratch space.
///
/// A frame is a word to jump to once it is received, where to store its
/// words, how many there are, and the words. The streams for the trees
/// under the root's neighbours are written to the ports facing them: each
/// tree's loading, and then each tree's start. The root's own loads are
/// stored in its RAM, and the code that sets its registers and stacks after
/// them, so that the last frame jumps there, or to where the root starts.
/// A root without a descriptor goes back to waiting on its ports and its
/// pin, at cold, so that it can be sent another stream. (Its warm executes
/// from the ports and the pin, and so the word a pin wakeup reads.)
pub fn asyncStream(
    gpa: Allocator,
    layout: Chip.Layout,
    root: u16,
    descriptors: []const Descriptor,
    programs: []const Program,
    buffer: []Word,
) (Allocator.Error || error{ NoSuchNode, NoSuchBin, StreamTooLong, RootTooLong })![]Word {
    const root_index = layout.index(root) orelse return error.NoSuchNode;
    var tree: Tree = try .init(gpa, layout, root_index, descriptors, programs);
    defer tree.deinit(gpa);

    // the root's port is never used, as it does not execute a stream
    var builder: Builder = .{ .layout = layout, .root_port = .up, .tree = tree, .programs = programs, .buffer = buffer };
    for ([_]Builder.Pass{ .load, .start }) |pass| for (directions) |direction| {
        const child = layout.neighbour(root_index, direction) orelse continue;
        if (tree.parent[child] != root_index or !tree.needed[child]) continue;
        const header = try builder.reserve(3);
        const start = builder.len;
        try builder.emit(pass, child);
        header.* = frameHeader(read_frame, port.multiport(.initOne(direction)), builder.len - start);
    };

    const d = tree.descriptor_of[root_index] orelse {
        (try builder.reserve(3)).* = frameHeader(ga144.romWord(root, "cold").?, 0, 0);
        return buffer[0..builder.len];
    };
    var end: usize = 0;
    for (d.loads[0..d.load_count]) |load| if (load.len > 0) {
        const program = findBin(programs, load.bin).?;
        const words = try builder.reserveSlice(3 + load.len);
        words[0..3].* = frameHeader(read_frame, load.destination, load.len);
        @memcpy(words[3..], program.ram[load.source..][0..load.len]);
        end = @max(end, @as(usize, load.destination) + load.len);
    };
    // the code to set registers and stacks, then jump to where it starts
    const header = try builder.reserve(3);
    const start = builder.len;
    try builder.setUp(d);
    const setup = builder.len - start;
    if (setup == 1) {
        // only the jump, which the frame can do itself
        builder.len -= 4;
        (try builder.reserve(3)).* = frameHeader(d.p, 0, 0);
    } else {
        if (end + setup > 64) return error.RootTooLong;
        header.* = frameHeader(@intCast(end), @intCast(end), setup);
    }
    return buffer[0..builder.len];
}

fn frameHeader(jump: u10, destination: u9, len: usize) [3]Word {
    return .{ jump, destination, @intCast(len) };
}

/// Writes the bytes a UART sends node 708's ROM for each word of an async
/// boot stream, into `buffer`, which takes 3 bytes for each word. The first
/// byte's low 6 bits are x2d, a pattern the ROM measures the bit time with,
/// and its high 2 bits the word's low 2 bits. The ROM reads data bits as
/// inverted, so the bytes are too.
pub fn asyncBytes(words: []const Word, buffer: []u8) []u8 {
    for (words, 0..) |word, i| {
        const w: u18 = @bitCast(word);
        buffer[3 * i ..][0..3].* = .{
            ~(@as(u8, @truncate(w << 6)) | 0x2d),
            ~@as(u8, @truncate(w >> 2)),
            ~@as(u8, @truncate(w >> 10)),
        };
    }
    return buffer[0 .. 3 * words.len];
}

/// The tree a stream takes through the array from its root, and the nodes
/// whose trees have a program
const Tree = struct {
    descriptor_of: []?*const Descriptor,
    /// each node's parent, and the root its own
    parent: []?u16,
    needed: []bool,

    fn init(gpa: Allocator, layout: Chip.Layout, root_index: u16, descriptors: []const Descriptor, programs: []const Program) (Allocator.Error || error{ NoSuchNode, NoSuchBin })!Tree {
        const count = layout.count();
        const descriptor_of = try gpa.alloc(?*const Descriptor, count);
        errdefer gpa.free(descriptor_of);
        @memset(descriptor_of, null);
        for (descriptors) |*descriptor| {
            descriptor_of[layout.index(descriptor.node) orelse return error.NoSuchNode] = descriptor;
            for (descriptor.loads[0..descriptor.load_count]) |load| _ = findBin(programs, load.bin) orelse return error.NoSuchBin;
        }

        // a breadth first tree, so streams take the shortest path to each node
        const parent = try gpa.alloc(?u16, count);
        errdefer gpa.free(parent);
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
        @memset(needed, false);
        var i = tail;
        while (i > 0) {
            i -= 1;
            const node = queue[i];
            if (descriptor_of[node] != null) needed[node] = true;
            if (needed[node]) needed[parent[node].?] = true;
        }
        return .{ .descriptor_of = descriptor_of, .parent = parent, .needed = needed };
    }

    fn deinit(self: *Tree, gpa: Allocator) void {
        gpa.free(self.descriptor_of);
        gpa.free(self.parent);
        gpa.free(self.needed);
        self.* = undefined;
    }
};

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
    tree: Tree,
    programs: []const Program,
    buffer: []Word,
    len: usize = 0,

    const Pass = enum { load, start };

    /// Emits a pass of the stream for the tree under node `i`
    fn emit(self: *Builder, pass: Pass, i: u16) error{StreamTooLong}!void {
        const descriptor = self.tree.descriptor_of[i];
        // execute only from the port facing the parent from now on
        if (pass == .load) try self.jump(port.multiport(.initOne(self.parentPort(i))));

        for (directions) |direction| {
            const child = self.layout.neighbour(i, direction) orelse continue;
            if (self.tree.parent[child] != i or !self.tree.needed[child]) continue;

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
                const words = try self.reserveSlice(5 + load.len);
                words[0..5].* = copyLoop(.@"a!", .@"!+", load.destination, load.len);
                @memcpy(words[5..], program.ram[load.source..][0..load.len]);
            },
            .start => try self.setUp(d),
        }
    }

    /// code that sets registers and stacks as a descriptor says, then jumps
    /// to where the node starts
    fn setUp(self: *Builder, d: *const Descriptor) error{StreamTooLong}!void {
        if (d.io) |io| {
            try self.literal(.@"b!", Computer.io_address);
            try self.literal(.@"!b", io);
        }
        if (d.a) |a| try self.literal(.@"a!", a);
        if (d.b) |b| try self.literal(.@"b!", b);
        for (d.return_stack[0..d.return_stack_len]) |value| try self.literal(.@">r", value);
        for (d.stack[0..d.stack_len]) |value| try self.literal(.@".", value);
        try self.jump(d.p);
    }

    /// code that fetches a literal with @p and then runs `opcode`
    fn literal(self: *Builder, opcode: Opcode, value: Word) error{StreamTooLong}!void {
        const words = try self.reserve(2);
        words[0] = Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = opcode, .slot_2 = .@".", .slot_3 = 7 });
        words[1] = value;
    }

    fn reserve(self: *Builder, comptime n: usize) error{StreamTooLong}!*[n]Word {
        return (try self.reserveSlice(n))[0..n];
    }

    fn reserveSlice(self: *Builder, n: usize) error{StreamTooLong}![]Word {
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
        const parent = self.tree.parent[i].?;
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
    try expectEqual(words.len, feeder.next);

    for (assembled) |program| {
        const n = chip.node(program.node).?;
        try expectEqualSlices(Word, program.ram[0..program.len], n.mem[0..program.len]);
    }
    // node 000 started at main, after its first word
    try expectEqual(Address.fromWord(5), chip.node(0).?.p.address);
    try expectEqual(7, chip.node(0).?.data_stack.t);
    try expectEqual(Address.fromWord(2), chip.node(102).?.p.address);

    // nodes on the way without programs went back to waiting on their ports
    try expectEqual(Address.fromWord(0x1b5), chip.node(1).?.p.address);
    try expectEqual(Address.fromWord(0x1a5), chip.node(101).?.p.address);
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

    try expectEqual(feeder.words.len, feeder.next);
    // node 001 received the value with its program, not as boot code
    try expectEqual(5, chip.node(1).?.data_stack.t);
    try expectEqualSlices(Word, assembled[1].ram[0..assembled[1].len], chip.node(1).?.mem[0..assembled[1].len]);
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
    try expectEqualStrings("BOOT ME", output.buffered());
}

test "boot node 708 from ROM through a UART" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    try chip.loadRom(parsed);

    // node 707 gives node 708 two bytes, which it sends back on its pin
    // 708.1, an inverted line, at 921600 baud with a bit time of 1085 ns
    var programs: [2]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const source =
        \\ node 707 : main left b! 72 !b 105 !b up b! @b
        \\ node 708 : main left b! io a! @b send @b send up b! @b
        \\ : bit ( level ) ! 428 for unext ;
        \\ : send ( c ) 3 bit 7 for dup 1 and 1 xor 2 + bit 2/ next drop 2 bit ;
    ;
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);
    var descriptors: [2]Descriptor = undefined;
    var words: [256]Word = undefined;
    const frames = try asyncStream(std.testing.allocator, .ga144, 708, ofPrograms(assembled, &descriptors), assembled, &words);
    var bytes: [3 * words.len]u8 = undefined;

    var output_buffer: [16]u8 = undefined;
    var output: Io.Writer = .fixed(&output_buffer);
    var uart: Uart = .init(921600, &output);
    uart.preload = asyncBytes(frames, &bytes);
    try chip.attachUart(&uart, 708);
    try chip.run();

    try expectEqualStrings("Hi", output.buffered());
    for (assembled) |program| {
        const n = chip.node(program.node).?;
        try expectEqualSlices(Word, program.ram[0..program.len], n.mem[0..program.len]);
    }
    // waiting for its pin on its up port, which the idle line never wakes
    try expect(chip.node(708).?.waitsOnPin());
}

test "boot node 708 from input that arrives while it waits on its pin" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    try chip.loadRom(parsed);

    var programs: [1]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes("node 708 : main 5 right b! @b", &programs, &diagnostic);
    // one frame that loads RAM and jumps to 0, as ga-tools makes for a
    // single node, which only boots if the node wakes on the start bit of
    // its first word, and not the next change of the line
    var words: [67]Word = undefined;
    words[0..3].* = frameHeader(0, 0, assembled[0].len);
    @memcpy(words[3..][0..assembled[0].len], assembled[0].ram[0..assembled[0].len]);
    const frames = words[0 .. 3 + assembled[0].len];
    var bytes: [3 * words.len]u8 = undefined;

    var output: Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &output);
    try chip.attachUart(&uart, 708);
    // with no input, node 708 waits on its pin
    try chip.run();
    try expect(chip.node(708).?.waitsOnPin());

    // and its start bit begins as it arrives, at the node's time
    var input_buffer: [bytes.len]u8 = undefined;
    var input = try Console.testInput(&input_buffer, asyncBytes(frames, &bytes));
    uart.input = .{ .io = std.testing.io, .queue = &input };
    try chip.run();
    try expectEqual(5, chip.node(708).?.data_stack.t);
}

test "node 708 takes another stream once it has booted only its neighbours" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    try chip.loadRom(parsed);

    var programs: [2]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes(
        \\ node 608 : main 6 left b! @b
        \\ node 708 : main 5 right b! @b
    , &programs, &diagnostic);
    // a stream for node 608 only, and then one for node 708
    const descriptors: [1]Descriptor = .{.ofProgram(assembled[0])};
    var first_buffer: [256]Word = undefined;
    const first = try asyncStream(std.testing.allocator, .ga144, 708, &descriptors, assembled, &first_buffer);
    var first_bytes: [3 * first_buffer.len]u8 = undefined;
    var second: [67]Word = undefined;
    second[0..3].* = frameHeader(0, 0, assembled[1].len);
    @memcpy(second[3..][0..assembled[1].len], assembled[1].ram[0..assembled[1].len]);
    var second_bytes: [3 * second.len]u8 = undefined;

    var output: Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &output);
    uart.preload = asyncBytes(first, &first_bytes);
    var input_buffer: [second_bytes.len]u8 = undefined;
    var input = try Console.testInput(&input_buffer, asyncBytes(second[0 .. 3 + assembled[1].len], &second_bytes));
    uart.input = .{ .io = std.testing.io, .queue = &input };
    try chip.attachUart(&uart, 708);
    try chip.run();
    try expectEqual(6, chip.node(608).?.data_stack.t);
    try expectEqual(5, chip.node(708).?.data_stack.t);
}

test asyncStream {
    const source =
        \\ node 708 : main dup ;
        \\ node 608 : main over ;
    ;
    var programs: [2]Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);
    var buffer: [256]Word = undefined;

    // a root without a descriptor goes to cold
    var descriptors: [2]Descriptor = .{ .ofProgram(assembled[1]), .ofProgram(assembled[0]) };
    const without = try asyncStream(std.testing.allocator, .ga144, 708, descriptors[0..1], assembled, &buffer);
    try expectEqualSlices(Word, &.{ 0xaa, 0, 0 }, without[without.len - 3 ..]);

    // node 608 is loaded and started through the port facing it, down
    const with = try asyncStream(std.testing.allocator, .ga144, 708, &descriptors, assembled, &buffer);
    try expectEqualSlices(Word, &.{ read_frame, port.multiport(.initOne(.down)) }, with[0..2]);
    // then node 708's RAM, and a frame that jumps to main
    try expectEqualSlices(Word, &.{ assembled[0].entry.toWord(), 0, 0 }, with[with.len - 3 ..]);
    const load = with.len - 3 - assembled[0].len - 3;
    try expectEqualSlices(Word, &.{ read_frame, 0, assembled[0].len }, with[load..][0..3]);

    // code to set up registers goes in RAM after the program
    descriptors[1].a = 0x15d;
    const set_up = try asyncStream(std.testing.allocator, .ga144, 708, &descriptors, assembled, &buffer);
    try expectEqualSlices(Word, &.{ assembled[0].len, assembled[0].len, 3 }, set_up[set_up.len - 6 ..][0..3]);
    descriptors[1].loads[0].len = 64;
    descriptors[1].loads[0].bin = 708;
    try expectError(error.RootTooLong, asyncStream(std.testing.allocator, .ga144, 708, &descriptors, assembled, &buffer));
}

test asyncBytes {
    var buffer: [6]u8 = undefined;
    // as ga-tools sends words to node 708
    try expectEqualSlices(u8, &.{ 0xd2, 0xff, 0xff, 0x92, 0xe0, 0x00 }, asyncBytes(&.{ 0, @bitCast(@as(u18, 0x3fc7d)) }, &buffer));
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
    try expectEqual(feeder.words.len, feeder.next);

    // and the same as setting them up without a stream
    var set_up: Chip = try .init(std.testing.allocator, .ga144);
    defer set_up.deinit(std.testing.allocator);
    for (descriptors) |descriptor| try set_up.setUp(descriptor, assembled);

    for (descriptors) |descriptor| {
        const n = booted.node(descriptor.node).?;
        const expected = set_up.node(descriptor.node).?;
        try expectEqualSlices(Word, expected.mem[0..64], n.mem[0..64]);
        try expectEqual(expected.p, n.p);
        // a stream uses A and B to load nodes, unless they are set
        if (descriptor.a != null) try expectEqual(expected.a, n.a);
        if (descriptor.b != null) try expectEqual(expected.b, n.b);
        try expectEqual(expected.io, n.io);
        for (0..descriptor.stack_len) |_| try expectEqual(expected.data_stack.pop(), n.data_stack.pop());
        for (0..descriptor.return_stack_len) |_| try expectEqual(expected.return_stack.pop(), n.return_stack.pop());
    }
    const n = set_up.node(0).?;
    try expectEqualSlices(Word, assembled[0].ram[1..4], n.mem[10..13]);
    try expectEqual(assembled[1].ram[0], n.mem[20]);
    try expectEqual(0x123, n.a);
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
    try expectEqualStrings(
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
    try expectEqual(0, (try stream(std.testing.allocator, .ga144, 1, .up, &.{}, &.{}, &buffer)).len);
    try expectError(error.NoSuchNode, stream(std.testing.allocator, .ga144, 18, .up, &.{}, &.{}, &buffer));
    const program: Program = .{ .node = 717, .ram = @splat(0), .len = 64, .entry = .{ .io = false, .rom = false, .local = 0 } };
    try expectError(error.StreamTooLong, stream(std.testing.allocator, .ga144, 1, .up, &.{.ofProgram(program)}, &.{program}, &buffer));
    // a load from a bin that was not saved
    try expectError(error.NoSuchBin, stream(std.testing.allocator, .ga144, 1, .up, &.{.ofProgram(program)}, &.{}, &buffer));
}

fn ofPrograms(programs: []const Program, buffer: []Descriptor) []Descriptor {
    for (programs, buffer[0..programs.len]) |program, *descriptor| descriptor.* = .ofProgram(program);
    return buffer[0..programs.len];
}

const assembler = @import("assembler.zig");
const Program = assembler.Program;
const Console = @import("Console.zig");
const Uart = @import("Uart.zig");
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
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
