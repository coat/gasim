//! libgasim-pty.so, which gives gasim's ptys modem lines. Loaded into a
//! program with LD_PRELOAD, such as Wine running arrayForth 3, or Python
//! running ga-tools, it answers the ioctls that get and set RTS and DTR,
//! which a pty refuses, on a pty that gasim put a serial port on, by asking
//! gasim (see `lines.zig`), so that the program can reset a chip with RTS as
//! on the board. Other ioctls, and these on anything else, are libc's as
//! they are. Linux only.

/// a safety check failing traps, with no stack trace, which would pull in
/// much of std, and its threads, to a library loaded into another program
pub const panic = std.debug.no_panic;

/// ioctl, which C declares `int ioctl(int fd, unsigned long request, ...)`,
/// with its one argument after `request` named: Linux's calling conventions,
/// on x86_64 and aarch64 at least, pass it as they would a named one, and
/// Zig cannot take variadic arguments on aarch64
const Ioctl = *const fn (fd: c_int, request: c_ulong, arg: usize) callconv(.c) c_int;

/// libc's ioctl, found on first use
var next_ioctl: std.atomic.Value(?Ioctl) = .init(null);

/// glibc's and musl's RTLD_NEXT
const rtld_next: *anyopaque = @ptrFromInt(std.math.maxInt(usize));

/// the TIOCM bits for RTS and DTR
const tiocm_dtr: c_int = 0x002;
const tiocm_rts: c_int = 0x004;

/// how long gasim has to answer: as long as the chip takes to take a change
/// of RTS, at the end of the round it is in
const timeout_seconds = 5;

export fn ioctl(fd: c_int, request: c_ulong, arg: usize) callconv(.c) c_int {
    const real = next_ioctl.load(.acquire) orelse found: {
        const found: Ioctl = @ptrCast(@alignCast(std.c.dlsym(rtld_next, "ioctl") orelse std.c.abort()));
        next_ioctl.store(found, .release);
        break :found found;
    };
    const result = real(fd, request, arg);
    // musl's ioctl takes an int, which leaves the rest of the register as
    // it was
    const op = opOf(@truncate(request)) orelse return result;
    if (result == 0 or arg == 0 or std.c._errno().* != @backingInt(posix.E.NOTTY)) return result;
    if (answer(fd, op, @ptrFromInt(arg))) return 0;
    std.c._errno().* = @backingInt(posix.E.NOTTY);
    return -1;
}

/// the operation that `request` asks gasim for, if it is one
fn opOf(request: u32) ?lines.Op {
    return switch (request) {
        T.IOCMGET => .get,
        T.IOCMSET => .set,
        T.IOCMBIS => .bis,
        T.IOCMBIC => .bic,
        else => null,
    };
}

/// Does `op` with the TIOCM bits at `arg`, on the lines of the pty `fd` is,
/// if gasim has it. Returns false if gasim does not answer.
fn answer(fd: c_int, op: lines.Op, arg: *align(1) c_int) bool {
    var path_buffer: [64]u8 = undefined;
    var proc_buffer: [32]u8 = undefined;
    const proc = std.fmt.bufPrintSentinel(&proc_buffer, "/proc/self/fd/{d}", .{fd}, 0) catch return false;
    const len = std.c.readlink(proc, &path_buffer, path_buffer.len);
    if (len <= 0) return false;
    const path = path_buffer[0..@intCast(len)];
    if (!std.mem.startsWith(u8, path, "/dev/pts/")) return false;

    const given = if (op == .get) 0 else (if (arg.* & tiocm_rts != 0) lines.rts else 0) | (if (arg.* & tiocm_dtr != 0) lines.dtr else 0);
    const state = ask(path, lines.request(op, given)) orelse return false;
    if (op == .get) arg.* = (if (state & lines.rts != 0) tiocm_rts else 0) | (if (state & lines.dtr != 0) tiocm_dtr else 0);
    return true;
}

/// Sends gasim `request` for the pty at `path`, returning the lines it
/// answers with, or null if it does not, or is not this user's
fn ask(path: []const u8, request: u8) ?u8 {
    var name_buffer: [lines.max_name]u8 = undefined;
    const name = lines.name(&name_buffer, path) catch return null;
    const socket = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (socket < 0) return null;
    defer _ = std.c.close(socket);
    // with the 0 after the name that Zig's `net.UnixAddress` adds
    var address: posix.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(address.path[0..name.len], name);
    const address_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + name.len + 1);
    if (std.c.connect(socket, @ptrCast(&address), address_len) != 0) return null;
    // as anyone can listen on an abstract socket
    var credentials: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
    var credentials_len: posix.socklen_t = @sizeOf(@TypeOf(credentials));
    if (std.c.getsockopt(socket, posix.SOL.SOCKET, posix.SO.PEERCRED, &credentials, &credentials_len) != 0 or
        credentials.uid != std.c.getuid()) return null;
    const timeout: posix.timeval = .{ .sec = timeout_seconds, .usec = 0 };
    for ([_]u32{ posix.SO.RCVTIMEO, posix.SO.SNDTIMEO }) |option|
        if (std.c.setsockopt(socket, posix.SOL.SOCKET, option, &timeout, @sizeOf(posix.timeval)) != 0) return null;
    // without SIGPIPE, which would kill a program that does not ignore it
    // if gasim has closed the connection
    if (std.c.send(socket, @ptrCast(&request), 1, posix.MSG.NOSIGNAL) != 1) return null;
    var state: u8 = undefined;
    while (true) {
        const got = std.c.read(socket, @ptrCast(&state), 1);
        if (got == 1) return state;
        if (got < 0 and posix.errno(got) == .INTR) continue;
        return null;
    }
}

const lines = @import("lines.zig");

const std = @import("std");
const posix = std.posix;
const T = std.os.linux.T;
