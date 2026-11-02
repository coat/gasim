//! The GA144's ROMs: the kinds of ROM a node can have, their named entry
//! points, and dumps of a real chip's ROM. Which node has which, and its
//! pins, are in `chips/ga144.zon` (see `Spec`).

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

pub const RomWord = struct { []const u8, u10 };

/// Named entry points into ROM. Addresses with bit 9 set enter Extended
/// Arithmetic Mode, and those from x0c0 up are mirrors of x080 to x0bf.
pub fn romWords(rom_type: RomType) []const RomWord {
    return switch (rom_type) {
        .basic => &.{
            .{ "relay", 0xa1 },    .{ "warm", 0xa9 },     .{ "poly", 0xaa },
            .{ "*.17", 0xb0 },     .{ "*.", 0xb7 },       .{ "taps", 0xbc },
            .{ "interp", 0xc4 },   .{ "triangle", 0xce }, .{ "clc", 0x2d3 },
            .{ "--u/mod", 0x2d5 }, .{ "-u/mod", 0x2d6 },
        },
        .analog => &.{
            .{ "relay", 0xa1 },    .{ "warm", 0xa9 },     .{ "poly", 0xaa },
            .{ "*.17", 0xb0 },     .{ "*.", 0xb7 },       .{ "-dac", 0xbc },
            .{ "interp", 0xc4 },   .{ "triangle", 0xce }, .{ "clc", 0x2d3 },
            .{ "--u/mod", 0x2d5 }, .{ "-u/mod", 0x2d6 },
        },
        .serdes_boot => &.{
            .{ "relay", 0xa1 },    .{ "warm", 0xa9 },     .{ "cold", 0xaa },
            .{ "*.17", 0xb0 },     .{ "*.", 0xb7 },       .{ "taps", 0xbc },
            .{ "interp", 0xc4 },   .{ "triangle", 0xce }, .{ "clc", 0x2d3 },
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
            .{ "*.17", 0xc3 },     .{ "*.", 0xca },      .{ "clc", 0x2cf },
            .{ "--u/mod", 0x2d1 }, .{ "-u/mod", 0x2d2 },
        },
        .special => &.{.{ "warm", 0xa9 }},
    };
}

/// address of a named ROM word in a ROM of `rom_type`
pub fn romWordOf(rom_type: RomType, name: []const u8) ?u10 {
    return rom_word_maps.get(rom_type).get(name);
}

const rom_word_maps = maps: {
    var maps: std.EnumArray(RomType, std.StaticStringMap(u10)) = undefined;
    for (std.enums.values(RomType)) |rom_type| maps.set(rom_type, .initComptime(romWords(rom_type)));
    break :maps maps;
};

/// the GA144 node whose ROM a basic node gets
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

test romWordOf {
    try expectEqual(0xa9, romWordOf(.basic, "warm"));
    try expectEqual(0xcc, romWordOf(.sync_boot, "*.17"));
    try expectEqual(null, romWordOf(.async_boot, "*.17"));
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
    try expectError(error.TooManyNodes, parseRom(writer.buffered(), &roms));
    try expectError(error.InvalidRom, parseRom("708\n1\n2\n", &roms));

    const parsed = try parseRom(writer.buffered()[0 .. writer.buffered().len - "262143\n".len], &roms);
    try expectEqual(2, parsed.len);
    try expectEqual(708, parsed[0].node);
    try expectEqual(9, parsed[1].node);
    try expectEqual(63, parsed[1].words[63]);
}

const Word = @import("f18.zig").Word;

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
