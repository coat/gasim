//! A writer that keeps the last of what is written to it, dropping the
//! older half of its lines whenever its buffer is full, such as for a
//! trace to show as the chip runs.
//!
//! The writer points back into it, so it must not move once written to.

const Tail = @This();

writer: Io.Writer,
/// lines were dropped to make room
dropped: bool = false,

pub fn init(buffer: []u8) Tail {
    return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
}

/// Forgets what was written
pub fn clear(self: *Tail) void {
    self.writer.end = 0;
    self.dropped = false;
}

fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const self: *Tail = @alignCast(@fieldParentPtr("writer", w));
    self.dropped = true;
    const kept = w.buffer[w.end / 2 .. w.end];
    const lines = if (std.mem.indexOfScalar(u8, kept, '\n')) |nl| kept[nl + 1 ..] else kept[kept.len..];
    @memmove(w.buffer[0..lines.len], lines);
    w.end = lines.len;
    // what cannot fit even so is dropped too
    if (data[0].len <= w.buffer.len - w.end) return 0;
    var len: usize = 0;
    for (data[0 .. data.len - 1]) |d| len += d.len;
    return len + data[data.len - 1].len * splat;
}

const std = @import("std");
const Io = std.Io;

test "keeps whole lines, the last of them" {
    var buffer: [64]u8 = undefined;
    var tail: Tail = .init(&buffer);
    for (0..20) |k| try tail.writer.print("line {d:0>3}\n", .{k});
    try std.testing.expect(tail.dropped);
    const kept = tail.writer.buffered();
    try std.testing.expectStringStartsWith(kept, "line ");
    try std.testing.expectStringEndsWith(kept, "line 019\n");

    tail.clear();
    try std.testing.expectEqualStrings("", tail.writer.buffered());
    try std.testing.expect(!tail.dropped);
}
