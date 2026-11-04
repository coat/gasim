//! Boot streams laid out as arrayForth 3's STREAMER (blocks 1602 to 1618 of
//! its disk) lays them out for node 708's ROM, rather than as `boot` does.
//!
//! The STREAMER boots nodes along a path, a line of neighbours from the
//! root, instead of a tree. A frame for the root's ROM writes the rest of
//! the frame to the path's next node, which executes it from that port.
//! Each node on the path copies, with a pump, what is for the nodes past it
//! to the next one, and then sets itself up. The nodes are set up from the
//! end of the path back, and every node on it is: those without a
//! descriptor have B addressing IO and start at warm, as FRAME[ leaves
//! them. A second frame then loads the root and jumps to where it starts.

/// node 708's default path (df708, block 1612), the ENTIRE chip, as its
/// corners
pub const entire: [18]u16 = .{ 708, 717, 17, 0, 100, 116, 216, 200, 300, 316, 416, 400, 500, 516, 616, 600, 700, 707 };

/// Draws a path into `buffer` as arrayForth 3's ORGN and TO do: from the
/// first of `corners`, a line along a row or a column to each next one
pub fn draw(corners: []const u16, buffer: []u16) error{ NotInLine, PathTooLong }![]u16 {
    if (corners.len == 0) return buffer[0..0];
    if (buffer.len == 0) return error.PathTooLong;
    buffer[0] = corners[0];
    var len: usize = 1;
    for (corners[1..]) |corner| {
        const from: i32 = buffer[len - 1];
        const difference = @as(i32, corner) - from;
        // KOUNT: a whole number of rows, or of columns within one
        const distance = @abs(difference);
        if ((distance / 100 == 0) == (distance % 100 == 0)) return error.NotInLine;
        const step: i32 = (if (distance % 100 == 0) @as(i32, 100) else 1) * std.math.sign(difference);
        var node = from;
        while (node != corner) {
            node += step;
            if (len == buffer.len) return error.PathTooLong;
            buffer[len] = @intCast(node);
            len += 1;
        }
    }
    return buffer[0..len];
}

pub const Error = error{
    /// the path does not start at node 708, the only root built here
    UnknownRoot,
    PathTooShort,
    NoSuchNode,
    NotNeighbours,
    RepeatedNode,
    /// a descriptor is for a node off the path, which the STREAMER would
    /// leave as it is
    NotOnPath,
    /// the root's ROM can store one part of RAM, in place
    RootTooManyLoads,
    RootNotInPlace,
    NoSuchBin,
    StreamTooLong,
};

/// The most words `stream` can take for a path of `path_len` nodes, to size
/// its buffer
pub fn maxLen(path_len: usize, descriptors: []const Descriptor) usize {
    // the frame's header and its first call, a pump and a default set up
    // for each node, and the root's frame
    var len = 4 + path_len * (5 + 3) + 3 + 64;
    for (descriptors) |d| {
        for (d.loads[0..d.load_count]) |load| len += 5 + load.len;
        len += psiz(d);
    }
    return len;
}

/// Builds a stream into `buffer` that sets up the nodes on `path` as
/// `descriptors` say, from the bins of `programs`, as one FRAME[ and
/// ]FRAME of the STREAMER do for root 708.
///
/// As the STREAMER does, the root's descriptor only says what to load into
/// its RAM, from one bin to the same addresses, and where it starts: its
/// registers and stacks are left as they are. A root without a load stores
/// the first word of bin 0, or 0 when that bin was not saved, at its RAM
/// address 0. Unlike the STREAMER, a descriptor for a node off the path
/// is an error. The descriptors are taken as they are, so they should
/// carry FRAME['s defaults, as those of gasim's arrayForth do: one without
/// a B, as from `Descriptor.ofProgram`, leaves B as it is, where the
/// STREAMER sets it to IO.
pub fn stream(
    layout: Chip.Layout,
    path: []const u16,
    descriptors: []const Descriptor,
    programs: []const Program,
    buffer: []Word,
) Error![]Word {
    if (path.len < 2) return error.PathTooShort;
    if (path[0] != 708) return error.UnknownRoot;
    for (path, 0..) |node, i| {
        _ = layout.index(node) orelse return error.NoSuchNode;
        if (std.mem.indexOfScalar(u16, path[0..i], node) != null) return error.RepeatedNode;
        if (i > 0) _ = try wall(layout, path[i - 1], node);
    }
    for (descriptors) |d| {
        if (std.mem.indexOfScalar(u16, path, d.node) == null) return error.NotOnPath;
        for (d.loads[0..d.load_count]) |load| _ = boot.findBin(programs, load.bin) orelse return error.NoSuchBin;
    }

    var builder: Builder = .{ .buffer = buffer };
    // #FRAME: the first call, a pump for each node that passes the frame
    // on, and each node's loads and set up
    var len: usize = 1 + 5 * (path.len - 2);
    for (path[1..]) |node| len += init(descriptorOf(descriptors, node));
    if (len > std.math.maxInt(u18)) return error.StreamTooLong;

    // asyORG: the root writes the frame to the path's next node, which
    // executes from that port, and then reads another frame
    try builder.word(boot.read_frame | jump);
    try builder.word(try wall(layout, path[0], path[1]));
    try builder.word(@bitCast(@as(u18, @intCast(len))));
    try builder.word(call | try wall(layout, path[0], path[1]));

    // +PUMP: each node keeps its own loads and set up, the last of what it
    // is sent, and copies the rest on, after focusing the next node too
    var rest = len - 1;
    for (1..path.len - 1) |i| {
        rest -= init(descriptorOf(descriptors, path[i])) + 5;
        try builder.instruction(.{ .slot_0 = .@"@p", .slot_1 = .dup, .slot_2 = .@"a!", .slot_3 = @intCast(@backingInt(Opcode.@"@p") >> 2) });
        try builder.word(call | try wall(layout, path[i], path[i + 1]));
        try builder.word(@bitCast(@as(u18, @intCast(rest - 1))));
        try builder.instruction(.{ .slot_0 = .@">r", .slot_1 = .@"!", .slot_2 = .@".", .slot_3 = nop });
        try builder.instruction(.{ .slot_0 = .@"@p", .slot_1 = .@"!", .slot_2 = .unext, .slot_3 = nop });
    }

    // from the end of the path back, +LOADS and +POST
    var i = path.len - 1;
    while (i > 0) : (i -= 1) {
        const d = descriptorOf(descriptors, path[i]);
        for (d.loads[0..d.load_count]) |load| {
            try builder.instruction(.{ .slot_0 = .@"@p", .slot_1 = .@"a!", .slot_2 = .@"@p", .slot_3 = nop });
            try builder.word(load.destination);
            try builder.word(@as(Word, load.len) - 1);
            try builder.instruction(.{ .slot_0 = .@">r", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = nop });
            try builder.instruction(.{ .slot_0 = .@"@p", .slot_1 = .@"!+", .slot_2 = .unext, .slot_3 = nop });
            const program = boot.findBin(programs, load.bin).?;
            for (program.ram[load.source..][0..load.len]) |w| try builder.word(w);
        }
        if (d.io) |io| {
            try builder.literal(.@"b!", Computer.io_address);
            try builder.literal(.@"!b", io);
        }
        if (d.a) |a| try builder.literal(.@"a!", a);
        if (d.b) |b| try builder.literal(.@"b!", b);
        for (d.return_stack[0..d.return_stack_len]) |value| try builder.literal(.@">r", value);
        for (d.stack[0..d.stack_len]) |value| try builder.literal(.@".", value);
        try builder.word(jump | @as(Word, d.p));
    }

    // serEND and +ROOT: the root's frame
    const root = descriptorOf(descriptors, path[0]);
    if (root.load_count > 1) return error.RootTooManyLoads;
    const load: Descriptor.Load = if (root.load_count == 1) root.loads[0] else .{ .bin = 0, .len = 0 };
    if (load.source != load.destination) return error.RootNotInPlace;
    const count = @max(load.len, 1);
    try builder.word(jump | @as(Word, root.p));
    try builder.word(load.destination);
    try builder.word(count);
    const bin: ?[]const Word = if (boot.findBin(programs, load.bin)) |program| &program.ram else null;
    for (@as(usize, load.destination)..@as(usize, load.destination) + count) |address| try builder.word(if (bin) |ram| ram[address] else 0);
    return buffer[0..builder.len];
}

/// the descriptor of a node, or what FRAME[ leaves it with
fn descriptorOf(descriptors: []const Descriptor, node: u16) Descriptor {
    for (descriptors) |d| if (d.node == node) return d;
    return .{ .node = node, .b = Computer.io_address, .p = ga144.romWordOf(.basic, "warm").? };
}

/// INITS: the words that load a node and set it up, LSIZ and PSIZ
fn init(d: Descriptor) usize {
    var len = psiz(d);
    for (d.loads[0..d.load_count]) |load| len += 5 + load.len;
    return len;
}

fn psiz(d: Descriptor) usize {
    var len: usize = 1;
    if (d.io != null) len += 4;
    if (d.a != null) len += 2;
    if (d.b != null) len += 2;
    return len + 2 * (@as(usize, d.stack_len) + d.return_stack_len);
}

/// WALL and CPORT: the port between two neighbours, which each calls by
/// the same name
fn wall(layout: Chip.Layout, from: u16, to: u16) error{NotNeighbours}!Word {
    const i = layout.index(from).?;
    for ([_]Direction{ .right, .down, .left, .up }) |direction| {
        if (layout.neighbour(i, direction) == layout.index(to).?) return port.multiport(.initOne(direction));
    }
    return error.NotNeighbours;
}

/// A jump or call from an instruction's first slot, as the STREAMER writes
/// them, with the slots its destination does not take as 0
const jump: Word = transfer(.jump);
const call: Word = transfer(.call);

fn transfer(opcode: Opcode) Word {
    return @bitCast((@as(u18, @backingInt(opcode)) << 13) ^ (@as(u18, @bitCast(Instruction.encoding)) & 0x3e000));
}

const nop: u3 = @intCast(@backingInt(Opcode.@".") >> 2);

const Builder = struct {
    buffer: []Word,
    len: usize = 0,

    fn word(self: *Builder, w: Word) error{StreamTooLong}!void {
        if (self.len == self.buffer.len) return error.StreamTooLong;
        self.buffer[self.len] = w;
        self.len += 1;
    }

    fn instruction(self: *Builder, i: Instruction) error{StreamTooLong}!void {
        try self.word(i.encode());
    }

    /// a literal fetched with @p, for `opcode` to take
    fn literal(self: *Builder, opcode: Opcode, value: Word) error{StreamTooLong}!void {
        try self.instruction(.{ .slot_0 = .@"@p", .slot_1 = opcode, .slot_2 = .@".", .slot_3 = nop });
        try self.word(value);
    }
};

test draw {
    var buffer: [Chip.Layout.chip_numbers]u16 = undefined;
    try expectEqualSlices(u16, &.{ 708, 608, 508, 408, 308, 208, 108, 107, 7, 8, 9 }, try draw(&.{ 708, 108, 107, 7, 9 }, &buffer));
    // the default path covers the chip
    const all = try draw(&entire, &buffer);
    try expectEqual(144, all.len);
    for (all, 0..) |node, i| try expect(std.mem.indexOfScalar(u16, all[0..i], node) == null);

    try expectError(error.NotInLine, draw(&.{ 708, 607 }, &buffer));
    try expectError(error.NotInLine, draw(&.{ 708, 708 }, &buffer));
    try expectError(error.PathTooLong, draw(&.{ 708, 717 }, buffer[0..5]));
}

test stream {
    const source =
        \\ node 608 : main dup ;
    ;
    var programs: [1]Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);
    var buffer: [256]Word = undefined;
    var descriptors: [1]Descriptor = .{.ofProgram(assembled[0])};

    // as block 1584's stream to node 715, but to 608 along a path from 708
    // through its down port, and on to 508 through 608's up port
    const words = try stream(.ga144, &.{ 708, 608, 508 }, &descriptors, assembled, &buffer);
    const down: Word = port.multiport(.initOne(.down));
    const up: Word = port.multiport(.initOne(.up));
    const len = 1 + 5 + 3 + (5 + @as(Word, assembled[0].len) + 1);
    try expectEqualSlices(Word, &.{ 0x100ae, down, len, 0x12000 | down }, words[0..4]);
    // 608 pumps the 3 words after its pump to 508, focusing it first
    try expectEqualSlices(Word, &.{ 0x12000 | up, 3 - 1 }, words[5..7]);
    // 508 starts at warm with B addressing IO, and 608 loads itself, which
    // ofProgram leaves B as it is
    try expectEqualSlices(Word, &.{ Computer.io_address, 0x100a9 }, words[10..12]);
    try expectEqualSlices(Word, &.{ 0, assembled[0].len - 1 }, words[13..15]);
    const end = 17 + assembled[0].len;
    try expectEqualSlices(Word, assembled[0].ram[0..assembled[0].len], words[17..end]);
    try expectEqual(0x10000 | assembled[0].entry.toWord(), words[end]);
    // then the root's frame, to warm, with the word of a bin 0 not saved
    try expectEqualSlices(Word, &.{ 0x100a9, 0, 1, 0 }, words[end + 1 ..]);
    // the frame is as long as its header says
    try expectEqual(end - 2, @as(usize, @intCast(len)));

    try expectError(error.NotOnPath, stream(.ga144, &.{ 708, 708 - 1 }, &descriptors, assembled, &buffer));
    try expectError(error.NotNeighbours, stream(.ga144, &.{ 708, 508 }, &descriptors, assembled, &buffer));
    try expectError(error.RepeatedNode, stream(.ga144, &.{ 708, 608, 708 }, &descriptors, assembled, &buffer));
    try expectError(error.UnknownRoot, stream(.ga144, &.{ 608, 708 }, &descriptors, assembled, &buffer));
    try expectError(error.StreamTooLong, stream(.ga144, &.{ 708, 608 }, &descriptors, assembled, buffer[0..10]));
}

test "the root's frame loads its RAM in place and jumps to where it starts" {
    const source =
        \\ node 608 : main dup drop ;  5 , 6 , 7 ,
    ;
    var programs: [1]Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);
    var buffer: [256]Word = undefined;
    var descriptors: [1]Descriptor = .{.ofProgram(assembled[0])};
    descriptors[0].node = 708;
    const len = assembled[0].len;

    // 608's program, from its bin, in all of 708's RAM, which the A and B
    // of the descriptor do not reach
    descriptors[0].loads[0].len = 64;
    descriptors[0].a = 5;
    var words = try stream(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer);
    const entry = 0x10000 | assembled[0].entry.toWord();
    try expectEqualSlices(Word, &.{ entry, 0, 64 }, words[words.len - 67 ..][0..3]);
    try expectEqualSlices(Word, &assembled[0].ram, words[words.len - 64 ..]);
    // 608 is not described, and takes only FRAME['s defaults
    try expectEqualSlices(Word, &.{ Computer.io_address, 0x100a9 }, words[5..7]);
    try expectEqual(words.len - 67, 7);

    // a part of it, to the addresses it comes from
    descriptors[0].loads[0] = .{ .bin = 608, .source = 1, .destination = 1, .len = len - 1 };
    words = try stream(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer);
    try expectEqualSlices(Word, &.{ entry, 1, len - 1 }, words[7..10]);
    try expectEqualSlices(Word, assembled[0].ram[1..len], words[10..]);

    // no load, to read another frame, as block 1897's 708 ser-exec /P
    descriptors[0].load_count = 0;
    descriptors[0].p = boot.read_frame;
    words = try stream(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer);
    try expectEqualSlices(Word, &.{ 0x100ae, 0, 1, 0 }, words[7..]);

    descriptors[0].load_count = 2;
    descriptors[0].loads[1] = descriptors[0].loads[0];
    try expectError(error.RootTooManyLoads, stream(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer));
    descriptors[0].load_count = 1;
    descriptors[0].loads[0].destination = 0;
    try expectError(error.RootNotInPlace, stream(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer));
}

const assembler = @import("assembler.zig");
const boot = @import("boot.zig");
const Descriptor = boot.Descriptor;
const Program = assembler.Program;
const Chip = @import("Chip.zig");
const ga144 = @import("ga144.zig");
const f18 = @import("f18.zig");
const Computer = f18.Computer;
const Instruction = f18.Instruction;
const Word = f18.Word;
const Opcode = @import("opcodes.zig").Opcode;
const port = @import("port.zig");
const Direction = port.Direction;

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
