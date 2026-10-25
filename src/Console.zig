//! A simulated terminal attached to a comm port of a node. Each word the node
//! writes to the port is output as a byte, and each read from the port takes
//! the next byte of input.

port: Port = .{},
input: *Io.Reader,
output: *Io.Writer,
/// set, for example from a signal handler, to stop `Chip.run`
interrupted: std.atomic.Value(bool) = .init(false),
/// true while blocked waiting for input, when all output has been flushed
waiting: std.atomic.Value(bool) = .init(false),
/// true once the node has read or written the console
used: bool = false,

const Console = @This();

/// the console's side of the port; the node uses the other one
const side: Side = .b;

pub fn attach(self: *Console, node: *Computer, direction: Direction) void {
    node.ports[@backingInt(direction)] = .{ .port = &self.port, .side = side.other() };
}

/// Completes a transfer the node is waiting on. Returns false if the node is
/// not waiting on the console, or wants input after the end of the input.
/// Unless `wait` is set, it also returns false rather than block when no
/// input is buffered.
pub fn service(self: *Console, wait: bool) !bool {
    switch (self.port.state) {
        .writing => |w| if (w.side != side) {
            self.used = true;
            const word: u18 = @bitCast(self.port.read(side).?);
            try self.output.writeByte(@truncate(word));
            return true;
        },
        .reading => |r| if (r != side) {
            self.used = true;
            if (self.input.bufferedLen() == 0) {
                if (!wait) return false;
                // show any prompt before waiting on input
                try self.output.flush();
                self.waiting.store(true, .release);
            }
            defer self.waiting.store(false, .release);
            const byte = self.input.takeByte() catch |err| switch (err) {
                error.EndOfStream => return false,
                else => |e| return e,
            };
            _ = self.port.write(side, byte);
            return true;
        },
        else => {},
    }
    return false;
}

test service {
    var reader: Io.Reader = .fixed("a");
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .input = &reader, .output = &writer };

    // nothing to do
    try std.testing.expect(!try console.service(true));
    try std.testing.expect(!console.used);

    // output
    try std.testing.expect(!console.port.write(.a, 'x'));
    try std.testing.expect(try console.service(false));
    try std.testing.expect(console.port.write(.a, 'x'));
    try std.testing.expectEqualStrings("x", writer.buffered());
    try std.testing.expect(console.used);

    // input
    try std.testing.expectEqual(null, console.port.read(.a));
    try std.testing.expect(try console.service(false));
    try std.testing.expectEqual('a', console.port.read(.a));

    // end of input
    try std.testing.expectEqual(null, console.port.read(.a));
    try std.testing.expect(!try console.service(true));
}

test "service does not wait for input unless asked" {
    var reader: Io.Reader = .fixed("");
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .input = &reader, .output = &writer };

    try std.testing.expectEqual(null, console.port.read(.a));
    try std.testing.expect(!try console.service(false));
    // the node is still waiting
    try std.testing.expect(console.port.otherReading(.b));
}

const Computer = @import("f18.zig").Computer;
const ports = @import("port.zig");
const Direction = ports.Direction;
const Port = ports.Port;
const Side = ports.Side;

const std = @import("std");
const Io = std.Io;
