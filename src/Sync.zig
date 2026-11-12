//! The master of a synchronous serial line on two GPIO pins of a node, as
//! the EVB002's host node 300 is to the target's through J34 and J35 (DB014
//! 8.3.4), sending words for node 300's sync boot ROM to boot from: a boot
//! stream (`streamer`, root 300). It drives the clock, the node's pin 17,
//! and the data, its pin 1, as the disk's sync master, bin 1901's `18o`
//! (block 2289), does: for each word, the clock high with the data let go,
//! then the word's bits two at a time, high bits first, the first set while
//! the clock is high and held as it falls, the second set while it is low
//! and held as it rises. Each of these takes `half`, as 1901's delay does
//! its own, and the clock stays high from one word to the next. After the
//! last word, it lets go of both pins.
//!
//! It sends on its own time from `start`, with no flow control, as 1901
//! does, so a node must keep up. A node waiting on the clock, its wakeup
//! pin, as node 300's ROM does for the first word, wakes on its edges
//! (`attachPins`).

words: []const Word,
/// picoseconds each level of the clock, or each bit, is held
half: u64 = default_half,
/// when the first word begins
start: u64 = default_half,

const Sync = @This();

/// a round 100 ns, somewhat faster than 1901, whose levels last 130 to
/// 150 ns, its delay `40 for unext` with the rest of its loop; node 300's
/// ROM keeps up with far less
pub const default_half = 100_000;

/// the halves of a word: the clock high, then four for each two bits
const word_halves = 1 + 4 * 9;

pub fn init(words: []const Word) Sync {
    return .{ .words = words };
}

/// Puts the master on two pins: it drives `clock`, which has to be the
/// wakeup pin, pin 17, of its node, and `data`
pub fn attachPins(self: *Sync, chip: *Chip, clock: Chip.PinRef, data: Chip.PinRef) error{ NoSuchPin, TwoDevices, NotWakeupPin, Full }!void {
    if (clock.pin != 17) return error.NotWakeupPin;
    // a pin there is not, before one that is taken
    const taken = [2]bool{ try chip.pinTaken(clock), try chip.pinTaken(data) };
    if (taken[0] or taken[1] or try chip.sameNet(clock, data)) return error.TwoDevices;
    try chip.attachDevice(self.device(), clock, true);
    chip.attachPin(clock, self.clockDevice()) catch unreachable;
    chip.attachPin(data, self.dataDevice()) catch unreachable;
}

/// the master as a device of the chip
pub fn device(self: *Sync) Device {
    return .{ .context = self, .vtable = &vtable };
}

const vtable: Device.VTable = .{ .nextEdge = nextEdge, .state = .of(Sync) };

fn nextEdge(context: *anyopaque, time: u64) ?u64 {
    const self: *Sync = @ptrCast(@alignCast(context));
    return self.nextClockEdge(time);
}

pub fn clockDevice(self: *Sync) pins.Device {
    return .{ .context = self, .drive = driveClock };
}

pub fn dataDevice(self: *Sync) pins.Device {
    return .{ .context = self, .drive = driveData };
}

/// the clock and the data, or null for each that is let go
const Levels = struct { clock: ?bool, data: ?bool };

/// the levels at `time`
fn levels(self: *const Sync, time: u64) Levels {
    if (time < self.start) return .{ .clock = null, .data = null };
    const half = (time - self.start) / self.half;
    const k = half / word_halves;
    if (k >= self.words.len) return .{ .clock = null, .data = null };
    const phase = half % word_halves;
    if (phase == 0) return .{ .clock = true, .data = null };
    // two bits, each held over two halves, as the clock goes high, low,
    // low, high
    const pair = (phase - 1) / 4;
    const step = (phase - 1) % 4;
    const bit = 17 - 2 * pair - @intFromBool(step >= 2);
    const word: u18 = @bitCast(self.words[@intCast(k)]);
    return .{ .clock = step == 0 or step == 3, .data = word >> @intCast(bit) & 1 != 0 };
}

/// when the clock next changes after `now`, if it does
pub fn nextClockEdge(self: *const Sync, now: u64) ?u64 {
    const level = self.levels(now).clock;
    const end = self.start + self.words.len * word_halves * self.half;
    if (now >= end) return null;
    var time = if (now < self.start) self.start else self.start + ((now - self.start) / self.half + 1) * self.half;
    while (time <= end) : (time += self.half) {
        if (self.levels(time).clock != level) return time;
    }
    return null;
}

fn drive(level: ?bool) pins.Drive {
    const high = level orelse return .{};
    return .{ .strength = .strong, .high = high };
}

fn driveClock(context: *anyopaque, time: u64) pins.Drive {
    const self: *Sync = @ptrCast(@alignCast(context));
    return drive(self.levels(time).clock);
}

fn driveData(context: *anyopaque, time: u64) pins.Drive {
    const self: *Sync = @ptrCast(@alignCast(context));
    return drive(self.levels(time).data);
}

test "a word's bits, two to each clock cycle, high bits first" {
    var sync: Sync = .init(&.{ @bitCast(@as(u18, 0x2_0001)), 0 });
    sync.start = 10;
    sync.half = 10;
    try std.testing.expectEqual(null, sync.levels(0).clock);
    // the clock high, the data let go, then bit 17 as the clock falls and
    // bit 16 as it rises
    try std.testing.expectEqual(Levels{ .clock = true, .data = null }, sync.levels(10));
    try std.testing.expectEqual(Levels{ .clock = true, .data = true }, sync.levels(20));
    try std.testing.expectEqual(Levels{ .clock = false, .data = true }, sync.levels(30));
    try std.testing.expectEqual(Levels{ .clock = false, .data = false }, sync.levels(40));
    try std.testing.expectEqual(Levels{ .clock = true, .data = false }, sync.levels(50));
    // bit 0, the last, as the clock rises, and the next word
    try std.testing.expectEqual(Levels{ .clock = true, .data = true }, sync.levels(10 + 36 * 10));
    try std.testing.expectEqual(Levels{ .clock = true, .data = null }, sync.levels(10 + 37 * 10));
    // then nothing, after the last
    try std.testing.expectEqual(null, sync.levels(10 + 2 * 37 * 10).clock);

    // the clock's edges: up at the start, down and up in each cycle, but
    // not from one word to the next, and down as it is let go
    try std.testing.expectEqual(10, sync.nextClockEdge(0));
    try std.testing.expectEqual(30, sync.nextClockEdge(10));
    try std.testing.expectEqual(50, sync.nextClockEdge(30));
    try std.testing.expectEqual(10 + 39 * 10, sync.nextClockEdge(10 + 36 * 10));
    try std.testing.expectEqual(10 + 2 * 37 * 10, sync.nextClockEdge(10 + 2 * 37 * 10 - 5));
    try std.testing.expectEqual(null, sync.nextClockEdge(10 + 2 * 37 * 10));
}

const Chip = @import("Chip.zig");
const Device = @import("Device.zig");
const pins = @import("pins.zig");
const Word = @import("f18.zig").Word;

const std = @import("std");
