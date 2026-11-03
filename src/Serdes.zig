//! A SERDES link between two SERDES nodes, as between the EVB002's host
//! node 701 and target node 001: a 2-wire synchronous, half duplex line on
//! which either node sends 18-bit words to the other (DB001 3.6). A node
//! starts sending by writing its first word to its data register and then
//! setting io bit 17, and sends each word after by writing it to its up
//! port, which waits until the word before has been sent. It receives by
//! reading up. There is no flow control: a word the receiving node has not
//! read when the next one arrives is lost. Nor is half duplex enforced:
//! both nodes can send at once, a node that sends can still receive, and
//! clearing io bit 17 does not cut short a word being sent.

ends: [2]End,

const Serdes = @This();

/// picoseconds to send a word, 18 bits at about 450 Mb/s (DB001 3.6), as
/// the G144A12's data book gives no timing for it yet (DB002 5.5.9)
pub const word_time: u64 = 40_000;

/// the io bit that has a node send while it is set
pub const send_bit: u18 = 1 << 17;

/// the link's side of the nodes' up ports, which the nodes use side a of
pub const side: port.Side = .b;

/// A node on the link
pub const End = struct {
    /// the node's index
    index: u16,
    /// the node's up port, from which the link takes the words it sends,
    /// and to which it delivers the words it receives
    port: Port = .{},
    /// whether io bit 17 is set
    sending: bool = false,
    /// when the word being sent is finished, and the next can start
    free: u64 = 0,
    /// words on their way to the other end, the earliest first
    flight: [2]Arrival = @splat(.{}),
    flight_len: u2 = 0,
    /// a word received and not yet read, which the next to arrive replaces
    latch: ?Arrival = null,

    /// Sends the word in the data register when io bit 17 is set, as the
    /// node writes io. Setting it again while a word is being sent, which
    /// DB001 does not describe, sends nothing.
    pub fn written(self: *End, node: *const Computer) void {
        const sending = @as(u18, @bitCast(node.io)) & send_bit != 0;
        defer self.sending = sending;
        if (sending and !self.sending and node.time >= self.free and self.flight_len < self.flight.len)
            _ = self.send(node.data.?, node.time);
    }

    /// Takes a word the node writes to up, if it is sending. Returns when
    /// the word starts to be sent, which the node waits until, as it waits
    /// for the word before to be finished.
    pub fn take(self: *End, time: u64) ?u64 {
        if (!self.sending or !self.port.otherWriting(side)) return null;
        return self.send(self.port.read(side).?, time);
    }

    /// Hands the word received to the node, if it is reading up. Returns
    /// when the word arrived, which the node takes it at if it is behind.
    pub fn deliver(self: *End) ?u64 {
        const arrival = self.latch orelse return null;
        if (!self.port.otherReading(side)) return null;
        std.debug.assert(self.port.write(side, arrival.value));
        self.latch = null;
        return arrival.time;
    }

    /// the time the next word sent from this end arrives at the other
    pub fn nextArrival(self: *const End) ?u64 {
        return if (self.flight_len > 0) self.flight[0].time else null;
    }

    fn send(self: *End, value: Word, time: u64) u64 {
        const start = @max(time, self.free);
        self.free = start + word_time;
        // the word before arrived as this one started, which the node
        // waits for, so it has landed
        std.debug.assert(self.flight_len < self.flight.len);
        // (stepped by hand, out of turn, the word before is landed first:
        // see `Chip.serdesPortChanged`)
        self.flight[self.flight_len] = .{ .value = value, .time = self.free };
        self.flight_len += 1;
        return start;
    }
};

/// A word, and when it arrives at, or arrived at, the receiving end
pub const Arrival = struct {
    value: Word = 0,
    time: u64 = 0,
};

pub fn init(a: u16, b: u16) Serdes {
    return .{ .ends = .{ .{ .index = a }, .{ .index = b } } };
}

/// Puts the next word sent from end `from` in the other end's latch, in
/// place of any word there that was not read
pub fn land(self: *Serdes, from: u1) void {
    const sender = &self.ends[from];
    const arrival = sender.flight[0];
    sender.flight[0] = sender.flight[1];
    sender.flight[1] = .{};
    sender.flight_len -= 1;
    self.ends[1 - from].latch = arrival;
}

/// the device a SERDES node's io writes are told to (`Computer.pin_device`)
pub fn pinDevice(end: *End) Computer.PinDevice {
    return .{ .context = end, .read = noRead, .written = writtenDevice };
}

fn noRead(_: *anyopaque, _: *Computer) void {}

fn writtenDevice(context: *anyopaque, node: *const Computer) void {
    const end: *End = @ptrCast(@alignCast(context));
    end.written(node);
}

test "a word written to data is sent when io bit 17 is set" {
    var link: Serdes = .init(0, 1);
    var node: Computer = .reset;
    node.data = 5;
    node.time = 1000;
    link.ends[0].written(&node);
    try std.testing.expectEqual(0, link.ends[0].flight_len);
    node.io = @bitCast(send_bit);
    link.ends[0].written(&node);
    try std.testing.expectEqual(1000 + word_time, link.ends[0].nextArrival());
    // setting it again sends nothing more
    link.ends[0].written(&node);
    try std.testing.expectEqual(1, link.ends[0].flight_len);

    link.land(0);
    try std.testing.expectEqual(Arrival{ .value = 5, .time = 1000 + word_time }, link.ends[1].latch.?);
}

test "setting io bit 17 again while a word is sent sends nothing" {
    var link: Serdes = .init(0, 1);
    var node: Computer = .reset;
    node.data = 1;
    for (0..3) |_| {
        node.io = @bitCast(send_bit);
        link.ends[0].written(&node);
        node.io = 0;
        link.ends[0].written(&node);
    }
    try std.testing.expectEqual(1, link.ends[0].flight_len);
    node.time = word_time;
    node.io = @bitCast(send_bit);
    link.ends[0].written(&node);
    try std.testing.expectEqual(2, link.ends[0].flight_len);
}

test "a word written to up waits for the one before" {
    var link: Serdes = .init(0, 1);
    var node: Computer = .reset;
    node.data = 1;
    node.io = @bitCast(send_bit);
    link.ends[0].written(&node);
    // the node writes the next word to up at once
    try std.testing.expect(!link.ends[0].port.write(.a, 2));
    try std.testing.expectEqual(word_time, link.ends[0].take(10));
    try std.testing.expect(link.ends[0].port.write(.a, 2));
    try std.testing.expectEqual(2, link.ends[0].flight_len);
    try std.testing.expectEqual(2 * word_time, link.ends[0].flight[1].time);
}

test "a word not read is lost to the next" {
    var link: Serdes = .init(0, 1);
    link.ends[0].sending = true;
    for ([_]Word{ 1, 2 }) |value| {
        try std.testing.expect(!link.ends[0].port.write(.a, value));
        _ = link.ends[0].take(0).?;
        try std.testing.expect(link.ends[0].port.write(.a, value));
        link.land(0);
    }
    try std.testing.expectEqual(null, link.ends[1].deliver());
    try std.testing.expectEqual(null, link.ends[1].port.read(.a));
    try std.testing.expectEqual(2 * word_time, link.ends[1].deliver());
    try std.testing.expectEqual(2, link.ends[1].port.read(.a));
}

const f18 = @import("f18.zig");
const Computer = f18.Computer;
const Word = f18.Word;
const port = @import("port.zig");
const Port = port.Port;

const std = @import("std");
