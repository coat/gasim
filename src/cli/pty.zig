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

/// The modem lines a program on the terminal side sets, RTS and DTR, which
/// a pty does not carry: a program loaded with libgasim-pty.so
/// (`preload.zig`), such as Wine, gets and sets them through a socket named
/// after the terminal side's path (see `lines.zig`). Only on Linux, which
/// has abstract sockets.
pub const lines_supported = supported and builtin.os.tag == .linux;

comptime {
    std.debug.assert(lines.rts == Uart.Lines.rts and lines.dtr == Uart.Lines.dtr);
}

/// Listens for programs getting and setting the pty's lines (see
/// `lines_supported`), before anything can open the pty
pub fn listenLines(self: *const Pty, io: Io) (net.UnixAddress.ListenError || error{NameTooLong})!net.Server {
    var buffer: [lines.max_name]u8 = undefined;
    const address: net.UnixAddress = try .init(try lines.name(&buffer, self.path));
    return address.listen(io, .{});
}

/// Answers programs getting and setting `state`, on `server`, one at a
/// time, until canceled. Programs of other users are refused, and those
/// that send nothing for a second are dropped.
pub fn serveLines(server: *net.Server, io: Io, state: *Uart.Lines) Io.Cancelable!void {
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => continue,
        };
        defer stream.close(io);
        if (!sameUser(stream.socket.handle) or !setTimeout(stream.socket.handle, 1)) continue;
        var in_buffer: [1]u8 = undefined;
        var reader = stream.reader(io, &in_buffer);
        const request = reader.interface.takeByte() catch continue;
        if (lines.operation(request) != .get) try state.set(lines.apply(state.state.load(.acquire), request));
        var out_buffer: [1]u8 = undefined;
        var writer = stream.writer(io, &out_buffer);
        writer.interface.writeByte(state.state.load(.acquire)) catch continue;
        writer.interface.flush() catch continue;
    }
}

/// whether the program on the other end of `socket` is this user's
pub fn sameUser(socket: posix.socket_t) bool {
    if (comptime !lines_supported) return false;
    var credentials: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
    var len: posix.socklen_t = @sizeOf(@TypeOf(credentials));
    if (std.c.getsockopt(socket, posix.SOL.SOCKET, posix.SO.PEERCRED, &credentials, &len) != 0) return false;
    return credentials.uid == std.c.getuid();
}

/// Has reads and writes on `socket` fail after `seconds`. Returns false if
/// they cannot.
pub fn setTimeout(socket: posix.socket_t, seconds: i32) bool {
    if (comptime !lines_supported) return false;
    const timeout: posix.timeval = .{ .sec = seconds, .usec = 0 };
    for ([_]u32{ posix.SO.RCVTIMEO, posix.SO.SNDTIMEO }) |option|
        if (std.c.setsockopt(socket, posix.SOL.SOCKET, option, &timeout, @sizeOf(posix.timeval)) != 0) return false;
    return true;
}

/// whether `path` is a pseudo-terminal's terminal side, as Linux and the
/// BSDs, or macOS, name them
pub fn isPtyPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/dev/pts/") or std.mem.startsWith(u8, path, "/dev/ttys");
}

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

pub const OpenError = error{ OpenFailed, NotATerminal, OutOfMemory };

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

/// libc's struct termios, for its tcgetattr and tcsetattr: the flags, which
/// every libc puts first, and room for the rest. Zig's `posix.termios` is
/// Linux's, which is smaller than glibc's, 44 bytes to 60, so glibc's
/// tcgetattr writes past its end.
const Termios = extern struct {
    iflag: posix.tc_iflag_t,
    oflag: posix.tc_oflag_t,
    cflag: posix.tc_cflag_t,
    lflag: posix.tc_lflag_t,
    rest: [128]u8,
};

extern "c" fn tcgetattr(fd: posix.fd_t, termios: *Termios) c_int;
extern "c" fn tcsetattr(fd: posix.fd_t, action: c_int, termios: *const Termios) c_int;

/// as cfmakeraw does: bytes in and out as they are, 8 bits, no echo
fn makeRaw(fd: posix.fd_t) error{NotATerminal}!void {
    var t: Termios = undefined;
    if (tcgetattr(fd, &t) != 0) return error.NotATerminal;
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
    if (tcsetattr(fd, @backingInt(posix.TCSA.NOW), &t) != 0) return error.NotATerminal;
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

test "a program gets and sets the lines through the socket named after the pty" {
    if (!lines_supported) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer: [16]u8 = undefined;
    var queue: [16]u8 = undefined;
    var pty = try open(io, arena_state.allocator(), &buffer, &queue);
    defer pty.close(io);
    var server = try pty.listenLines(io);
    defer server.deinit(io);
    var buffers: [2][1]u8 = undefined;
    // not wired, so that a change is not waited on
    var state: Uart.Lines = .init(io, &buffers);
    var serving = try io.concurrent(serveLines, .{ &server, io, &state });
    defer serving.cancel(io) catch {};

    var name: [lines.max_name]u8 = undefined;
    const address: net.UnixAddress = try .init(try lines.name(&name, pty.path));
    for ([_][2]u8{
        .{ lines.request(.get, 0), lines.rts | lines.dtr },
        .{ lines.request(.bic, lines.rts), lines.dtr },
        .{ lines.request(.bis, lines.rts), lines.rts | lines.dtr },
        .{ lines.request(.set, lines.dtr), lines.dtr },
        .{ lines.request(.get, 0), lines.dtr },
    }) |exchange| {
        const stream = try address.connect(io);
        defer stream.close(io);
        var out: [1]u8 = undefined;
        var writer = stream.writer(io, &out);
        try writer.interface.writeByte(exchange[0]);
        try writer.interface.flush();
        var in: [1]u8 = undefined;
        var reader = stream.reader(io, &in);
        try std.testing.expectEqual(exchange[1], try reader.interface.takeByte());
    }
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

const lines = @import("lines.zig");
const gasim = @import("gasim");
const Uart = gasim.Uart;

const builtin = @import("builtin");
const std = @import("std");
const net = std.Io.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
