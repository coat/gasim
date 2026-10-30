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
//!     13 feedback       gray number in the cell's upper 27 bits, which
//!                       arrayForth 2 writes after a name as it compiles it,
//!                       such as the address of an F18 definition
//!     14 format         blue word that lays out the block, such as cr
//!     15 comment_number white number in the cell's upper 27 bits
//!
//! The upper 28 bits of a word's cell hold its characters, packed from the
//! top with a code of 4, 5 or 7 bits each, so that the common letters take
//! fewer: `0xxx` for ` rtoeani`, `10xxx` for `smcylgfw`, and `11xxxxx` for
//! the rest of `dvpbhxuq0123456789j-k.z/;:!+@*,?`. A character whose code
//! does not fit fits anyway if the bits that are cut off are zeros, and
//! otherwise starts an extension cell. A variable's name fits in one cell,
//! as colorForth reads its value from the next. A number's bit 4 says to
//! show it in hex.
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
    /// more than `max_chars` characters, or a variable's name longer than
    /// a cell
    WordTooLong,
    /// a white or gray number that does not fit in 27 bits
    NumberOutOfRange,
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
    feedback,
    format,
    comment_number,

    pub fn isNumber(self: Tag) bool {
        return self.isLong() or self.isShort();
    }

    /// a number in the next cell
    pub fn isLong(self: Tag) bool {
        return self == .execute_long or self == .compile_long;
    }

    /// a number in the upper 27 bits of the cell
    pub fn isShort(self: Tag) bool {
        return switch (self) {
            .compile_short, .execute_short, .feedback, .comment_number => true,
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
            .comment, .capitalized, .uppercase, .comment_number => .white,
            .variable => .magenta,
            .feedback => .gray,
            .format => .blue,
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

    /// A yellow or green number, packed into one cell if it fits, or a
    /// white or gray one, which must
    pub fn number(color: Color, value: i32, hex: bool) Error!Token {
        const short = fitsShort(value);
        const tag: Tag = switch (color) {
            .yellow => if (short) .execute_short else .execute_long,
            .green => if (short) .compile_short else .compile_long,
            .white => if (short) .comment_number else return error.NumberOutOfRange,
            .gray => if (short) .feedback else return error.NumberOutOfRange,
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
        if (self.tag.isLong() or self.tag == .variable) return 2;
        if (self.tag.isShort()) return 1;
        return packedCells(self.text());
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

/// A place in blocks as a line number, for diagnostics and listings: a
/// token of a block, counting from 1, after 256 for each block before it
pub fn line(block: usize, token: usize) usize {
    return block * cells_per_block + token;
}

/// the block and token of a line number from `line`
pub fn place(at: usize) struct { block: usize, token: usize } {
    return .{ .block = (at -| 1) / cells_per_block, .token = (at -| 1) % cells_per_block + 1 };
}

/// the number of blocks in `bytes`, counting a partial block at the end
pub fn blockCount(bytes: []const u8) usize {
    return std.math.divCeil(usize, bytes.len, block_size) catch unreachable;
}

/// Decodes the tokens of a block, up to the first zero cell. A block that is
/// not colorForth source, such as compressed blocks, decodes to nonsense.
pub fn decode(block: *const [block_size]u8, tokens: *[cells_per_block]Token) Error![]Token {
    var reader: Reader = .{ .block = block };
    var len: usize = 0;
    while (try reader.next()) |token| {
        tokens[len] = token;
        len += 1;
    }
    return tokens[0..len];
}

/// Reads the tokens of a block one at a time, as `decode` does
pub const Reader = struct {
    block: *const [block_size]u8,
    /// the next cell to read
    cell: usize = 0,

    /// the next token, or null at the zero cell that ends the block
    pub fn next(self: *Reader) Error!?Token {
        if (self.cell == cells_per_block) return null;
        const cell = self.take();
        if (cell == 0) {
            self.cell = cells_per_block;
            return null;
        }
        const tag: Tag = @fromBackingInt(@intCast(@as(u4, @truncate(cell))));
        var token: Token = .{ .tag = tag };
        if (tag.isLong()) {
            token.value = @bitCast(self.take());
            token.hex = cell & 0x10 != 0;
            return token;
        }
        if (tag.isShort()) {
            token.value = @as(i32, @bitCast(cell)) >> 5;
            token.hex = cell & 0x10 != 0;
            return token;
        }
        try unpack(cell, &token);
        // a variable's name fits in its cell, so an extension after its
        // value is one on its own
        if (tag == .variable) token.value = @bitCast(self.take());
        // more characters, even for an extension without a word before it
        while (tag != .variable and self.cell < cells_per_block) {
            const more = cellAt(self.block, self.cell);
            if (more == 0 or @as(u4, @truncate(more)) != 0) break;
            self.cell += 1;
            try unpack(more, &token);
        }
        applyCase(&token);
        return token;
    }

    /// the next cell, or zero past the end of the block, as a number cut
    /// off by it is
    fn take(self: *Reader) u32 {
        if (self.cell == cells_per_block) return 0;
        self.cell += 1;
        return cellAt(self.block, self.cell - 1);
    }
};

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
            .execute_short, .compile_short, .feedback, .comment_number => {
                setCell(block, i, @as(u32, @bitCast(token.value)) << 5 | hex | tag);
                i += 1;
            },
            else => {
                var cells: [max_chars]u32 = undefined;
                const packed_cells = try pack(token.text(), &cells);
                if (token.tag == .variable and packed_cells.len > 1) return error.WordTooLong;
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

/// the blocks at the start of an arrayForth 2 image that it never
/// compresses: the kernel, and the source it loads first, which decompresses
/// the rest
pub const uncompressed_blocks = 36;

/// the block whose variables say whether an image is compressed, and the
/// first of its source, as the blocks before it hold the kernel's code
pub const header_block = 18;

/// whether `bytes` are an arrayForth 2 image, compressed or not, as its
/// block 18 starts with the variable `ns`
pub fn isImage(bytes: []const u8) bool {
    if (bytes.len < (header_block + 1) * block_size) return false;
    return headerVariable(bytes[header_block * block_size ..][0..block_size], 0, "ns") != null;
}

pub const ImageError = Error || error{
    /// the compressed bits end before the blocks they hold, or before the
    /// sectors `ns` counts
    ImageTruncated,
    /// a compressed image does not fit
    ImageFull,
};

/// The number of blocks an arrayForth 2 image holds once decompressed, or
/// null if it is not compressed. Its block 18 starts with the variables
/// `ns`, which is negative while the blocks after the first 36 are
/// compressed, and `nblk`, the number of blocks.
pub fn compressedBlocks(image: []const u8) ?usize {
    if (image.len < (header_block + 1) * block_size) return null;
    const block = image[header_block * block_size ..][0..block_size];
    const ns = headerVariable(block, 0, "ns") orelse return null;
    const nblk = headerVariable(block, 2, "nblk") orelse return null;
    if (ns >= 0 or nblk < uncompressed_blocks) return null;
    return @intCast(nblk);
}

/// the value of the variable `name` at cell `i` of a block, if it is there
fn headerVariable(block: *const [block_size]u8, i: usize, name: []const u8) ?i32 {
    const cell = cellAt(block, i);
    if (@as(u4, @truncate(cell)) != @backingInt(Tag.variable)) return null;
    var token: Token = .{ .tag = .variable };
    unpack(cell, &token) catch return null;
    if (!std.mem.eql(u8, token.text(), name)) return null;
    return @bitCast(cellAt(block, i + 1));
}

/// Decompresses an arrayForth 2 image into `out`, `compressedBlocks(image)`
/// blocks long, as arrayForth 2 does as it starts: the first 36 blocks are
/// copied, and the rest decoded from the bits that follow them, block by
/// block, most significant bit of each cell first. Each token is its tag,
/// then a long number's hex bit and value, a short number's upper 28 bits,
/// or a word's characters and a `0000` after them, and a variable's value.
/// A tag of 0 ends a block. `ns` is made positive, as the blocks are no
/// longer compressed.
pub fn decompress(image: []const u8, out: []u8) ImageError!void {
    const start = uncompressed_blocks * block_size;
    if (image.len < start) return error.ImageTruncated;
    @memcpy(out[0..start], image[0..start]);
    const ns: *[4]u8 = out[header_block * block_size + 4 ..][0..4];
    const sectors = std.math.cast(i32, @abs(std.mem.readInt(i32, ns, .little))) orelse return error.ImageTruncated;
    std.mem.writeInt(i32, ns, sectors, .little);

    var stream: BitReader = .{ .bytes = image[start..] };
    var tokens: [cells_per_block]Token = undefined;
    for (uncompressed_blocks..out.len / block_size) |n| {
        var len: usize = 0;
        while (true) {
            const tag: Tag = @fromBackingInt(@intCast(try stream.take(4)));
            if (tag == .extension) break;
            if (len == cells_per_block) return error.BlockFull;
            var token: Token = .{ .tag = tag };
            if (tag.isLong()) {
                token.hex = try stream.take(1) == 1;
                token.value = @bitCast(try stream.take(32));
            } else if (tag.isShort()) {
                const cell = try stream.take(28) << 4 | @backingInt(tag);
                token.value = @as(i32, @bitCast(cell)) >> 5;
                token.hex = cell & 0x10 != 0;
            } else {
                while (try stream.char()) |index| {
                    if (token.len == max_chars) return error.WordTooLong;
                    token.chars[token.len] = characters[index];
                    token.len += 1;
                }
                if (tag == .variable) token.value = @bitCast(try stream.take(32));
            }
            applyCase(&token);
            tokens[len] = token;
            len += 1;
        }
        try encode(tokens[0..len], out[n * block_size ..][0..block_size]);
    }
}

/// Compresses an image as arrayForth 2 does, into `out`, returning how long
/// it is: whole blocks, with `ns` negative and counting its 512-byte
/// sectors, and `nc` its 18-block cylinders
pub fn compress(image: []const u8, out: []u8) ImageError!usize {
    const start = uncompressed_blocks * block_size;
    if (out.len < start) return error.ImageFull;
    @memcpy(out[0..start], image[0..start]);
    @memset(out[start..], 0);

    var stream: BitWriter = .{ .bytes = out[start..] };
    var tokens: [cells_per_block]Token = undefined;
    for (uncompressed_blocks..blockCount(image)) |n| {
        var block: [block_size]u8 = @splat(0);
        const bytes = image[n * block_size ..][0..@min(block_size, image.len - n * block_size)];
        @memcpy(block[0..bytes.len], bytes);
        for (try decode(&block, &tokens)) |token| {
            // nothing can say where an extension on its own starts
            if (token.tag == .extension) return error.InvalidCharacter;
            try stream.put(@backingInt(token.tag), 4);
            if (token.tag.isLong()) {
                try stream.put(@intFromBool(token.hex), 1);
                try stream.put(@bitCast(token.value), 32);
            } else if (token.tag.isShort()) {
                try stream.put(@as(u32, @bitCast(token.value)) << 1 | @intFromBool(token.hex), 28);
            } else {
                for (token.text()) |c| {
                    const index = code(std.ascii.toLower(c)) orelse return error.InvalidCharacter;
                    // a space would end the word
                    if (index == 0) return error.InvalidCharacter;
                    const value, const width = bits(index);
                    try stream.put(value, width);
                }
                try stream.put(0, 4);
                if (token.tag == .variable) try stream.put(@bitCast(token.value), 32);
            }
        }
        try stream.put(0, 4);
    }

    const len = start + std.mem.alignForward(usize, std.math.divCeil(usize, stream.at, 8) catch unreachable, block_size);
    if (len > out.len) return error.ImageFull;
    const header = out[header_block * block_size ..][0..block_size];
    if (headerVariable(header, 0, "ns") != null) setCell(header, 1, @bitCast(-@as(i32, @intCast(len / 512))));
    if (headerVariable(header, 4, "nc") != null) setCell(header, 5, @intCast(std.math.divCeil(usize, len, 18 * block_size) catch unreachable));
    return len;
}

/// reads the bits of a compressed image, most significant bit of each cell
/// first
const BitReader = struct {
    bytes: []const u8,
    /// bits read so far
    at: usize = 0,

    fn take(self: *BitReader, n: u6) ImageError!u32 {
        var value: u32 = 0;
        for (0..n) |_| {
            if (byteOf(self.at) >= self.bytes.len) return error.ImageTruncated;
            value = value << 1 | (self.bytes[byteOf(self.at)] >> @intCast(7 - self.at % 8) & 1);
            self.at += 1;
        }
        return value;
    }

    /// the code of the next character of a word, or null at its end
    fn char(self: *BitReader) ImageError!?u6 {
        const first = try self.take(4);
        if (first & 0b1000 == 0) return if (first == 0) null else @intCast(first);
        if (first & 0b0100 == 0) return @intCast(8 + ((first << 1 | try self.take(1)) & 0b111));
        return @intCast(16 + ((first << 3 | try self.take(3)) & 0b11111));
    }
};

/// writes the bits of a compressed image into zeros, as `BitReader` reads
/// them
const BitWriter = struct {
    bytes: []u8,
    /// bits written so far
    at: usize = 0,

    fn put(self: *BitWriter, value: u32, n: u6) ImageError!void {
        var i = n;
        while (i > 0) {
            i -= 1;
            if (byteOf(self.at) >= self.bytes.len) return error.ImageFull;
            self.bytes[byteOf(self.at)] |= @intCast((value >> @intCast(i) & 1) << @intCast(7 - self.at % 8));
            self.at += 1;
        }
    }
};

/// the byte holding a bit of a compressed image, as cells are little-endian
fn byteOf(bit: usize) usize {
    const cell = bit / 32;
    return cell * 4 + 3 - bit % 32 / 8;
}

/// Writes a block's tokens as text, with a mark before a token whose color
/// differs from the one before it, as muforth lists colorForth: `:` red,
/// `[` yellow, `]` green, `\` cyan, `(` white, `@` magenta, `^` gray and
/// `~` blue. Lines start as `startsLine` says.
pub fn writeText(tokens: []const Token, writer: *Io.Writer) Io.Writer.Error!void {
    var color: Color = .none;
    var before: ?Token = null;
    for (tokens) |token| {
        if (before) |b| {
            if (startsLine(b, token)) {
                try writer.writeAll(if (isFormat(b, "br")) "\n\n" else "\n");
            } else try writer.writeByte(' ');
        }
        const c = token.tag.color();
        if (c != color or c == .red or c == .magenta) if (mark(c)) |m| try writer.writeByte(m);
        color = c;
        try writer.print("{f}", .{token});
        if (token.tag == .variable) try writer.print(" {d}", .{token.value});
        before = token;
    }
    if (before != null) try writer.writeByte('\n');
}

/// Whether a token starts a line, as colorForth shows a block, after the
/// token before it: a red or magenta one does, unless a blue `-cr` comes
/// before it, and so does one after a blue `cr`, or `br` and an empty line
pub fn startsLine(before: Token, token: Token) bool {
    if (isFormat(before, "cr") or isFormat(before, "br")) return true;
    const c = token.tag.color();
    return (c == .red or c == .magenta) and !isFormat(before, "-cr");
}

/// Counts the lines of a block, from 0, as `writeText` writes them
pub const Lines = struct {
    before: ?Token = null,
    line: usize = 0,

    /// the line of the next token of the block
    pub fn of(self: *Lines, token: Token) usize {
        if (self.before) |b| if (startsLine(b, token)) {
            self.line += if (isFormat(b, "br")) 2 else 1;
        };
        self.before = token;
        return self.line;
    }
};

fn isFormat(token: Token, text: []const u8) bool {
    return token.tag == .format and std.mem.eql(u8, token.text(), text);
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
        try Token.number(.yellow, 25, false),
        try Token.number(.green, -1, true),
        try Token.number(.green, 1 << 26, false),
        try Token.number(.yellow, -(1 << 26), false),
        try Token.number(.yellow, std.math.minInt(i32), true),
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
        try Token.word(.comment, "Counts"), try Token.word(.define, "inc"), try Token.number(.green, 1, false),
        try Token.word(.compile, "+"),      try Token.word(.compile, ";"),  try Token.word(.format, "cr"),
        variable,                           try Token.word(.define, "x"),   try Token.number(.yellow, 0x1f, true),
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

test "arrayForth 2 images compress and decompress" {
    const blocks = uncompressed_blocks + 3;
    var image: [blocks * block_size]u8 = @splat(0);
    // the variables that say whether the image is compressed
    var ns = try Token.word(.variable, "ns");
    ns.value = 2 * blocks;
    var nblk = try Token.word(.variable, "nblk");
    nblk.value = blocks;
    var nc = try Token.word(.variable, "nc");
    nc.value = 17;
    try encode(&.{ ns, nblk, nc, try Token.word(.comment, "Header") }, image[header_block * block_size ..][0..block_size]);
    image[0] = 0xeb;
    var count = try Token.word(.variable, "count");
    count.value = -7;
    try encode(&.{
        try Token.word(.define, "compile"), try Token.number(.green, -5, true),    try Token.number(.yellow, 1 << 30, false),
        try Token.word(.comment, "GA144"),  try Token.number(.white, 2009, false), try Token.number(.gray, 0x32, true),
        count,                              try Token.word(.format, "...."),
    }, image[(uncompressed_blocks + 2) * block_size ..][0..block_size]);
    try std.testing.expectEqual(null, compressedBlocks(&image));

    var compressed: [blocks * block_size]u8 = undefined;
    const len = try compress(&image, &compressed);
    try std.testing.expectEqual((uncompressed_blocks + 1) * block_size, len);
    try std.testing.expectEqual(blocks, compressedBlocks(compressed[0..len]));
    var tokens: [cells_per_block]Token = undefined;
    const header = try decode(compressed[header_block * block_size ..][0..block_size], &tokens);
    try std.testing.expectEqual(-@as(i32, @intCast(len / 512)), header[0].value);
    // 37 blocks are three cylinders
    try std.testing.expectEqual(3, header[2].value);

    var decompressed: [blocks * block_size]u8 = undefined;
    try decompress(compressed[0..len], &decompressed);
    try std.testing.expectEqual(null, compressedBlocks(&decompressed));
    try std.testing.expectEqualSlices(u8, image[uncompressed_blocks * block_size ..], decompressed[uncompressed_blocks * block_size ..]);
    try std.testing.expectEqual(0xeb, decompressed[0]);

    try std.testing.expectError(error.ImageTruncated, decompress(compressed[0 .. uncompressed_blocks * block_size + 8], &decompressed));
    // even before the blocks it copies, or with ns as low as it goes
    try std.testing.expectError(error.ImageTruncated, decompress(compressed[0 .. (header_block + 1) * block_size], &decompressed));
    std.mem.writeInt(i32, compressed[header_block * block_size + 4 ..][0..4], std.math.minInt(i32), .little);
    try std.testing.expectError(error.ImageTruncated, decompress(compressed[0..len], &decompressed));
    try std.testing.expectError(error.ImageFull, compress(&image, compressed[0 .. uncompressed_blocks * block_size]));
}

test "an extension after a variable's value is one on its own" {
    var variable = try Token.word(.variable, "h");
    variable.value = 5;
    var block: [block_size]u8 = undefined;
    try encode(&.{ variable, try Token.word(.extension, "cr") }, &block);
    var tokens: [cells_per_block]Token = undefined;
    const decoded = try decode(&block, &tokens);
    try std.testing.expectEqual(2, decoded.len);
    try std.testing.expectEqualStrings("h", decoded[0].text());
    try std.testing.expectEqual(5, decoded[0].value);
    try std.testing.expectEqual(.extension, decoded[1].tag);
    try std.testing.expectEqualStrings("cr", decoded[1].text());
    try expectRoundTrip(&block);
}

test "compressed bits that end within a cell" {
    // a cell's first bits are in its last byte, which is missing
    const start = uncompressed_blocks * block_size;
    var image: [(uncompressed_blocks + 1) * block_size]u8 = @splat(0);
    var out: [image.len]u8 = undefined;
    try std.testing.expectError(error.ImageTruncated, decompress(image[0 .. start + 3], &out));

    try encode(&.{try Token.word(.compile, "dup")}, image[start..][0..block_size]);
    var compressed: [image.len]u8 = undefined;
    try std.testing.expectError(error.ImageFull, compress(&image, compressed[0 .. start + 3]));
}

fn expectSameTokens(expected: []const Token, actual: []const Token) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expectEqual(e.tag, a.tag);
        try std.testing.expectEqual(e.value, a.value);
        try std.testing.expectEqual(e.hex, a.hex);
        try std.testing.expectEqualStrings(e.text(), a.text());
    }
}

const example_blocks: []const []const u8 = &.{
    "examples/alphabet.cf", "examples/echo.cf",   "examples/hello.cf",
    "examples/multiply.cf", "examples/upcase.cf", "examples/variables.cf",
};

/// Any block decodes or fails to, and what it decodes to encodes into a
/// block that decodes the same, and encodes again to the same bytes
fn fuzzBlock(_: void, smith: *std.testing.Smith) !void {
    var block: [block_size]u8 = undefined;
    @memset(block[smith.slice(&block)..], 0);
    var tokens: [cells_per_block]Token = undefined;
    // a space packs into no bits at the end of a cell, so words with one,
    // which nothing but nonsense decodes to, may not come back the same.
    // Leave them out, and any extension after one, which would otherwise
    // join the word before it.
    var len: usize = 0;
    var skipped = false;
    for (decode(&block, &tokens) catch return) |token| {
        skipped = std.mem.indexOfScalar(u8, token.text(), ' ') != null or (skipped and token.tag == .extension);
        if (skipped) continue;
        tokens[len] = token;
        len += 1;
    }
    const decoded = tokens[0..len];
    var encoded: [block_size]u8 = undefined;
    try encode(decoded, &encoded);

    var again: [cells_per_block]Token = undefined;
    const redecoded = try decode(&encoded, &again);
    try expectSameTokens(decoded, redecoded);
    var reencoded: [block_size]u8 = undefined;
    try encode(redecoded, &reencoded);
    try std.testing.expectEqualSlices(u8, &encoded, &reencoded);
}

test "fuzz blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var seeds: std.ArrayList([]const u8) = .empty;
    try fuzz.addFiles(arena.allocator(), &seeds, example_blocks, block_size, block_size);
    try std.testing.fuzz({}, fuzzBlock, .{ .corpus = seeds.items });
}

/// the most blocks after the uncompressed ones that the image fuzz tests try
const fuzz_blocks = 4;

/// An image of any blocks after the uncompressed ones compresses or fails
/// to, and decompresses to blocks of the same tokens
fn fuzzCompress(_: void, smith: *std.testing.Smith) !void {
    const start = uncompressed_blocks * block_size;
    var image: [(uncompressed_blocks + fuzz_blocks) * block_size]u8 = @splat(0);
    const source = image[0 .. start + smith.slice(image[start..])];
    var compressed: [image.len * 2]u8 = undefined;
    const len = compress(source, &compressed) catch return;
    var decompressed: [image.len]u8 = undefined;
    const out = decompressed[0 .. blockCount(source) * block_size];
    try decompress(compressed[0..len], out);

    for (uncompressed_blocks..blockCount(source)) |n| {
        var block: [block_size]u8 = @splat(0);
        const bytes = source[n * block_size ..][0..@min(block_size, source.len - n * block_size)];
        @memcpy(block[0..bytes.len], bytes);
        var expected: [cells_per_block]Token = undefined;
        var actual: [cells_per_block]Token = undefined;
        try expectSameTokens(try decode(&block, &expected), try decode(out[n * block_size ..][0..block_size], &actual));
    }
}

test "fuzz compressing images" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var seeds: std.ArrayList([]const u8) = .empty;
    try fuzz.addFiles(arena.allocator(), &seeds, example_blocks, null, fuzz_blocks * block_size);
    try std.testing.fuzz({}, fuzzCompress, .{ .corpus = seeds.items });
}

/// Any bits after the uncompressed blocks decompress or fail to, and what
/// they decompress to compresses and decompresses to the same bytes
fn fuzzDecompress(_: void, smith: *std.testing.Smith) !void {
    const start = uncompressed_blocks * block_size;
    var image: [(uncompressed_blocks + fuzz_blocks) * block_size]u8 = @splat(0);
    const len = smith.slice(image[start..]);
    var out: [image.len]u8 = undefined;
    decompress(image[0 .. start + len], &out) catch return;

    var compressed: [image.len * 2]u8 = undefined;
    const compressed_len = try compress(&out, &compressed);
    var again: [image.len]u8 = undefined;
    try decompress(compressed[0..compressed_len], &again);
    try std.testing.expectEqualSlices(u8, out[start..], again[start..]);
}

test "fuzz decompressing images" {
    // the bits of each example compressed
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var seeds: std.ArrayList([]const u8) = .empty;
    const start = uncompressed_blocks * block_size;
    for (example_blocks) |path| {
        const bytes = try fuzz.read(arena.allocator(), path) orelse continue;
        var image: [(uncompressed_blocks + 1) * block_size]u8 = @splat(0);
        @memcpy(image[start..][0..bytes.len], bytes);
        var compressed: [image.len]u8 = undefined;
        const len = try compress(&image, &compressed);
        try fuzz.add(arena.allocator(), &seeds, compressed[start..len], fuzz_blocks * block_size);
    }
    try std.testing.fuzz({}, fuzzDecompress, .{ .corpus = seeds.items });
}

const fuzz = @import("fuzz.zig");
