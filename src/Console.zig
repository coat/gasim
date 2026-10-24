//! A simulated terminal attached to a comm port of a node. Each word the node
//! writes to the port is output as a byte, and each read from the port takes
//! the next byte of input.

port: Port = .{},
input: *Io.Reader,
output: *Io.Writer,
/// set, for example from a signal handler, to stop `run`
interrupted: std.atomic.Value(bool) = .init(false),
/// true while blocked waiting for input, when all output has been flushed
waiting: std.atomic.Value(bool) = .init(false),

const Console = @This();

/// the console's side of the port; the node uses the other one
const side: Side = .b;

pub fn attach(self: *Console, node: *Computer, direction: Direction) void {
    node.ports[@backingInt(direction)] = .{ .port = &self.port, .side = side.other() };
}

/// Completes a transfer the node is waiting on. Returns false if the node is
/// not waiting on the console, or wants input after the end of the input.
pub fn service(self: *Console) !bool {
    switch (self.port.state) {
        .writing => |w| if (w.side != side) {
            const word: u18 = @bitCast(self.port.read(side).?);
            try self.output.writeByte(@truncate(word));
            return true;
        },
        .reading => |r| if (r != side) {
            if (self.input.bufferedLen() == 0) {
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

/// Runs `node` until it suspends on something the console cannot complete,
/// or the console is interrupted.
pub fn run(self: *Console, node: *Computer) !void {
    while (!self.interrupted.load(.monotonic)) {
        node.step();
        if (node.suspended and !try self.service()) break;
    }
    try self.output.flush();
}

/// Assembles `source` into a node with a console on its up port, and checks
/// what it outputs given `input`
pub fn expectOutput(source: []const u8, input: []const u8, expected: []const u8) !void {
    var diagnostic: assembler.Diagnostic = .{};
    const program = try assembler.assemble(source, &diagnostic);

    var node: Computer = .reset;
    program.load(&node);

    var reader: Io.Reader = .fixed(input);
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .input = &reader, .output = &writer };
    console.attach(&node, .up);

    try console.run(&node);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "output" {
    try expectOutput("up b! 72 !b 105 !b", "", "Hi");
}

test "input" {
    try expectOutput("up b! @b @b + !b", "\x20\x21", "A");
}

test "stops at the end of input" {
    try expectOutput("up b! begin @b !b again", "echo", "echo");
}

test "stops when interrupted" {
    var diagnostic: assembler.Diagnostic = .{};
    const program = try assembler.assemble("up b! 1 !b begin again", &diagnostic);
    var node: Computer = .reset;
    program.load(&node);

    var reader: Io.Reader = .fixed("");
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .input = &reader, .output = &writer };
    console.attach(&node, .up);

    // run the program up to its endless loop
    for (0..4) |_| {
        node.step();
        if (node.suspended) _ = try console.service();
    }
    console.interrupted.store(true, .monotonic);
    try console.run(&node);
    try std.testing.expectEqualStrings("\x01", writer.buffered());
}

const assembler = @import("assembler.zig");
const Computer = @import("f18.zig").Computer;
const ports = @import("port.zig");
const Direction = ports.Direction;
const Port = ports.Port;
const Side = ports.Side;

const std = @import("std");
const Io = std.Io;
