//! A simulated terminal attached to a comm port of a node. Each word the node
//! writes to the port is output as a byte, and each read from the port takes
//! the next byte of input.
//!
//! Input arrives through a queue, so that the chip can keep running while
//! another task waits for it (see `readInput`), or without one, as bytes
//! given with `give` by a host with no tasks, such as the web's.

port: Port = .{},
/// where input comes from; without a queue, only what is given with `give`
input: ?Queue = null,
/// input taken from `input` in one go, or given, but not yet read by the node
taken: [512]u8 = undefined,
taken_start: u16 = 0,
taken_end: u16 = 0,
/// set by `end`, when input is given rather than queued
ended: bool = false,
output: *Io.Writer,
/// set, for example from a signal handler, to stop `Chip.run`
interrupted: std.atomic.Value(bool) = .init(false),
/// true while blocked waiting for input, when all output has been flushed
waiting: std.atomic.Value(bool) = .init(false),
/// true once the node has read or written the console
used: bool = false,

const Console = @This();

/// a queue of input, closed at the end of it, and the `Io` it is used with
pub const Queue = struct {
    io: Io,
    queue: *Io.Queue(u8),
};

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

/// Gives the node input, without a queue. Returns how much of `bytes` there
/// was room for: the rest can be given once the node has read some.
pub fn give(self: *Console, bytes: []const u8) usize {
    if (self.ended) return 0;
    if (self.taken_start > 0) {
        const left = self.taken[self.taken_start..self.taken_end];
        @memmove(self.taken[0..left.len], left);
        self.taken_start = 0;
        self.taken_end = @intCast(left.len);
    }
    const n = @min(bytes.len, self.taken.len - self.taken_end);
    @memcpy(self.taken[self.taken_end..][0..n], bytes[0..n]);
    self.taken_end += @intCast(n);
    return n;
}

/// Ends input given with `give`, as closing the queue ends queued input
pub fn end(self: *Console) void {
    self.ended = true;
}

/// Whether the node is waiting on the console for input it does not have
pub fn wantsInput(self: Console) bool {
    return switch (self.port.state) {
        .reading => |r| r != side and self.taken_start == self.taken_end,
        else => false,
    };
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
    const input = self.input orelse return false;
    var got = input.queue.get(input.io, &self.taken, 0) catch |err| switch (err) {
        error.Closed => return false,
        else => |e| return e,
    };
    if (got == 0) {
        if (!wait) return false;
        // show any prompt before waiting on input
        try self.output.flush();
        self.waiting.store(true, .release);
        defer self.waiting.store(false, .release);
        got = input.queue.get(input.io, &self.taken, 1) catch |err| switch (err) {
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
    var console: Console = .{ .input = .{ .io = std.testing.io, .queue = &input }, .output = &writer };

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
    var console: Console = .{ .input = .{ .io = std.testing.io, .queue = &input }, .output = &writer };

    try std.testing.expectEqual(null, console.port.read(.a));
    try std.testing.expect(!try console.service(false));
    // the node is still waiting
    try std.testing.expect(console.port.otherReading(.b));
}

test give {
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .output = &writer };

    // the node waits for input that has not been given
    try std.testing.expectEqual(null, console.port.read(.a));
    try std.testing.expect(console.wantsInput());
    try std.testing.expect(!try console.service(true));

    try std.testing.expectEqual(2, console.give("ab"));
    try std.testing.expect(!console.wantsInput());
    try std.testing.expect(try console.service(false));
    try std.testing.expectEqual('a', console.port.read(.a));

    // what is left is kept as more is given, until there is no room
    var lots: [600]u8 = @splat('c');
    try std.testing.expectEqual(console.taken.len - 1, console.give(&lots));
    try std.testing.expectEqual(0, console.give("d"));
    try std.testing.expectEqual(null, console.port.read(.a));
    try std.testing.expect(try console.service(false));
    try std.testing.expectEqual('b', console.port.read(.a));

    // nothing is taken after the end
    console.end();
    try std.testing.expectEqual(0, console.give("e"));
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
