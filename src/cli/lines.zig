//! How libgasim-pty.so (`preload.zig`) gets and sets the modem lines of a
//! pty gasim has (`Pty.serveLines`), RTS and DTR, which a pty does not
//! carry: through an abstract Unix socket named after the pty's path
//! (`name`), connecting, sending a byte, an operation and the lines it is
//! of (`request`), and reading back the lines as they are after it. gasim
//! does one at a time, so each is atomic. Only on Linux, which has abstract
//! sockets.

/// the lines' bits, as `Uart.Lines` has them
pub const rts: u8 = 1;
pub const dtr: u8 = 2;

pub const Op = enum(u2) {
    get,
    /// set the lines to those given
    set,
    /// set those given
    bis,
    /// clear those given
    bic,
};

pub fn request(op: Op, lines: u8) u8 {
    return @as(u8, @backingInt(op)) << 6 | (lines & (rts | dtr));
}

/// the operation of `byte`, a request
pub fn operation(byte: u8) Op {
    return @fromBackingInt(@intCast(byte >> 6));
}

/// the lines after request `byte` from `lines`
pub fn apply(lines: u8, byte: u8) u8 {
    const given = byte & (rts | dtr);
    return switch (operation(byte)) {
        .get => lines,
        .set => given,
        .bis => lines | given,
        .bic => lines & ~given,
    };
}

const prefix = "\x00gasim-pty-lines:";

/// longest a name is: a sockaddr_un's path, less the 0 after it that Zig's
/// `net.UnixAddress` adds
pub const max_name = 107;

/// the abstract socket's name for the pty whose terminal side is at
/// `path`, in `buffer`, without the 0 after it
pub fn name(buffer: *[max_name]u8, path: []const u8) error{NameTooLong}![]const u8 {
    if (prefix.len + path.len > buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len..][0..path.len], path);
    return buffer[0 .. prefix.len + path.len];
}

test apply {
    try std.testing.expectEqual(rts | dtr, apply(rts | dtr, request(.get, 0)));
    try std.testing.expectEqual(dtr, apply(rts | dtr, request(.set, dtr)));
    try std.testing.expectEqual(rts | dtr, apply(dtr, request(.bis, rts)));
    try std.testing.expectEqual(dtr, apply(rts | dtr, request(.bic, rts)));
}

const std = @import("std");
