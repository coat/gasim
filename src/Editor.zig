//! Edits colorForth blocks a token at a time, as AshleyF's Color editor
//! does: the cursor is on a token, and the editor is either moving between
//! tokens or typing a new one. A token's color is set as it is typed, or
//! changed afterwards. Typing a space finishes a word and starts the next,
//! in green after a red name, and in the same color otherwise. A word typed
//! in yellow, green or white that reads as a number, such as `-5` or `$1f`,
//! becomes one.
//!
//! The editor works on caller-provided blocks of a file, decoding the block
//! being edited into tokens and encoding it back as it leaves it. It never
//! lets a block's tokens take more cells than it has. Blocks that are not
//! colorForth source, such as the kernel of an arrayForth 2 image, cannot
//! be edited, as they would not encode back the same.

const Editor = @This();

/// the blocks of the file, which may hold more than `count` to grow into
blocks: []u8,
/// blocks in the file, which saving writes at least
count: usize,
/// the block being edited
block: usize = 0,
tokens: [cells_per_block]Token = undefined,
len: usize = 0,
/// the token the cursor is on, which is `len` only when there are none
cursor: usize = 0,
mode: Mode = .normal,
/// a number typed in normal mode before a key, such as a block to go to
prefix: ?usize = null,
/// the block is not colorForth source, and cannot be edited
read_only: bool = false,
/// a block left has changed since it was opened or saved, which
/// `unsaved` also tells of the block being edited
modified: bool = false,
/// tokens deleted or copied, the latest last, to put back
clipboard: [clipboard_capacity]Token = undefined,
clipboard_len: usize = 0,
undos: Snapshots = .{},
redos: Snapshots = .{},

pub const Mode = enum { normal, insert };

pub const Error = error{
    /// the block has no room for another cell
    BlockFull,
    /// the block is not colorForth source
    ReadOnly,
    /// a word colorForth cannot pack, or a variable's name longer than a
    /// cell
    InvalidWord,
    /// a white number that does not fit in 27 bits
    NumberOutOfRange,
    /// a hex number cannot be a word, as colorForth has no `$`
    HexWord,
    NoSuchBlock,
};

const clipboard_capacity = 64;
const history_capacity = 64;

/// Opens a file of `count` blocks, in `blocks` that may hold more, at the
/// first block of source: block 18 of an arrayForth 2 image, past its
/// kernel, and otherwise block 0
pub fn open(self: *Editor, blocks: []u8, count: usize) void {
    std.debug.assert(blocks.len % block_size == 0 and count * block_size <= blocks.len and blocks.len > 0);
    self.* = .{ .blocks = blocks, .count = count };
    self.load(if (colorforth.isImage(blocks)) colorforth.header_block else 0);
}

/// the number of blocks the file can grow to
pub fn capacity(self: Editor) usize {
    return self.blocks.len / block_size;
}

/// the token under the cursor, if there is one
pub fn current(self: *const Editor) ?*const Token {
    return if (self.cursor < self.len) &self.tokens[self.cursor] else null;
}

/// the cells the tokens of the block take, with the one being typed taking
/// what it would as it is
pub fn cells(self: Editor) usize {
    var used: usize = 0;
    for (self.tokens[0..self.len], 0..) |token, i| {
        const typing = self.mode == .insert and i == self.cursor;
        used += if (typing) (finished(token) catch token).cells() else token.cells();
    }
    return used;
}

/// whether a token starts a line, as colorForth shows a block
pub fn startsLine(self: Editor, i: usize) bool {
    return i == 0 or colorforth.startsLine(self.tokens[i - 1], self.tokens[i]);
}

/// Moves to another block, leaving the one being edited as it is
pub fn goTo(self: *Editor, block: usize) Error!void {
    if (block >= self.capacity()) return error.NoSuchBlock;
    self.flush();
    self.load(block);
}

/// The file to save, flushing the block being edited: at least the blocks
/// it had, and as many more as hold anything
pub fn contents(self: *Editor) []const u8 {
    self.flush();
    var n = self.capacity();
    while (n > self.count and std.mem.allEqual(u8, self.blocks[(n - 1) * block_size ..][0..block_size], 0)) n -= 1;
    return self.blocks[0 .. n * block_size];
}

/// whether any block has changed since the file was opened or saved,
/// including the one being edited, or being typed into
pub fn unsaved(self: *Editor) bool {
    self.flush();
    return self.modified or self.mode == .insert;
}

/// notes that `contents` was saved
pub fn saved(self: *Editor) void {
    self.count = self.contents().len / block_size;
    self.modified = false;
}

pub fn left(self: *Editor) void {
    self.cursor -|= 1;
}

pub fn right(self: *Editor) void {
    if (self.cursor + 1 < self.len) self.cursor += 1;
}

pub fn first(self: *Editor) void {
    self.cursor = 0;
}

pub fn last(self: *Editor) void {
    self.cursor = self.len -| 1;
}

/// moves to the next red word, or the last token if there is none
pub fn nextDefinition(self: *Editor) void {
    var i = self.cursor + 1;
    while (i < self.len) : (i += 1) if (self.tokens[i].tag == .define) break;
    self.cursor = @min(i, self.len -| 1);
}

/// moves to the red word before, or the first token if there is none
pub fn previousDefinition(self: *Editor) void {
    var i = self.cursor;
    while (i > 0) {
        i -= 1;
        if (self.tokens[i].tag == .define) break;
    }
    self.cursor = i;
}

/// Starts typing a new token before the cursor, or after it, in the color
/// that would follow the token before it
pub fn insert(self: *Editor, after: bool) Error!void {
    try self.editable();
    const at = if (after and self.len > 0) self.cursor + 1 else self.cursor;
    const before: ?Color = if (at > 0) self.tokens[at - 1].tag.color() else null;
    try self.startToken(at, nextColor(before));
}

/// Starts typing a red word at the start of a new line after the one the
/// cursor is on, or before it, keeping what follows on its own line
pub fn openLine(self: *Editor, above: bool) Error!void {
    try self.editable();
    var at = self.cursor;
    if (above) {
        while (at > 0 and !self.startsLine(at)) at -= 1;
    } else if (self.len > 0) {
        at += 1;
        while (at < self.len and !self.startsLine(at)) at += 1;
    }
    try self.startToken(at, .red);
    // a red word starts a line of its own, and anything else needs a cr
    if (at + 1 < self.len and self.startsLine(at + 1)) return;
    if (at + 1 == self.len) return;
    try self.insertToken(at + 1, cr());
}

/// Types a character into the token being typed
pub fn typeChar(self: *Editor, c: u8) Error!void {
    std.debug.assert(self.mode == .insert);
    const token = &self.tokens[self.cursor];
    // upper case only in comments, and $ only before hex digits, which
    // finishing the word checks
    const packable = std.mem.indexOfScalar(u8, colorforth.characters, c) != null or
        (token.tag.color() == .white and std.mem.indexOfScalar(u8, colorforth.characters, std.ascii.toLower(c)) != null);
    if (c == ' ' or !(packable or c == '$')) return error.InvalidWord;
    if (token.len == colorforth.max_chars) return error.InvalidWord;
    token.chars[token.len] = c;
    token.len += 1;
    if (self.cells() > cells_per_block) {
        token.len -= 1;
        return error.BlockFull;
    }
}

/// Takes back the last character typed, or with none, goes back to typing
/// the token before
pub fn backspace(self: *Editor) void {
    std.debug.assert(self.mode == .insert);
    const token = &self.tokens[self.cursor];
    if (token.len > 0) {
        token.len -= 1;
        return;
    }
    if (self.cursor == 0) return;
    self.removeToken(self.cursor);
    self.cursor -= 1;
    reopen(&self.tokens[self.cursor]);
}

/// Finishes the token being typed and starts the next, unless nothing has
/// been typed
pub fn space(self: *Editor) Error!void {
    std.debug.assert(self.mode == .insert);
    if (self.tokens[self.cursor].len == 0) return;
    try self.finish();
    try self.startToken(self.cursor + 1, nextColor(self.tokens[self.cursor].tag.color()));
}

/// Finishes the token being typed and starts a red one on the next line
pub fn enter(self: *Editor) Error!void {
    std.debug.assert(self.mode == .insert);
    if (self.tokens[self.cursor].len > 0) {
        try self.finish();
        self.cursor += 1;
    } else self.removeToken(self.cursor);
    try self.insertToken(self.cursor, cr());
    try self.startToken(self.cursor + 1, .red);
}

/// Finishes the token being typed, if anything was, and stops typing
pub fn escape(self: *Editor) Error!void {
    if (self.mode == .normal) return;
    if (self.tokens[self.cursor].len > 0) {
        try self.finish();
    } else {
        self.removeToken(self.cursor);
        self.cursor = @min(self.cursor, self.len -| 1);
    }
    self.mode = .normal;
}

/// Changes the color of the token under the cursor, or the one being typed
pub fn setColor(self: *Editor, color: Color) Error!void {
    try self.editable();
    if (self.mode == .insert) {
        self.tokens[self.cursor].tag = wordTag(color);
        return;
    }
    const token = self.current() orelse return;
    var changed: Token = token.*;
    reopen(&changed);
    changed.tag = wordTag(color);
    changed = try finished(changed);
    if (changed.tag == .variable and token.tag == .variable) changed.value = token.value;
    self.checkpoint();
    const old = self.tokens[self.cursor];
    self.tokens[self.cursor] = changed;
    if (self.cells() > cells_per_block) {
        self.tokens[self.cursor] = old;
        _ = self.undos.pop();
        return error.BlockFull;
    }
}

/// Deletes the token under the cursor, or the one before it, onto the
/// clipboard
pub fn delete(self: *Editor, before: bool) Error!void {
    try self.editable();
    if (before and self.cursor == 0) return;
    const at = if (before) self.cursor - 1 else self.cursor;
    if (at >= self.len) return;
    self.checkpoint();
    self.copy(self.tokens[at]);
    self.removeToken(at);
    if (before) self.cursor -= 1;
    self.cursor = @min(self.cursor, self.len -| 1);
}

/// Copies the token under the cursor onto the clipboard, and moves on
pub fn yank(self: *Editor) void {
    const token = self.current() orelse return;
    self.copy(token.*);
    self.right();
}

/// Puts the token last deleted or copied after the cursor, or before it
pub fn put(self: *Editor, after: bool) Error!void {
    try self.editable();
    if (self.clipboard_len == 0) return;
    const at = if (after and self.len > 0) self.cursor + 1 else self.cursor;
    self.checkpoint();
    self.insertToken(at, self.clipboard[self.clipboard_len - 1]) catch |err| {
        _ = self.undos.pop();
        return err;
    };
    self.clipboard_len -= 1;
    self.cursor = at;
}

pub fn undo(self: *Editor) void {
    const s = self.undos.pop() orelse return;
    self.redos.push(self.snapshot());
    self.restore(s);
}

pub fn redo(self: *Editor) void {
    const s = self.redos.pop() orelse return;
    self.undos.push(self.snapshot());
    self.restore(s);
}

/// Moves the cursor to the token at `i`, or the last, finishing any being
/// typed, as clicking on a token does
pub fn moveTo(self: *Editor, i: usize) Error!void {
    try self.escape();
    self.cursor = @min(i, self.len -| 1);
}

/// A key pressed in the editor, as a front end tells of it: a character as
/// typed, with shift giving upper case, or a key with a name. Keys with alt
/// or other modifiers are not the editor's.
pub const Key = struct {
    code: Code,
    ctrl: bool = false,

    pub const Code = union(enum) {
        char: u8,
        left,
        right,
        up,
        down,
        home,
        end,
        page_up,
        page_down,
        escape,
        enter,
        backspace,
    };

    pub fn char(c: u8) Key {
        return .{ .code = .{ .char = c } };
    }
};

/// What a key asks the front end to do, as the editor cannot
pub const Action = enum {
    none,
    /// save `contents` to the file
    save,
    /// compile the block being edited
    compile,
    /// show or hide blue words
    toggle_format,
    quit,
};

/// Handles a key as the editor's key map has it: vim-like moving and
/// editing in normal mode, typing in insert mode, and colors with ctrl, or
/// with shift in normal mode. A number typed before `g` is a block to go to.
pub fn key(self: *Editor, k: Key) Error!Action {
    if (k.ctrl) {
        const c = switch (k.code) {
            .char => |c| c,
            else => return .none,
        };
        // a color, as it is typed or afterwards
        if (colorOfKey("rygwtvb", c)) |color| try self.setColor(color);
        if (c == 's') {
            try self.escape();
            return .save;
        }
        return .none;
    }

    if (self.mode == .insert) {
        switch (k.code) {
            .escape => try self.escape(),
            .enter => try self.enter(),
            .backspace => self.backspace(),
            .char => |c| if (c == ' ') try self.space() else if (c > ' ' and c < 0x7f) try self.typeChar(c),
            else => {},
        }
        return .none;
    }

    // a number typed before a key, such as a block to go to before g
    if (k.code == .char and std.ascii.isDigit(k.code.char) and (k.code.char != '0' or self.prefix != null)) {
        self.prefix = (self.prefix orelse 0) *| 10 +| (k.code.char - '0');
        return .none;
    }
    const prefix = self.prefix;
    self.prefix = null;

    switch (k.code) {
        .left => self.left(),
        .right => self.right(),
        .down => self.nextDefinition(),
        .up => self.previousDefinition(),
        .home => self.first(),
        .end => self.last(),
        .page_down => try self.goTo(self.block + 1),
        .page_up => if (self.block > 0) try self.goTo(self.block - 1),
        .escape, .enter, .backspace => {},
        .char => |c| {
            if (colorOfKey("RYGWCMB", c)) |color| try self.setColor(color);
            switch (c) {
                'h', 'b' => self.left(),
                'l', 'w' => self.right(),
                'j' => self.nextDefinition(),
                'k' => self.previousDefinition(),
                '0' => self.first(),
                '$' => self.last(),
                ']' => try self.goTo(self.block + 1),
                '[' => if (self.block > 0) try self.goTo(self.block - 1),
                'g' => if (prefix) |block| try self.goTo(block) else self.first(),
                'i' => try self.insert(false),
                'a' => try self.insert(true),
                'o' => try self.openLine(false),
                'O' => try self.openLine(true),
                'x' => try self.delete(false),
                'X' => try self.delete(true),
                'y' => self.yank(),
                'p' => try self.put(true),
                'P' => try self.put(false),
                'u' => self.undo(),
                'U' => self.redo(),
                'f' => return .toggle_format,
                's' => return .save,
                'L' => return .compile,
                'q' => return .quit,
                else => {},
            }
        },
    }
    return .none;
}

/// the color a letter of `letters` stands for, in the order of `key_colors`
fn colorOfKey(letters: *const [key_colors.len]u8, c: u8) ?Color {
    const i = std.mem.indexOfScalar(u8, letters, c) orelse return null;
    return key_colors[i];
}

const key_colors = [_]Color{ .red, .yellow, .green, .white, .cyan, .magenta, .blue };

/// what went wrong, to tell whoever is editing
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.BlockFull => "the block is full",
        error.ReadOnly => "this block is not colorForth source, so it cannot be edited",
        error.InvalidWord => "colorForth has no such character here, or names a variable in one cell",
        error.NumberOutOfRange => "a white number fits in 27 bits",
        error.HexWord => "a hex number can only be yellow, green or white",
        error.NoSuchBlock => "there is no such block",
    };
}

fn editable(self: Editor) Error!void {
    if (self.read_only) return error.ReadOnly;
}

/// starts typing an empty token in `color` at `at`, remembering the block
/// to go back to if there is room for it
fn startToken(self: *Editor, at: usize, color: Color) Error!void {
    if (self.mode == .normal) {
        self.checkpoint();
        self.insertToken(at, .{ .tag = wordTag(color) }) catch |err| {
            _ = self.undos.pop();
            return err;
        };
    } else try self.insertToken(at, .{ .tag = wordTag(color) });
    self.cursor = at;
    self.mode = .insert;
}

fn insertToken(self: *Editor, at: usize, token: Token) Error!void {
    if (self.cells() + token.cells() > cells_per_block) return error.BlockFull;
    std.mem.copyBackwards(Token, self.tokens[at + 1 .. self.len + 1], self.tokens[at..self.len]);
    self.tokens[at] = token;
    self.len += 1;
}

fn removeToken(self: *Editor, at: usize) void {
    std.mem.copyForwards(Token, self.tokens[at .. self.len - 1], self.tokens[at + 1 .. self.len]);
    self.len -= 1;
}

/// makes the token being typed a word or number it can be, staying in
/// insert mode if it cannot
fn finish(self: *Editor) Error!void {
    const token = try finished(self.tokens[self.cursor]);
    const old = self.tokens[self.cursor];
    self.tokens[self.cursor] = token;
    if (self.cells() > cells_per_block) {
        self.tokens[self.cursor] = old;
        return error.BlockFull;
    }
}

/// a word as typed, as the word or number it can be
fn finished(typed: Token) Error!Token {
    if (typed.tag.isNumber()) return typed;
    const text = typed.text();
    const color = typed.tag.color();
    if (color == .yellow or color == .green or color == .white) if (parseNumber(text)) |number| {
        return Token.number(color, number.value, number.hex) catch error.NumberOutOfRange;
    };
    if (std.mem.indexOfScalar(u8, text, '$') != null) return error.HexWord;
    var token = Token.word(typed.tag, text) catch return error.InvalidWord;
    if (token.tag == .variable and token.cells() > 2) return error.InvalidWord;
    token.value = typed.value;
    return token;
}

/// makes a finished token one being typed again, a number as its digits
fn reopen(token: *Token) void {
    if (token.tag.isNumber()) {
        var writer: Io.Writer = .fixed(&token.chars);
        token.format(&writer) catch unreachable;
        token.len = @intCast(writer.end);
    }
    token.tag = wordTag(token.tag.color());
}

fn copy(self: *Editor, token: Token) void {
    if (self.clipboard_len == clipboard_capacity) {
        std.mem.copyForwards(Token, self.clipboard[0 .. clipboard_capacity - 1], self.clipboard[1..]);
        self.clipboard_len -= 1;
    }
    self.clipboard[self.clipboard_len] = token;
    self.clipboard_len += 1;
}

/// remembers the block before a change, to undo it, which forgets what was
/// undone
fn checkpoint(self: *Editor) void {
    self.undos.push(self.snapshot());
    self.redos = .{};
}

fn snapshot(self: *Editor) Snapshot {
    self.flush();
    return .{ .block = self.block, .cursor = self.cursor, .bytes = self.blocks[self.block * block_size ..][0..block_size].* };
}

fn restore(self: *Editor, s: Snapshot) void {
    self.flush();
    @memcpy(self.blocks[s.block * block_size ..][0..block_size], &s.bytes);
    self.modified = true;
    self.load(s.block);
    self.cursor = @min(s.cursor, self.len -| 1);
}

/// encodes the tokens back into the block, unless it is being typed into
fn flush(self: *Editor) void {
    if (self.read_only or self.mode == .insert) return;
    var bytes: [block_size]u8 = undefined;
    // tokens never take more cells than the block has
    colorforth.encode(self.tokens[0..self.len], &bytes) catch unreachable;
    const block = self.blocks[self.block * block_size ..][0..block_size];
    if (std.mem.eql(u8, block, &bytes)) return;
    block.* = bytes;
    self.modified = true;
}

/// decodes a block, which can be edited if it encodes back the same
fn load(self: *Editor, block: usize) void {
    self.block = block;
    self.cursor = 0;
    self.mode = .normal;
    const bytes = self.blocks[block * block_size ..][0..block_size];
    const tokens = colorforth.decode(bytes, &self.tokens) catch {
        self.len = 0;
        self.read_only = true;
        return;
    };
    self.len = tokens.len;
    var encoded: [block_size]u8 = undefined;
    colorforth.encode(tokens, &encoded) catch {
        self.read_only = true;
        return;
    };
    self.read_only = !std.mem.eql(u8, bytes, &encoded);
}

/// the tag of a word typed in a color
fn wordTag(color: Color) Tag {
    return switch (color) {
        .red => .define,
        .yellow => .execute,
        .green, .none, .gray => .compile,
        .cyan => .macro,
        .white => .comment,
        .magenta => .variable,
        .blue => .format,
    };
}

/// the color of a token typed after one, or a red one first
fn nextColor(before: ?Color) Color {
    const color = before orelse return .red;
    return switch (color) {
        .red, .cyan, .magenta, .blue, .gray, .none => .green,
        else => color,
    };
}

/// a blue cr, which ends a line
fn cr() Token {
    return Token.word(.format, "cr") catch unreachable;
}

/// a number as typed: decimal digits or `$` and hex digits, after an
/// optional `-`
pub fn parseNumber(text: []const u8) ?struct { value: i32, hex: bool } {
    var digits = text;
    const negative = digits.len > 0 and digits[0] == '-';
    if (negative) digits = digits[1..];
    const hex = digits.len > 0 and digits[0] == '$';
    if (hex) digits = digits[1..];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c) and !(hex and std.ascii.isHex(c))) return null;
    const magnitude = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return null;
    // hex numbers wrap, as colorForth shows cells, and decimal ones do not
    if (!hex and magnitude > @as(u32, if (negative) 1 << 31 else (1 << 31) - 1)) return null;
    const value: i32 = @bitCast(magnitude);
    return .{ .value = if (negative) -%value else value, .hex = hex };
}

const Snapshot = struct {
    block: usize,
    cursor: usize,
    bytes: [block_size]u8,
};

/// the latest `history_capacity` snapshots, dropping the oldest
const Snapshots = struct {
    items: [history_capacity]Snapshot = undefined,
    start: usize = 0,
    len: usize = 0,

    fn push(self: *Snapshots, s: Snapshot) void {
        if (self.len == history_capacity) {
            self.start = (self.start + 1) % history_capacity;
            self.len -= 1;
        }
        self.items[(self.start + self.len) % history_capacity] = s;
        self.len += 1;
    }

    fn pop(self: *Snapshots) ?Snapshot {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.items[(self.start + self.len) % history_capacity];
    }
};

const colorforth = @import("colorforth.zig");
const block_size = colorforth.block_size;
const cells_per_block = colorforth.cells_per_block;
const Color = colorforth.Color;
const Tag = colorforth.Tag;
const Token = colorforth.Token;

const std = @import("std");
const Io = std.Io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

/// an editor on a file of `blocks` empty blocks, or ones given
fn testEditor(comptime blocks: usize) !struct { *Editor, *[blocks * block_size]u8 } {
    const editor = try std.testing.allocator.create(Editor);
    const bytes = try std.testing.allocator.create([blocks * block_size]u8);
    @memset(bytes, 0);
    editor.open(bytes, blocks);
    return .{ editor, bytes };
}

fn freeEditor(editor: *Editor, bytes: anytype) void {
    std.testing.allocator.destroy(editor);
    std.testing.allocator.destroy(bytes);
}

fn typeText(editor: *Editor, text: []const u8) !void {
    for (text) |c| if (c == ' ') try editor.space() else try editor.typeChar(c);
}

/// the editor's block as text
fn expectText(editor: *Editor, expected: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try colorforth.writeText(editor.tokens[0..editor.len], &writer);
    try expectEqualStrings(expected, writer.buffered());
}

test "typing a definition, with colors following the one before" {
    const editor, const bytes = try testEditor(2);
    defer freeEditor(editor, bytes);
    try expect(!editor.read_only);
    try expect(!editor.unsaved());

    // the first word is red, and green follows it
    try editor.insert(false);
    try typeText(editor, "inc 1 + ;");
    try editor.escape();
    try expectEqual(.normal, editor.mode);
    try expectText(editor, ":inc ]1 + ;\n");
    try expect(editor.unsaved());
    try expectEqual(.compile_short, editor.tokens[1].tag);
    try expectEqual(3, editor.cursor);

    // enter starts a red word on the next line, and a color typed changes
    // the word being typed
    try editor.insert(true);
    try editor.enter();
    try typeText(editor, "x ");
    try editor.setColor(.yellow);
    try typeText(editor, "$1f -5 dup");
    try editor.setColor(.cyan);
    try editor.escape();
    try expectText(editor, ":inc ]1 + ; ~cr\n:x [$1f -5 \\dup\n");
    try expect(editor.tokens[6].hex);
    try expectEqual(-5, editor.tokens[7].value);

    // the block is written back as the editor leaves it
    try editor.goTo(1);
    try expect(editor.modified);
    var tokens: [cells_per_block]Token = undefined;
    try expectEqual(9, (try colorforth.decode(bytes[0..block_size], &tokens)).len);
    try expectEqual(2 * block_size, editor.contents().len);
    editor.saved();
    try expect(!editor.unsaved());
}

test "words that cannot be typed" {
    const editor, const bytes = try testEditor(1);
    defer freeEditor(editor, bytes);
    try editor.insert(false);
    try expectError(error.InvalidWord, editor.typeChar('#'));
    try expectError(error.InvalidWord, editor.typeChar('D'));
    // a red word cannot be a hex number, or a name a number
    try typeText(editor, "$1");
    try expectError(error.HexWord, editor.space());
    try expectEqual(.insert, editor.mode);
    editor.backspace();
    editor.backspace();
    try typeText(editor, "x ");
    try editor.setColor(.white);
    try typeText(editor, "GA144 Chuck");
    try editor.typeChar('M');
    try expectError(error.InvalidWord, editor.escape());
    editor.backspace();
    try editor.escape();
    try expectText(editor, ":x (GA144 Chuck\n");

    // backspace past the start of a word goes back into the one before
    try editor.insert(true);
    editor.backspace();
    try expectEqualStrings("Chuck", editor.tokens[editor.cursor].text());
    editor.backspace();
    try editor.escape();
    try expectText(editor, ":x (GA144 Chuc\n");
}

test "moving, deleting, putting back, and undoing" {
    const editor, const bytes = try testEditor(1);
    defer freeEditor(editor, bytes);
    try editor.insert(false);
    try typeText(editor, "a 1 ");
    try editor.enter();
    try typeText(editor, "b 2 ");
    try editor.enter();
    try typeText(editor, "c 3");
    try editor.escape();
    try expectText(editor, ":a ]1 ~cr\n:b ]2 ~cr\n:c ]3\n");

    editor.first();
    editor.nextDefinition();
    try expectEqualStrings("b", editor.current().?.text());
    editor.nextDefinition();
    editor.previousDefinition();
    try expectEqualStrings("b", editor.current().?.text());
    try expect(editor.startsLine(editor.cursor));

    try editor.delete(false);
    try editor.delete(false);
    try expectText(editor, ":a ]1 ~cr\ncr\n:c ]3\n");
    try editor.put(false);
    try editor.put(false);
    try expectText(editor, ":a ]1 ~cr\n:b ]2 ~cr\n:c ]3\n");

    try editor.setColor(.magenta);
    try expectText(editor, ":a ]1 ~cr\n@b 0 ]2 ~cr\n:c ]3\n");
    try editor.setColor(.green);
    try expectText(editor, ":a ]1 ~cr\n]b 2 ~cr\n:c ]3\n");
    editor.undo();
    try expectText(editor, ":a ]1 ~cr\n@b 0 ]2 ~cr\n:c ]3\n");
    editor.undo();
    try expectText(editor, ":a ]1 ~cr\n:b ]2 ~cr\n:c ]3\n");
    editor.redo();
    try expectText(editor, ":a ]1 ~cr\n@b 0 ]2 ~cr\n:c ]3\n");

    // a line opened below keeps what follows on its own
    editor.first();
    try editor.openLine(false);
    try typeText(editor, "new");
    try editor.escape();
    try expectText(editor, ":a ]1 ~cr\n:new\n@b 0 ]2 ~cr\n:c ]3\n");
    // and one that does not start a line by itself is put on its own
    editor.undo();
    editor.cursor = 3;
    try editor.setColor(.green);
    editor.first();
    try editor.openLine(false);
    try typeText(editor, "new");
    try editor.escape();
    try expectText(editor, ":a ]1 ~cr\n:new ~cr\n]b 2 ~cr\n:c ]3\n");
}

test "a full block takes no more" {
    const editor, const bytes = try testEditor(1);
    defer freeEditor(editor, bytes);
    try editor.insert(false);
    for (0..cells_per_block - 1) |_| try typeText(editor, "a ");
    try typeText(editor, "b");
    try expectError(error.BlockFull, editor.space());
    try editor.escape();
    try expectEqual(cells_per_block, editor.len);
    try expectEqual(cells_per_block, editor.cells());
    try expectError(error.BlockFull, editor.insert(true));

    // a number being typed takes the cells it will, so one too large for a
    // cell of its own does not fit
    editor.last();
    try editor.delete(false);
    try editor.insert(true);
    try typeText(editor, "9999999");
    try expectError(error.BlockFull, editor.typeChar('9'));
}

test "blocks that are not source cannot be edited" {
    // a block with more after the zero cell that ends it
    var bytes: [2 * block_size]u8 = @splat(0);
    bytes[0] = 1;
    bytes[8] = 0x12;
    var editor: Editor = undefined;
    editor.open(&bytes, 2);
    try expect(editor.read_only);
    try expectError(error.ReadOnly, editor.insert(false));
    try editor.goTo(1);
    try expect(!editor.read_only);
    try expectError(error.NoSuchBlock, editor.goTo(2));
    // and leaving them changes nothing
    try editor.goTo(0);
    try expect(!editor.modified);
}

test "numbers as typed" {
    try expectEqual(5, parseNumber("5").?.value);
    try expectEqual(-5, parseNumber("-5").?.value);
    try expectEqual(-1, parseNumber("$ffffffff").?.value);
    try expectEqual(-0x1f, parseNumber("-$1f").?.value);
    try expectEqual(std.math.minInt(i32), parseNumber("-2147483648").?.value);
    try expectEqual(null, parseNumber("2147483648"));
    try expectEqual(null, parseNumber("-"));
    try expectEqual(null, parseNumber("1,"));
    try expectEqual(null, parseNumber("$"));
}

/// gives the editor each character of `text` as a key
fn keys(editor: *Editor, text: []const u8) !Action {
    var action: Action = .none;
    for (text) |c| action = try editor.key(.char(c));
    return action;
}

test key {
    const editor, const bytes = try testEditor(3);
    defer freeEditor(editor, bytes);

    // typing, with ctrl for a color as it is typed
    try expectEqual(.none, try keys(editor, "iinc 1 + ; x"));
    try expectEqual(.none, try editor.key(.{ .code = .{ .char = 'y' }, .ctrl = true }));
    _ = try editor.key(.{ .code = .escape });
    try expectEqual(.normal, editor.mode);
    try expectText(editor, ":inc ]1 + ; [x\n");

    // moving and changing a color with shift
    _ = try keys(editor, "0lW");
    try expectText(editor, ":inc (1 ]+ ; [x\n");
    _ = try editor.key(.{ .code = .end });
    try expectEqual(4, editor.cursor);

    // a number before g is a block to go to, and g alone the first token
    _ = try keys(editor, "2g");
    try expectEqual(2, editor.block);
    try expectEqual(null, editor.prefix);
    _ = try editor.key(.{ .code = .page_up });
    try expectEqual(1, editor.block);
    _ = try keys(editor, "[");
    _ = try keys(editor, "$g");
    try expectEqual(0, editor.cursor);

    // what the front end does, saving with ctrl+s from typing too
    try expectEqual(.save, try keys(editor, "s"));
    try expectEqual(.compile, try keys(editor, "L"));
    try expectEqual(.toggle_format, try keys(editor, "f"));
    try expectEqual(.quit, try keys(editor, "q"));
    _ = try keys(editor, "a");
    try expectEqual(.save, try editor.key(.{ .code = .{ .char = 's' }, .ctrl = true }));
    try expectEqual(.normal, editor.mode);

    try expectError(error.NoSuchBlock, keys(editor, "9g"));
}

test "the rest of the key map" {
    const editor, const bytes = try testEditor(1);
    defer freeEditor(editor, bytes);

    // two definitions, with backspace and enter as typed
    _ = try keys(editor, "ia 1 ;x");
    _ = try editor.key(.{ .code = .backspace });
    _ = try editor.key(.{ .code = .enter });
    _ = try editor.key(.{ .code = .{ .char = 'r' }, .ctrl = true });
    _ = try keys(editor, "b 2 ;");
    _ = try editor.key(.{ .code = .escape });
    try expectText(editor, ":a ]1 ; ~cr\n:b ]2 ;\n");

    // moving by token and by definition, with letters and named keys
    _ = try keys(editor, "0j");
    try expectEqual(4, editor.cursor);
    _ = try keys(editor, "k");
    try expectEqual(0, editor.cursor);
    _ = try editor.key(.{ .code = .down });
    try expectEqual(4, editor.cursor);
    _ = try editor.key(.{ .code = .up });
    try expectEqual(0, editor.cursor);
    _ = try keys(editor, "lw");
    try expectEqual(2, editor.cursor);
    _ = try keys(editor, "h");
    _ = try editor.key(.{ .code = .right });
    try expectEqual(2, editor.cursor);
    _ = try keys(editor, "b");
    _ = try editor.key(.{ .code = .left });
    try expectEqual(0, editor.cursor);
    _ = try editor.key(.{ .code = .end });
    _ = try editor.key(.{ .code = .home });
    try expectEqual(0, editor.cursor);

    // escape, enter and backspace do nothing out of insert mode, nor ctrl
    // with a key that is not a character, and a number before another key
    // is forgotten
    for ([_]Key.Code{ .escape, .enter, .backspace }) |code| _ = try editor.key(.{ .code = code });
    try expectEqual(.none, try editor.key(.{ .code = .left, .ctrl = true }));
    _ = try keys(editor, "3l");
    try expectEqual(null, editor.prefix);
    try expectEqual(1, editor.cursor);

    // deleting, undoing and redoing
    _ = try keys(editor, "0x");
    try expectText(editor, "]1 ; ~cr\n:b ]2 ;\n");
    _ = try keys(editor, "u");
    try expectText(editor, ":a ]1 ; ~cr\n:b ]2 ;\n");
    _ = try keys(editor, "U");
    try expectText(editor, "]1 ; ~cr\n:b ]2 ;\n");
    _ = try keys(editor, "uX");
    try expectText(editor, ":a ]1 ; ~cr\n:b ]2 ;\n");
    _ = try keys(editor, "lX");
    try expectText(editor, "]1 ; ~cr\n:b ]2 ;\n");

    // copying and putting after and before
    _ = try keys(editor, "0yp");
    try expectText(editor, "]1 ; 1 ~cr\n:b ]2 ;\n");
    _ = try keys(editor, "yP");
    try expectText(editor, "]1 ; 1 1 ~cr\n:b ]2 ;\n");

    // opening a line below and above, to type in
    _ = try keys(editor, "o");
    try expectEqual(.insert, editor.mode);
    _ = try keys(editor, "c");
    _ = try editor.key(.{ .code = .escape });
    _ = try keys(editor, "0O");
    try expectEqual(.insert, editor.mode);
    _ = try keys(editor, "d");
    _ = try editor.key(.{ .code = .escape });
    try expectText(editor, ":d ~cr\n]1 ; 1 1 ~cr\n:c\n:b ]2 ;\n");
}

test describe {
    try expectEqualStrings("the block is full", describe(error.BlockFull));
    try expectEqualStrings("there is no such block", describe(error.NoSuchBlock));
}

test moveTo {
    const editor, const bytes = try testEditor(1);
    defer freeEditor(editor, bytes);
    _ = try keys(editor, "ia b c");
    try editor.moveTo(1);
    try expectEqual(.normal, editor.mode);
    try expectEqual(1, editor.cursor);
    try editor.moveTo(10);
    try expectEqual(2, editor.cursor);
}
