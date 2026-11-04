//! Boot streams laid out as arrayForth 3's STREAMER (blocks 1602 to 1618 of
//! its disk) lays them out for the ROM of node 708, which reads them from
//! its pins as a UART sends them, or node 705, which reads them from an SPI
//! flash (`Flash`), rather than as `boot` does.
//!
//! The STREAMER boots nodes along a path, a line of neighbours from the
//! root, instead of a tree. A frame for the root's ROM writes the rest of
//! the frame to the path's next node, which executes it from that port.
//! Each node on the path copies, with a pump, what is for the nodes past it
//! to the next one, and then sets itself up. The nodes are set up from the
//! end of the path back, and every node on it is: those without a
//! descriptor have B addressing IO and start at warm, as FRAME[ leaves
//! them. A second frame then loads the root and jumps to where it starts.
//! A stream of several frames has them one after another, each with its
//! own path and descriptors: every frame but the last has to leave the
//! root reading the next, at ser-exec or spi-exec, or at code of its own.
//! Between them can be frames for the root's ROM alone (/ROOT), and, in a
//! stream for flash, FORWARD, which tells the root's code where the next
//! frame starts in the flash.

/// The roots the STREAMER builds streams for here (ROOTS, block 1602, also
/// has 300 and 207): where the root's ROM reads a frame (asyORG, spiORG),
/// and its default path, the ENTIRE chip, as its corners (df708, df705)
pub const roots = [_]struct { node: u16, exec: u10, entire: []const u16 }{
    .{ .node = 708, .exec = boot.read_frame, .entire = &.{ 708, 717, 17, 0, 100, 116, 216, 200, 300, 316, 416, 400, 500, 516, 616, 600, 700, 707 } },
    .{ .node = 705, .exec = spi_exec, .entire = &.{ 705, 700, 0, 17, 117, 101, 201, 217, 317, 301, 401, 417, 517, 501, 601, 617, 717, 706 } },
};

/// where node 705's ROM reads a frame from the flash
pub const spi_exec: u10 = 0xb6;

/// the default path of the root `node`, if it is one
pub fn entire(node: u16) ?[]const u16 {
    for (roots) |r| if (r.node == node) return r.entire;
    return null;
}

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
    /// the path does not start at a root of `roots`
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
    /// a frame before the last leaves the root at warm, FRAME['s default,
    /// where it no longer reads the stream, as the STREAMER would let it
    RootStopsReading,
    NoSuchBin,
    StreamTooLong,
    /// frames from different roots
    MixedRoots,
    /// FORWARD in a stream that is not for flash, from 705
    ForwardNotFlash,
    /// FORWARD after no frame whose root's frame loads x32 words or more,
    /// the last of which it patches with the address
    ForwardNoRoot,
    /// FORWARD to past where 16 bits of an address shifted up 2 reach,
    /// 16 KB of flash, which the STREAMER would cut short
    ForwardTooFar,
    /// /ROOT of words past the end of RAM
    RootPastRam,
};

/// A frame of a stream, from one FRAME[ to its ]FRAME: the path it takes
/// from the root, and the descriptors of the nodes it sets up
pub const Frame = struct {
    path: []const u16,
    descriptors: []const Descriptor,
};

/// /ROOT: a frame for the root's ROM alone, which loads `count` words, at
/// least 1, from address `address` of a bin to the same addresses of the
/// root's RAM, and jumps to `jump`, such as the speed-up of the disk's
/// streams for flash (`0 0 3 1608 /ROOT`)
pub const RootFrame = struct {
    jump: u10,
    address: u6 = 0,
    count: u7 = 0,
    bin: u32,
};

/// What a stream is made of, one after another
pub const Part = union(enum) {
    frame: Frame,
    root: RootFrame,
    /// FORWARD (block 1613), in a stream for flash: pads the stream with
    /// zero words to a whole number of 8, so that the next part starts on
    /// a byte of flash once packed, and patches words x23 and x31 of what
    /// the last frame's root frame loads, with that byte's address shifted
    /// up 2, as spi-boot takes it. Those are RAM x23 and x31 when the load
    /// is all of RAM, as the disk's `1710 /RAM` is, whose fwd is there. A
    /// root left at spi-exec would read the padding as a frame and stop,
    /// so the root's own code, such as bin 1710's /frm, reads on from the
    /// address.
    forward,
};

/// The most words `stream` can take for `parts`, to size its buffer
pub fn maxLen(parts: []const Part) usize {
    var len: usize = 0;
    for (parts) |part| switch (part) {
        .frame => |f| {
            // the frame's header and its first call, a pump and a default
            // set up for each node, and the root's frame
            len += 4 + f.path.len * (5 + 3) + 3 + 64;
            for (f.descriptors) |d| {
                for (d.loads[0..d.load_count]) |load| len += 5 + load.len;
                len += psiz(d);
            }
        },
        .root => len += 3 + 64,
        .forward => len += 7,
    };
    return len;
}

/// Builds a stream into `buffer` of `parts` one after another, from the
/// bins of `programs`, as the STREAMER does. A stream for root 705 then
/// goes to flash through `pack`.
pub fn stream(
    layout: Chip.Layout,
    parts: []const Part,
    programs: []const Program,
    buffer: []Word,
) Error![]Word {
    var root: ?u16 = null;
    for (parts) |part| if (part == .frame) {
        const node = if (part.frame.path.len > 0) part.frame.path[0] else return error.PathTooShort;
        if (root != null and root != node) return error.MixedRoots;
        root = node;
    };
    var len: usize = 0;
    // the root's RAM in the last frame's root frame, which FORWARD patches
    var root_ram: ?struct { at: usize, address: u6, count: u7 } = null;
    for (parts, 0..) |part, i| {
        // the root, which goes on to `jump`, reads what follows
        const goes_to: ?u10 = switch (part) {
            .frame => |f| jump: {
                const words = try frame(layout, f.path, f.descriptors, programs, buffer[len..]);
                const load = rootLoad(descriptorOf(f.descriptors, f.path[0]));
                root_ram = .{ .at = len + words.len - load.count, .address = load.address, .count = load.count };
                len += words.len;
                break :jump descriptorOf(f.descriptors, f.path[0]).p;
            },
            .root => |r| jump: {
                var builder: Builder = .{ .buffer = buffer[len..] };
                try builder.rootFrame(r, programs);
                len += builder.len;
                break :jump r.jump;
            },
            .forward => {
                if (root) |r| if (r != 705) return error.ForwardNotFlash;
                const ram = root_ram orelse return error.ForwardNoRoot;
                if (ram.count <= 0x31) return error.ForwardNoRoot;
                while (len % 8 != 0) : (len += 1) {
                    if (len == buffer.len) return error.StreamTooLong;
                    buffer[len] = 0;
                }
                // S-LNG D2/ 9 8 M*/ D2* D2*: the bytes so far, once packed,
                // shifted up 2, of which the STREAMER keeps 16 bits
                const address = len * 18 / 8 * 4;
                if (address > 0xffff) return error.ForwardTooFar;
                // PAT: words of the root frame's payload, from BORG
                for ([_]usize{ 0x23, 0x31 }) |k| buffer[ram.at + k] = @intCast(address);
                continue;
            },
        };
        const later = for (parts[i + 1 ..]) |after| {
            if (after != .forward) break true;
        } else false;
        if (later and goes_to == warm) return error.RootStopsReading;
    }
    return buffer[0..len];
}

/// Packs a stream for flash as the STREAMER's PACK does (block 1614), into
/// `buffer`: the words' 18 bits one after another, high bits first, in
/// 16-bit cells of two bytes, high byte first, the last padded with zeros.
/// What follows in the flash is the caller's: PACK leaves zeros, to the end
/// of the 1024-byte block WRITE-FLASH writes, where `Flash` reads as erased,
/// which 705's ROM takes no differently.
pub fn pack(words: []const Word, buffer: []u8) error{StreamTooLong}![]u8 {
    // PACK's "too long!", for a length of 16 bits
    if (words.len + 7 > 0xffff) return error.StreamTooLong;
    const len = (words.len * 18 + 15) / 16 * 2;
    if (buffer.len < len) return error.StreamTooLong;
    const bits = Flash.pack(words, buffer[0..len]);
    // which pads with ones, as erased flash reads
    const used = words.len * 18;
    if (used % 8 != 0) bits[bits.len - 1] &= @as(u8, 0xff) << @intCast(8 - used % 8);
    if (bits.len < len) buffer[len - 1] = 0;
    return buffer[0..len];
}

/// Builds a frame into `buffer` that sets up the nodes on `path` as
/// `descriptors` say, from the bins of `programs`, as one FRAME[ and
/// ]FRAME of the STREAMER do, for the root that starts the path.
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
fn frame(
    layout: Chip.Layout,
    path: []const u16,
    descriptors: []const Descriptor,
    programs: []const Program,
    buffer: []Word,
) Error![]Word {
    if (path.len < 2) return error.PathTooShort;
    const exec = for (roots) |r| {
        if (r.node == path[0]) break r.exec;
    } else return error.UnknownRoot;
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

    // asyORG, spiORG: the root writes the frame to the path's next node,
    // which executes from that port, and then reads another frame
    try builder.word(jump | @as(Word, exec));
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

    // serEND, spiEND and +ROOT: the root's frame
    const root = descriptorOf(descriptors, path[0]);
    if (root.load_count > 1) return error.RootTooManyLoads;
    if (root.load_count == 1 and root.loads[0].source != root.loads[0].destination) return error.RootNotInPlace;
    const load = rootLoad(root);
    try builder.rootFrame(.{ .jump = root.p, .address = load.address, .count = load.count, .bin = load.bin }, programs);
    return buffer[0..builder.len];
}

/// what +ROOT loads into the root's RAM: its one load, or else a word of
/// bin 0 at address 0
fn rootLoad(root: Descriptor) struct { bin: u32, address: u6, count: u7 } {
    if (root.load_count == 0) return .{ .bin = 0, .address = 0, .count = 1 };
    const load = root.loads[0];
    return .{ .bin = load.bin, .address = @intCast(load.destination), .count = @max(load.len, 1) };
}

/// the descriptor of a node, or what FRAME[ leaves it with
fn descriptorOf(descriptors: []const Descriptor, node: u16) Descriptor {
    for (descriptors) |d| if (d.node == node) return d;
    return .{ .node = node, .b = Computer.io_address, .p = warm };
}

const warm = ga144.romWordOf(.basic, "warm").?;

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

    /// /ROOT: a frame for the root's ROM that loads its RAM from a bin, or
    /// with zeros when the bin, which can only be +ROOT's bin 0, was not
    /// saved, and jumps
    fn rootFrame(self: *Builder, r: RootFrame, programs: []const Program) Error!void {
        const count = @max(r.count, 1);
        if (@as(usize, r.address) + count > 64) return error.RootPastRam;
        const bin: ?[]const Word = if (boot.findBin(programs, r.bin)) |program| &program.ram else null;
        try self.word(jump | @as(Word, r.jump));
        try self.word(r.address);
        try self.word(count);
        for (@as(usize, r.address)..@as(usize, r.address) + count) |address| try self.word(if (bin) |ram| ram[address] else 0);
    }
};

test draw {
    var buffer: [Chip.Layout.chip_numbers]u16 = undefined;
    try expectEqualSlices(u16, &.{ 708, 608, 508, 408, 308, 208, 108, 107, 7, 8, 9 }, try draw(&.{ 708, 108, 107, 7, 9 }, &buffer));
    // each root's default path covers the chip
    for (roots) |r| {
        const all = try draw(r.entire, &buffer);
        try expectEqual(144, all.len);
        try expectEqual(r.node, all[0]);
        for (all, 0..) |node, i| try expect(std.mem.indexOfScalar(u16, all[0..i], node) == null);
    }
    try expectEqual(null, entire(300));

    try expectError(error.NotInLine, draw(&.{ 708, 607 }, &buffer));
    try expectError(error.NotInLine, draw(&.{ 708, 708 }, &buffer));
    try expectError(error.PathTooLong, draw(&.{ 708, 717 }, buffer[0..5]));
}

test frame {
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
    const words = try frame(.ga144, &.{ 708, 608, 508 }, &descriptors, assembled, &buffer);
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

    try expectError(error.NotOnPath, frame(.ga144, &.{ 708, 708 - 1 }, &descriptors, assembled, &buffer));
    try expectError(error.NotNeighbours, frame(.ga144, &.{ 708, 508 }, &descriptors, assembled, &buffer));
    try expectError(error.RepeatedNode, frame(.ga144, &.{ 708, 608, 708 }, &descriptors, assembled, &buffer));
    try expectError(error.UnknownRoot, frame(.ga144, &.{ 608, 708 }, &descriptors, assembled, &buffer));
    try expectError(error.StreamTooLong, frame(.ga144, &.{ 708, 608 }, &descriptors, assembled, buffer[0..10]));
}

test stream {
    const source =
        \\ node 608 : main dup ;
    ;
    var programs: [1]Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);
    var buffer: [512]Word = undefined;
    var single: [256]Word = undefined;

    // a frame that leaves 708 reading the next, which boots 608 along
    // another path
    const reading: [1]Descriptor = .{.{ .node = 708, .p = boot.read_frame }};
    const loading: [1]Descriptor = .{.ofProgram(assembled[0])};
    const frames = [_]Frame{
        .{ .path = &.{ 708, 707 }, .descriptors = &reading },
        .{ .path = &.{ 708, 608, 508 }, .descriptors = &loading },
    };
    const parts = [_]Part{ .{ .frame = frames[0] }, .{ .frame = frames[1] } };
    const words = try stream(.ga144, &parts, assembled, &buffer);
    try expect(words.len <= maxLen(&parts));
    // the frames one after another, each as it is alone
    const first = try frame(.ga144, frames[0].path, frames[0].descriptors, assembled, &single);
    try expectEqualSlices(Word, first, words[0..first.len]);
    try expectEqualSlices(Word, &.{ 0x100ae, 0, 1, 0 }, first[first.len - 4 ..]);
    try expectEqualSlices(Word, try frame(.ga144, frames[1].path, frames[1].descriptors, assembled, &single), words[first.len..]);
    try expectEqual(0, (try stream(.ga144, &.{}, assembled, &buffer)).len);

    // but for the last, a frame that leaves the root at warm would leave
    // the rest unread
    const warm_frame: Part = .{ .frame = .{ .path = &.{ 708, 707 }, .descriptors = &.{} } };
    try expectError(error.RootStopsReading, stream(.ga144, &.{ parts[1], parts[1] }, assembled, &buffer));
    try expectError(error.RootStopsReading, stream(.ga144, &.{ warm_frame, parts[0] }, assembled, &buffer));
    try expectError(error.RootStopsReading, stream(.ga144, &.{ .{ .root = .{ .jump = warm, .bin = 608 } }, parts[0] }, assembled, &buffer));
    try expectError(error.NotNeighbours, stream(.ga144, &.{ parts[0], .{ .frame = .{ .path = &.{ 708, 508 }, .descriptors = &loading } } }, assembled, &buffer));
    try expectError(error.StreamTooLong, stream(.ga144, &parts, assembled, buffer[0 .. first.len + 3]));
    try expectError(error.MixedRoots, stream(.ga144, &.{ parts[0], .{ .frame = .{ .path = &.{ 705, 706 }, .descriptors = &.{} } } }, assembled, &buffer));
}

test "a stream for flash, from root 705, with a frame of its own for the root and FORWARD" {
    const source =
        \\ node 606 : main dup ;
        \\ node 705 : main over ;
    ;
    var programs: [2]Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try assembler.assembleNodes(source, &programs, &diagnostic);
    var buffer: [512]Word = undefined;

    // a speed-up for the root alone, which loads 3 words of 705's bin at 0
    // and jumps to 0, as the disk's `0 0 3 1608 /ROOT`, and a frame whose
    // root starts at spi-exec, which spiORG's header jumps to too: laid
    // out, if not a stream 705 would read past FORWARD's padding
    var root: Descriptor = .ofProgram(assembled[1]);
    root.p = spi_exec;
    // all of its RAM, as the disk's `705 +NODE 1710 /RAM`
    root.loads[0].len = 64;
    const descriptors = [_]Descriptor{ .ofProgram(assembled[0]), root };
    var parts = [_]Part{
        .{ .root = .{ .jump = 0, .count = 3, .bin = 705 } },
        .{ .frame = .{ .path = &.{ 705, 706, 606 }, .descriptors = &descriptors } },
        .forward,
        .{ .frame = .{ .path = &.{ 705, 704 }, .descriptors = &.{} } },
    };
    const words = try stream(.ga144, &parts, assembled, &buffer);
    try expect(words.len <= maxLen(&parts));
    try expectEqualSlices(Word, &.{ 0x10000, 0, 3 }, words[0..3]);
    try expectEqualSlices(Word, assembled[1].ram[0..3], words[3..6]);
    // east of an odd column is left
    const left: Word = port.multiport(.initOne(.left));
    try expectEqualSlices(Word, &.{ 0x100b6, left }, words[6..8]);
    // the root's frame loads all of its RAM, in which FORWARD patched x23
    // and x31 with where the next frame starts: after the padding, a whole
    // number of 8 words, as bytes once packed, shifted up 2
    const next = std.mem.lastIndexOfScalar(Word, words, 0x100b6).?;
    try expectEqual(0, next % 8);
    const header = std.mem.lastIndexOf(Word, words[0..next], &.{ 0x100b6, 0, 64 }).?;
    const ram = words[header + 3 ..][0..64];
    try expectEqual(@as(Word, @intCast(next * 18 / 8 * 4)), ram[0x23]);
    try expectEqual(ram[0x23], ram[0x31]);
    try expectEqualSlices(Word, assembled[1].ram[0..0x23], ram[0..0x23]);
    for (words[header + 3 + 64 .. next]) |w| try expectEqual(0, w);

    // FORWARD needs a frame for flash before it, whose root's frame loads
    // its RAM through x31
    try expectError(error.ForwardNoRoot, stream(.ga144, &.{ parts[0], .forward, parts[1] }, assembled, &buffer));
    root.loads[0].len = 0x31;
    const short = [_]Descriptor{ descriptors[0], root };
    try expectError(error.ForwardNoRoot, stream(.ga144, &.{ .{ .frame = .{ .path = &.{ 705, 706, 606 }, .descriptors = &short } }, .forward }, assembled, &buffer));
    // with no frame at all, from either root
    try expectError(error.ForwardNoRoot, stream(.ga144, &.{.forward}, assembled, &buffer));
    // as PAT does, the words of the root frame's payload, which for a load
    // from 2 are RAM x25 and x33
    root.loads[0] = .{ .bin = 705, .source = 2, .destination = 2, .len = 62 };
    const from_2 = [_]Descriptor{ descriptors[0], root };
    const patched = try stream(.ga144, &.{ .{ .frame = .{ .path = &.{ 705, 706, 606 }, .descriptors = &from_2 } }, .forward }, assembled, &buffer);
    const payload = std.mem.lastIndexOf(Word, patched, &.{ 0x100b6, 2, 62 }).? + 3;
    try expectEqual(@as(Word, @intCast(patched.len * 18 / 8 * 4)), patched[payload + 0x23]);
    try expectEqual(assembled[1].ram[0x23], patched[payload + 0x23 - 2]);
    try expectError(error.ForwardNotFlash, stream(.ga144, &.{ .{ .frame = .{ .path = &.{ 708, 707 }, .descriptors = &.{.{ .node = 708, .p = boot.read_frame }} } }, .forward }, assembled, &buffer));
    try expectError(error.RootPastRam, stream(.ga144, &.{.{ .root = .{ .jump = 0, .address = 62, .count = 3, .bin = 705 } }}, assembled, &buffer));
    // and to reach the next frame with 16 bits
    var far: [8 * 1024]Word = undefined;
    parts[0] = .{ .root = .{ .jump = spi_exec, .count = 64, .bin = 705 } };
    var many: [120]Part = undefined;
    for (&many) |*part| part.* = parts[0];
    many[many.len - 2] = parts[1];
    many[many.len - 1] = .forward;
    try expectError(error.ForwardTooFar, stream(.ga144, &many, assembled, &far));
}

test pack {
    var buffer: [16]u8 = undefined;
    // 18 bits of 1, then 18 of 0: 36 bits, in 3 cells of 16, padded with 0
    try expectEqualSlices(u8, &.{ 0xff, 0xff, 0xc0, 0x00, 0x00, 0x00 }, try pack(&.{ -1, 0 }, &buffer));
    // 8 words fill 9 cells
    var nine: [18]u8 = undefined;
    try expectEqual(18, (try pack(&@as([8]Word, @splat(-1)), &nine)).len);
    try expectError(error.StreamTooLong, pack(&.{ -1, 0 }, buffer[0..5]));
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
    var words = try frame(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer);
    const entry = 0x10000 | assembled[0].entry.toWord();
    try expectEqualSlices(Word, &.{ entry, 0, 64 }, words[words.len - 67 ..][0..3]);
    try expectEqualSlices(Word, &assembled[0].ram, words[words.len - 64 ..]);
    // 608 is not described, and takes only FRAME['s defaults
    try expectEqualSlices(Word, &.{ Computer.io_address, 0x100a9 }, words[5..7]);
    try expectEqual(words.len - 67, 7);

    // a part of it, to the addresses it comes from
    descriptors[0].loads[0] = .{ .bin = 608, .source = 1, .destination = 1, .len = len - 1 };
    words = try frame(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer);
    try expectEqualSlices(Word, &.{ entry, 1, len - 1 }, words[7..10]);
    try expectEqualSlices(Word, assembled[0].ram[1..len], words[10..]);

    // no load, to read another frame, as block 1897's 708 ser-exec /P
    descriptors[0].load_count = 0;
    descriptors[0].p = boot.read_frame;
    words = try frame(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer);
    try expectEqualSlices(Word, &.{ 0x100ae, 0, 1, 0 }, words[7..]);

    descriptors[0].load_count = 2;
    descriptors[0].loads[1] = descriptors[0].loads[0];
    try expectError(error.RootTooManyLoads, frame(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer));
    descriptors[0].load_count = 1;
    descriptors[0].loads[0].destination = 0;
    try expectError(error.RootNotInPlace, frame(.ga144, &.{ 708, 608 }, &descriptors, assembled, &buffer));
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
const Flash = @import("Flash.zig");

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
