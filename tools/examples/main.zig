//! Writes the examples in a folder, with their descriptions, as JSON. The
//! web version's Examples menu reads it, because a web page can't list a
//! folder. `zig build web` runs it.
//!
//!   examples <dir> <index.json>
const std = @import("std");
const examples = @import("examples");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: examples <dir> <index.json>\n", .{});
        std.process.exit(2);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    const all = try examples.list(arena, io, dir);

    var out = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer out.close(io);
    var buffer: [4096]u8 = undefined;
    var w = out.writer(io, &buffer);
    try std.json.Stringify.value(all, .{ .whitespace = .indent_2 }, &w.interface);
    try w.interface.writeByte('\n');
    try w.interface.flush();
}
