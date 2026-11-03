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
/// the modem lines the program on the other end of the port sets, if they
/// reach the UART (see `takeRts`)
lines: ?*Lines = null,

const Uart = @This();

pub const Frame = struct {
    byte: u8,
    start: u64,
};

/// bits in a frame, with its start and stop bits
const frame_bits = 10;

pub fn init(baud: u32, output: *Io.Writer) Uart {
    return .{ .bit_time = 1_000_000_000_000 / @as(u64, baud), .output = output };
}

/// The modem lines that the program on the other end of a port sets, RTS
/// and DTR, set from one other thread (`set`), and RTS taken by the chip
/// (`Uart.takeRts`) if a chip acts on it (`wired`). They start set, as a
/// program that opens a port sets them.
pub const Lines = struct {
    /// as last set, a bit each
    state: std.atomic.Value(u8) = .init(rts | dtr),
    /// whether a chip acts on RTS (see `Chip.attachRts`), set before the
    /// lines are
    wired: bool = false,
    /// RTS as it changed, 1 for set, the change the chip has not taken
    changes: Io.Queue(u8),
    /// whether `changes` may have one, so that the chip looks only then
    changed: std.atomic.Value(bool) = .init(false),
    /// a byte for each change the chip has taken, for `set` to wait on
    taken: Io.Queue(u8),
    /// rung as RTS changes, for a run waiting for input
    doorbell: ?*Io.Queue(u8) = null,
    io: Io,

    pub const rts: u8 = 1;
    pub const dtr: u8 = 2;

    pub fn init(io: Io, buffers: *[2][1]u8) Lines {
        return .{ .changes = .init(&buffers[0]), .taken = .init(&buffers[1]), .io = io };
    }

    /// Sets the lines to `state`, as the program sets them, waiting until
    /// the chip has taken a change of RTS, so that what the program sends
    /// after it reaches the chip after it
    pub fn set(self: *Lines, state: u8) Io.Cancelable!void {
        if (!try self.change(state)) return;
        if (self.doorbell) |bell| _ = bell.put(self.io, &.{0}, 0) catch {};
        _ = self.taken.getOne(self.io) catch |err| switch (err) {
            error.Closed => {},
            else => |e| return e,
        };
    }

    /// Sets the lines to `state`, as `set` does without waiting. Returns
    /// whether the chip is to take a change of RTS, which waits while it
    /// has not taken the one before.
    pub fn change(self: *Lines, state: u8) Io.Cancelable!bool {
        const before = self.state.swap(state, .acq_rel);
        if ((before ^ state) & rts == 0 or !self.wired) return false;
        self.changes.putOne(self.io, state & rts) catch |err| switch (err) {
            error.Closed => return false,
            else => |e| return e,
        };
        self.changed.store(true, .release);
        return true;
    }
};

/// the next change of RTS that the chip has not taken, true for set
pub fn takeRts(self: *Uart) ?bool {
    const lines = self.lines orelse return null;
    if (!lines.changed.load(.acquire)) return null;
    var change: [1]u8 = undefined;
    // cleared first, so that a change put after the queue is found empty
    // sets it again
    lines.changed.store(false, .release);
    const got = lines.changes.getUncancelable(lines.io, &change, 0) catch 0;
    if (got == 0) return null;
    _ = lines.taken.putUncancelable(lines.io, &.{0}, 0) catch {};
    return change[0] != 0;
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
        error.Closed => return false,
        else => |e| return e,
    };
    if (got == 0) {
        if (!wait) return false;
        try self.output.flush();
        self.waiting.store(true, .release);
        defer self.waiting.store(false, .release);
        got = input.queue.get(input.io, room, 1) catch |err| switch (err) {
            error.Closed => return false,
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

test "a change of RTS is taken, and set waits for it" {
    const io = std.testing.io;
    var buffers: [2][1]u8 = undefined;
    var lines: Lines = .init(io, &buffers);
    var writer: Io.Writer = .fixed(&.{});
    var uart: Uart = .{ .bit_time = 10, .output = &writer, .lines = &lines };
    // not wired, so nothing to take, however many changes
    for (0..4) |k| try lines.set(if (k % 2 == 0) Lines.dtr else Lines.rts);
    try expectEqual(null, uart.takeRts());
    lines.wired = true;
    // DTR alone is not taken
    try expect(!try lines.change(Lines.rts | Lines.dtr));
    try expectEqual(null, uart.takeRts());
    var setting = try io.concurrent(Lines.set, .{ &lines, 0 });
    var taken: ?bool = null;
    while (taken == null) taken = uart.takeRts();
    try setting.await(io);
    try expectEqual(false, taken.?);
    try expectEqual(null, uart.takeRts());
}

const pins = @import("pins.zig");
const Console = @import("Console.zig");

const std = @import("std");
const Io = std.Io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
