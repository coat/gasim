//! Configuration of the nodes of a GA144: which ROM each node has, its GPIO
//! pins, and where it starts after reset. Chips with other layouts use the
//! same configuration by node number, and nodes beyond the GA144's are basic
//! nodes.

pub const RomType = enum {
    basic,
    analog,
    serdes_boot,
    sync_boot,
    async_boot,
    spi_boot,
    one_wire,
    /// external memory and eForth support, whose ROM words are not described
    special,
};

pub fn romType(node: u16) RomType {
    return switch (node) {
        117, 617, 709, 713, 717 => .analog,
        1, 701 => .serdes_boot,
        300 => .sync_boot,
        708 => .async_boot,
        705 => .spi_boot,
        200 => .one_wire,
        7, 8, 9, 105, 106, 107, 108 => .special,
        else => .basic,
    };
}

pub const RomWord = struct { []const u8, u10 };

/// Named entry points into ROM. Addresses with bit 9 set enter Extended
/// Arithmetic Mode, and those from x0c0 up are mirrors of x080 to x0bf.
pub fn romWords(rom_type: RomType) []const RomWord {
    return switch (rom_type) {
        .basic => &.{
            .{ "relay", 0xa1 },    .{ "warm", 0xa9 },     .{ "poly", 0xaa },
            .{ "*.17", 0xb0 },     .{ "*.", 0xb7 },       .{ "taps", 0xbc },
            .{ "interp", 0xc4 },   .{ "triangle", 0xce }, .{ "clc", 0xd3 },
            .{ "--u/mod", 0x2d5 }, .{ "-u/mod", 0x2d6 },
        },
        .analog => &.{
            .{ "relay", 0xa1 },    .{ "warm", 0xa9 },     .{ "poly", 0xaa },
            .{ "*.17", 0xb0 },     .{ "*.", 0xb7 },       .{ "-dac", 0xbc },
            .{ "interp", 0xc4 },   .{ "triangle", 0xce }, .{ "clc", 0xd3 },
            .{ "--u/mod", 0x2d5 }, .{ "-u/mod", 0x2d6 },
        },
        .serdes_boot => &.{
            .{ "relay", 0xa1 },    .{ "warm", 0xa9 },     .{ "cold", 0xaa },
            .{ "*.17", 0xb0 },     .{ "*.", 0xb7 },       .{ "taps", 0xbc },
            .{ "interp", 0xc4 },   .{ "triangle", 0xce }, .{ "clc", 0xd3 },
            .{ "--u/mod", 0x2d5 }, .{ "-u/mod", 0x2d6 },
        },
        .sync_boot => &.{
            .{ "relay", 0xa1 }, .{ "warm", 0xa9 }, .{ "cold", 0xaa },
            .{ "*.17", 0xcc },  .{ "taps", 0xd3 }, .{ "triangle", 0xdb },
        },
        .async_boot => &.{
            .{ "relay", 0xa1 }, .{ "warm", 0xa9 }, .{ "cold", 0xaa },
            .{ "lsh", 0xd9 },   .{ "rsh", 0xdb },
        },
        .spi_boot => &.{ .{ "relay", 0xa1 }, .{ "warm", 0xa9 }, .{ "cold", 0xaa } },
        .one_wire => &.{
            .{ "warm", 0xa9 },     .{ "cold", 0xaa },    .{ "triangle", 0xbe },
            .{ "*.17", 0xc3 },     .{ "*.", 0xca },      .{ "clc", 0xcf },
            .{ "--u/mod", 0x2d1 }, .{ "-u/mod", 0x2d2 },
        },
        .special => &.{.{ "warm", 0xa9 }},
    };
}

/// address of a named ROM word in a node
pub fn romWord(node: u16, name: []const u8) ?u10 {
    return rom_word_maps.get(romType(node)).get(name);
}

const rom_word_maps = maps: {
    var maps: std.EnumArray(RomType, std.StaticStringMap(u10)) = undefined;
    for (std.enums.values(RomType)) |rom_type| maps.set(rom_type, .initComptime(romWords(rom_type)));
    break :maps maps;
};

/// Boot nodes start at cold, in ROM, after reset. Node 200 starts at warm.
/// Every other node starts with a multiport execute of its neighbours' ports.
pub fn resetAddress(node: u16) ?u9 {
    return switch (node) {
        1, 300, 701, 705, 708 => 0xaa,
        200 => 0xa9,
        else => null,
    };
}

/// io bits of the GPIO pins a node has, out of 17, 5, 3 and 1
pub fn pins(node: u16) u18 {
    return switch (node) {
        100, 200, 500, 600, 715, 217, 317, 417, 517 => 1 << 17,
        300, 708 => 1 << 17 | 1 << 1,
        705, 8 => 1 << 17 | 1 << 5 | 1 << 3 | 1 << 1,
        else => 0,
    };
}

/// True for the SERDES nodes, whose data register is written at reset
pub fn hasData(node: u16) bool {
    return node == 1 or node == 701;
}

/// the node whose ROM is given to nodes beyond a GA144
pub const basic_node = 404;

pub const NodeRom = struct {
    node: u16,
    words: [64]Word,
};

/// Parses a ROM dump: for each node, its number on a line followed by its
/// 64 ROM words, one per line, in decimal.
pub fn parseRom(text: []const u8, roms: []NodeRom) error{ InvalidRom, TooManyNodes }![]NodeRom {
    var lines = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var count: usize = 0;
    while (lines.next()) |line| {
        if (count == roms.len) return error.TooManyNodes;
        const rom = &roms[count];
        rom.node = std.fmt.parseInt(u16, line, 10) catch return error.InvalidRom;
        for (&rom.words) |*word| {
            const value = std.fmt.parseInt(u18, lines.next() orelse return error.InvalidRom, 10) catch return error.InvalidRom;
            word.* = @bitCast(value);
        }
        count += 1;
    }
    return roms[0..count];
}

/// Reads the GA144 ROM dump in rom/, skipping the test if it is missing, as
/// rom/ is not part of the package
pub fn testRom(roms: *[144]NodeRom) ![]NodeRom {
    const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/ga144.txt", std.testing.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer std.testing.allocator.free(text);
    return parseRom(text, roms);
}

test romWord {
    try std.testing.expectEqual(0xa9, romWord(404, "warm"));
    try std.testing.expectEqual(0xcc, romWord(300, "*.17"));
    try std.testing.expectEqual(null, romWord(708, "*.17"));
    try std.testing.expectEqual(0xb0, romWord(1717, "*.17"));
}

test parseRom {
    var text: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    for ([_]u16{ 708, 9 }) |node| {
        try writer.print("{d}\n", .{node});
        for (0..64) |i| try writer.print("{d}\n", .{i});
    }
    try writer.writeAll("262143\n");

    var roms: [2]NodeRom = undefined;
    try std.testing.expectError(error.TooManyNodes, parseRom(writer.buffered(), &roms));
    try std.testing.expectError(error.InvalidRom, parseRom("708\n1\n2\n", &roms));

    const parsed = try parseRom(writer.buffered()[0 .. writer.buffered().len - "262143\n".len], &roms);
    try std.testing.expectEqual(2, parsed.len);
    try std.testing.expectEqual(708, parsed[0].node);
    try std.testing.expectEqual(9, parsed[1].node);
    try std.testing.expectEqual(63, parsed[1].words[63]);
}

const Word = @import("f18.zig").Word;

const std = @import("std");
