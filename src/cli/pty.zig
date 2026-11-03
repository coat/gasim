//! A pseudo-terminal for one of a board's serial ports, as a USB serial
//! port's device would be: a program such as arrayForth 3 under Wine opens
//! the terminal side (`path`), and gasim reads and writes the other. The
//! terminal side is kept open too, so that reading does not fail while no
//! program has it open, and is raw, so that bytes pass as they are.

master: Io.File,
/// kept open, as above
terminal: Io.File,
/// the terminal side's path, such as /dev/pts/7
path: [:0]const u8,
/// what the chip sends, for `writeOut` to write to the terminal side's
/// reader. Bytes no one reads in time are dropped, as a USB serial chip's
/// would be, rather than holding up the chip.
writer: Io.Writer,
/// what the chip sent and `writeOut` has not written yet
output: Io.Queue(u8),
io: Io,
/// bytes dropped, as no one read them
dropped: usize = 0,

const Pty = @This();

/// with libc, which the pseudo-terminal calls are in
pub const supported = builtin.link_libc and (builtin.os.tag == .linux or builtin.os.tag.isDarwin() or builtin.os.tag.isBSD());

/// whether `path` is a pseudo-terminal's terminal side, as Linux and the
/// BSDs, or macOS, name them
pub fn isPtyPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/dev/pts/") or std.mem.startsWith(u8, path, "/dev/ttys");
}

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

pub const OpenError = error{ OpenFailed, NotATerminal, Unexpected, ProcessOrphaned, OutOfMemory };

/// Opens a pseudo-terminal, with its path allocated in `arena`, an output
/// buffer of `buffer`, and `queue` for what is waiting to be written
pub fn open(io: Io, arena: Allocator, buffer: []u8, queue: []u8) OpenError!Pty {
    if (comptime !supported) return error.OpenFailed;
    return openSupported(io, arena, buffer, queue);
}

fn openSupported(io: Io, arena: Allocator, buffer: []u8, queue: []u8) OpenError!Pty {
    const flags: std.c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
    const master = posix_openpt(@bitCast(flags));
    if (master < 0) return error.OpenFailed;
    errdefer _ = std.c.close(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) return error.OpenFailed;
    const name = ptsname(master) orelse return error.OpenFailed;
    const path = try arena.dupeSentinel(u8, std.mem.span(name), 0);
    const terminal = std.c.open(path, flags);
    if (terminal < 0) return error.OpenFailed;
    errdefer _ = std.c.close(terminal);
    try makeRaw(terminal);
    return .{
        .master = .{ .handle = master, .flags = .{ .nonblocking = false } },
        .terminal = .{ .handle = terminal, .flags = .{ .nonblocking = false } },
        .path = path,
        .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } },
        .output = .init(queue),
        .io = io,
    };
}

pub fn close(self: *Pty, io: Io) void {
    self.master.close(io);
    self.terminal.close(io);
}

/// as cfmakeraw does: bytes in and out as they are, 8 bits, no echo
fn makeRaw(fd: posix.fd_t) !void {
    var t = try posix.tcgetattr(fd);
    t.iflag.IGNBRK = false;
    t.iflag.BRKINT = false;
    t.iflag.PARMRK = false;
    t.iflag.ISTRIP = false;
    t.iflag.INLCR = false;
    t.iflag.IGNCR = false;
    t.iflag.ICRNL = false;
    t.iflag.IXON = false;
    t.oflag.OPOST = false;
    t.lflag.ECHO = false;
    t.lflag.ECHONL = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.cflag.CSIZE = .CS8;
    t.cflag.PARENB = false;
    try posix.tcsetattr(fd, .NOW, t);
}

fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const self: *Pty = @alignCast(@fieldParentPtr("writer", w));
    self.send(w.buffered());
    w.end = 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        self.send(bytes);
        n += bytes.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| self.send(last);
    return n + last.len * splat;
}

/// queues what there is room for, dropping the rest
fn send(self: *Pty, bytes: []const u8) void {
    const queued = self.output.putUncancelable(self.io, bytes, 0) catch 0;
    self.dropped += bytes.len - queued;
}

/// Writes what the chip sends to the terminal side, on a thread of its own
/// until canceled, as a write blocks while the terminal side's reader has no
/// room: `poll` saying there is room is no promise of how much, and on macOS
/// is only a byte's
pub fn writeOut(self: *Pty) (Io.File.Writer.Error || Io.QueueClosedError)!void {
    var buffer: [256]u8 = undefined;
    while (true) {
        const n = try self.output.get(self.io, &buffer, 1);
        try self.master.writeStreamingAll(self.io, buffer[0..n]);
    }
}

test "bytes pass both ways through a pseudo-terminal" {
    if (!supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer: [16]u8 = undefined;
    var queue: [16]u8 = undefined;
    var pty = try open(std.testing.io, arena_state.allocator(), &buffer, &queue);
    defer pty.close(std.testing.io);
    try std.testing.expect(std.mem.startsWith(u8, pty.path, "/dev/"));
    var writing = try std.testing.io.concurrent(writeOut, .{&pty});
    defer writing.cancel(std.testing.io) catch {};

    // a program on the terminal side, without echo or line editing
    const program = std.c.open(pty.path, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    try std.testing.expect(program >= 0);
    defer _ = std.c.close(program);
    try std.testing.expectEqual(3, std.c.write(program, "a\rb", 3));
    var got: [3]u8 = undefined;
    try std.testing.expectEqual(3, std.c.read(pty.master.handle, &got, 3));
    try std.testing.expectEqualStrings("a\rb", &got);

    try pty.writer.writeAll("\n\x00");
    try pty.writer.flush();
    try std.testing.expectEqual(2, std.c.read(program, &got, 3));
    try std.testing.expectEqualStrings("\n\x00", got[0..2]);
    try std.testing.expectEqual(0, pty.dropped);
}

test "bytes no one reads are dropped" {
    if (!supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer: [16]u8 = undefined;
    var queue: [16]u8 = undefined;
    var pty = try open(std.testing.io, arena_state.allocator(), &buffer, &queue);
    defer pty.close(std.testing.io);
    var writing = try std.testing.io.concurrent(writeOut, .{&pty});
    defer writing.cancel(std.testing.io) catch {};
    const block: [4096]u8 = @splat('x');
    for (0..256) |_| try pty.writer.writeAll(&block);
    try pty.writer.flush();
    try std.testing.expect(pty.dropped > 0);
}

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
