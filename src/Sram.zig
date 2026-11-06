//! An asynchronous SRAM of 16-bit words, as the EVB002's 1M words on the
//! host's nodes 007, 008 and 009 (DB014 5.4, 7.1): its address on node
//! 009's parallel bus and two high lines, its data on node 007's bus, and
//! chip enable (CE-) and write enable (WE-), which the board pulls up. With
//! no output enable, it drives the data bus with the addressed word while
//! CE- is low and WE- high, at once, and stores the word on the data bus
//! at the address when a write ends, as CE- or WE- rises with the other
//! low. The data bus's bits 16 and 17 are not its, and read as 0, as the
//! board pulls them down.
//!
//! The buses keep their charge when nothing drives them, as the disk's own
//! bus tests have them do (blocks 1893, 1894): the data bus has what was
//! last on it, from node 007 or the SRAM. The SRAM cluster reads a word
//! after it has ended the read cycle (block 2335's `r16`, 4735), so from
//! that charge.
//!
//! A write takes the address and data from just before it ends: a node
//! that changes address lines in the io write that ends it, as node 008's
//! SRAM control does, does so as the SRAM latches. Nodes run at their own
//! times, so the SRAM keeps what the buses and lines were lately, to drive
//! the data bus as it was at the time of the node reading it. Its words
//! change when a write ends, which a node reading at an earlier time, which
//! no SRAM control does, would see.
//!
//! Like the UART and the flash, it is not in the chip's snapshots.

words: []u16,
/// the address bus, and whether node 009 drives it, which it does from
/// reset; and the data bus as node 007 drives it, if it does
address: Timeline(?u18) = .{ .before = 0 },
data: Timeline(?u18) = .{ .before = 0 },
/// the word on the data bus when the SRAM last stopped driving it
held: Timeline(u16) = .{ .before = 0 },
/// the lines, as the board leaves them: CE- and WE- pulled up, and the
/// high address lines held low by node 008's pulldowns
enable: Timeline(bool) = .{ .before = true },
write: Timeline(bool) = .{ .before = true },
high: [2]Timeline(bool) = .{ .{ .before = false }, .{ .before = false } },

const Sram = @This();

/// which `snapshot` saves as the few that are not zero
pub const snapshot_skip = .{"words"};

/// the words of the EVB002's SRAM
pub const evb002_words = 1 << 20;

/// An SRAM of `words`, as many as its address lines reach, a power of 2
pub fn init(words: []u16) Sram {
    return .{ .words = words };
}

pub fn addressBus(self: *Sram) Computer.BusDevice {
    return .{ .context = self, .read = undriven, .written = addressWritten };
}

pub fn dataBus(self: *Sram) Computer.BusDevice {
    return .{ .context = self, .read = readData, .written = dataWritten };
}

pub fn enableDevice(self: *Sram) pins.Device {
    return .{ .context = self, .changed = enableChanged };
}

pub fn writeDevice(self: *Sram) pins.Device {
    return .{ .context = self, .changed = writeChanged };
}

/// the high address line `k`, 0 above the bus's 18 lines and 1 above that
pub fn highDevice(self: *Sram, k: u1) pins.Device {
    return .{ .context = &self.high[k], .changed = highChanged };
}

/// the word at the address the bus and high lines give at `time`, or as
/// they were just before it
fn wordIndex(self: *const Sram, time: u64) usize {
    const bus: usize = self.address.at(time) orelse 0;
    const high = @as(usize, @intFromBool(self.high[0].at(time))) | @as(usize, @intFromBool(self.high[1].at(time))) << 1;
    return (high << 18 | bus) & (self.words.len - 1);
}

/// whether it drives the data bus at `time`
fn drives(self: *const Sram, time: u64) bool {
    return !self.enable.at(time) and self.write.at(time);
}

/// what is on the data bus at `time`, from node 007 or the SRAM, or what
/// was last
fn dataAt(self: *const Sram, time: u64) u18 {
    if (self.data.at(time)) |value| return value;
    if (self.drives(time)) return self.words[self.wordIndex(time)];
    const released = self.data.since(time);
    if (self.held.since(time) > released) return self.held.at(time);
    return self.data.at(released -| 1) orelse 0;
}

fn readData(context: *anyopaque, node: *const Computer) ?u18 {
    const self: *Sram = @ptrCast(@alignCast(context));
    return self.dataAt(node.time) & 0xffff;
}

fn undriven(_: *anyopaque, _: *const Computer) ?u18 {
    return null;
}

fn addressWritten(context: *anyopaque, node: *const Computer) void {
    const self: *Sram = @ptrCast(@alignCast(context));
    self.address.set(node.time, if (node.drivesBus()) @bitCast(node.data.?) else null);
}

fn dataWritten(context: *anyopaque, node: *const Computer) void {
    const self: *Sram = @ptrCast(@alignCast(context));
    self.data.set(node.time, if (node.drivesBus()) @bitCast(node.data.?) else null);
}

fn enableChanged(context: *anyopaque, time: u64, high: bool) void {
    const self: *Sram = @ptrCast(@alignCast(context));
    if (high and !self.enable.latest()) {
        if (self.write.latest()) self.release(time) else self.store(time);
    }
    self.enable.set(time, high);
}

fn writeChanged(context: *anyopaque, time: u64, high: bool) void {
    const self: *Sram = @ptrCast(@alignCast(context));
    if (!self.enable.latest()) {
        if (high and !self.write.latest()) self.store(time);
        if (!high and self.write.latest()) self.release(time);
    }
    self.write.set(time, high);
}

fn highChanged(context: *anyopaque, time: u64, high: bool) void {
    const line: *Timeline(bool) = @ptrCast(@alignCast(context));
    line.set(time, high);
}

/// stops driving the data bus at `time`, which keeps the word, if it had
/// begun to
fn release(self: *Sram, time: u64) void {
    if (@max(self.enable.since(time), self.write.since(time)) == time) return;
    self.held.add(time, self.words[self.wordIndex(time -| 1)]);
}

/// ends a write at `time`, with the address and data from before it
fn store(self: *Sram, time: u64) void {
    const before = time -| 1;
    self.words[self.wordIndex(before)] = @truncate(self.dataAt(before));
}

/// What something was over time, the latest few changes
fn Timeline(comptime T: type) type {
    return struct {
        /// what it was before the oldest change kept
        before: T,
        times: [capacity]u64 = @splat(0),
        values: [capacity]T = @splat(std.mem.zeroes(T)),
        start: u8 = 0,
        len: u8 = 0,

        const capacity = 16;
        const Self = @This();

        fn latest(self: *const Self) T {
            return if (self.len == 0) self.before else self.values[(self.start + self.len - 1) % capacity];
        }

        /// notes the value from `time`, no earlier than the last, if it
        /// changes
        fn set(self: *Self, time: u64, value: T) void {
            if (!std.meta.eql(self.latest(), value)) self.add(time, value);
        }

        /// notes the value from `time`, no earlier than the last, even if
        /// it is the same
        fn add(self: *Self, time: u64, value: T) void {
            if (self.len == capacity) {
                self.before = self.values[self.start];
                self.start = (self.start + 1) % capacity;
                self.len -= 1;
            }
            const k = (self.start + self.len) % capacity;
            self.times[k] = time;
            self.values[k] = value;
            self.len += 1;
        }

        fn at(self: *const Self, time: u64) T {
            const k = self.change(time) orelse return self.before;
            return self.values[k];
        }

        /// when it last changed, at `time` or before, or 0 if before the
        /// oldest change kept
        fn since(self: *const Self, time: u64) u64 {
            const k = self.change(time) orelse return 0;
            return self.times[k];
        }

        fn change(self: *const Self, time: u64) ?usize {
            var n = self.len;
            while (n > 0) {
                n -= 1;
                const k = (self.start + n) % capacity;
                if (self.times[k] <= time) return k;
            }
            return null;
        }
    };
}

test "a write stores the data bus's word at the address, and a read drives it" {
    const words = try std.testing.allocator.alloc(u16, evb002_words);
    defer std.testing.allocator.free(words);
    @memset(words, 0);
    var sram: Sram = .init(words);
    var address: Computer = .reset;
    address.data = 0;
    var data: Computer = .reset;
    data.data = 0;
    const address_bus = sram.addressBus();
    const data_bus = sram.dataBus();
    const enable = sram.enableDevice();
    const write = sram.writeDevice();
    const high = sram.highDevice(1);

    // x31234 to x8.0005, the top line high: the address and data driven,
    // then CE- and WE- low, and both high in the write that also takes the
    // top line back low, which the SRAM latches before
    address.time = 10;
    address.data = 5;
    address_bus.written(address_bus.context, &address);
    data.time = 10;
    data.data = @bitCast(@as(u18, 0x31234));
    data_bus.written(data_bus.context, &data);
    high.changed.?(high.context, 10, true);
    enable.changed.?(enable.context, 20, false);
    write.changed.?(write.context, 20, false);
    high.changed.?(high.context, 30, false);
    write.changed.?(write.context, 30, true);
    enable.changed.?(enable.context, 30, true);
    try std.testing.expectEqual(0x1234, words[2 << 18 | 5]);
    try std.testing.expectEqual(0, words[5]);

    // a read, with node 007 not driving: the bus keeps what 007 drove, but
    // bits 16 and 17, until CE- is low, and then has the word, at the
    // address as it is at the reader's time
    words[2 << 18 | 6] = 0xbeef;
    data.time = 40;
    data.io = @bitCast(@as(u18, 0x14555));
    data_bus.written(data_bus.context, &data);
    try std.testing.expectEqual(0x1234, data_bus.read(data_bus.context, &data).?);
    high.changed.?(high.context, 50, true);
    enable.changed.?(enable.context, 50, false);
    data.time = 60;
    try std.testing.expectEqual(0x1234, data_bus.read(data_bus.context, &data).?);
    address.time = 70;
    address.data = 6;
    address_bus.written(address_bus.context, &address);
    try std.testing.expectEqual(0x1234, data_bus.read(data_bus.context, &data).?);
    data.time = 70;
    try std.testing.expectEqual(0xbeef, data_bus.read(data_bus.context, &data).?);
    // and once CE- is high, the word it drove, as a read cycle ends before
    // the SRAM cluster reads
    enable.changed.?(enable.context, 80, true);
    data.time = 90;
    try std.testing.expectEqual(0xbeef, data_bus.read(data_bus.context, &data).?);

    // a write with node 007 not driving stores what the bus keeps, and CE-
    // and WE- low together drive nothing first
    enable.changed.?(enable.context, 100, false);
    write.changed.?(write.context, 100, false);
    address.time = 100;
    address.data = 7;
    address_bus.written(address_bus.context, &address);
    write.changed.?(write.context, 110, true);
    try std.testing.expectEqual(0xbeef, words[2 << 18 | 7]);
}

const pins = @import("pins.zig");
const Computer = @import("f18.zig").Computer;

const std = @import("std");
