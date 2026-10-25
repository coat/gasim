//! A simulated terminal attached to a comm port of a node. Each word the node
//! writes to the port is output as a byte, and each read from the port takes
//! the next byte of input.
//!
//! Input arrives through a queue, so that the chip can keep running while
//! another task waits for it. See `readInput`.

port: Port = .{},
io: Io,
/// closed at the end of input
input: *Io.Queue(u8),
/// input taken from `input` in one go, but not yet read by the node
taken: [512]u8 = undefined,
taken_start: u16 = 0,
taken_end: u16 = 0,
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

/// Copies `reader` into `input` until the end of input, then closes `input`.
/// Run it concurrently with the chip, so that waiting for input does not
/// stop other nodes.
pub fn readInput(io: Io, reader: *Io.Reader, input: *Io.Queue(u8)) (error{ReadFailed} || Io.Cancelable)!void {
    defer input.close(io);
    while (true) {
        const bytes = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        reader.toss(input.put(io, bytes, 1) catch |err| switch (err) {
            // the console stopped taking input
            error.Closed => return,
            else => |e| return e,
        });
    }
}

pub fn attach(self: *Console, node: *Computer, direction: Direction) void {
    node.ports[@backingInt(direction)] = .{ .port = &self.port, .side = side.other() };
}

/// Completes a transfer the node is waiting on. Returns false if the node is
/// not waiting on the console, or wants input after the end of the input.
/// Unless `wait` is set, it also returns false rather than block when no
/// input has arrived.
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
            if (self.taken_start == self.taken_end and !try self.take(wait)) return false;
            _ = self.port.write(side, self.taken[self.taken_start]);
            self.taken_start += 1;
            return true;
        },
        else => {},
    }
    return false;
}

/// Fills `buffer` with all of `bytes` as input for tests, ending the input
pub fn testInput(buffer: []u8, bytes: []const u8) !Io.Queue(u8) {
    var input: Io.Queue(u8) = .init(buffer);
    try input.putAll(std.testing.io, bytes);
    input.close(std.testing.io);
    return input;
}

/// Takes as much input as has arrived, waiting for some if `wait` is set.
/// Returns false if there is none, or at the end of input.
fn take(self: *Console, wait: bool) !bool {
    var got = self.input.get(self.io, &self.taken, 0) catch |err| switch (err) {
        error.Closed => return false,
        else => |e| return e,
    };
    if (got == 0) {
        if (!wait) return false;
        // show any prompt before waiting on input
        try self.output.flush();
        self.waiting.store(true, .release);
        defer self.waiting.store(false, .release);
        got = self.input.get(self.io, &self.taken, 1) catch |err| switch (err) {
            error.Closed => return false,
            else => |e| return e,
        };
    }
    self.taken_start = 0;
    self.taken_end = @intCast(got);
    return true;
}

test service {
    var input_buffer: [1]u8 = undefined;
    var input = try testInput(&input_buffer, "a");
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .io = std.testing.io, .input = &input, .output = &writer };

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
    // input that has not ended
    var input: Io.Queue(u8) = .init(&.{});
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .io = std.testing.io, .input = &input, .output = &writer };

    try std.testing.expectEqual(null, console.port.read(.a));
    try std.testing.expect(!try console.service(false));
    // the node is still waiting
    try std.testing.expect(console.port.otherReading(.b));
}

test readInput {
    var reader: Io.Reader = .fixed("abc");
    var buffer: [8]u8 = undefined;
    var input: Io.Queue(u8) = .init(&buffer);
    try readInput(std.testing.io, &reader, &input);

    var got: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abc", got[0..try input.get(std.testing.io, &got, 0)]);
    try std.testing.expectError(error.Closed, input.get(std.testing.io, &got, 0));
}

const Computer = @import("f18.zig").Computer;
const ports = @import("port.zig");
const Direction = ports.Direction;
const Port = ports.Port;
const Side = ports.Side;

const std = @import("std");
const Io = std.Io;
