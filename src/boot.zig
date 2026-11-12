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
        try writer.print("boot node {f}\n", .{Chip.nodeName(self.node)});
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

/// Descriptors for a source that has none, into `buffer`: each program in
/// its node's own bin is loaded and started at its entry, and code saved in
/// other bins is not loaded
pub fn ownDescriptors(programs: []const Program, buffer: []Descriptor) []Descriptor {
    var count: usize = 0;
    for (programs) |program| if (program.bin == null) {
        buffer[count] = .ofProgram(program);
        count += 1;
    };
    return buffer[0..count];
}

/// what code needs of a chip's ROM
pub const RomUse = union(enum) {
    /// a program calls or names a word of ROM, here in its source
    word: assembler.Diagnostic,
    /// a node starts in ROM
    start: Descriptor,
};

/// The first use `descriptors` make of ROM, for a chip that has none
/// loaded, or null if they make none
pub fn romUse(descriptors: []const Descriptor, programs: []const Program) ?RomUse {
    for (descriptors) |descriptor| {
        for (descriptor.loads[0..descriptor.load_count]) |part| {
            const program = findBin(programs, part.bin) orelse continue;
            if (program.rom_word) |word| return .{ .word = word };
        }
        if (descriptor.p & 0x180 == 0x080) return .{ .start = descriptor };
    }
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
        // the root's ROM, an asynchronous boot ROM's
        (try builder.reserve(3)).* = frameHeader(ga144.romWordOf(.async_boot, "cold").?, 0, 0);
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
        len += 4 + 2 + 2 + 2 * (@as(usize, descriptor.stack_len) + descriptor.return_stack_len);
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

test "node 705 boots from the EVB002's SPI flash with NO BOOT off" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    var programs: [1]Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes("node 705 : main 5 right b! @b", &programs, &diagnostic);
    const program = assembled[0];

    // a frame to RAM at 0 that jumps to main, whose first word passes the
    // ROM's check of its high 6 bits, from x2 to x21 (BOOT-02 2.1)
    var words: [3 + 64]Word = undefined;
    words[0..3].* = .{ 0x10000 | program.entry.toWord(), 0, program.len };
    @memcpy(words[3..][0..program.len], program.ram[0..program.len]);
    var bytes: [(words.len * 18 + 7) / 8]u8 = undefined;
    var flash: Flash = .init(Flash.pack(words[0 .. 3 + program.len], &bytes));

    for ([_]bool{ false, true }) |no_boot| {
        const gpa = std.testing.allocator;
        var chip: Chip = try .initChips(gpa, .ga144, Board.evb002.chips);
        defer chip.deinit(gpa);
        try chip.loadRom(parsed);
        const settings = [_]Board.Setting{.{ .name = "J26", .on = no_boot }};
        var fault: Board.Fault = .none;
        try Board.evb002.apply(&chip, &.{}, &settings, &fault);
        flash = .init(flash.contents);
        try Board.evb002.attachFlash(&chip, &flash, &settings);
        try chip.run();
        const n = chip.node(705).?;
        if (no_boot) {
            // J26 holds 705.17 high, so 705 does not boot, and the flash is
            // never selected
            try expect(n.data_stack.t != 5);
            try expect(!flash.selected);
            try expectEqual(0, flash.count);
        } else {
            try expectEqual(5, n.data_stack.t);
            try expectEqualSlices(Word, program.ram[0..program.len], n.mem[0..program.len]);
        }
    }
}

test "node 705 reads another frame from where spi-boot sends it in the flash" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    // frame 1 calls spi-boot (xB0) with 497, the ROM's half bit time, the
    // address x100 shifted up 2, as spiadr is, and spicmd, the read and
    // the address's high byte; frame 2, at x100, starts main
    var bytes: [0x200]u8 = @splat(0xff);
    for ([_][]const u8{ "node 705 : main 497 0x400 >r 0xc00 0xb0 >r ;", "node 705 : main 7 right b! @b" }, [_]usize{ 0, 0x100 }) |source, at| {
        var programs: [1]Program = undefined;
        var diagnostic: assembler.Diagnostic = .{};
        const program = (try assembler.assembleNodes(source, &programs, &diagnostic))[0];
        var words: [3 + 64]Word = undefined;
        words[0..3].* = .{ 0x10000 | program.entry.toWord(), 0, program.len };
        @memcpy(words[3..][0..program.len], program.ram[0..program.len]);
        _ = Flash.pack(words[0 .. 3 + program.len], bytes[at..]);
    }
    const gpa = std.testing.allocator;
    var chip: Chip = try .initChips(gpa, .ga144, Board.evb002.chips);
    defer chip.deinit(gpa);
    try chip.loadRom(parsed);
    const settings = [_]Board.Setting{.{ .name = "J26", .on = false }};
    var fault: Board.Fault = .none;
    try Board.evb002.apply(&chip, &.{}, &settings, &fault);
    var flash: Flash = .init(&bytes);
    try Board.evb002.attachFlash(&chip, &flash, &settings);
    try chip.run();
    try expectEqual(7, chip.node(705).?.data_stack.t);
    try expect(chip.wiring.contention == null);
    // a flash's nets take one device each
    var again: Flash = .init(&.{});
    try expectError(error.TwoDevices, Board.evb002.attachFlash(&chip, &again, &settings));
}

test "a stream from root 705 boots from the EVB002's flash, its root reading the frame FORWARD says" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    var programs: [4]Program = undefined;
    var descriptor_buffer: [8]Descriptor = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    // as the disk's streams for flash: a speed-up for the root alone, as
    // bin 1608 is, then a frame that leaves the root in code of its own,
    // which reads the next frame from where FORWARD patches into its fwd,
    // at x23, as bin 1710's /frm does
    const assembled = try arrayforth.assembleScript(
        \\ STREAMER LOAD
        \\ ASM[ # 705 NODE # 1608 BIN ERS # 0 org : spifast 5. dup spi-exec ; >BIN
        \\      # 705 NODE # 1710 BIN ERS # x22 org : /frm x3A38. >r 5. xC00. spi-boot ; >BIN
        \\      # 606 NODE ERS # 0 org : main 6. right b! @b ; >BIN
        \\      # 704 NODE ERS # 0 org : main 4. right b! @b ; >BIN ]ASM
        \\ 0 ARRAY EAST  705 ORGN 706 TO 606 TO -1 ,
        \\ 0 ARRAY WEST  705 ORGN 704 TO -1 ,
        \\ 705 STREAM[   0 0 3 1608 /ROOT
        \\    ' EAST COURSE  FRAME[  606 +NODE 606 /RAM 0 /P  705 +NODE 1710 /RAM 1710 ITS /frm /P  ]FRAME  FORWARD
        \\    ' WEST COURSE  FRAME[  704 +NODE 704 /RAM 0 /P  ]FRAME
        \\ ]STREAM
    , null, &programs, &descriptor_buffer, &diagnostic);
    var part_buffer: [arrayforth.Stream.max_parts]streamer.Part = undefined;
    const parts = assembled.parts(&part_buffer);
    try expectEqual(4, parts.len);
    var buffer: [512]Word = undefined;
    const words = try streamer.stream(.ga144, parts, assembled.programs, &buffer);
    var bytes: [(buffer.len * 18 + 15) / 16 * 2]u8 = undefined;
    var flash: Flash = .init(try streamer.pack(words, &bytes));

    const gpa = std.testing.allocator;
    var chip: Chip = try .initChips(gpa, .ga144, Board.evb002.chips);
    defer chip.deinit(gpa);
    try chip.loadRom(parsed);
    const settings = [_]Board.Setting{.{ .name = "J26", .on = false }};
    var fault: Board.Fault = .none;
    try Board.evb002.apply(&chip, &.{}, &settings, &fault);
    try Board.evb002.attachFlash(&chip, &flash, &settings);
    try chip.run();
    try expectEqual(6, chip.node(606).?.data_stack.t);
    try expectEqual(4, chip.node(704).?.data_stack.t);
    // the root went on to read the second frame through /frm, with the
    // address FORWARD patched in, not 1710's x3A38, where the second
    // frame starts, packed: after a whole number of 8 words
    const fwd = chip.node(705).?.mem[0x23];
    try expect(fwd != 0x3a38);
    try expectEqual(fwd, chip.node(705).?.mem[0x31]);
    const next = std.mem.lastIndexOfScalar(Word, words, 0x10000 | @as(Word, streamer.spi_exec)).?;
    try expectEqual(@as(Word, @intCast(next * 18 / 8 * 4)), fwd);
    try expect(chip.wiring.contention == null);
}

test "arrayForth 3's applications boot through the EVB002's USB port A as their descriptors say" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    const gpa = std.testing.allocator;
    const disk = try Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(disk);

    // the stream arrayForth 3 builds to install the SRAM cluster, block
    // 1897 up to its ]STREAM, after the configuration that says where its
    // modules are and the bins it loads, the cluster's and 108's (block
    // 2298)
    var sram: Io.Writer.Allocating = .init(gpa);
    defer sram.deinit();
    try sram.writer.writeAll("1562 LOAD  2331 LOAD  2298 LOAD\n");
    const install = disk[1897 * 1024 ..][0..1024];
    for (0..16) |line| try sram.writer.print("{s}\n", .{install[line * 64 ..][0..64]});
    const install_end = std.mem.indexOf(u8, sram.written(), "]STREAM").? + "]STREAM".len;

    const applications = [_][]const u8{
        sram.written()[0..install_end],
        // the Ethernet NIC with its clock monitor, as block 1665 adds it to
        // pF/144's stream, without the polyFORTH VM, which the block 1665
        // test describes, so that this boots through 708. Block 1583
        // adds it to pF/144 with the crystal oscillator too (?CLK 2), whose
        // descriptors load a bin 516 that nothing builds.
        \\1562 LOAD  STREAMER LOAD  1 CONSTANT ?CLK  1 CONSTANT ?ETH  2001 LOAD
        \\708 STREAM[
        \\   FRAME[  ( Residual) SRAM 2 + LOAD  ' s708 COURSE
        \\      ( Async bootable)  708 +NODE xAA /P
        \\      ( Clock/Ether)  ENIC 1+ LOAD
        \\   ]FRAME
        \\]STREAM
        ,
    };
    for (applications) |source| {
        // on the heap, as a program for each node number is too much for
        // some stacks
        const programs = try gpa.alloc(Program, Chip.Layout.chip_numbers);
        defer gpa.free(programs);
        var descriptor_buffer: [Chip.Layout.chip_numbers]Descriptor = undefined;
        var diagnostic: assembler.Diagnostic = .{};
        const assembled = arrayforth.assembleScript(source, disk, programs, &descriptor_buffer, &diagnostic) catch |err| {
            std.debug.print("{s}: {t} at block {d} line {d} '{s}'\n", .{ source, err, (diagnostic.line -| 1) / 16, (diagnostic.line -| 1) % 16, diagnostic.token });
            return err;
        };
        try expect(assembled.descriptors.len > 0);

        // as gasim lays out the stream, and as the STREAMER does along the
        // frame's path
        const descriptors = assembled.descriptors;
        const ours = try gpa.alloc(Word, maxLen(.ga144, descriptors) + 3 * (descriptors.len + 2));
        defer gpa.free(ours);
        var part_buffer: [arrayforth.Stream.max_parts]streamer.Part = undefined;
        const parts = assembled.parts(&part_buffer);
        try expectEqual(1, parts.len);
        const theirs = try gpa.alloc(Word, streamer.maxLen(parts));
        defer gpa.free(theirs);
        const streams = [_]struct { []const u8, []const Word }{
            .{ "gasim's", try asyncStream(gpa, .ga144, 708, descriptors, assembled.programs, ours) },
            .{ "the STREAMER's", try streamer.stream(.ga144, parts, assembled.programs, theirs) },
        };
        // but for 708, which reads frames at ser-exec and starts at cold
        // from reset, so that being at either says nothing of its boot
        var checked_buffer: [Chip.Layout.chip_numbers]Descriptor = undefined;
        var checked_len: usize = 0;
        for (descriptors) |d| if (d.node != 708) {
            checked_buffer[checked_len] = d;
            checked_len += 1;
        };
        const checked = checked_buffer[0..checked_len];
        for (streams) |s| {
            const name, const words = s;
            // as many at a time as there can be breakpoints, which stop
            // each node where it starts
            var first: usize = 0;
            while (first < checked.len) : (first += Chip.max_breakpoints) {
                const batch = checked[first..@min(first + Chip.max_breakpoints, checked.len)];
                expectBootsAsDescribed(parsed, batch, .{ .uart = words }, assembled.programs, null) catch |err| {
                    std.debug.print("{s} with {s} stream\n", .{ source, name });
                    return err;
                };
            }
        }
    }
}

test "a stream of several frames boots each along its own path, and sets a node up again" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    var programs: [4]Program = undefined;
    var descriptor_buffer: [8]Descriptor = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    // the first frame starts 508, and 608 on code that goes back to warm,
    // and leaves 708 reading the next; along a path of its own, through
    // 608 again, the second frame starts 608 on its own code, and 707
    const assembled = try arrayforth.assembleScript(
        \\ STREAMER LOAD
        \\ ASM[ # 508 NODE ERS # 0 org : main 5. main ; >BIN
        \\      # 608 NODE # 1608 BIN ERS # 0 org : main 1. warm ; >BIN
        \\      # 608 NODE ERS # 0 org : main 6. main ; >BIN
        \\      # 707 NODE ERS # 0 org : main 7. main ; >BIN ]ASM
        \\ 0 ARRAY DOWNWARD  708 ORGN 508 TO -1 ,
        \\ 0 ARRAY ACROSS  708 ORGN 608 TO 607 TO 707 TO -1 ,
        \\ 708 STREAM[   ' DOWNWARD COURSE
        \\    FRAME[  508 +NODE 508 /RAM 0 /P  608 +NODE 1608 /RAM 0 /P  708 +NODE 708 ITS ser-exec /P  ]FRAME
        \\    ' ACROSS COURSE
        \\    FRAME[  608 +NODE 608 /RAM 0 /P  707 +NODE 707 /RAM 0 /P  ]FRAME
        \\ ]STREAM
    , null, &programs, &descriptor_buffer, &diagnostic);
    var frame_buffer: [arrayforth.Stream.max_frames]streamer.Frame = undefined;
    const frames = assembled.frames(&frame_buffer);
    try expectEqual(2, frames.len);
    var part_buffer: [arrayforth.Stream.max_parts]streamer.Part = undefined;
    var buffer: [512]Word = undefined;
    const words = try streamer.stream(.ga144, assembled.parts(&part_buffer), assembled.programs, &buffer);
    // 608 is at 0 with its first frame's code before it is with its own
    const checked = [_]Descriptor{ frames[0].descriptors[0], frames[1].descriptors[0], frames[1].descriptors[1] };
    try expectEqual(608, checked[1].node);
    try expectBootsAsDescribed(parsed, &checked, .{ .uart = words }, assembled.programs, null);
}

test "a stream from root 300 boots through node 300's synchronous line, frame after frame" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    var programs: [4]Program = undefined;
    var descriptor_buffer: [8]Descriptor = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    // the first frame starts 500 and leaves 300 reading the next, which
    // starts 301 and loads 300 itself
    const assembled = try arrayforth.assembleScript(
        \\ STREAMER LOAD
        \\ ASM[ # 500 NODE ERS # 0 org : main 5. main ; >BIN
        \\      # 301 NODE ERS # 0 org : main 1. main ; >BIN
        \\      # 300 NODE ERS # 0 org : main 3. main ; >BIN ]ASM
        \\ 0 ARRAY UPWARD  300 ORGN 500 TO -1 ,
        \\ 0 ARRAY ACROSS  300 ORGN 301 TO -1 ,
        \\ 300 STREAM[   ' UPWARD COURSE
        \\    FRAME[  500 +NODE 500 /RAM 0 /P  300 +NODE 300 ITS ser-exec /P  ]FRAME
        \\    ' ACROSS COURSE
        \\    FRAME[  301 +NODE 301 /RAM 0 /P  300 +NODE 300 /RAM 0 /P  ]FRAME
        \\ ]STREAM
    , null, &programs, &descriptor_buffer, &diagnostic);
    try expectEqual(streamer.sync_exec, assembled.descriptors[1].p);
    var frame_buffer: [arrayforth.Stream.max_frames]streamer.Frame = undefined;
    const frames = assembled.frames(&frame_buffer);
    var part_buffer: [arrayforth.Stream.max_parts]streamer.Part = undefined;
    var buffer: [512]Word = undefined;
    const words = try streamer.stream(.ga144, assembled.parts(&part_buffer), assembled.programs, &buffer);
    const checked = [_]Descriptor{ frames[0].descriptors[0], frames[1].descriptors[0], frames[1].descriptors[1] };
    try expectEqual(300, checked[2].node);
    try expectBootsAsDescribed(parsed, &checked, .{ .sync = words }, assembled.programs, null);
}

test "a stream from root 207 boots its path as the snorkel sends it, 207 going on as it is" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    var programs: [4]Program = undefined;
    var descriptor_buffer: [8]Descriptor = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try arrayforth.assembleScript(
        \\ STREAMER LOAD
        \\ ASM[ # 209 NODE ERS # 0 org : main 9. main ; >BIN
        \\      # 210 NODE ERS # 0 org : main 10. main ; >BIN ]ASM
        \\ 0 ARRAY ALONG  207 ORGN 210 TO -1 ,
        \\ 207 STREAM[   ' ALONG COURSE
        \\    FRAME[  209 +NODE 209 /RAM 0 /P  210 +NODE 210 /RAM 0 /P  ]FRAME
        \\ ]STREAM
    , null, &programs, &descriptor_buffer, &diagnostic);
    var part_buffer: [arrayforth.Stream.max_parts]streamer.Part = undefined;
    var buffer: [512]Word = undefined;
    const words = try streamer.stream(.ga144, assembled.parts(&part_buffer), assembled.programs, &buffer);
    // 208, which pumps the rest on, and is left at warm
    const checked = [_]Descriptor{ assembled.descriptors[0], assembled.descriptors[1], .{ .node = 208, .b = Computer.io_address, .p = ga144.romWordOf(.basic, "warm").? } };
    try expectBootsAsDescribed(parsed, &checked, .{ .snorkel = .{ .words = words } }, assembled.programs, null);
}

test "the disk's sync master, bin 1901's 18o, clocks a word out as Sync does" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    const gpa = std.testing.allocator;
    const disk = try Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(disk);

    // node 300 with bin 1901 (block 2289), sending x2A5A5 with 18o, then
    // letting go of the line with off, and going back to warm
    const source =
        \\2289 LOAD
        \\300 +NODE 1901 /RAM  IO /B  1901 ITS 18o /P  x2A5A5. 1 /STACK  xA9. 1901 ITS off 0 2 /RSTACK
    ;
    const programs = try gpa.alloc(Program, Chip.Layout.chip_numbers);
    defer gpa.free(programs);
    var descriptor_buffer: [2]Descriptor = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = arrayforth.assembleScript(source, disk, programs, &descriptor_buffer, &diagnostic) catch |err| {
        std.debug.print("{t} at block {d} line {d} '{s}'\n", .{ err, (diagnostic.line -| 1) / 16, (diagnostic.line -| 1) % 16, diagnostic.token });
        return err;
    };
    const word: Word = @bitCast(@as(u18, 0x2a5a5));

    // the levels of the clock and the data at each edge of the clock
    const Edge = struct { clock: bool, data: bool };
    const Recorder = struct {
        clock: bool = false,
        data: bool = false,
        edges: [64]Edge = undefined,
        len: usize = 0,

        fn clockChanged(context: *anyopaque, _: u64, high: bool) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (high == self.clock) return;
            self.clock = high;
            self.edges[self.len] = .{ .clock = high, .data = self.data };
            self.len += 1;
        }

        fn dataChanged(context: *anyopaque, _: u64, high: bool) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.data = high;
        }
    };
    var recorder: Recorder = .{};
    var chip: Chip = try .init(gpa, .ga144);
    defer chip.deinit(gpa);
    try chip.loadRom(parsed);
    try chip.attachPin(.{ .node = 300, .pin = 17 }, .{ .context = &recorder, .changed = Recorder.clockChanged });
    try chip.attachPin(.{ .node = 300, .pin = 1 }, .{ .context = &recorder, .changed = Recorder.dataChanged });
    for (assembled.descriptors) |d| try chip.setUp(d, assembled.programs);
    try chip.run();
    try expect(Chip.waitsForCode(chip.node(300).?));

    // as Sync drives them, a line let go reading low
    var sync: Sync = .init(&.{word});
    const clock = sync.clockDevice();
    const data = sync.dataDevice();
    var expected: [64]Edge = undefined;
    var len: usize = 0;
    var time: u64 = 0;
    while (sync.nextClockEdge(time)) |edge| : (time = edge) {
        expected[len] = .{ .clock = clock.drive.?(clock.context, edge).high, .data = data.drive.?(data.context, edge).high };
        len += 1;
    }
    // up, then down and up for each two bits, and down as it lets go
    try expectEqual(1 + 2 * 9 + 1, len);
    try std.testing.expectEqualSlices(Edge, expected[0..len], recorder.edges[0..recorder.len]);
}

test "arrayForth 3's streams from root 207 boot as pF/144's snorkel sends them" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    const gpa = std.testing.allocator;
    const disk = try Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(disk);

    // up to their ]STREAM, before !SNORK sends them: block 1581's test of
    // descriptors, to 715, and block 1583's, which adds the NIC to pF/144,
    // with the clock monitor (?CLK 1) rather than the crystal oscillator
    // (2), whose descriptors load a bin 516 that nothing builds, after the
    // bins the NIC needs
    var sources: [2]Io.Writer.Allocating = .{ .init(gpa), .init(gpa) };
    defer for (&sources) |*source| source.deinit();
    try sources[1].writer.writeAll("1562 LOAD  STREAMER LOAD  1 CONSTANT ?CLK  1 CONSTANT ?ETH  2001 LOAD\n");
    for ([_]u16{ 1581, 1583 }, &sources, [_]usize{ 0, 2 }) |block, *source, first| {
        const text = disk[@as(usize, block) * 1024 ..][0..1024];
        for (first..16) |line| try source.writer.print("{s}\n", .{text[line * 64 ..][0..64]});
    }

    for (&sources) |*source| {
        const written = source.written();
        const text = written[0 .. std.mem.indexOf(u8, written, "]STREAM").? + "]STREAM".len];
        const programs = try gpa.alloc(Program, Chip.Layout.chip_numbers);
        defer gpa.free(programs);
        const descriptor_buffer = try gpa.alloc(Descriptor, Chip.Layout.chip_numbers);
        defer gpa.free(descriptor_buffer);
        var diagnostic: assembler.Diagnostic = .{};
        const assembled = arrayforth.assembleScript(text, disk, programs, descriptor_buffer, &diagnostic) catch |err| {
            std.debug.print("{s}: {t} at block {d} line {d} '{s}'\n", .{ text, err, (diagnostic.line -| 1) / 16, (diagnostic.line -| 1) % 16, diagnostic.token });
            return err;
        };
        try expectEqual(207, assembled.stream.?.root);
        var part_buffer: [arrayforth.Stream.max_parts]streamer.Part = undefined;
        const parts = assembled.parts(&part_buffer);
        const buffer = try gpa.alloc(Word, streamer.maxLen(parts));
        defer gpa.free(buffer);
        const words = try streamer.stream(.ga144, parts, assembled.programs, buffer);
        try expect(assembled.descriptors.len > 0);
        var first: usize = 0;
        while (first < assembled.descriptors.len) : (first += Chip.max_breakpoints) {
            const batch = assembled.descriptors[first..@min(first + Chip.max_breakpoints, assembled.descriptors.len)];
            expectBootsAsDescribed(parsed, batch, .{ .snorkel = .{ .words = words } }, assembled.programs, null) catch |err| {
                std.debug.print("{s}\n", .{text});
                return err;
            };
        }
    }
}

test "pF/144's serial boot, block 1665, describes the VM and sends its streams and nucleus" {
    const gpa = std.testing.allocator;
    const disk = Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer gpa.free(disk);

    // as arrayForth 3 does, with its configuration (block 1562) and all
    // its stock code assembled (2280), as DB006 5.2.2.2 asks
    const programs = try gpa.alloc(Program, Chip.Layout.chip_numbers);
    defer gpa.free(programs);
    const descriptor_buffer = try gpa.alloc(Descriptor, 4 * Chip.Layout.chip_numbers);
    defer gpa.free(descriptor_buffer);
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = arrayforth.assembleScript("1562 LOAD  2280 LOAD  1665 LOAD", disk, programs, descriptor_buffer, &diagnostic) catch |err| {
        std.debug.print("{t} at block {d} line {d} '{s}'\n", .{ err, (diagnostic.line -| 1) / 16, (diagnostic.line -| 1) % 16, diagnostic.token });
        return err;
    };
    // block 1666's stream, which resets the chip, then the nucleus, and
    // then block 1665's, which doesn't
    const sends = assembled.sends();
    try expectEqual(3, sends.len);
    try expectEqual(true, sends[0].stream.reset);
    try expectEqual(.nucleus, std.meta.activeTag(sends[1]));
    try expectEqual(false, sends[2].stream.reset);

    var frames: [arrayforth.Stream.max_frames]streamer.Frame = undefined;
    // the wires from 708 down to 108, and 108 to write the nucleus to the
    // SRAM, after the cluster's own nodes, 107, 7, 8 and 9
    const nuc = assembled.framesOf(&sends[0].stream.stream, &frames);
    try expectEqual(1, nuc.len);
    try expectEqualSlices(u16, &.{ 708, 608, 508, 408, 308, 208, 108, 107, 7, 8, 9 }, nuc[0].path);
    const wire = findDescriptor(nuc[0].descriptors, 408).?;
    try expectEqual(1711, wire.loads[0].bin);
    try expectEqual(1713, findDescriptor(nuc[0].descriptors, 108).?.loads[0].bin);

    // the VM, as blocks 1981 and 1982 describe it: the bitsy, the stack,
    // the buds, the serial nodes, the snorkel and the SPI flash's 705
    const vm = assembled.framesOf(&sends[2].stream.stream, &frames);
    try expectEqual(1, vm.len);
    const bitsy = findDescriptor(vm[0].descriptors, 105).?;
    try expectEqual(1703, bitsy.loads[0].bin);
    try expectEqualSlices(Word, &.{ 0xffe0, 0x15555, 1 }, bitsy.stack[0..bitsy.stack_len]);
    for ([_]struct { u16, u32 }{ .{ 106, 1700 }, .{ 206, 1702 }, .{ 205, 1705 }, .{ 6, 1701 }, .{ 5, 1704 }, .{ 100, 1706 }, .{ 200, 1707 }, .{ 207, 1605 }, .{ 705, 1606 } }) |node_bin| {
        try expectEqual(node_bin[1], findDescriptor(vm[0].descriptors, node_bin[0]).?.loads[0].bin);
    }
    // /WIRE's -1 ?RAM ! replaced 101's ganglion with the wire
    const serial_wire = findDescriptor(vm[0].descriptors, 101).?;
    try expectEqual(1, serial_wire.load_count);
    try expectEqual(1709, serial_wire.loads[0].bin);
    try expectEqual(0xaa, findDescriptor(vm[0].descriptors, 708).?.p);

    // the 2-chip boot, block 1662, sends the bridge's stream too, which
    // fills the sends there are room for
    const two = try arrayforth.assembleScript("1562 LOAD  2280 LOAD  1662 LOAD", disk, programs, descriptor_buffer, &diagnostic);
    try expectEqual(arrayforth.Send.max, two.sends().len);
    // and softsim's, block 1674, describes the VM with no stream, once the
    // STREAMER is loaded, as softsim loads it, as far as its crystal
    // oscillator (?CLK 2), whose descriptors load a bin 516 that nothing
    // builds, as with block 1583
    try expectError(error.NoSuchBin, arrayforth.assembleScript("1562 LOAD  2280 LOAD  STREAMER LOAD  1674 LOAD", disk, programs, descriptor_buffer, &diagnostic));
}

fn findDescriptor(descriptors: []const Descriptor, node: u16) ?*const Descriptor {
    for (descriptors) |*d| if (d.node == node) return d;
    return null;
}

test "arrayForth 3's stream for flash, after block 1671, boots through the EVB002's flash and SRAM as described" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    const gpa = std.testing.allocator;
    const disk = try Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(disk);

    // block 1671 without the polyFORTH VM, which the block 1665 test
    // describes, and with the NIC, as the 708 test has it, so that the second
    // frame describes nodes, after the bins it loads: the speed-up (block
    // 2286), 705's flash boot and the wires to the SRAM (2295, 2296), and
    // the SRAM cluster's (2331). Block 1672's
    // frame sets up the wires and 108 to take pF/144's nucleus from flash
    // x20000 to the SRAM, and leaves 705 in bin 1710's start, which copies
    // it and then reads the next frame where FORWARD says.
    const source =
        \\1562 LOAD  2331 LOAD  2286 LOAD  2295 LOAD  2296 LOAD
        \\STREAMER LOAD  1 CONSTANT ?CLK  1 CONSTANT ?ETH  2001 LOAD
        \\705 STREAM[
        \\   ( Speedup)  0 0 3 1608 /ROOT
        \\   ( Nucleus to SRAM)  1672 LOAD
        \\   FRAME[  ( Residual) SRAM 2 + LOAD  ' s705 COURSE
        \\      ( Async bootable)  708 +NODE xAA /P
        \\      ( Clock/Ether)  ENIC 1+ LOAD
        \\   ]FRAME
        \\]STREAM
    ;
    // on the heap, as with the interpreter they would overflow the 1 MB
    // stack a test has on Windows
    const programs = try gpa.alloc(Program, Chip.Layout.chip_numbers);
    defer gpa.free(programs);
    const descriptor_buffer = try gpa.alloc(Descriptor, 4 * Chip.Layout.chip_numbers);
    defer gpa.free(descriptor_buffer);
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = arrayforth.assembleScript(source, disk, programs, descriptor_buffer, &diagnostic) catch |err| {
        std.debug.print("{t} at block {d} line {d} '{s}'\n", .{ err, (diagnostic.line -| 1) / 16, (diagnostic.line -| 1) % 16, diagnostic.token });
        return err;
    };
    var part_buffer: [arrayforth.Stream.max_parts]streamer.Part = undefined;
    const parts = assembled.parts(&part_buffer);
    try expectEqual(4, parts.len);
    try expectEqual(1608, parts[0].root.bin);
    try expectEqual(.forward, std.meta.activeTag(parts[2]));
    // the first frame along df705, and the second along s705, which keeps
    // off the SRAM cluster
    try expectEqual(144, parts[1].frame.path.len);
    try expectEqual(140, parts[3].frame.path.len);

    const words = try gpa.alloc(Word, streamer.maxLen(parts));
    defer gpa.free(words);
    const stream_words = try streamer.stream(.ga144, parts, assembled.programs, words);
    // the stream at 0, and at x20000 a nucleus of one word, 16 bits of a
    // count less 1 and the word
    const image = try gpa.alloc(u8, 0x20004);
    defer gpa.free(image);
    @memset(image, 0xff);
    _ = try streamer.pack(stream_words, image);
    image[0x20000..][0..4].* = .{ 0, 0, 0x12, 0x34 };

    // each node of the first frame, but 705 and 708, starts as described
    const checked_buffer = try gpa.alloc(Descriptor, Chip.Layout.chip_numbers);
    defer gpa.free(checked_buffer);
    var checked_len: usize = 0;
    for (parts[1].frame.descriptors) |d| if (d.node != 705 and d.node != 708) {
        checked_buffer[checked_len] = d;
        checked_len += 1;
    };
    try expectEqual(13, checked_len);
    const sram_words = try gpa.alloc(u16, Sram.evb002_words);
    defer gpa.free(sram_words);
    @memset(sram_words, 0xffff);
    try expectBootsAsDescribed(parsed, checked_buffer[0..checked_len], .{ .flash = image }, assembled.programs, sram_words);

    // and with the nucleus through the wires to 108, which stores it to the
    // SRAM, 705 reads the second frame where FORWARD patched into its RAM:
    // the first frame's nodes that it does not reach, the SRAM cluster, and
    // each node it describes, start as described
    checked_len = 0;
    for (parts[1].frame.descriptors) |d| if (d.node != 705 and d.node != 708 and std.mem.indexOfScalar(u16, parts[3].frame.path, d.node) == null) {
        checked_buffer[checked_len] = d;
        checked_len += 1;
    };
    try expectEqual(4, checked_len);
    for (parts[3].frame.descriptors) |d| if (d.node != 705 and d.node != 708) {
        checked_buffer[checked_len] = d;
        checked_len += 1;
    };
    try expectEqual(4 + 30, checked_len);
    var first: usize = 0;
    while (first < checked_len) : (first += Chip.max_breakpoints) {
        @memset(sram_words, 0xffff);
        try expectBootsAsDescribed(parsed, checked_buffer[first..@min(first + Chip.max_breakpoints, checked_len)], .{ .flash = image }, assembled.programs, sram_words);
    }
    // by when the last of the second frame's nodes start, the nucleus is in
    // the SRAM, its count less 1 at 0 and its word next, at 4, as node 009
    // puts addresses on the bus shifted up 2
    try expectEqual(0, sram_words[0]);
    try expectEqual(0x1234, sram_words[4]);
    // and nothing else is written
    try expectEqual(sram_words.len - 2, std.mem.count(u16, sram_words, &.{0xffff}));

    // FORWARD's address, in the first frame's root frame, which loads all
    // of 705's RAM from bin 1710, is where the second frame starts
    const second = std.mem.lastIndexOfScalar(Word, stream_words, 0x10000 | @as(Word, streamer.spi_exec)).?;
    const root_ram = std.mem.lastIndexOf(Word, stream_words[0..second], &.{ 0, 64 }).? + 2;
    const fwd: u18 = @bitCast(stream_words[root_ram + 0x23]);
    try expectEqual(second * 18 / 8, fwd >> 2);
    // which is the x3A38 that bin 1710's source has for fwd, as FORWARD
    // patched it when the disk's stream was built: the speed-up and the
    // first frame, 1651 words, pad to 1656, as the STREAMER's did, so they
    // end in the same 8 words as its
    try expectEqual(0x3a38, fwd);
    try expectEqual(1656, second);
    var unpadded = second;
    while (stream_words[unpadded - 1] == 0) unpadded -= 1;
    try expectEqual(1651, unpadded);
}

test "arrayForth 3's two-chip stream for flash, block 1668, boots the target through the EVB002's sync bridge as described" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    const gpa = std.testing.allocator;
    const disk = try Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(disk);

    // block 1668 as the block 1671 test has it, without the polyFORTH VM
    // and with the NIC, and with the block's own test of two target nodes,
    // after the bins it loads, the bridge's among them: the loader on host
    // 400 (block 2290), the bridge on host 300 and target 300 (2287) and
    // the sync master that loads the target's (2289)
    const source =
        \\1562 LOAD  2331 LOAD  2286 LOAD  2295 LOAD  2296 LOAD
        \\2287 LOAD  2289 LOAD  2290 LOAD
        \\STREAMER LOAD  1 CONSTANT ?CLK  1 CONSTANT ?ETH  2001 LOAD
        \\1669 LOAD
        \\705 STREAM[   ' sr705 COURSE
        \\   ( Speedup)  0 0 3 1608 /ROOT
        \\   ( Nucleus to SRAM)  1672 LOAD
        \\   ( Build bridge)  ' br705 COURSE  1670 LOAD
        \\   FRAME[  ( Residual) SRAM 2 + LOAD  ' ss705 COURSE
        \\      ( Async bootable)  708 +NODE xAA /P
        \\      ( Test)  10500 +NODE x30000. /IO  10100 +NODE x30000. /IO
        \\      ( Clock/Ether)  ENIC 1+ LOAD
        \\   ]FRAME
        \\]STREAM
    ;
    const programs = try gpa.alloc(Program, Chip.Layout.chip_numbers);
    defer gpa.free(programs);
    const descriptor_buffer = try gpa.alloc(Descriptor, 4 * Chip.Layout.chip_numbers);
    defer gpa.free(descriptor_buffer);
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = arrayforth.assembleScript(source, disk, programs, descriptor_buffer, &diagnostic) catch |err| {
        std.debug.print("{t} at block {d} line {d} '{s}'\n", .{ err, (diagnostic.line -| 1) / 16, (diagnostic.line -| 1) % 16, diagnostic.token });
        return err;
    };
    var part_buffer: [arrayforth.Stream.max_parts]streamer.Part = undefined;
    const parts = assembled.parts(&part_buffer);
    try expectEqual(6, parts.len);
    try expectEqual(.forward, std.meta.activeTag(parts[2]));
    try expectEqual(.forward, std.meta.activeTag(parts[4]));
    // the bridge's frame, along br705 to host 300, and the last, along
    // ss705, which keeps off the bridge's 300s and crosses from host 400 to
    // target 400
    const bridge = parts[3].frame;
    try expectEqual(300, bridge.path[bridge.path.len - 1]);
    const last = parts[5].frame;
    try expectEqual(282, last.path.len);
    const crossing = std.mem.indexOfScalar(u16, last.path, 10400).?;
    try expectEqual(400, last.path[crossing - 1]);
    try expectEqual(null, std.mem.indexOfScalar(u16, last.path, 300));
    try expectEqual(null, std.mem.indexOfScalar(u16, last.path, 10300));
    // the target's nodes the block's test describes, after 708's
    try expectEqualSlices(u16, &.{ 708, 10500, 10100 }, &.{ last.descriptors[0].node, last.descriptors[1].node, last.descriptors[2].node });

    const words = try gpa.alloc(Word, streamer.maxLen(parts));
    defer gpa.free(words);
    const stream_words = try streamer.stream(Board.evb002.layout(.ga144), parts, assembled.programs, words);
    // the stream at 0, and at x20000 a nucleus of one word, as in the block
    // 1671 test
    const image = try gpa.alloc(u8, 0x20004);
    defer gpa.free(image);
    @memset(image, 0xff);
    _ = try streamer.pack(stream_words, image);
    image[0x20000..][0..4].* = .{ 0, 0, 0x12, 0x34 };
    const sram_words = try gpa.alloc(u16, Sram.evb002_words);
    defer gpa.free(sram_words);

    // the bridge's nodes start as described: host 400 at bin 1907's start,
    // which resets the target, loads bin 1904 into target 300 through host
    // 300's sync master, and then into host 300; and then, through the
    // bridge, the last frame's, the target's 500 and 100 among them
    for ([_][]const Descriptor{ bridge.descriptors, last.descriptors }, [_]usize{ 3, 32 }) |descriptors, count| {
        var checked: [Chip.max_breakpoints]Descriptor = undefined;
        var len: usize = 0;
        for (descriptors) |d| if (d.node != 705 and d.node != 708) {
            checked[len] = d;
            len += 1;
        };
        try expectEqual(count, len);
        @memset(sram_words, 0xffff);
        try expectBootsAsDescribed(parsed, checked[0..len], .{ .flash = image }, assembled.programs, sram_words);
    }
}

test "arrayForth 3's two-chip test, block 1582, boots target 500 from root 207 through the EVB002's sync bridge" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    const gpa = std.testing.allocator;
    const disk = try Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(disk);
    const programs = try gpa.alloc(Program, Chip.Layout.chip_numbers);
    defer gpa.free(programs);
    const descriptor_buffer = try gpa.alloc(Descriptor, Chip.Layout.chip_numbers);
    defer gpa.free(descriptor_buffer);
    var diagnostic: assembler.Diagnostic = .{};
    var discarding: Io.Writer.Discarding = .init(&.{});
    var session: arrayforth.Session = .init(programs, descriptor_buffer, &diagnostic, .{ .out = &discarding.writer, .blocks = disk });

    // the bridge, as the IDE erects it (block 1623's SPAN) or block 1670's
    // frame sets it up, without its 705 (whose bin 1710 is block 2295's)
    // and 708: host 400's loader, 500 with the bridge's bin to read, and
    // 300's sync master
    var sources: [2]Io.Writer.Allocating = .{ .init(gpa), .init(gpa) };
    defer for (&sources) |*source| source.deinit();
    try sources[0].writer.writeAll("1562 LOAD  2287 LOAD  2289 LOAD  2290 LOAD  2295 LOAD  STREAMER LOAD  1669 LOAD\n705 STREAM[  ' br705 COURSE\n");
    // and block 1582, up to its ]STREAM, before !SNORK sends it
    for ([_]u16{ 1670, 1582 }, &sources) |block, *source| {
        const text = disk[@as(usize, block) * 1024 ..][0..1024];
        for (0..16) |line| try source.writer.print("{s}\n", .{text[line * 64 ..][0..64]});
    }
    const bridge_source = sources[0].written();
    const bridge_text = try std.fmt.allocPrint(gpa, "{s} ]STREAM", .{bridge_source[0 .. std.mem.indexOf(u8, bridge_source, "]FRAME").? + "]FRAME".len]});
    defer gpa.free(bridge_text);
    var set_up: [3]Descriptor = undefined;
    var set_up_len: usize = 0;
    session.interpret(bridge_text) catch |err| {
        std.debug.print("{t} at line {d} '{s}'\n", .{ err, diagnostic.line, diagnostic.token });
        return err;
    };
    for (session.assembled().descriptors) |d| if (d.node != 705 and d.node != 708) {
        set_up[set_up_len] = d;
        // a frame leaves a node's return stack with where it executes
        // from, a port it reads 400 from, which 300's off returns to
        if (d.node == 300) {
            set_up[set_up_len].return_stack[0] = port.multiport(.initOne(.up));
            set_up[set_up_len].return_stack_len = 1;
        }
        set_up_len += 1;
    };
    try expectEqual(3, set_up_len);

    const written = sources[1].written();
    session.interpret(written[0 .. std.mem.indexOf(u8, written, "]STREAM").? + "]STREAM".len]) catch |err| {
        std.debug.print("{t} at line {d} '{s}'\n", .{ err, diagnostic.line, diagnostic.token });
        return err;
    };
    try session.finish();
    const assembled = session.assembled();
    var part_buffer: [arrayforth.Stream.max_parts]streamer.Part = undefined;
    const parts = assembled.parts(&part_buffer);
    // from 207 along row 4 to host 400, and on to target 400 and 500
    try expectEqualSlices(u16, &.{ 207, 307, 407, 406, 405, 404, 403, 402, 401, 400, 10400, 10500 }, parts[0].frame.path);
    try expectEqual(10500, assembled.descriptors[0].node);
    const buffer = try gpa.alloc(Word, streamer.maxLen(parts));
    defer gpa.free(buffer);
    const words = try streamer.stream(Board.evb002.layout(.ga144), parts, assembled.programs, buffer);
    try expectBootsAsDescribed(parsed, assembled.descriptors, .{ .snorkel = .{ .words = words, .set_up = set_up[0..set_up_len] } }, assembled.programs, null);
}

test "arrayForth 3's SRAM cluster writes the EVB002's SRAM and reads it back" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    const gpa = std.testing.allocator;
    const disk = try Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(disk);

    // the cluster's bins and descriptors (blocks 2331 and 2332), and a
    // master on 108 with block 2337's words, which reads each word after
    // the cluster's 007 has sent 008 stop, ending the read cycle, from the
    // charge the SRAM left on the data bus (block 4735)
    const source =
        \\1562 LOAD  2331 LOAD  2332 LOAD
        \\1999 108 ASM[ NODE BIN ERS  # 0 org
        \\: x! ( n a)  dup dup xor  : ex! ( n da)  : mk! ( m f -p)  inv !b inv !b !b ;
        \\: x@ ( a - n)  dup dup xor  : ex@ ( da - n)  !b !b @b ;
        \\: go  x1234. 4. x!  x5678. 6. x!  4. x@  6. x@  begin end
        \\>BIN ]ASM
        \\108 +NODE  1999 /RAM  LEFT /B  1999 ITS go /P
    ;
    const programs = try gpa.alloc(Program, Chip.Layout.chip_numbers);
    defer gpa.free(programs);
    var descriptor_buffer: [8]Descriptor = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = arrayforth.assembleScript(source, disk, programs, &descriptor_buffer, &diagnostic) catch |err| {
        std.debug.print("{t} at block {d} line {d} '{s}'\n", .{ err, (diagnostic.line -| 1) / 16, (diagnostic.line -| 1) % 16, diagnostic.token });
        return err;
    };
    try expectEqual(5, assembled.descriptors.len);

    var chip: Chip = try .init(gpa, .ga144);
    defer chip.deinit(gpa);
    try chip.loadRom(parsed);
    const sram_words = try gpa.alloc(u16, Sram.evb002_words);
    defer gpa.free(sram_words);
    @memset(sram_words, 0);
    var sram: Sram = .init(sram_words);
    try Board.evb002.attachSram(&chip, &sram, &.{});
    for (assembled.descriptors) |d| try chip.setUp(d, assembled.programs);
    for (0..100_000) |_| _ = chip.step();

    const master = chip.node(108).?;
    try expectEqual(0x5678, master.data_stack.t);
    try expectEqual(0x1234, master.data_stack.s);
    // at 4 and 6 shifted up 2, as 009 puts them on the bus
    try expectEqual(0x1234, sram_words[4 << 2]);
    try expectEqual(0x5678, sram_words[6 << 2]);
    try expectEqual(sram_words.len - 2, std.mem.count(u16, sram_words, &.{0}));
}

/// Boots the EVB002's host chip, node 708 with a stream through USB port A,
/// node 705 from the contents of its flash, with J26 (NO BOOT) off, node
/// 300 from a synchronous line's master on its pins, with J34 and J35 off,
/// or nodes from 207 as its snorkel would (`Snorkel`), after setting up the
/// nodes of `set_up`, and checks that each node of `checked` starts as its
/// descriptor says. The board's SRAM holds `sram_words`, if given, or else
/// words of its own.
fn expectBootsAsDescribed(roms: []const ga144.NodeRom, checked: []const Descriptor, from: union(enum) { uart: []const Word, flash: []const u8, sync: []const Word, snorkel: struct { words: []const Word, set_up: []const Descriptor = &.{} } }, programs: []const Program, sram_words: ?[]u16) !void {
    const gpa = std.testing.allocator;
    var chip: Chip = try .initChips(gpa, .ga144, Board.evb002.chips);
    defer chip.deinit(gpa);
    try chip.loadRom(roms);
    const own_words: ?[]u16 = if (sram_words == null) try gpa.alloc(u16, Sram.evb002_words) else null;
    defer if (own_words) |words| gpa.free(words);
    if (own_words) |words| @memset(words, 0);
    var sram: Sram = .init(sram_words orelse own_words.?);

    const words = if (from == .uart) from.uart else &.{};
    const bytes = try gpa.alloc(u8, 3 * words.len);
    defer gpa.free(bytes);

    var discarding: Io.Writer.Discarding = .init(&.{});
    const port_a = Board.evb002.serialPort("A").?;
    var uart: Uart = .init(port_a.baud, &discarding.writer);
    uart.preload = asyncBytes(words, bytes);
    var fault: Board.Fault = .none;
    const settings: []const Board.Setting = switch (from) {
        .flash => &.{.{ .name = "J26", .on = false }},
        .sync => &.{ .{ .name = "J34", .on = false }, .{ .name = "J35", .on = false } },
        else => &.{},
    };
    try Board.evb002.apply(&chip, &.{.{ .uart = &uart, .port = port_a }}, settings, &fault);
    var flash: Flash = .init(if (from == .flash) from.flash else &.{});
    if (from == .flash) try Board.evb002.attachFlash(&chip, &flash, settings);
    var sync: Sync = .init(if (from == .sync) from.sync else &.{});
    if (from == .sync) try chip.attachSyncPins(&sync, .{ .node = 300, .pin = 17 }, .{ .node = 300, .pin = 1 });
    var snorkel: Snorkel = .{ .words = if (from == .snorkel) from.snorkel.words else &.{} };
    if (from == .snorkel) for (from.snorkel.set_up) |d| try chip.setUp(d, programs);
    try Board.evb002.attachSram(&chip, &sram, settings);
    for (checked) |d| try chip.breakpoints.insert(.init(chip.layout.index(d.node).?, @truncate(d.p)));

    // a node that starts at a port, as the NIC's 616 does at its left
    // one, may have executed from that port while it booted, so a node has
    // started once it is at P, set up as its descriptor says. The run is
    // bounded, as one that never is would loop through P, or never get
    // there, while the nodes that have started run on.
    const differences = try gpa.alloc(?[]const u8, checked.len);
    defer gpa.free(differences);
    @memset(differences, null);
    var started: usize = 0;
    var stops: usize = 0;
    var rounds: usize = 0;
    while (started < checked.len) : (stops += 1) {
        // as `Chip.run` does, without waiting for more input than the
        // UART's preloaded stream
        chip.hit = null;
        while (chip.hit == null and stops < max_stops and rounds < max_rounds) : (rounds += 1) {
            const fed = snorkel.feed(&chip);
            _ = try chip.service();
            if (!chip.step() and !fed) break;
        }
        const stop = chip.hit orelse {
            for (checked, differences) |d, difference| if (chip.breakpoints.contains(.init(chip.layout.index(d.node).?, @truncate(d.p)))) {
                if (difference) |what|
                    std.debug.print("node {f} reached {x:0>3} with its {s} otherwise than as\n{f}", .{ Chip.nodeName(d.node), d.p, what, d })
                else
                    std.debug.print("node {f} never reached {x:0>3}\n", .{ Chip.nodeName(d.node), d.p });
            };
            return error.NotStarted;
        };
        const index = stop.breakpoint.index;
        const node_number = chip.layout.nodeNumber(index);
        for (checked, differences) |d, *difference| if (d.node == node_number) {
            difference.* = startDifference(&chip.nodes[index], d, programs);
            if (difference.* == null) {
                _ = try chip.breakpoints.toggle(stop.breakpoint);
                started += 1;
            }
        };
    }
}

/// Stands in for pF/144's snorkel in node 207, which writes a stream from
/// root 207 to the port of its path's next node: each word as 207 executes
/// `! ;` from its port, with the word on its stack and A at that port, the
/// one the stream's first word calls
const Snorkel = struct {
    words: []const Word,
    next: usize = 0,

    /// gives 207 the next word if it waits for code; returns whether it did
    fn feed(self: *Snorkel, chip: *Chip) bool {
        if (self.next == self.words.len) return false;
        const i = chip.layout.index(207).?;
        const n = &chip.nodes[i];
        if (!Chip.waitsForCode(n)) return false;
        n.a = self.words[0] & 0x1ff;
        n.data_stack.push(self.words[self.next]);
        chip.execute(i, Instruction.encode(.{ .slot_0 = .@"!", .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 })) catch unreachable;
        self.next += 1;
        return true;
    }
};

/// how many times nodes may reach where they start, and rounds of the chip
/// they may take, before they have all started
const max_stops = 1000;
const max_rounds = 30_000_000;

/// what of node `n`, about to fetch its next word, is not as `d` sets it
/// up, if anything
fn startDifference(n: *const Computer, d: Descriptor, programs: []const Program) ?[]const u8 {
    for (d.loads[0..d.load_count]) |load| {
        const program = findBin(programs, load.bin).?;
        if (!std.mem.eql(Word, program.ram[load.source..][0..load.len], n.mem[load.destination..][0..load.len])) return "RAM";
    }
    if (d.a) |a| if (a != n.a) return "A";
    if (d.b) |b| if (@as(u9, @truncate(@as(u18, @bitCast(b)))) != n.b) return "B";
    if (d.io) |io| if (io != n.io) return "IO";
    // the values pushed, the last on top
    var data = n.data_stack;
    var k = d.stack_len;
    while (k > 0) : (k -= 1) if (d.stack[k - 1] != data.pop()) return "stack";
    var returns = n.return_stack;
    k = d.return_stack_len;
    while (k > 0) : (k -= 1) if (d.return_stack[k - 1] != returns.pop()) return "return stack";
    if (d.p != @as(u10, @bitCast(n.p))) return "P";
    return null;
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

test "what a source without descriptors loads, and what it uses of ROM" {
    var programs: [2]Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes("node 0\ndup\nnode 1\nwarm\n", &programs, &diagnostic);
    var buffer: [2]Descriptor = undefined;
    const descriptors = ownDescriptors(assembled, &buffer);
    try expectEqual(2, descriptors.len);
    try expectEqual(1, descriptors[1].node);

    try expectEqual(null, romUse(descriptors[0..1], assembled));
    try expectEqualStrings("warm", romUse(descriptors, assembled).?.word.token);
    // warm, where a node that is not set up starts
    var in_rom = descriptors[0];
    in_rom.p = 0xa9;
    try expectEqual(0, romUse(&.{in_rom}, assembled).?.start.node);
}

const arrayforth = @import("arrayforth.zig");
const assembler = @import("assembler.zig");
const Board = @import("Board.zig");
const Program = assembler.Program;
const Console = @import("Console.zig");
const Uart = @import("Uart.zig");
const Flash = @import("Flash.zig");
const Sram = @import("Sram.zig");
const Sync = @import("Sync.zig");
const ga144 = @import("ga144.zig");
const testRom = @import("rom.zig").testRom;
const streamer = @import("streamer.zig");
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
