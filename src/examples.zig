//! Lists the examples for the Examples menus in the GUI and the web version.
//!
//! An example is a .ga, .af or .cf file. Its description comes from the
//! comment at the start of the file, in the form `name - what it does`.
//!
//! All three languages assemble to the same code. If a program has more
//! than one version, the list shows only one: the .cf version, because the
//! editor can change it, or else the .ga version.

const std = @import("std");
const colorforth = @import("colorforth.zig");

/// The extensions of example files. When a program has several versions,
/// the list keeps the one whose extension comes first here.
pub const extensions: []const []const u8 = &.{ ".cf", ".ga", ".af" };

/// How much of a file to read to find its description.
pub const header_size = colorforth.block_size;

pub fn isExample(name: []const u8) bool {
    return rank(name) != null;
}

/// Returns the position of the file's extension in `extensions`.
fn rank(name: []const u8) ?usize {
    for (extensions, 0..) |ext, k| if (std.mem.endsWith(u8, name, ext) and name.len > ext.len) return k;
    return null;
}

/// Returns the file name without its extension.
fn stem(name: []const u8) []const u8 {
    return name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
}

/// Returns the example's description, written into `buffer`, or null if
/// the file has none.
///
/// The description is the comment at the start of the file, with these
/// changes:
/// - It drops the file's name and the ` - ` after it. The name can have
///   its extension or not.
/// - It drops a closing `, as hello.ga does`, because the list shows only
///   one version.
/// - It capitalizes the first letter.
pub fn about(name: []const u8, bytes: []const u8, buffer: []u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    (if (std.mem.endsWith(u8, name, ".cf")) colorforthComment(bytes, &w) else sourceComment(bytes, &w)) catch {};
    const written = buffer[0..w.end];
    var start = std.mem.indexOfNone(u8, written, " ") orelse return null;
    if (std.mem.indexOf(u8, written[start..], " - ")) |dash| {
        const named = written[start..][0..dash];
        if (std.mem.eql(u8, named, name) or std.mem.eql(u8, named, stem(name))) start += dash + 3;
    }
    var text = written[start..];
    // For example, "print a greeting, as hello.ga does" becomes "print a greeting".
    if (std.mem.indexOf(u8, text, ", as ")) |as| {
        const after = text[as + 5 ..];
        const word = std.mem.trimEnd(u8, after[0 .. std.mem.indexOfScalar(u8, after, ' ') orelse after.len], ".,;:");
        if (isExample(word)) text.len = as;
    }
    while (text.len > 0 and text[text.len - 1] == ' ') text.len -= 1;
    if (text.len == 0) return null;
    text[0] = std.ascii.toUpper(text[0]);
    return text;
}

/// Writes the `\` comment lines at the start of a .ga or .af file, joined
/// with spaces. It stops at the first empty comment line.
fn sourceComment(bytes: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var lines = std.mem.splitScalar(u8, bytes[0..@min(bytes.len, header_size)], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r\t");
        if (!std.mem.startsWith(u8, line, "\\ ")) return;
        const text = std.mem.trim(u8, line[2..], " \t");
        if (text.len == 0) return;
        if (w.end > 0) try w.writeByte(' ');
        try w.writeAll(text);
    }
}

/// Writes the white (comment) words at the start of block 0 of a .cf file.
/// It stops at the first word of another color, such as the blue `cr` at the
/// end of the first line. If the file is shorter than a block, it reads the
/// rest as zeros.
fn colorforthComment(bytes: []const u8, w: *std.Io.Writer) (colorforth.Error || std.Io.Writer.Error)!void {
    var block: [colorforth.block_size]u8 = @splat(0);
    const len = @min(bytes.len, block.len);
    @memcpy(block[0..len], bytes[0..len]);
    var reader: colorforth.Reader = .{ .block = &block };
    while (try reader.next()) |token| {
        if (token.tag.color() != .white) return;
        if (w.end > 0) try w.writeByte(' ');
        try w.print("{f}", .{token});
    }
}

/// An example's file name and description.
pub const Example = struct {
    name: []const u8,
    about: []const u8,

    /// Sorts by name without the extension, then in the order of `extensions`.
    fn lessThan(_: void, a: Example, b: Example) bool {
        return switch (std.mem.order(u8, stem(a.name), stem(b.name))) {
            .lt => true,
            .gt => false,
            .eq => rank(a.name).? < rank(b.name).?,
        };
    }
};

/// Returns the examples in `dir`, sorted by name, with one version of each
/// program. It skips folders inside `dir`. If it can't read `dir`, it returns
/// an empty list.
pub fn list(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) std.mem.Allocator.Error![]Example {
    var found: std.ArrayList(Example) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        // Some file systems don't report the kind. If the entry is a folder,
        // reading it below fails, and the loop skips it.
        if (entry.kind != .file and entry.kind != .sym_link and entry.kind != .unknown) continue;
        if (!isExample(entry.name)) continue;
        var file = dir.openFile(io, entry.name, .{}) catch continue;
        defer file.close(io);
        var bytes: [header_size]u8 = undefined;
        const len = file.readPositionalAll(io, &bytes, 0) catch continue;
        const name = try arena.dupe(u8, entry.name);
        var buffer: [256]u8 = undefined;
        try found.append(arena, .{ .name = name, .about = try arena.dupe(u8, about(name, bytes[0..len], &buffer) orelse "") });
    }
    std.mem.sort(Example, found.items, {}, Example.lessThan);
    // Keep the first version of each program.
    var kept: usize = 0;
    for (found.items) |e| {
        if (kept > 0 and std.mem.eql(u8, stem(found.items[kept - 1].name), stem(e.name))) continue;
        found.items[kept] = e;
        kept += 1;
    }
    return found.items[0..kept];
}

const expectEqualStrings = std.testing.expectEqualStrings;

test "what a .ga or .af file does is the comment it starts with" {
    var buffer: [256]u8 = undefined;
    try expectEqualStrings("Print a greeting", about("hello.ga", "\\ hello.ga - print a greeting\n\\\n\\ More.\n: main", &buffer).?);
    try expectEqualStrings(
        "Copy input",
        about("echo.af", "\\ echo.af - copy input, as\r\n\\ echo.ga does in arrayForth 3\n\n: main", &buffer).?,
    );
    try std.testing.expectEqual(null, about("x.ga", ": main ;", &buffer));
    // It drops ", as" only when an example's file name follows.
    try expectEqualStrings("Print, as fast as it can", about("x.ga", "\\ x.ga - print, as fast as it can\n", &buffer).?);
    try expectEqualStrings("Print", about("x.ga", "\\ x.ga - print, as x.cf.\n", &buffer).?);
    // It drops the text before " - " only when that text is the file's name.
    try expectEqualStrings("Print a greeting - slowly", about("x.ga", "\\ print a greeting - slowly\n", &buffer).?);
    try expectEqualStrings("Print", about("x.ga", "\\ x - print\n", &buffer).?);
}

test "what a .cf file does is the comment its block 0 starts with" {
    const tokens = [_]colorforth.Token{
        try .word(.comment, "hello"),
        try .word(.comment, "-"),
        try .word(.comment, "print"),
        try .word(.comment, "it"),
        try .word(.execute, "node"),
        try .word(.comment, "more"),
    };
    var block: [colorforth.block_size]u8 = undefined;
    try colorforth.encode(&tokens, &block);
    var buffer: [256]u8 = undefined;
    try expectEqualStrings("Print it", about("hello.cf", &block, &buffer).?);
    // A file shorter than a block.
    try expectEqualStrings("Print it", about("hello.cf", block[0 .. 4 * 4], &buffer).?);
    try colorforth.encode(tokens[4..], &block);
    try std.testing.expectEqual(null, about("hello.cf", &block, &buffer));
}

test "the repository's examples each say what they do" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "examples", .{ .iterate = true });
    defer dir.close(std.testing.io);
    const all = try list(arena.allocator(), std.testing.io, dir);
    try std.testing.expect(all.len > 0);
    for (all) |e| {
        try std.testing.expect(isExample(e.name));
        if (e.about.len == 0) {
            std.debug.print("{s} does not say what it does\n", .{e.name});
            return error.TestUnexpectedResult;
        }
    }
    // One version of each program, the .cf one when there is one.
    var names: std.ArrayList(u8) = .empty;
    for (all) |e| try names.print(arena.allocator(), " {s} ", .{e.name});
    for ([_][]const u8{ " hello.cf ", " echo.cf ", " upcase.cf ", " uart.ga " }) |n| try std.testing.expect(std.mem.indexOf(u8, names.items, n) != null);
    for ([_][]const u8{ " hello.ga ", " hello.af ", " echo.af ", " upcase.ga " }) |n| try std.testing.expect(std.mem.indexOf(u8, names.items, n) == null);
    for (all) |e| if (std.mem.eql(u8, e.name, "hello.cf")) try expectEqualStrings("Print a greeting", e.about);
}
