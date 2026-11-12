//! A simulated UART on two GPIO pins of a node, as an FTDI USB serial port
//! is wired to node 708 of each chip on GreenArrays' evaluation boards. It
//! sends the node bytes of input on one pin, and outputs the bytes the node
//! sends on another. Frames are a start bit, 8 data bits, least significant
//! first, and a stop bit.
//!
//! Levels are worked out at the node's own time, in picoseconds (see
//! `Computer.time`), whenever the node looks at its pins. The evaluation
//! boards' FTDI chips invert both lines, so by default the pins idle low and
//! a start bit is high, as the async boot ROM of node 708 expects.

/// picoseconds a bit lasts
bit_time: u64,
/// whether the pins are low for a mark (idle, and data bits of 1)
inverted: bool = true,
/// io bits of the pin the device drives and the pin the node drives
rx_pin: u18 = 1 << 17,
tx_pin: u18 = 1 << 1,

/// bytes sent before any input, such as a boot stream
preload: []const u8 = &.{},
/// where input comes from after `preload`; without a queue, only `preload`
input: ?Console.Queue = null,
/// input taken from `input` in one go, but not yet sent
taken: [512]u8 = undefined,
taken_start: u16 = 0,
taken_end: u16 = 0,
/// the node's time when what was taken arrived, before which it is not sent
arrived: u64 = 0,
/// the frame being sent, and when its start bit begins
sending: ?Frame = null,
/// when the line is free for the next frame
free: u64 = 0,

output: *Io.Writer,
/// the frame being received, with the bits sampled so far
receiving: ?Frame = null,
receiving_bits: u4 = 0,
/// the level of the node's pin, as a mark or not, since it was last seen
tx_mark: bool = true,
/// bytes received but not yet written to `output`
received: [16]u8 = undefined,
received_len: u8 = 0,
/// set, for example from a signal handler, to stop `Chip.run`
interrupted: std.atomic.Value(bool) = .init(false),
/// true while blocked waiting for input, when all output has been flushed
waiting: std.atomic.Value(bool) = .init(false),
/// true once the node has sent a byte, or woken on the pin the device
/// drives (see `Chip.wakeOnPin`)
used: bool = false,

const Uart = @This();

/// not what a UART was, but where this process has it
pub const snapshot_skip = .{ "input", "output", "interrupted", "waiting" };

pub const Frame = struct {
    byte: u8,
    start: u64,
};

/// bits in a frame, with its start and stop bits
const frame_bits = 10;

pub fn init(baud: u32, output: *Io.Writer) Uart {
    return .{ .bit_time = 1_000_000_000_000 / @as(u64, baud), .output = output };
}

/// Attaches the UART to the pins of a node, the node driving `tx_pin` and
/// the UART `rx_pin`
pub fn attach(self: *Uart, chip: *Chip, number: u16) error{ NoSuchNode, NoPins }!void {
    const n = chip.node(number) orelse return error.NoSuchNode;
    if (n.pins & self.rx_pin == 0 or n.pins & self.tx_pin == 0) return error.NoPins;
    self.attachPins(chip, .{ .node = number, .pin = @intCast(@ctz(self.rx_pin)) }, .{ .node = number, .pin = @intCast(@ctz(self.tx_pin)) }) catch
        return error.NoPins;
}

/// Attaches the UART to two pins, which may be of different nodes: it
/// drives `rx`, which the chip receives on, and listens to `tx`, which it
/// sends on. Either may be left out, as a board's jumper can leave a line
/// unconnected.
pub fn attachPins(self: *Uart, chip: *Chip, rx: ?Chip.PinRef, tx: ?Chip.PinRef) error{ NoSuchPin, TwoDevices, Full }!void {
    // a pin there is not, before one that is taken
    for ([_]?Chip.PinRef{ rx, tx }) |pin| if (pin) |p| {
        _ = try chip.pinTaken(p);
    };
    for ([_]?Chip.PinRef{ rx, tx }) |pin| if (pin) |p| if (try chip.pinTaken(p)) return error.TwoDevices;
    if (rx != null and tx != null and try chip.sameNet(rx.?, tx.?)) return error.TwoDevices;
    // serviced at the time of the node it sends to, if it sends
    const pin = rx orelse tx orelse return;
    try chip.attachDevice(self.device(), pin, rx != null);
    if (rx) |p| {
        self.rx_pin = @as(u18, 1) << p.pin;
        chip.attachPin(p, self.rxDevice()) catch unreachable;
    }
    if (tx) |p| {
        self.tx_pin = @as(u18, 1) << p.pin;
        chip.attachPin(p, self.txDevice()) catch unreachable;
    }
}

/// the UART as a device of the chip
pub fn device(self: *Uart) Device {
    return .{
        .context = self,
        .vtable = &vtable,
        .output = self.output,
        .interrupted = &self.interrupted,
        .waiting = &self.waiting,
    };
}

const vtable: Device.VTable = .{
    .service = serviceDevice,
    .nextEdge = nextEdge,
    .pinRead = pinRead,
    .state = .of(Uart),
};

fn serviceDevice(context: *anyopaque, time: u64, wait: bool) Device.ServiceError!bool {
    const self: *Uart = @ptrCast(@alignCast(context));
    return if (wait) self.waitForInput(time) else self.service(time);
}

fn nextEdge(context: *anyopaque, time: u64) ?u64 {
    const self: *Uart = @ptrCast(@alignCast(context));
    return self.nextRxEdge(time);
}

fn pinRead(context: *anyopaque) void {
    const self: *Uart = @ptrCast(@alignCast(context));
    self.used = true;
}

/// The UART as the device driving the net of the pin it sends on
pub fn rxDevice(self: *Uart) pins.Device {
    return .{ .context = self, .drive = rxDrive };
}

/// The UART as the device listening on the net of the pin it receives on
pub fn txDevice(self: *Uart) pins.Device {
    return .{ .context = self, .changed = txChanged };
}

fn rxDrive(context: *anyopaque, time: u64) pins.Drive {
    const self: *Uart = @ptrCast(@alignCast(context));
    return .{ .strength = .strong, .high = self.rxHigh(time) };
}

fn txChanged(context: *anyopaque, time: u64, high: bool) void {
    const self: *Uart = @ptrCast(@alignCast(context));
    self.observe(time, high);
}

/// The level of the pin the device drives at `now`
pub fn rxHigh(self: *Uart, now: u64) bool {
    self.advance(now);
    return self.levelAt(now) != self.inverted;
}

/// The first time after `now` that the pin the device drives changes, if
/// that is known: it is not once the device runs out of bytes to send
pub fn nextRxEdge(self: *Uart, now: u64) ?u64 {
    self.advance(now);
    const mark = self.levelAt(now);
    // with nothing being sent, there is nothing to send
    const frame = self.sending orelse return null;
    // at most the stop bit, as the frame is still being sent
    const bit: usize = if (now < frame.start) 0 else @intCast((now - frame.start) / self.bit_time + 1);
    for (bit..frame_bits) |k| {
        if (bitMark(frame.byte, k) != mark) return frame.start + k * self.bit_time;
    }
    // the stop bit is a mark, which the next frame's start bit is not
    if (!self.hasByte()) return null;
    return @max(frame.start + frame_bits * self.bit_time, self.arrived);
}

/// Notes the level of the pin the node drives at `now`, receiving any byte
/// it completes. Call it after each step of the node, and when it writes
/// io, as `txDevice` is.
pub fn observe(self: *Uart, now: u64, high: bool) void {
    if (self.receiving) |frame| {
        // sample the middle of each data bit, at the level held until now
        while (self.receiving_bits < 8) : (self.receiving_bits += 1) {
            const sample = frame.start + (2 * @as(u64, self.receiving_bits) + 3) * self.bit_time / 2;
            if (sample > now) break;
            if (self.tx_mark) self.receiving.?.byte |= @as(u8, 1) << @intCast(self.receiving_bits);
        }
        if (self.receiving_bits == 8) {
            self.used = true;
            if (self.received_len < self.received.len) {
                self.received[self.received_len] = self.receiving.?.byte;
                self.received_len += 1;
            }
            self.receiving = null;
        }
    }
    const mark = high != self.inverted;
    // a start bit can begin once the last data bit has been sampled, as the
    // stop bit is not checked
    if (self.receiving == null and self.tx_mark and !mark) {
        self.receiving = .{ .byte = 0, .start = now };
        self.receiving_bits = 0;
    }
    self.tx_mark = mark;
}

/// Writes what the node sent, and takes any input that has arrived, at the
/// node's time `now`. Returns false if there was nothing to do.
pub fn service(self: *Uart, now: u64) !bool {
    var serviced = false;
    if (self.received_len > 0) {
        try self.output.writeAll(self.received[0..self.received_len]);
        self.received_len = 0;
        serviced = true;
    }
    // as much as there is room for, so that bytes that arrived together are
    // sent without gaps between them
    if (try self.take(now, false)) serviced = true;
    return serviced;
}

/// Adds bytes to send after `preload`, as arriving at the node's time `now`,
/// so that a line idle until then does not send them in the past
pub fn addPreload(self: *Uart, arena: Allocator, bytes: []const u8, now: u64) Allocator.Error!void {
    if (bytes.len == 0) return;
    if (!self.hasByte()) self.arrived = now;
    self.preload = try std.mem.concat(arena, u8, &.{ self.preload, bytes });
}

/// Waits for input, with nothing left to send. Returns false at the end of
/// input, or if there is still something to send.
pub fn waitForInput(self: *Uart, now: u64) !bool {
    if (self.hasByte()) return false;
    return self.take(now, true);
}

/// whether there is a byte to send after the frame being sent
fn hasByte(self: *const Uart) bool {
    return self.preload.len > 0 or self.taken_start < self.taken_end;
}

/// Moves on to the frame being sent at `now`, taking the next byte when a
/// frame ends
fn advance(self: *Uart, now: u64) void {
    while (true) {
        if (self.sending) |frame| {
            const end = frame.start + frame_bits * self.bit_time;
            if (now < end) return;
            self.free = end;
            self.sending = null;
        }
        const byte = self.nextByte() orelse return;
        self.sending = .{ .byte = byte, .start = @max(self.free, self.arrived) };
    }
}

fn nextByte(self: *Uart) ?u8 {
    if (self.preload.len > 0) {
        defer self.preload = self.preload[1..];
        return self.preload[0];
    }
    if (self.taken_start == self.taken_end) return null;
    defer self.taken_start += 1;
    return self.taken[self.taken_start];
}

/// whether the line is a mark at `now`
fn levelAt(self: *const Uart, now: u64) bool {
    const frame = self.sending orelse return true;
    if (now < frame.start) return true;
    return bitMark(frame.byte, @intCast((now - frame.start) / self.bit_time));
}

/// whether bit `k` of a frame sending `byte` is a mark
fn bitMark(byte: u8, k: usize) bool {
    return switch (k) {
        0 => false,
        1...8 => byte >> @intCast(k - 1) & 1 != 0,
        else => true,
    };
}

/// Takes as much input as has arrived and there is room for after what is
/// still to be sent, waiting for some if `wait` is set. Returns false if
/// there is none, or at the end of input.
fn take(self: *Uart, now: u64, wait: bool) !bool {
    const input = self.input orelse return false;
    const pending = self.taken_end - self.taken_start;
    if (self.taken_start > 0) {
        @memmove(self.taken[0..pending], self.taken[self.taken_start..self.taken_end]);
        self.taken_start = 0;
        self.taken_end = pending;
    }
    const room = self.taken[pending..];
    if (room.len == 0) return false;
    var got = input.queue.get(input.io, room, 0) catch |err| switch (err) {
        error.Closed => {
            // the end of input, which is not asked for again each round
            self.input = null;
            return false;
        },
        else => |e| return e,
    };
    if (got == 0) {
        if (!wait) return false;
        try self.output.flush();
        self.waiting.store(true, .release);
        defer self.waiting.store(false, .release);
        got = input.queue.get(input.io, room, 1) catch |err| switch (err) {
            error.Closed => {
                self.input = null;
                return false;
            },
            else => |e| return e,
        };
    }
    // bytes that follow others still to be sent go straight after them
    if (!self.hasByte()) self.arrived = now;
    self.taken_end += @intCast(got);
    return true;
}

test "sends frames back to back on an inverted line" {
    var writer: Io.Writer = .fixed(&.{});
    var uart: Uart = .{ .bit_time = 10, .output = &writer, .preload = "\x01\x80" };

    // a start bit, data bit 0 a mark, bits 1 to 7 not
    try expect(uart.rxHigh(0));
    try expect(!uart.rxHigh(10));
    try expect(uart.rxHigh(25));
    try expectEqual(90, uart.nextRxEdge(25));
    // the stop bit, then the next frame's start bit
    try expect(!uart.rxHigh(95));
    try expectEqual(100, uart.nextRxEdge(95));
    try expect(uart.rxHigh(100));
    // bit 7 of 0x80 is the only mark of the second frame
    try expectEqual(180, uart.nextRxEdge(100));
    try expect(!uart.rxHigh(185));
    // then the line is idle, with nothing more to send
    try expectEqual(null, uart.nextRxEdge(185));
    try expect(!uart.rxHigh(1000));
}

test "receives what the node sends" {
    var buffer: [4]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var uart: Uart = .{ .bit_time = 10, .output = &writer };

    // 'A' is 0x41: a start bit, then 1 0 0 0 0 0 1 0, as an inverted line
    const levels = [_]bool{ true, false, true, true, true, true, true, false, true, false };
    // a few steps of the node in each bit
    for (levels, 0..) |level, k| for (0..3) |j| uart.observe(k * 10 + j * 3, level);
    try expect(try uart.service(100));
    try expectEqualStrings("A", writer.buffered());
    try expect(uart.used);
}

test "input added to an idle line is sent from then" {
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var uart: Uart = .{ .bit_time = 10, .output = &writer };
    try uart.addPreload(std.testing.allocator, "", 500);
    try std.testing.expectEqual(0, uart.arrived);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try uart.addPreload(arena.allocator(), "\x01", 500);
    try std.testing.expectEqual(500, uart.arrived);
    // the start bit is at 500, not long past
    try std.testing.expectEqual(500, uart.nextRxEdge(0).?);
}

test "input arriving on an idle line is sent from when it arrived" {
    var writer: Io.Writer = .fixed(&.{});
    var input_buffer: [1]u8 = undefined;
    var input = try Console.testInput(&input_buffer, "x");
    var uart: Uart = .{ .bit_time = 10, .output = &writer, .input = .{ .io = std.testing.io, .queue = &input } };

    try expectEqual(null, uart.nextRxEdge(0));
    try expect(try uart.service(500));
    // a start bit from 500, then 'x' is 0x78, whose bit 3 is its first mark
    try expect(uart.rxHigh(505));
    try expectEqual(540, uart.nextRxEdge(505));
    // the end of input
    try expect(!try uart.waitForInput(2000));
}

const Chip = @import("Chip.zig");
const Device = @import("Device.zig");
const pins = @import("pins.zig");
const Console = @import("Console.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
