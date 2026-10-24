//! A comm port is a half duplex 18-bit channel between two parties: two
//! nodes, or a node and a simulated device. A transfer happens only when one
//! side writes while the other side reads. Whichever side arrives first
//! suspends until the other side performs the complementary operation.
//!
//! Every operation is retried by a suspended party until it completes, so
//! `read` and `write` are safe to call repeatedly with the same arguments.

pub const Side = enum(u1) {
    a,
    b,

    pub fn other(self: Side) Side {
        return @fromBackingInt(@intCast(~@backingInt(self)));
    }
};

/// Names of the four comm ports, in the order their bits appear in an I/O
/// address and the io register.
pub const Direction = enum(u2) {
    right,
    down,
    left,
    up,
};

/// The set of ports selected by a (multiport) I/O address
pub const Select = std.EnumSet(Direction);

/// Decodes the ports selected by an I/O address such as x1D5 (right) or
/// x1A5 (rdlu), or returns null if the address does not select any port.
pub fn select(address: u9) ?Select {
    if (address & 0x10f != 0x105) return null;
    var ports: Select = .empty;
    // R and L are active high, D and U are active low
    ports.setPresent(.right, address & 0x80 != 0);
    ports.setPresent(.down, address & 0x40 == 0);
    ports.setPresent(.left, address & 0x20 != 0);
    ports.setPresent(.up, address & 0x10 == 0);
    return ports;
}

pub const Port = struct {
    state: State = .idle,

    pub const State = union(enum) {
        idle,
        /// this side is suspended reading
        reading: Side,
        /// this side offered a value and is suspended until it is read
        writing: struct { side: Side, value: Word },
        /// a writer handed a value to this suspended reader, which takes it
        /// when it resumes
        delivered: struct { side: Side, value: Word },
        /// the reader took the value offered by this side, which completes
        /// its write when it resumes
        taken: Side,
    };

    /// Returns the value written by the other side, or null if `side` must
    /// suspend until the other side writes.
    pub fn read(self: *Port, side: Side) ?Word {
        switch (self.state) {
            .idle => self.state = .{ .reading = side },
            .writing => |w| if (w.side != side) {
                self.state = .{ .taken = w.side };
                return w.value;
            },
            .delivered => |d| if (d.side == side) {
                self.state = .idle;
                return d.value;
            },
            .reading, .taken => {},
        }
        return null;
    }

    /// Returns true once `value` has been read by the other side, or false if
    /// `side` must suspend until the other side reads.
    pub fn write(self: *Port, side: Side, value: Word) bool {
        switch (self.state) {
            .idle => self.state = .{ .writing = .{ .side = side, .value = value } },
            .reading => |r| if (r != side) {
                self.state = .{ .delivered = .{ .side = r, .value = value } };
                return true;
            },
            .taken => |t| if (t == side) {
                self.state = .idle;
                return true;
            },
            .writing, .delivered => {},
        }
        return false;
    }

    /// Withdraws a read by `side`, used when another port of a multiport read
    /// completed instead. A value already delivered to `side` is discarded:
    /// its writer has completed, and only one port's value is taken.
    pub fn cancelRead(self: *Port, side: Side) void {
        switch (self.state) {
            .reading => |r| if (r == side) {
                self.state = .idle;
            },
            .delivered => |d| if (d.side == side) {
                self.state = .idle;
            },
            else => {},
        }
    }

    /// Withdraws a pending write by `side`, used when another port of a
    /// multiport write completed instead.
    pub fn cancelWrite(self: *Port, side: Side) void {
        if (self.state == .writing and self.state.writing.side == side) self.state = .idle;
    }

    /// True when the other side of the port is suspended reading
    pub fn otherReading(self: Port, side: Side) bool {
        return self.state == .reading and self.state.reading != side;
    }

    /// True when the other side of the port is suspended writing
    pub fn otherWriting(self: Port, side: Side) bool {
        return self.state == .writing and self.state.writing.side != side;
    }
};

/// One end of a port, as seen by a node
pub const Link = struct {
    port: ?*Port = null,
    side: Side = .a,
};

test select {
    try expectEqual(Select.initOne(.right), select(0x1d5).?);
    try expectEqual(Select.initOne(.down), select(0x115).?);
    try expectEqual(Select.initOne(.left), select(0x175).?);
    try expectEqual(Select.initOne(.up), select(0x145).?);
    try expectEqual(Select.full, select(0x1a5).?);
    try expectEqual(Select.initMany(&.{ .right, .down, .up }), select(0x185).?);
    try expectEqual(Select.initMany(&.{ .down, .left }), select(0x135).?);

    // io register and RAM
    try expectEqual(null, select(0x15d));
    try expectEqual(null, select(0x005));
}

test "reader arrives first" {
    var port: Port = .{};

    try expectEqual(null, port.read(.a));
    // retrying while suspended has no effect
    try expectEqual(null, port.read(.a));
    try expect(port.otherReading(.b));

    try expect(port.write(.b, 42));
    try expectEqual(42, port.read(.a));
    try expectEqual(Port.State.idle, port.state);
}

test "writer arrives first" {
    var port: Port = .{};

    try expect(!port.write(.a, 42));
    try expect(!port.write(.a, 42));
    try expect(port.otherWriting(.b));
    // a side cannot read its own write
    try expectEqual(null, port.read(.a));

    try expectEqual(42, port.read(.b));
    try expect(port.write(.a, 42));
    try expectEqual(Port.State.idle, port.state);
}

test "both sides writing deadlock" {
    var port: Port = .{};

    try expect(!port.write(.a, 1));
    try expect(!port.write(.b, 2));
    try expect(!port.write(.a, 1));
}

test "cancel" {
    var port: Port = .{};

    _ = port.read(.a);
    port.cancelRead(.b);
    try expect(port.otherReading(.b));
    port.cancelRead(.a);
    try expectEqual(Port.State.idle, port.state);

    // a value delivered to the canceled side is discarded
    _ = port.read(.a);
    try expect(port.write(.b, 1));
    port.cancelRead(.b);
    try expectEqual(.delivered, std.meta.activeTag(port.state));
    port.cancelRead(.a);
    try expectEqual(Port.State.idle, port.state);

    _ = port.write(.a, 1);
    port.cancelWrite(.a);
    try expectEqual(Port.State.idle, port.state);
}

const Word = @import("f18.zig").Word;

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
