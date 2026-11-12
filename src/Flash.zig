//! An SPI flash memory on four GPIO pins, as the EVB002's on host node
//! 705's (DB014 5.3), for that node's ROM to boot from (BOOT-02 2). While
//! chip select is low, it shifts in a command byte and a 24-bit address
//! from the chip's data out on each rising edge of the clock, high bits
//! first, and for a read (03) shifts out its bytes from that address on the
//! chip's data in, high bits first, from each falling edge after: SPI mode
//! 3, as 705's ROM drives it. Past its contents it reads as erased flash
//! does, all ones, and past 16 MB, the most 24 bits address, from the start
//! again. It ignores other commands, so it cannot be written, and keeps no
//! time of its own: it follows the edges however fast they come.
//!
//! Like the UART, it is not in the chip's snapshots, so it is set up for one
//! run from reset.

contents: []const u8,
/// what it has seen of the pins it listens to
selected: bool = false,
clock: bool = false,
data_out: bool = false,
/// the command and address shifted in since chip select fell, and how many
/// bits of them
shifted: u32 = 0,
count: u6 = 0,
/// the bit to send next, counted from the start of the flash, once a read
/// has its address
next_bit: ?u32 = null,
/// how it has driven data in, which a node may read at a time before the
/// latest change
output: pins.History = .{ .before = .{} },

const Flash = @This();

/// what 24 bits address
pub const max_len = 1 << 24;

pub fn init(contents: []const u8) Flash {
    return .{ .contents = contents };
}

/// Puts the flash on four pins, any of which can be left unconnected: it
/// listens to the clock, chip select and data out, and drives data in
pub fn attachPins(self: *Flash, chip: *Chip, clock: ?Chip.PinRef, select: ?Chip.PinRef, data_out: ?Chip.PinRef, data_in: ?Chip.PinRef) error{ NoSuchPin, TwoDevices, Full }!void {
    const refs = [_]?Chip.PinRef{ clock, select, data_out, data_in };
    // a pin there is not, before one that is taken
    for (refs) |ref| if (ref) |p| {
        _ = try chip.pinTaken(p);
    };
    for (refs, 0..) |ref, k| if (ref) |p| {
        if (try chip.pinTaken(p)) return error.TwoDevices;
        for (refs[0..k]) |other| if (other) |q| if (try chip.sameNet(p, q)) return error.TwoDevices;
    };
    try chip.attachDevice(self.device(), null, false);
    for (refs, [_]pins.Device{ self.clockDevice(), self.selectDevice(), self.dataOutDevice(), self.dataInDevice() }) |ref, pin_device| if (ref) |p| {
        chip.attachPin(p, pin_device) catch unreachable;
    };
}

/// the flash as a device of the chip
pub fn device(self: *Flash) Device {
    return .{ .context = self, .vtable = &vtable };
}

const vtable: Device.VTable = .{ .state = .of(Flash) };

pub fn clockDevice(self: *Flash) pins.Device {
    return .{ .context = self, .changed = clockChanged };
}

pub fn selectDevice(self: *Flash) pins.Device {
    return .{ .context = self, .changed = selectChanged };
}

pub fn dataOutDevice(self: *Flash) pins.Device {
    return .{ .context = self, .changed = dataOutChanged };
}

pub fn dataInDevice(self: *Flash) pins.Device {
    return .{ .context = self, .drive = drive };
}

/// the byte at `address`, as it reads
pub fn byte(self: *const Flash, address: u32) u8 {
    return if (address < self.contents.len) self.contents[address] else 0xff;
}

fn clockChanged(context: *anyopaque, time: u64, high: bool) void {
    const self: *Flash = @ptrCast(@alignCast(context));
    if (high == self.clock) return;
    self.clock = high;
    if (!self.selected) return;
    if (high) {
        // data out as it was before this write: a node that changed it with
        // the clock's rise would break the flash's setup time, which 705's
        // ROM does not
        if (self.count == 32) return;
        self.shifted = self.shifted << 1 | @intFromBool(self.data_out);
        self.count += 1;
        if (self.count == 32 and self.shifted >> 24 == read) self.next_bit = (self.shifted & (max_len - 1)) * 8;
    } else if (self.next_bit) |*bit| {
        const value = self.byte(bit.* / 8 % max_len);
        self.output.set(time, .{ .strength = .strong, .high = value << @intCast(bit.* % 8) & 0x80 != 0 });
        bit.* +%= 1;
    }
}

fn selectChanged(context: *anyopaque, time: u64, high: bool) void {
    const self: *Flash = @ptrCast(@alignCast(context));
    if (high) {
        // which ends the command, and lets go of data in
        self.selected = false;
        self.next_bit = null;
        self.output.set(time, .{});
    } else if (!self.selected) {
        self.selected = true;
        self.shifted = 0;
        self.count = 0;
    }
}

fn dataOutChanged(context: *anyopaque, _: u64, high: bool) void {
    const self: *Flash = @ptrCast(@alignCast(context));
    self.data_out = high;
}

fn drive(context: *anyopaque, time: u64) pins.Drive {
    const self: *Flash = @ptrCast(@alignCast(context));
    return self.output.at(time);
}

/// the command that reads
const read = 0x03;

/// Packs 18-bit words into bytes for a flash, high bits first and with no
/// gaps, as a stream for SPI boot is kept (BOOT-02 2), into `buffer`, which
/// takes 9 bytes for each 4 words, the last byte padded with ones, as
/// erased flash reads
pub fn pack(words: []const Word, buffer: []u8) []u8 {
    const len = (words.len * 18 + 7) / 8;
    @memset(buffer[0..len], 0xff);
    for (words, 0..) |word, i| {
        const w: u18 = @bitCast(word);
        for (0..18) |k| {
            const bit = i * 18 + k;
            if (w >> @intCast(17 - k) & 1 == 0) buffer[bit / 8] &= ~(@as(u8, 0x80) >> @intCast(bit % 8));
        }
    }
    return buffer[0..len];
}

test pack {
    var buffer: [9]u8 = undefined;
    // 18 bits of 1, then 18 of 0, and 4 of padding
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xc0, 0x00, 0x0f }, pack(&.{ -1, 0 }, &buffer));
    // 4 words fill 9 bytes, the last ending with 4's low 8 bits
    try std.testing.expectEqual(9, pack(&.{ 1, 2, 3, 4 }, &buffer).len);
    try std.testing.expectEqual(0x00, buffer[0]);
    try std.testing.expectEqual(0x04, buffer[8]);
}

test "a read sends the bytes from its address, high bits first, from each falling edge" {
    var flash: Flash = .init(&.{ 0x12, 0xa5 });
    const clock = flash.clockDevice();
    const select = flash.selectDevice();
    const data_out = flash.dataOutDevice();
    const data_in = flash.dataInDevice();
    var time: u64 = 0;
    // a node's pulldown holds the clock low, then it goes high, chip select
    // falls, and 03 and the address 1 are sent from data out
    clock.changed.?(clock.context, time, true);
    select.changed.?(select.context, time, false);
    const command: u32 = 0x03_000001;
    for (0..32) |k| {
        time += 10;
        clock.changed.?(clock.context, time, false);
        data_out.changed.?(data_out.context, time, command >> @intCast(31 - k) & 1 != 0);
        time += 10;
        clock.changed.?(clock.context, time, true);
    }
    try std.testing.expectEqual(pins.Strength.none, data_in.drive.?(data_in.context, time).strength);
    // xa5, then erased flash
    var got: u16 = 0;
    for (0..16) |_| {
        time += 10;
        clock.changed.?(clock.context, time, false);
        time += 10;
        clock.changed.?(clock.context, time, true);
        got = got << 1 | @intFromBool(data_in.drive.?(data_in.context, time).high);
    }
    try std.testing.expectEqual(0xa5ff, got);
    // as it was at a time before the read
    try std.testing.expectEqual(pins.Strength.none, data_in.drive.?(data_in.context, 100).strength);

    // deselected, it lets go, and another command starts afresh
    select.changed.?(select.context, time, true);
    try std.testing.expectEqual(pins.Strength.none, data_in.drive.?(data_in.context, time).strength);
    select.changed.?(select.context, time, false);
    try std.testing.expectEqual(0, flash.count);
    try std.testing.expectEqual(null, flash.next_bit);
}

const Chip = @import("Chip.zig");
const Device = @import("Device.zig");
const pins = @import("pins.zig");
const Word = @import("f18.zig").Word;

const std = @import("std");
