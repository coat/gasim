//! GPIO pins as connections. A net joins the pins of nodes, and a device
//! such as the UART, each of which drives it, or does not, at a strength.
//! The strongest drive gives the net's level; two of the same strength that
//! disagree are contention, as two outputs driving a wire both ways. A net
//! nothing drives keeps the level it had.
//!
//! A node's pins are driven as the 2-bit field of each in io says (DB001
//! §3.4): 00 not at all, 01 by a weak pulldown, which is how they start,
//! and 10 and 11 low and high. Nodes run at their own times, so each pin
//! keeps the drives it was given lately, and a net is read as it was at the
//! time of the node reading it, not as the last node to write left it.
//! That holds for nodes ahead of the reader, which every node running is,
//! as the node furthest behind steps first; a node waiting, which drives
//! nothing new until it goes on, is read as it drives now.

pub const Strength = enum(u2) {
    none,
    /// a node's pulldown, 01 in io
    weak,
    /// a resistor on the board, which outweighs a node's pulldown
    pull,
    strong,
};

pub const Drive = struct {
    strength: Strength = .none,
    high: bool = false,
};

/// how a node drives the pin with io bit `bit`, out of 17, 5, 3 and 1, when
/// io is `io`
pub fn nodeDrive(io: u18, bit: u18) Drive {
    // the field starts at the pin's bit and goes down one
    const field = (io & (bit | bit >> 1)) / (bit >> 1);
    return switch (field) {
        0b00 => .{},
        0b01 => .{ .strength = .weak },
        0b10 => .{ .strength = .strong },
        else => .{ .strength = .strong, .high = true },
    };
}

/// The level of a net, from the drives on it, added one by one
pub const Resolver = struct {
    strength: Strength = .none,
    high: bool = false,
    contention: bool = false,

    pub fn add(self: *Resolver, drive: Drive) void {
        if (@backingInt(drive.strength) > @backingInt(self.strength)) {
            self.* = .{ .strength = drive.strength, .high = drive.high };
        } else if (drive.strength != .none and drive.strength == self.strength and drive.high != self.high) {
            self.contention = true;
        }
    }

    /// whether the net is high, `before` if nothing drives it. Contention
    /// reads low.
    pub fn level(self: Resolver, before: bool) bool {
        if (self.strength == .none) return before;
        return self.high and !self.contention;
    }
};

/// A pin's drives over time, the latest few
pub const History = struct {
    /// the drive before the oldest change kept
    before: Drive = .{ .strength = .weak },
    times: [capacity]u64 = undefined,
    drives: [capacity]Drive = undefined,
    start: u8 = 0,
    len: u8 = 0,

    /// changes kept. A node that changes a pin more often than this in one
    /// step, such as in a `unext` loop, leaves a node behind it reading the
    /// drive before the oldest kept.
    pub const capacity = 32;

    pub fn latest(self: *const History) Drive {
        return if (self.len == 0) self.before else self.drives[(self.start + self.len - 1) % capacity];
    }

    /// Notes the drive from `time`, which is no earlier than the last
    pub fn set(self: *History, time: u64, drive: Drive) void {
        if (std.meta.eql(self.latest(), drive)) return;
        if (self.len == capacity) {
            self.before = self.drives[self.start];
            self.start = (self.start + 1) % capacity;
            self.len -= 1;
        }
        const k = (self.start + self.len) % capacity;
        self.times[k] = time;
        self.drives[k] = drive;
        self.len += 1;
    }

    /// the drive at `time`, or `before` if it is earlier than every change
    /// kept
    pub fn at(self: *const History, time: u64) Drive {
        var n = self.len;
        while (n > 0) {
            n -= 1;
            const k = (self.start + n) % capacity;
            if (self.times[k] <= time) return self.drives[k];
        }
        return self.before;
    }

    /// the time of the first change kept after `time`
    pub fn nextChange(self: *const History, time: u64) ?u64 {
        for (0..self.len) |n| {
            const t = self.times[(self.start + n) % capacity];
            if (t > time) return t;
        }
        return null;
    }
};

/// A device on a net: what it drives the net as at a time, if it drives
/// it, and what it is told of the net's level as a node changes what it
/// drives, if it listens
pub const Device = struct {
    context: *anyopaque,
    drive: ?*const fn (context: *anyopaque, time: u64) Drive = null,
    changed: ?*const fn (context: *anyopaque, time: u64, high: bool) void = null,
};

pub const Pin = struct {
    /// index of the node in the chip
    node: u16,
    /// io bit, out of 17, 5, 3 and 1
    bit: u18,
    net: u16,
    /// the next pin on the same net
    next: ?u16 = null,
    history: History = .{},
};

pub const Net = struct {
    /// the first of the pins on it, which `Pin.next` goes on from
    first: u16,
    count: u16 = 1,
    /// a resistor to high or low
    pull: ?bool = null,
    device: ?Device = null,
    /// the level last read, at the time of whichever node read it, which the
    /// net keeps when nothing drives it
    high: bool = false,
    /// a node changed what it drives the net as, at this time, since nodes
    /// waiting on the net were last looked at
    changed: ?u64 = null,
};

/// The first two drives found on a net at the same strength that disagreed
pub const Contention = struct {
    net: u16,
    time: u64,
};

/// The pins of a chip's nodes and the nets they are on, allocated once so
/// that nodes can keep a pointer to it
pub const Wiring = struct {
    nodes: []Computer,
    /// in node order, so that node `i`'s are from `first_pin[i]` to
    /// `first_pin[i + 1]`
    pins: []Pin,
    first_pin: []u16,
    nets: []Net,
    contention: ?Contention = null,

    /// Allocates a net for each pin of the nodes, on its own
    pub fn create(gpa: Allocator, nodes: []Computer) Allocator.Error!*Wiring {
        var count: usize = 0;
        for (nodes) |n| count += @popCount(n.pins);
        const self = try gpa.create(Wiring);
        errdefer gpa.destroy(self);
        const all = try gpa.alloc(Pin, count);
        errdefer gpa.free(all);
        const nets = try gpa.alloc(Net, count);
        errdefer gpa.free(nets);
        const first_pin = try gpa.alloc(u16, nodes.len + 1);
        var k: u16 = 0;
        for (nodes, 0..) |n, i| {
            first_pin[i] = k;
            var bits = n.pins;
            while (bits != 0) : (bits &= bits - 1) {
                all[k] = .{ .node = @intCast(i), .bit = bits & -%bits, .net = k };
                nets[k] = .{ .first = k };
                k += 1;
            }
        }
        first_pin[nodes.len] = k;
        self.* = .{ .nodes = nodes, .pins = all, .first_pin = first_pin, .nets = nets };
        return self;
    }

    pub fn destroy(self: *Wiring, gpa: Allocator) void {
        gpa.free(self.pins);
        gpa.free(self.first_pin);
        gpa.free(self.nets);
        gpa.destroy(self);
    }

    /// the pins of node `i`
    pub fn pinsOf(self: *Wiring, i: u16) []Pin {
        return self.pins[self.first_pin[i]..self.first_pin[i + 1]];
    }

    /// the pin of node `i` with io bit `bit`
    pub fn pin(self: *Wiring, i: u16, bit: u18) ?*Pin {
        for (self.pinsOf(i)) |*p| if (p.bit == bit) return p;
        return null;
    }

    /// the pins on net `net`
    pub fn members(self: *Wiring, net: u16) Members {
        return .{ .pins = self.pins, .cursor = self.nets[net].first };
    }

    pub const Members = struct {
        pins: []Pin,
        cursor: ?u16,

        pub fn next(self: *Members) ?*Pin {
            const p = &self.pins[self.cursor orelse return null];
            self.cursor = p.next;
            return p;
        }
    };

    /// Whether anything but the pin is on its net, so that it is read from
    /// the net, rather than as the node drives it
    pub fn shared(self: *const Wiring, net: u16) bool {
        const n = self.nets[net];
        return n.count > 1 or n.pull != null or n.device != null;
    }

    /// Joins the net of pin `b` to the net of pin `a`
    pub fn connect(self: *Wiring, a: *Pin, b: *Pin) error{ TwoDevices, ConflictingPulls }!void {
        if (a.net == b.net) return;
        const into = &self.nets[a.net];
        const from = self.nets[b.net];
        const old = b.net;
        if (into.device != null and from.device != null) return error.TwoDevices;
        if (into.pull != null and from.pull != null and into.pull.? != from.pull.?) return error.ConflictingPulls;
        if (into.device == null) into.device = from.device;
        if (into.pull == null) into.pull = from.pull;
        // b's pins onto a's net, after the last of a's
        var last = &self.pins[into.first];
        while (last.next) |n| last = &self.pins[n];
        last.next = from.first;
        var it = self.members(b.net);
        while (it.next()) |p| p.net = a.net;
        into.count += from.count;
        // nothing is on b's old net now
        self.nets[old] = .{ .first = from.first, .count = 0 };
    }

    /// Makes the pins of node `i` that are on nets with something else on
    /// them read their level from the net
    pub fn hook(self: *Wiring, i: u16) void {
        const n = &self.nodes[i];
        for (self.pinsOf(i)) |*p| if (self.shared(p.net)) {
            // as the node drives it until now
            if (n.shared_pins & p.bit == 0 and p.history.len == 0) p.history.before = nodeDrive(@bitCast(n.io), p.bit);
            n.shared_pins |= p.bit;
            n.pin_device = .{ .context = self, .read = readPins, .written = writtenPins };
        };
        self.read(i);
    }

    /// Forgets the pins' histories, as after going back to a snapshot, each
    /// pin driven as its node's io says
    pub fn reset(self: *Wiring) void {
        for (self.pins) |*p| p.history = .{ .before = nodeDrive(@bitCast(self.nodes[p.node].io), p.bit) };
        for (self.nets) |*n| n.changed = null;
        self.contention = null;
    }

    /// whether net `net` is high at `time`, noting contention
    pub fn level(self: *Wiring, net: u16, time: u64) bool {
        var resolver: Resolver = .{};
        var it = self.members(net);
        while (it.next()) |p| resolver.add(p.history.at(time));
        const n = &self.nets[net];
        if (n.pull) |high| resolver.add(.{ .strength = .pull, .high = high });
        if (n.device) |device| if (device.drive) |drive| resolver.add(drive(device.context, time));
        if (resolver.contention and self.contention == null) self.contention = .{ .net = net, .time = time };
        n.high = resolver.level(n.high);
        return n.high;
    }

    /// Sets the levels of node `i`'s shared pins as their nets are at its
    /// time
    pub fn read(self: *Wiring, i: u16) void {
        const n = &self.nodes[i];
        for (self.pinsOf(i)) |*p| if (n.shared_pins & p.bit != 0) {
            if (self.level(p.net, n.time)) n.pin_inputs |= p.bit else n.pin_inputs &= ~p.bit;
        };
    }

    /// Notes how node `i` drives its shared pins from its time, tells the
    /// devices on their nets their levels, and marks the nets it changed
    pub fn written(self: *Wiring, i: u16) void {
        const n = &self.nodes[i];
        const io: u18 = @bitCast(n.io);
        for (self.pinsOf(i)) |*p| if (n.shared_pins & p.bit != 0) {
            const drive = nodeDrive(io, p.bit);
            const was = p.history.latest();
            p.history.set(n.time, drive);
            if (!std.meta.eql(was, drive)) self.nets[p.net].changed = n.time;
        };
        self.tell(i);
    }

    /// Tells the devices that listen on node `i`'s nets their levels at its
    /// time
    pub noinline fn tell(self: *Wiring, i: u16) void {
        const n = &self.nodes[i];
        for (self.pinsOf(i)) |*p| if (n.shared_pins & p.bit != 0) {
            const device = self.nets[p.net].device orelse continue;
            const changed = device.changed orelse continue;
            changed(device.context, n.time, self.level(p.net, n.time));
        };
    }

    fn readPins(context: *anyopaque, node: *Computer) void {
        const self: *Wiring = @ptrCast(@alignCast(context));
        self.read(self.indexOf(node));
    }

    fn writtenPins(context: *anyopaque, node: *const Computer) void {
        const self: *Wiring = @ptrCast(@alignCast(context));
        self.written(self.indexOf(node));
    }

    fn indexOf(self: *const Wiring, node: *const Computer) u16 {
        // a node of the chip's, not a copy of one
        std.debug.assert(@intFromPtr(node) >= @intFromPtr(self.nodes.ptr));
        const i = (@intFromPtr(node) - @intFromPtr(self.nodes.ptr)) / @sizeOf(Computer);
        std.debug.assert(i < self.nodes.len);
        return @intCast(i);
    }
};

test nodeDrive {
    try expectEqual(Drive{}, nodeDrive(0, 1 << 17));
    try expectEqual(Drive{ .strength = .weak }, nodeDrive(0b01 << 16, 1 << 17));
    try expectEqual(Drive{ .strength = .strong }, nodeDrive(0b10 << 16, 1 << 17));
    try expectEqual(Drive{ .strength = .strong, .high = true }, nodeDrive(0b11, 1 << 1));
    // the reset value of io pulls every pin down weakly
    try expectEqual(Drive{ .strength = .weak }, nodeDrive(0x15555, 1 << 5));
}

test Resolver {
    var r: Resolver = .{};
    try expect(r.level(true));
    r.add(.{ .strength = .weak });
    r.add(.{ .strength = .pull, .high = true });
    try expect(r.level(false));
    r.add(.{ .strength = .strong });
    try expect(!r.level(true) and !r.contention);
    r.add(.{ .strength = .strong, .high = true });
    try expect(r.contention and !r.level(true));
}

test History {
    var h: History = .{};
    h.set(10, .{ .strength = .strong, .high = true });
    h.set(20, .{ .strength = .strong });
    try expectEqual(Strength.weak, h.at(5).strength);
    try expect(h.at(10).high and h.at(15).high and !h.at(20).high);
    // the same drive again is no change
    h.set(30, .{ .strength = .strong });
    try expectEqual(2, h.len);
    // the oldest changes give way, leaving the drive before them
    for (0..History.capacity) |k| h.set(100 + k, .{ .strength = .strong, .high = k % 2 == 0 });
    try expect(!h.at(0).high);
    try expectEqual(History.capacity, h.len);
}

const Computer = @import("f18.zig").Computer;

const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
