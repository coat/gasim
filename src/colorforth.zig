//! colorForth source, as arrayForth 2 and Chuck Moore's colorForth keep it:
//! blocks of 256 32-bit cells, little-endian, each block a run of tokens
//! ended by a zero cell. A token's color says what it does, and is the low
//! four bits, its tag, of its first cell:
//!
//!     0  extension      more characters of the word before
//!     1  execute        yellow word, run as the block is loaded
//!     2  execute_long   yellow number in the next cell
//!     3  define         red word, the name of a definition
//!     4  compile        green word, compiled into the definition
//!     5  compile_long   green number in the next cell
//!     6  compile_short  green number in the cell's upper 27 bits
//!     7  macro          cyan word, a macro compiled rather than run
//!     8  execute_short  yellow number in the cell's upper 27 bits
//!     9  comment        white word in lower case
//!     10 capitalized    white word with its first letter in upper case
//!     11 uppercase      white word in upper case
//!     12 variable       magenta word, with its value in the next cell
//!     13 gray           gray word, as arrayForth 2 shows compiler feedback
//!     14 format         blue word that lays out the block, such as cr
//!     15 black          unused
//!
//! The upper 28 bits of a word's cell hold its characters, packed from the
//! top with a code of 4, 5 or 7 bits each, so that the common letters take
//! fewer: `0xxx` for ` rtoeani`, `10xxx` for `smcylgfw`, and `11xxxxx` for
//! the rest of `dvpbhxuq0123456789j-k.z/;:!+@*,?`. A character whose code
//! does not fit fits anyway if the bits that are cut off are zeros, and
//! otherwise starts an extension cell. A number's bit 4 says to show it in
//! hex.
//!
//! The editor works on tokens, which are decoded from and encoded into a
//! block's bytes without allocating. Encoding a decoded block of source gives
//! back the same bytes, up to the zero cell that ends it, as it does for the
//! source blocks of GreenArrays' OkadWork.cf.

pub const block_size = 1024;
pub const cells_per_block = block_size / 4;

/// the most characters a word may have, as that many extension cells
pub const max_chars = 64;

/// characters in the order of their codes, from 0
pub const characters = " rtoeanismcylgfwdvpbhxuq0123456789j-k.z/;:!+@*,?";

pub const Error = error{
    /// the tokens take more cells than a block has
    BlockFull,
    /// more than `max_chars` characters
    WordTooLong,
    /// a character colorForth cannot pack, such as an upper case letter in
    /// a word that is not a comment
    InvalidCharacter,
};

pub const Tag = enum(u4) {
    extension,
    execute,
    execute_long,
    define,
    compile,
    compile_long,
    compile_short,
    macro,
    execute_short,
    comment,
    capitalized,
    uppercase,
    variable,
    gray,
    format,
    black,

    pub fn isNumber(self: Tag) bool {
        return switch (self) {
            .execute_long, .compile_long, .compile_short, .execute_short => true,
            else => false,
        };
    }

    pub fn color(self: Tag) Color {
        return switch (self) {
            .extension => .none,
            .execute, .execute_long, .execute_short => .yellow,
            .define => .red,
            .compile, .compile_long, .compile_short => .green,
            .macro => .cyan,
            .comment, .capitalized, .uppercase => .white,
            .variable => .magenta,
            .gray => .gray,
            .format => .blue,
            .black => .black,
        };
    }
};

/// what a token's color says it does, as several tags share one
pub const Color = enum {
    /// an extension cell on its own, without a word before it
    none,
    red,
    yellow,
    green,
    cyan,
    white,
    magenta,
    gray,
    blue,
    black,
};

pub const Token = struct {
    tag: Tag,
    /// a number, or the value of a variable
    value: i32 = 0,
    /// a number to show in hex
    hex: bool = false,
    /// a word's characters, with comments in their case
    chars: [max_chars]u8 = undefined,
    len: u8 = 0,

    /// A word with `tag`, which for a white word is chosen by the case of
    /// `name` instead
    pub fn word(tag: Tag, name: []const u8) Error!Token {
        std.debug.assert(!tag.isNumber());
        if (name.len > max_chars) return error.WordTooLong;
        var token: Token = .{ .tag = if (tag.color() == .white) commentTag(name) orelse return error.InvalidCharacter else tag };
        for (name) |c| {
            if (code(c) == null and (token.tag.color() != .white or code(std.ascii.toLower(c)) == null)) return error.InvalidCharacter;
            if (c == ' ') return error.InvalidCharacter;
        }
        @memcpy(token.chars[0..name.len], name);
        token.len = @intCast(name.len);
        return token;
    }

    /// A yellow or green number, packed into one cell if it fits
    pub fn number(color: Color, value: i32, hex: bool) Token {
        const short = fitsShort(value);
        const tag: Tag = switch (color) {
            .yellow => if (short) .execute_short else .execute_long,
            .green => if (short) .compile_short else .compile_long,
            else => unreachable,
        };
        return .{ .tag = tag, .value = value, .hex = hex };
    }

    pub fn text(self: *const Token) []const u8 {
        return self.chars[0..self.len];
    }

    /// Writes the word, or the number in decimal or in hex after a `$`,
    /// which colorForth has no character for
    pub fn format(self: Token, writer: *Io.Writer) Io.Writer.Error!void {
        if (!self.tag.isNumber()) return writer.writeAll(self.text());
        if (self.hex) {
            if (self.value < 0) try writer.writeByte('-');
            return writer.print("${x}", .{@abs(self.value)});
        }
        return writer.print("{d}", .{self.value});
    }

    /// cells the token takes in a block
    pub fn cells(self: Token) usize {
        return switch (self.tag) {
            .execute_long, .compile_long => 2,
            .execute_short, .compile_short => 1,
            .variable => 1 + packedCells(self.text()),
            else => packedCells(self.text()),
        };
    }
};

/// the white tag for a comment written in `text`'s case, or null if it
/// mixes cases otherwise
pub fn commentTag(text: []const u8) ?Tag {
    var upper: usize = 0;
    var lower: usize = 0;
    for (text) |c| {
        if (std.ascii.isUpper(c)) upper += 1;
        if (std.ascii.isLower(c)) lower += 1;
    }
    if (upper == 0) return .comment;
    if (lower == 0 and !(upper == 1 and std.ascii.isUpper(text[0]) and text.len == 1)) return .uppercase;
    if (std.ascii.isUpper(text[0]) and upper == 1) return .capitalized;
    return null;
}

/// whether a number fits in the upper 27 bits of a cell
pub fn fitsShort(value: i32) bool {
    return value >= -(1 << 26) and value < 1 << 26;
}

/// the number of blocks in `bytes`, counting a partial block at the end
pub fn blockCount(bytes: []const u8) usize {
    return std.math.divCeil(usize, bytes.len, block_size) catch unreachable;
}

/// Decodes the tokens of a block, up to the first zero cell. A block that is
/// not colorForth source, such as compressed blocks, decodes to nonsense.
pub fn decode(block: *const [block_size]u8, tokens: *[cells_per_block]Token) Error![]Token {
    var len: usize = 0;
    var i: usize = 0;
    while (i < cells_per_block) {
        const cell = cellAt(block, i);
        i += 1;
        if (cell == 0) break;
        const tag: Tag = @fromBackingInt(@intCast(@as(u4, @truncate(cell))));
        switch (tag) {
            .execute_long, .compile_long => {
                // a number cut off by the end of the block is zero
                const value = if (i < cells_per_block) cellAt(block, i) else 0;
                i += 1;
                tokens[len] = .{ .tag = tag, .value = @bitCast(value), .hex = cell & 0x10 != 0 };
            },
            .execute_short, .compile_short => tokens[len] = .{
                .tag = tag,
                .value = @as(i32, @bitCast(cell)) >> 5,
                .hex = cell & 0x10 != 0,
            },
            .extension => if (len > 0 and !tokens[len - 1].tag.isNumber()) {
                try unpack(cell, &tokens[len - 1]);
                continue;
            } else {
                tokens[len] = .{ .tag = .extension };
                try unpack(cell, &tokens[len]);
            },
            else => {
                tokens[len] = .{ .tag = tag };
                try unpack(cell, &tokens[len]);
                if (tag == .variable) {
                    tokens[len].value = if (i < cells_per_block) @bitCast(cellAt(block, i)) else 0;
                    i += 1;
                }
            },
        }
        len += 1;
    }
    for (tokens[0..len]) |*token| applyCase(token);
    return tokens[0..len];
}

/// Encodes tokens into a block, filling the rest of it with zeros
pub fn encode(tokens: []const Token, block: *[block_size]u8) Error!void {
    var i: usize = 0;
    for (tokens) |token| {
        if (i + token.cells() > cells_per_block) return error.BlockFull;
        const tag: u32 = @backingInt(token.tag);
        const hex: u32 = if (token.hex) 0x10 else 0;
        switch (token.tag) {
            .execute_long, .compile_long => {
                setCell(block, i, tag | hex);
                setCell(block, i + 1, @bitCast(token.value));
                i += 2;
            },
            .execute_short, .compile_short => {
                setCell(block, i, @as(u32, @bitCast(token.value)) << 5 | hex | tag);
                i += 1;
            },
            else => {
                var cells: [max_chars]u32 = undefined;
                const packed_cells = try pack(token.text(), &cells);
                setCell(block, i, packed_cells[0] | tag);
                i += 1;
                if (token.tag == .variable) {
                    setCell(block, i, @bitCast(token.value));
                    i += 1;
                }
                for (packed_cells[1..]) |cell| {
                    setCell(block, i, cell);
                    i += 1;
                }
            },
        }
    }
    @memset(block[i * 4 ..], 0);
}

/// Writes a block's tokens as text, with a mark before a token whose color
/// differs from the one before it, as muforth lists colorForth: `:` red,
/// `[` yellow, `]` green, `\` cyan, `(` white, `@` magenta, `^` gray, `~`
/// blue and `!` black. Red and magenta words start a line, as colorForth
/// shows them, unless a blue `-cr` comes before, and so do blue `cr` and
/// `br`, the last after an empty line.
pub fn writeText(tokens: []const Token, writer: *Io.Writer) Io.Writer.Error!void {
    var color: Color = .none;
    var line_start = true;
    var cr_allowed = true;
    for (tokens) |token| {
        const c = token.tag.color();
        const defines = c == .red or c == .magenta;
        if (defines and !line_start and cr_allowed) {
            try writer.writeByte('\n');
            line_start = true;
        }
        if (!line_start) try writer.writeByte(' ');
        if (c != color or defines) if (mark(c)) |m| try writer.writeByte(m);
        color = c;
        try writer.print("{f}", .{token});
        if (token.tag == .variable) try writer.print(" {d}", .{token.value});
        line_start = false;
        cr_allowed = !(c == .blue and std.mem.eql(u8, token.text(), "-cr"));
        if (c == .blue and (std.mem.eql(u8, token.text(), "cr") or std.mem.eql(u8, token.text(), "br"))) {
            try writer.writeAll(if (token.text()[0] == 'b') "\n\n" else "\n");
            line_start = true;
        }
    }
    if (!line_start) try writer.writeByte('\n');
}

fn mark(color: Color) ?u8 {
    return switch (color) {
        .none => null,
        .red => ':',
        .yellow => '[',
        .green => ']',
        .cyan => '\\',
        .white => '(',
        .magenta => '@',
        .gray => '^',
        .blue => '~',
        .black => '!',
    };
}

/// the code of a character, as an index into `characters`
fn code(c: u8) ?u6 {
    const index = std.mem.indexOfScalar(u8, characters, c) orelse return null;
    return @intCast(index);
}

/// the bits of a character's code, and how many there are
fn bits(index: u6) struct { u7, u3 } {
    if (index < 8) return .{ index, 4 };
    if (index < 16) return .{ 0b10000 | (index - 8), 5 };
    return .{ 0b1100000 | @as(u7, index - 16), 7 };
}

/// Packs characters into the upper 28 bits of cells, the first cell's for
/// its tag and the rest as extensions
fn pack(text: []const u8, cells: *[max_chars]u32) Error![]u32 {
    var len: usize = 0;
    var cell: u32 = 0;
    // bits of the cell used, from the top
    var used: u5 = 0;
    for (text) |c| {
        const value, const width = bits(code(std.ascii.toLower(c)) orelse return error.InvalidCharacter);
        const zeros: u3 = @min(@ctz(value), width);
        var fit: u5 = width;
        if (@as(u6, used) + width > 28) {
            if (@as(u6, used) + width - zeros > 28) {
                cells[len] = cell;
                len += 1;
                cell = 0;
                used = 0;
            } else fit = 28 - used;
        }
        cell |= @as(u32, value >> @intCast(width - fit)) << @intCast(32 - @as(u6, used) - fit);
        used += fit;
    }
    cells[len] = cell;
    return cells[0 .. len + 1];
}

/// Appends the characters packed into a cell to a token's
fn unpack(cell: u32, token: *Token) Error!void {
    var rest = cell & ~@as(u32, 0xf);
    while (rest != 0) {
        const index: u6 = if (rest >> 31 == 0)
            @intCast(rest >> 28)
        else if (rest >> 30 == 0b10)
            @intCast(8 + (rest >> 27 & 0b111))
        else
            @intCast(16 + (rest >> 25 & 0b11111));
        _, const width = bits(index);
        rest <<= width;
        if (token.len == max_chars) return error.WordTooLong;
        token.chars[token.len] = characters[index];
        token.len += 1;
    }
}

/// puts a white word's characters into the case its tag says
fn applyCase(token: *Token) void {
    switch (token.tag) {
        .capitalized => if (token.len > 0) {
            token.chars[0] = std.ascii.toUpper(token.chars[0]);
        },
        .uppercase => for (token.chars[0..token.len]) |*c| {
            c.* = std.ascii.toUpper(c.*);
        },
        else => {},
    }
}

fn packedCells(text: []const u8) usize {
    var cells: [max_chars]u32 = undefined;
    return (pack(text, &cells) catch return 1).len;
}

fn cellAt(block: *const [block_size]u8, i: usize) u32 {
    return std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
}

fn setCell(block: *[block_size]u8, i: usize, cell: u32) void {
    std.mem.writeInt(u32, block[i * 4 ..][0..4], cell, .little);
}

const std = @import("std");
const Io = std.Io;

fn testBlock(cells: []const u32) [block_size]u8 {
    var block: [block_size]u8 = @splat(0);
    for (cells, 0..) |cell, i| setCell(&block, i, cell);
    return block;
}

fn expectRoundTrip(block: *const [block_size]u8) !void {
    var tokens: [cells_per_block]Token = undefined;
    var encoded: [block_size]u8 = undefined;
    try encode(try decode(block, &tokens), &encoded);
    try std.testing.expectEqualSlices(u8, block, &encoded);
}

test "words pack as colorForth packs them" {
    // colorForth's own blue words, which include a character cut short
    const words = .{
        .{ "cr", 0x9080000e },  .{ "-tab", 0xe64b8c0e }, .{ "tab", 0x25c6000e },  .{ "br", 0xc620000e },
        .{ "-cr", 0xe721000e }, .{ "cr+", 0x90fb000e },  .{ "tab3", 0x25c7ac0e }, .{ "tab8", 0x25c7c00e },
        .{ ".", 0xea00000e },   .{ "..", 0xebd4000e },   .{ "...", 0xebd7a80e },  .{ "....", 0xebd7af5e },
    };
    inline for (words) |w| {
        var block: [block_size]u8 = undefined;
        try encode(&.{try Token.word(.format, w[0])}, &block);
        try std.testing.expectEqual(w[1], cellAt(&block, 0));
        try std.testing.expectEqual(0, cellAt(&block, 1));

        var tokens: [cells_per_block]Token = undefined;
        const decoded = try decode(&block, &tokens);
        try std.testing.expectEqual(1, decoded.len);
        try std.testing.expectEqual(.format, decoded[0].tag);
        try std.testing.expectEqualStrings(w[0], decoded[0].text());
    }
}

test "long words continue in extension cells" {
    var block: [block_size]u8 = undefined;
    const tokens_in = [_]Token{ try Token.word(.define, "compile"), try Token.word(.compile, "dup") };
    try encode(&tokens_in, &block);
    // "compil" is 30 bits, so the "l" moves to an extension
    try std.testing.expectEqual(.define, @as(Tag, @fromBackingInt(@intCast(@as(u4, @truncate(cellAt(&block, 0)))))));
    try std.testing.expectEqual(.extension, @as(Tag, @fromBackingInt(@intCast(@as(u4, @truncate(cellAt(&block, 1)))))));
    try std.testing.expectEqual(2, tokens_in[0].cells());

    var tokens: [cells_per_block]Token = undefined;
    const decoded = try decode(&block, &tokens);
    try std.testing.expectEqual(2, decoded.len);
    try std.testing.expectEqualStrings("compile", decoded[0].text());
    try std.testing.expectEqualStrings("dup", decoded[1].text());
    try expectRoundTrip(&block);

    const long: [max_chars + 1]u8 = @splat('a');
    try std.testing.expectError(error.WordTooLong, Token.word(.compile, &long));
}

test "numbers short and long, in decimal and hex" {
    const tokens_in = [_]Token{
        .number(.yellow, 25, false),
        .number(.green, -1, true),
        .number(.green, 1 << 26, false),
        .number(.yellow, -(1 << 26), false),
        .number(.yellow, std.math.minInt(i32), true),
    };
    try std.testing.expectEqual(.execute_short, tokens_in[0].tag);
    try std.testing.expectEqual(.compile_short, tokens_in[1].tag);
    try std.testing.expectEqual(.compile_long, tokens_in[2].tag);
    try std.testing.expectEqual(.execute_short, tokens_in[3].tag);
    try std.testing.expectEqual(.execute_long, tokens_in[4].tag);

    var block: [block_size]u8 = undefined;
    try encode(&tokens_in, &block);
    try std.testing.expectEqual(25 << 5 | 8, cellAt(&block, 0));
    try std.testing.expectEqual(0xffffffe0 | 0x10 | 6, cellAt(&block, 1));
    try std.testing.expectEqual(5, cellAt(&block, 2));
    try std.testing.expectEqual(1 << 26, cellAt(&block, 3));

    var tokens: [cells_per_block]Token = undefined;
    const decoded = try decode(&block, &tokens);
    try std.testing.expectEqual(tokens_in.len, decoded.len);
    for (tokens_in, decoded) |expected, actual| {
        try std.testing.expectEqual(expected.tag, actual.tag);
        try std.testing.expectEqual(expected.value, actual.value);
        try std.testing.expectEqual(expected.hex, actual.hex);
    }
    try expectRoundTrip(&block);
}

test "variables keep their value in the next cell" {
    var variable = try Token.word(.variable, "h");
    variable.value = 0x1000;
    var block: [block_size]u8 = undefined;
    try encode(&.{ variable, try Token.word(.compile, "@") }, &block);
    try std.testing.expectEqual(0x1000, cellAt(&block, 1));

    var tokens: [cells_per_block]Token = undefined;
    const decoded = try decode(&block, &tokens);
    try std.testing.expectEqual(2, decoded.len);
    try std.testing.expectEqual(.variable, decoded[0].tag);
    try std.testing.expectEqual(0x1000, decoded[0].value);
    try std.testing.expectEqualStrings("@", decoded[1].text());
}

test "comments keep their case" {
    try std.testing.expectEqual(.comment, commentTag("ok"));
    try std.testing.expectEqual(.capitalized, commentTag("Chuck"));
    try std.testing.expectEqual(.uppercase, commentTag("GA144"));
    try std.testing.expectEqual(.capitalized, commentTag("A"));
    try std.testing.expectEqual(null, commentTag("camelCase"));
    try std.testing.expectError(error.InvalidCharacter, Token.word(.comment, "camelCase"));
    try std.testing.expectError(error.InvalidCharacter, Token.word(.compile, "DUP"));
    try std.testing.expectError(error.InvalidCharacter, Token.word(.compile, "a#b"));

    var block: [block_size]u8 = undefined;
    try encode(&.{ try Token.word(.comment, "Chuck"), try Token.word(.comment, "GA144"), try Token.word(.comment, "moore") }, &block);
    var tokens: [cells_per_block]Token = undefined;
    const decoded = try decode(&block, &tokens);
    try std.testing.expectEqual(.capitalized, decoded[0].tag);
    try std.testing.expectEqualStrings("Chuck", decoded[0].text());
    try std.testing.expectEqualStrings("GA144", decoded[1].text());
    try std.testing.expectEqualStrings("moore", decoded[2].text());
}

test "blocks end at a zero cell and round-trip" {
    // an extension with no word before it, a number cut off by the end of
    // the block, and cells after the zero that ends it
    var cells: [cells_per_block]u32 = @splat(0);
    cells[0] = 0x90800000;
    cells[1] = 0x9080000e;
    cells[cells_per_block - 1] = 2;
    var block = testBlock(&cells);
    var tokens: [cells_per_block]Token = undefined;
    try std.testing.expectEqual(2, (try decode(&block, &tokens)).len);
    try std.testing.expectEqual(.extension, tokens[0].tag);
    var encoded: [block_size]u8 = undefined;
    try encode(tokens[0..2], &encoded);
    try std.testing.expectEqualSlices(u8, block[0 .. block_size - 4], encoded[0 .. block_size - 4]);
    try std.testing.expectEqual(0, cellAt(&encoded, cells_per_block - 1));

    @memset(&cells, 0x9080000e);
    cells[cells_per_block - 1] = 0x10 | 2;
    block = testBlock(&cells);
    const decoded = try decode(&block, &tokens);
    try std.testing.expectEqual(cells_per_block, decoded.len);
    try std.testing.expectEqual(.execute_long, decoded[cells_per_block - 1].tag);
    try std.testing.expectError(error.BlockFull, encode(decoded, &block));
}

test "blocks as text" {
    var block: [block_size]u8 = undefined;
    var variable = try Token.word(.variable, "count");
    variable.value = 3;
    try encode(&.{
        try Token.word(.comment, "Counts"), try Token.word(.define, "inc"), .number(.green, 1, false),
        try Token.word(.compile, "+"),      try Token.word(.compile, ";"),  try Token.word(.format, "cr"),
        variable,                           try Token.word(.define, "x"),   .number(.yellow, 0x1f, true),
        try Token.word(.macro, "dup"),
    }, &block);
    var tokens: [cells_per_block]Token = undefined;
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeText(try decode(&block, &tokens), &writer);
    try std.testing.expectEqualStrings(
        \\(Counts
        \\:inc ]1 + ; ~cr
        \\@count 3
        \\:x [$1f \dup
        \\
    , writer.buffered());
}
