//! A rectangular array of F18A nodes, each connected to its neighbours by a
//! comm port, as on the GA144.
//!
//! Nodes are numbered yxx with node 000 in the lower left corner: x counts
//! columns to the east and y counts rows to the north.
//!
//! Port names alternate with position so that two neighbours use the same
//! name for the port between them. On even columns right faces east and left
//! faces west, and odd columns are the reverse. On even rows down faces north
//! and up faces south, and odd rows are the reverse. Ports facing off the edge
//! of the array are unconnected unless a device is attached.
//!
//! A board of several chips alike is one `Chip` of their arrays, numbered
//! k.yxx on chip k (see `Layout`), whose nodes run as one, joined by SERDES
//! links (`attachSerdes`) and wires between their pins.
//!
//! Nodes are configured as the chip's `Spec` says, with their ROM types,
//! GPIO pins and data registers, the GA144's by default (`Spec.ga144`).
//! Each pin is on a net, alone until wired to other pins or devices (see
//! `wire`, `pull` and `pins`).
//!
//! Each node keeps its own time, as it executes. A node that waits on a port
//! catches up with the node it transfers a word with, and the node furthest
//! behind in time steps next, so that devices on nodes' pins, which work at
//! their nodes' times, see what the nodes do in the order they do it.

layout: Layout,
/// what the chip is made of; the nodes it lists must outlive the chip
spec: Spec,
nodes: []Computer,
/// ports between neighbours
ports: []Port,

/// nodes to step, a binary heap of them, the earliest in time first (see
/// `stepsFirst`). Each node is in the queue at most once.
queue: []u16,
queue_len: usize = 0,
queued: []bool,
/// how many times a node has been stepped
steps: u64 = 0,
/// whether a node has been stepped, after the breakpoints on the words the
/// nodes start at were checked
started: bool = false,

/// where running stops, by node index
breakpoints: SmallSet(Breakpoint, max_breakpoints) = .{},
/// transfers through ports that stop running
watches: SmallSet(Watch, max_watches) = .{},
/// the first breakpoint a node reached, or watched transfer, since `run`
/// started or it was last cleared
hit: ?Stop = null,
/// where a line is written for each step that executes code. Tracing stops
/// if writing fails.
trace: ?*Io.Writer = null,
/// that each line of the trace is a JSON object
trace_json: bool = false,
/// the node to trace, by index, if not every one
trace_only: ?u16 = null,
/// where `run` stops of its own accord: once this many steps are taken, or
/// the earliest running node reaches this time, checked after each round
step_limit: u64 = std.math.maxInt(u64),
time_limit: u64 = std.math.maxInt(u64),
/// that `run` stopped at a limit
limited: bool = false,

/// the console, and the index of the node it is attached to
console: ?struct { device: *Console, index: u16 } = null,
/// words fed into a node, such as a boot stream
feeder: ?struct { device: *Feeder, index: u16 } = null,
/// the UARTs on nodes' pins (see `attachUartPins`)
uarts: UartLinks = .{},
/// a synchronous line's master on a node's pins (see `attachSyncPins`)
sync: ?SyncLink = null,
/// rung by whatever gives the UARTs input, so that a run with more than
/// one waits for any of them (see `waitForInput`)
doorbell: ?Console.Queue = null,
/// when something next happens outside the nodes, for a node waiting on it
/// while a node earlier in time runs: the UART's line or the synchronous
/// line's clock changing (see `wakeOnPin`), or a word arriving on a SERDES
/// link (see `arrivals`)
next_event: ?u64 = null,
/// the nodes' GPIO pins and the nets that join them to each other and to
/// devices
wiring: *gpio.Wiring,
/// links between SERDES nodes of different chips (see `attachSerdes`)
serdes: *SerdesLinks,
/// chips' RESET- pins on the nets of pins that drive them (see
/// `attachReset`)
resets: *ResetLines,
/// the chips held in reset, a bit each
held: u8 = 0,
/// where each node starts after reset, as `init`, `loadRom` and
/// `attachFeeder` leave it, for a chip that is reset again
reset_address: []Address,

const Chip = @This();

pub const max_breakpoints = 32;
pub const max_watches = 32;
pub const max_serdes = 4;

pub const max_resets = 4;
pub const max_uarts = 4;

/// A UART on a node's pins. `index` is the node of its rx pin, the one it
/// drives, or of its tx pin if rx is unconnected; `rx_pin` is the rx pin's
/// index in `wiring.pins`, if it is connected.
pub const UartLink = struct { device: *Uart, index: u16, rx_pin: ?u16 };

/// A synchronous line's master on a node's pins, `clock_pin` being the
/// index of its clock pin, the node's wakeup pin, in `wiring.pins`
pub const SyncLink = struct { device: *Sync, index: u16, clock_pin: u16 };

pub const UartLinks = struct {
    items: [max_uarts]UartLink = undefined,
    len: u8 = 0,

    pub fn slice(self: anytype) switch (@TypeOf(self)) {
        *UartLinks => []UartLink,
        else => []const UartLink,
    } {
        return self.items[0..self.len];
    }
};

/// A chip's RESET- pin, which holds the chip in reset while it is low, as a
/// device listening on the net of a pin that drives it. The changes it is
/// told of are acted on after the step that made them (`resetLines`).
pub const ResetLine = struct {
    chip: u8 = 0,
    /// as last told
    high: bool = true,
    /// changes not yet acted on, the earliest first. More in one step than
    /// this keep the latest in the last.
    edges: [4]Edge = @splat(.{}),
    edges_len: u8 = 0,

    pub const Edge = struct {
        time: u64 = 0,
        high: bool = false,
    };

    pub fn device(self: *ResetLine) gpio.Device {
        return .{ .context = self, .changed = changed };
    }

    fn changed(context: *anyopaque, time: u64, high: bool) void {
        const self: *ResetLine = @ptrCast(@alignCast(context));
        if (high == self.high) return;
        self.high = high;
        if (self.edges_len < self.edges.len) self.edges_len += 1;
        self.edges[self.edges_len - 1] = .{ .time = time, .high = high };
    }
};

pub const ResetLines = struct {
    items: [max_resets]ResetLine = @splat(.{}),
    len: u8 = 0,

    pub fn slice(self: *ResetLines) []ResetLine {
        return self.items[0..self.len];
    }
};

/// where a chip held in reset waits, an io address that is not a port, so
/// that fetching from it waits forever and nothing wakes it
const held_address: Address = Address.fromWord(0x1ff);

pub const SerdesLinks = struct {
    items: [max_serdes]Serdes = @splat(.init(0, 0)),
    len: u8 = 0,

    pub fn slice(self: *SerdesLinks) []Serdes {
        return self.items[0..self.len];
    }
};

/// Formats a node number as GreenArrays write it, such as 708, and on a
/// chip after the first, with the chip before it, such as 1.708
pub fn nodeName(number: u16) NodeName {
    return .{ .number = number };
}

pub const NodeName = struct {
    number: u16,

    pub fn format(self: NodeName, writer: *Io.Writer) Io.Writer.Error!void {
        const chip = self.number / Layout.chip_numbers;
        if (chip > 0) try writer.print("{d}.", .{chip});
        try writer.print("{d:0>3}", .{self.number % Layout.chip_numbers});
    }
};

/// Parses a node number as `nodeName` writes it, such as 708 or 1.708
pub fn parseNode(text: []const u8) error{InvalidNode}!u16 {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse
        return std.fmt.parseInt(u16, text, 10) catch error.InvalidNode;
    const chip = std.fmt.parseInt(u16, text[0..dot], 10) catch return error.InvalidNode;
    const local = std.fmt.parseInt(u16, text[dot + 1 ..], 10) catch return error.InvalidNode;
    if (local >= Layout.chip_numbers or chip > Layout.max_chips) return error.InvalidNode;
    return std.math.add(u16, chip * Layout.chip_numbers, local) catch error.InvalidNode;
}

/// A node about to fetch the word at an address. RAM and ROM addresses that
/// repeat the same word, such as x000 and x040, are the same breakpoint.
pub const Breakpoint = struct {
    index: u16,
    address: u9,

    pub fn init(index: u16, address: u9) Breakpoint {
        // only the low 6 bits of a RAM or ROM address select a word
        return .{ .index = index, .address = if (address & 0x100 == 0) address & 0x1bf else address };
    }
};

/// A node completing a read from, or a write to, one of its ports
pub const Watch = struct {
    index: u16,
    direction: Direction,
    write: bool,
};

/// why running stopped
pub const Stop = union(enum) {
    breakpoint: Breakpoint,
    /// with the value that was read or written
    watch: struct { watch: Watch, value: Word },

    pub fn index(self: Stop) u16 {
        return switch (self) {
            .breakpoint => |b| b.index,
            .watch => |w| w.watch.index,
        };
    }

    /// formats why running stopped, such as `node 000 reached 004` or `node
    /// 001 read 00068 from right`
    pub fn describe(self: Stop, layout: Layout) Description {
        return .{ .stop = self, .layout = layout };
    }

    pub const Description = struct {
        stop: Stop,
        layout: Layout,

        pub fn format(self: Description, writer: *Io.Writer) Io.Writer.Error!void {
            const number = self.layout.nodeNumber(self.stop.index());
            switch (self.stop) {
                .breakpoint => |b| try writer.print("node {f} reached {x:0>3}", .{ nodeName(number), b.address }),
                .watch => |w| try writer.print("node {f} {s} {x:0>5} {s} {t}", .{
                    nodeName(number),
                    if (w.watch.write) "wrote" else "read",
                    @as(u18, @bitCast(w.value)),
                    if (w.watch.write) "to" else "from",
                    w.watch.direction,
                }),
            }
        }
    };
};

/// A set of up to `capacity` items, such as breakpoints, without allocating
fn SmallSet(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: u8 = 0,

        const Self = @This();

        pub fn items(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn contains(self: Self, item: T) bool {
            for (self.items()) |i| if (std.meta.eql(i, item)) return true;
            return false;
        }

        /// Adds an item unless it is there already
        pub fn insert(self: *Self, item: T) error{Full}!void {
            if (self.contains(item)) return;
            if (self.len == capacity) return error.Full;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        /// Adds an item, or removes it if it is there. Returns whether it
        /// is there now.
        pub fn toggle(self: *Self, item: T) error{Full}!bool {
            for (self.buffer[0..self.len]) |*i| if (std.meta.eql(i.*, item)) {
                i.* = self.buffer[self.len - 1];
                self.len -= 1;
                return false;
            };
            try self.insert(item);
            return true;
        }
    };
}

/// The nodes, the ports between them and which nodes run next, to go back
/// to with `restore`. Devices keep their input and output, but their ports
/// go back too.
pub const Snapshot = struct {
    nodes: []Computer,
    ports: []Port,
    queue: []u16,
    queued: []bool,
    queue_len: usize = 0,
    steps: u64 = 0,
    started: bool = false,
    console_port: Port = .{},
    feeder_port: Port = .{},
    feeder_next: usize = 0,
    serdes: SerdesLinks = .{},
    resets: ResetLines = .{},
    held: u8 = 0,

    /// Allocates a snapshot of a chip with `layout`
    pub fn init(gpa: Allocator, layout: Layout) Allocator.Error!Snapshot {
        const nodes = try gpa.alloc(Computer, layout.count());
        errdefer gpa.free(nodes);
        const ports = try gpa.alloc(Port, layout.portCount());
        errdefer gpa.free(ports);
        const queue = try gpa.alloc(u16, layout.count());
        errdefer gpa.free(queue);
        return .{ .nodes = nodes, .ports = ports, .queue = queue, .queued = try gpa.alloc(bool, layout.count()) };
    }

    pub fn deinit(self: *Snapshot, gpa: Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.ports);
        gpa.free(self.queue);
        gpa.free(self.queued);
        self.* = undefined;
    }
};

/// Writes words to a node through a port, such as a boot stream
pub const Feeder = struct {
    port: Port = .{},
    words: []const Word,
    next: usize = 0,

    /// the feeder's side of the port; the node uses the other one
    const side: port.Side = .b;

    /// Writes the next word if the node is reading. Returns false if there
    /// is nothing to do.
    pub fn service(self: *Feeder) bool {
        if (self.next == self.words.len or !self.port.otherReading(side)) return false;
        _ = self.port.write(side, self.words[self.next]);
        self.next += 1;
        return true;
    }
};

/// The nodes' arrangement: rows and columns, on each of `chips` chips, as on
/// a board of several. Node numbers are yxx on the first chip, and k yyxx
/// on chip k, as arrayForth 3 numbers chips, written k.yxx; chip k's nodes
/// follow chip k-1's.
pub const Layout = struct {
    rows: u8,
    columns: u8,
    chips: u8 = 1,

    pub const ga144: Layout = .{ .rows = 8, .columns = 18 };

    /// node numbers of each chip, after the previous chip's
    pub const chip_numbers = 10000;

    /// the most chips node numbers can tell apart
    pub const max_chips = std.math.maxInt(u16) / chip_numbers;

    /// Parses rows and columns such as 8x18. Node numbers limit both to 100.
    pub fn parse(text: []const u8) error{InvalidLayout}!Layout {
        const x = std.mem.indexOfScalar(u8, text, 'x') orelse return error.InvalidLayout;
        const rows = std.fmt.parseInt(u8, text[0..x], 10) catch return error.InvalidLayout;
        const columns = std.fmt.parseInt(u8, text[x + 1 ..], 10) catch return error.InvalidLayout;
        if (rows == 0 or rows > 100 or columns == 0 or columns > 100) return error.InvalidLayout;
        return .{ .rows = rows, .columns = columns };
    }

    pub fn count(self: Layout) usize {
        return @as(usize, self.chipCount()) * self.chips;
    }

    /// the number of nodes on each chip
    pub fn chipCount(self: Layout) u16 {
        return @as(u16, self.rows) * self.columns;
    }

    /// the number of ports between neighbours
    pub fn portCount(self: Layout) usize {
        const rows: usize = self.rows;
        const columns: usize = self.columns;
        return (rows * (columns - 1) + (rows - 1) * columns) * self.chips;
    }

    /// index into `Chip.nodes` of a node number, if the node exists
    pub fn index(self: Layout, number: u16) ?u16 {
        const chip = number / chip_numbers;
        const x = number % 100;
        const y = number % chip_numbers / 100;
        if (chip >= self.chips or x >= self.columns or y >= self.rows) return null;
        return chip * self.chipCount() + y * self.columns + x;
    }

    pub fn nodeNumber(self: Layout, i: u16) u16 {
        const local = i % self.chipCount();
        return i / self.chipCount() * chip_numbers + local / self.columns * 100 + local % self.columns;
    }

    /// for messages, such as `a 8x18 layout`, or `2 chips of 8x18`
    pub fn format(self: Layout, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.chips == 1) return writer.print("a {d}x{d} layout", .{ self.rows, self.columns });
        try writer.print("{d} chips of {d}x{d}", .{ self.chips, self.rows, self.columns });
    }

    /// the column of node `i` on its chip
    pub fn column(self: Layout, i: u16) u16 {
        return i % self.chipCount() % self.columns;
    }

    /// the row of node `i` on its chip
    pub fn row(self: Layout, i: u16) u16 {
        return i % self.chipCount() / self.columns;
    }

    /// the ports of a node that face its neighbours, where it waits for code
    /// after reset
    pub fn neighbourPorts(self: Layout, i: u16) port.Select {
        var ports: port.Select = .empty;
        for (std.enums.values(Direction)) |direction| ports.setPresent(direction, self.neighbour(i, direction) != null);
        return ports;
    }

    /// index of the node on the other side of a port, if it is on the chip
    pub fn neighbour(self: Layout, i: u16, direction: Direction) ?u16 {
        const x = self.column(i);
        const y = self.row(i);
        return switch (facing(x, y, direction)) {
            .north => if (y + 1 < self.rows) i + self.columns else null,
            .south => if (y > 0) i - self.columns else null,
            .east => if (x + 1 < self.columns) i + 1 else null,
            .west => if (x > 0) i - 1 else null,
        };
    }
};

pub const Cardinal = enum {
    north,
    east,
    south,
    west,

    pub fn opposite(self: Cardinal) Cardinal {
        return switch (self) {
            .north => .south,
            .east => .west,
            .south => .north,
            .west => .east,
        };
    }
};

/// Which way a word goes through the port between two nodes, as a map
/// draws it, and why
pub const Flow = struct {
    /// toward the neighbour, rather than from it
    outward: bool,
    kind: Kind,

    pub const Kind = enum {
        /// a word went across in the last step, or has been handed over to
        /// be taken
        moved,
        /// a node is waiting to read or write
        waiting,
        /// a node is waiting for code
        code,
    };
};

/// What the port between node `i` and its neighbour toward `cardinal` is
/// doing, pointing the way the word goes. Nodes on both sides waiting to
/// read, as after reset, get none, as no word will go either way.
pub fn flow(self: *const Chip, i: u16, cardinal: Cardinal) ?Flow {
    const layout = self.layout;
    const n = &self.nodes[i];
    const direction = portToward(layout.column(i), layout.row(i), cardinal);
    const link = n.ports[@backingInt(direction)];
    const p = link.port orelse return null;
    const j = layout.neighbour(i, direction) orelse return null;
    const facing_back = portToward(layout.column(j), layout.row(j), cardinal.opposite());
    const other = &self.nodes[j];

    if (n.transfers.written.contains(direction) or other.transfers.read.contains(facing_back)) return .{ .outward = true, .kind = .moved };
    if (n.transfers.read.contains(direction) or other.transfers.written.contains(facing_back)) return .{ .outward = false, .kind = .moved };
    return switch (p.state) {
        .idle => null,
        .reading => |side| reading: {
            // the port remembers only the first of two readers
            const also_reading = if (side == link.side) self.waitsToRead(j, facing_back) else self.waitsToRead(i, direction);
            if (also_reading) break :reading null;
            const reader = if (side == link.side) n else other;
            break :reading .{ .outward = side != link.side, .kind = if (reader.status() == .code) .code else .waiting };
        },
        .writing => |w| .{ .outward = w.side == link.side, .kind = .waiting },
        .delivered => |d| .{ .outward = d.side != link.side, .kind = .moved },
        .taken => |side| .{ .outward = side == link.side, .kind = .moved },
    };
}

/// whether a node is waiting to read, or for code, on one of its ports
fn waitsToRead(self: *const Chip, i: u16, direction: Direction) bool {
    const address = switch (self.nodes[i].status()) {
        .code, .reading => |a| a,
        .running, .writing => return false,
    };
    const ports = port.select(address) orelse return false;
    return ports.contains(direction);
}

/// The port a node at column `x` and row `y` uses toward `cardinal`
pub fn portToward(x: u16, y: u16, cardinal: Cardinal) Direction {
    return switch (cardinal) {
        .north => if (y % 2 == 0) .down else .up,
        .south => if (y % 2 == 0) .up else .down,
        .east => if (x % 2 == 0) .right else .left,
        .west => if (x % 2 == 0) .left else .right,
    };
}

/// The cardinal direction a node at column `x` and row `y` faces through a port
pub fn facing(x: u16, y: u16, direction: Direction) Cardinal {
    return switch (direction) {
        .right => if (x % 2 == 0) .east else .west,
        .left => if (x % 2 == 0) .west else .east,
        .down => if (y % 2 == 0) .north else .south,
        .up => if (y % 2 == 0) .south else .north,
    };
}

/// Allocates and wires up the nodes. As after reset, nodes start with a
/// multiport execute of their neighbours' ports, waiting for code, until
/// they are loaded with ROM or a program.
pub fn init(gpa: Allocator, spec: Spec) Allocator.Error!Chip {
    return initChips(gpa, spec, 1);
}

/// As `init`, for `chips` chips alike, as on a board of several, which
/// SERDES links (`attachSerdes`) and wires between their pins join
pub fn initChips(gpa: Allocator, spec: Spec, chips: u8) Allocator.Error!Chip {
    var layout = spec.layout();
    layout.chips = chips;
    const count = layout.count();
    const nodes = try gpa.alloc(Computer, count);
    errdefer gpa.free(nodes);
    const rows: usize = layout.rows;
    const columns: usize = layout.columns;
    const ports = try gpa.alloc(Port, layout.portCount());
    errdefer gpa.free(ports);
    const queue = try gpa.alloc(u16, count);
    errdefer gpa.free(queue);
    const queued = try gpa.alloc(bool, count);
    errdefer gpa.free(queued);

    const serdes = try gpa.create(SerdesLinks);
    errdefer gpa.destroy(serdes);
    serdes.* = .{};
    const resets = try gpa.create(ResetLines);
    errdefer gpa.destroy(resets);
    resets.* = .{};
    const reset_address = try gpa.alloc(Address, count);
    errdefer gpa.free(reset_address);

    var chip: Chip = .{
        .layout = layout,
        .spec = spec,
        .nodes = nodes,
        .ports = ports,
        .queue = queue,
        .queued = queued,
        .wiring = undefined,
        .serdes = serdes,
        .resets = resets,
        .reset_address = reset_address,
    };
    @memset(ports, .{});
    @memset(queued, false);
    for (nodes, 0..) |*n, i| {
        // as on its own chip
        const number = layout.nodeNumber(@intCast(i)) % Layout.chip_numbers;
        n.* = .reset;
        n.pins = spec.pins(number);
        n.wake_port = wakePort(layout, @intCast(i), n.pins);
        if (spec.hasData(number)) n.data = 0;
        n.bus = spec.node(number).bus;
        n.p.address = Address.fromWord(port.multiport(layout.neighbourPorts(@intCast(i))));
        reset_address[i] = n.p.address;
        chip.wake(@intCast(i));
    }

    // the west or south node of each pair takes side a
    var next_port: usize = 0;
    for (0..chips) |c| for (0..rows) |y| {
        for (0..columns) |x| {
            const i = c * layout.chipCount() + y * columns + x;
            if (x + 1 < columns) {
                chip.connect(i, i + 1, portToward(@intCast(x), @intCast(y), .east), &ports[next_port]);
                next_port += 1;
            }
            if (y + 1 < rows) {
                chip.connect(i, i + columns, portToward(@intCast(x), @intCast(y), .north), &ports[next_port]);
                next_port += 1;
            }
        }
    };
    std.debug.assert(next_port == ports.len);
    chip.wiring = try .create(gpa, nodes);
    return chip;
}

pub fn deinit(self: *Chip, gpa: Allocator) void {
    gpa.free(self.nodes);
    gpa.free(self.ports);
    gpa.free(self.queue);
    gpa.free(self.queued);
    self.wiring.destroy(gpa);
    gpa.destroy(self.serdes);
    gpa.destroy(self.resets);
    gpa.free(self.reset_address);
    self.* = undefined;
}

/// Saves the chip into a snapshot allocated for its layout
pub fn save(self: Chip, snapshot: *Snapshot) void {
    @memcpy(snapshot.nodes, self.nodes);
    @memcpy(snapshot.ports, self.ports);
    @memcpy(snapshot.queue, self.queue);
    @memcpy(snapshot.queued, self.queued);
    snapshot.queue_len = self.queue_len;
    snapshot.steps = self.steps;
    snapshot.started = self.started;
    snapshot.serdes = self.serdes.*;
    snapshot.resets = self.resets.*;
    snapshot.held = self.held;
    if (self.console) |console| snapshot.console_port = console.device.port;
    if (self.feeder) |feeder| {
        snapshot.feeder_port = feeder.device.port;
        snapshot.feeder_next = feeder.device.next;
    }
}

/// Goes back to a snapshot saved from this chip
pub fn restore(self: *Chip, snapshot: *const Snapshot) void {
    @memcpy(self.nodes, snapshot.nodes);
    @memcpy(self.ports, snapshot.ports);
    @memcpy(self.queue, snapshot.queue);
    @memcpy(self.queued, snapshot.queued);
    self.queue_len = snapshot.queue_len;
    self.steps = snapshot.steps;
    self.started = snapshot.started;
    self.hit = null;
    self.next_event = null;
    self.serdes.* = snapshot.serdes;
    self.resets.* = snapshot.resets;
    self.held = snapshot.held;
    // the pins' histories are of the future the chip went back from
    self.wiring.reset();
    if (self.console) |console| console.device.port = snapshot.console_port;
    if (self.feeder) |feeder| {
        feeder.device.port = snapshot.feeder_port;
        feeder.device.next = snapshot.feeder_next;
    }
}

/// Whether the chip is as it was when saved into a snapshot, not counting
/// steps that changed nothing
pub fn matches(self: *const Chip, snapshot: *const Snapshot) bool {
    const eql = std.mem.eql;
    const bytes = std.mem.sliceAsBytes;
    if (!eql(u8, bytes(self.nodes), bytes(snapshot.nodes)) or
        !eql(u8, bytes(self.ports), bytes(snapshot.ports)) or
        !eql(u8, bytes(self.queue), bytes(snapshot.queue)) or
        !eql(bool, self.queued, snapshot.queued) or
        self.queue_len != snapshot.queue_len or
        !std.meta.eql(self.serdes.*, snapshot.serdes) or
        !std.meta.eql(self.resets.*, snapshot.resets) or
        self.held != snapshot.held) return false;
    if (self.console) |console| if (!std.meta.eql(console.device.port, snapshot.console_port)) return false;
    if (self.feeder) |feeder| if (!std.meta.eql(feeder.device.port, snapshot.feeder_port) or feeder.device.next != snapshot.feeder_next) return false;
    return true;
}

/// The port that reads pin 17 of a node on an edge as a wakeup pin: Up on
/// the top and bottom edges, and Left on the sides, if it faces off the
/// array
fn wakePort(layout: Layout, i: u16, pins: u18) ?Direction {
    if (pins & 1 << 17 == 0) return null;
    const y = layout.row(i);
    const direction: Direction = if (y == 0 or y + 1 == layout.rows) .up else .left;
    return if (layout.neighbour(i, direction) == null) direction else null;
}

/// connects two neighbours, which use the same name for their common port
fn connect(self: *Chip, a: usize, b: usize, direction: Direction, p: *Port) void {
    self.nodes[a].ports[@backingInt(direction)] = .{ .port = p, .side = .a };
    self.nodes[b].ports[@backingInt(direction)] = .{ .port = p, .side = .b };
}

pub fn node(self: Chip, number: u16) ?*Computer {
    return &self.nodes[self.layout.index(number) orelse return null];
}

/// Loads each node's ROM from a dump of a GA144's, and starts the nodes the
/// chip starts in ROM as after reset. A node gets the ROM of the GA144 node
/// with its number if that has the ROM type the chip gives it, and else of
/// a GA144 node that has. Nodes whose ROM is missing from the dump get a
/// basic node's, and wait for code on their ports as basic nodes do. Load
/// ROM before programs, and before stepping the chip.
pub fn loadRom(self: *Chip, roms: []const ga144.NodeRom) error{MissingRom}!void {
    const basic = findRom(roms, ga144.basic_node);
    for (self.nodes, 0..) |*n, i| {
        // as on its own chip
        const number = self.layout.nodeNumber(@intCast(i)) % Layout.chip_numbers;
        const own = romOfType(roms, number, self.spec.node(number).rom);
        const rom = own orelse basic orelse return error.MissingRom;
        @memcpy(n.mem[64..], &rom.words);
        // cold and warm are where they are only in a ROM of the node's type
        if (own != null) if (self.spec.resetAddress(number)) |address| {
            n.p.address = Address.fromWord(address);
            self.reset_address[i] = n.p.address;
        };
    }
}

/// the ROM in a dump of a GA144's for a node with `rom_type`: node
/// `number`'s if it has that type, or else another's that has. The special
/// nodes' ROMs differ from each other, so they have only their own.
fn romOfType(roms: []const ga144.NodeRom, number: u16, rom_type: ga144.RomType) ?*const ga144.NodeRom {
    if (Spec.ga144.node(number).rom == rom_type) if (findRom(roms, number)) |own| return own;
    if (rom_type == .special) return null;
    if (rom_type == .basic) if (findRom(roms, ga144.basic_node)) |basic| return basic;
    for (roms) |*rom| if (Spec.ga144.node(rom.node).rom == rom_type) return rom;
    return null;
}

fn findRom(roms: []const ga144.NodeRom, number: u16) ?*const ga144.NodeRom {
    for (roms) |*rom| if (rom.node == number) return rom;
    return null;
}

/// Loads a program into its node. Load programs before stepping the chip.
pub fn load(self: *Chip, program: assembler.Program) error{NoSuchNode}!void {
    const n = self.node(program.node) orelse return error.NoSuchNode;
    // a chip held in reset takes only the RAM, and stays held
    if (self.isHeld(@intCast(program.node / Layout.chip_numbers))) {
        @memcpy(n.mem[0..64], &program.ram);
    } else program.load(n);
}

/// Sets up a node as a boot descriptor says, without a boot stream: loads
/// its RAM from `programs`, sets its registers, pushes onto its stacks and
/// starts it at P. Set up nodes before stepping the chip.
pub fn setUp(self: *Chip, descriptor: boot.Descriptor, programs: []const assembler.Program) error{ NoSuchNode, NoSuchBin }!void {
    const n = self.node(descriptor.node) orelse return error.NoSuchNode;
    for (descriptor.loads[0..descriptor.load_count]) |part| {
        const program = boot.findBin(programs, part.bin) orelse return error.NoSuchBin;
        @memcpy(n.mem[part.destination..][0..part.len], program.ram[part.source..][0..part.len]);
    }
    // a chip held in reset takes only the RAM, and stays held
    if (self.isHeld(@intCast(descriptor.node / Layout.chip_numbers))) return;
    if (descriptor.io) |io| {
        n.io = io;
        if (n.pin_device) |device| device.written(device.context, n);
        if (n.bus_device) |device| device.written(device.context, n);
    }
    if (descriptor.a) |a| n.a = a;
    if (descriptor.b) |b| n.b = @truncate(@as(u18, @bitCast(b)));
    for (descriptor.return_stack[0..descriptor.return_stack_len]) |value| n.return_stack.push(value);
    for (descriptor.stack[0..descriptor.stack_len]) |value| n.data_stack.push(value);
    n.p = @bitCast(descriptor.p);
}

/// Has a node that is waiting for code from a port execute an instruction
/// word instead, as arrayForth 3's IDE gives words to a node through a port.
/// The node stops waiting on the port, and runs the word as if called from
/// it, with the port's address pushed onto the return stack: a return goes
/// back to the port, as does running off the end of the word, to wait for
/// code again. So `op ; ; ;` runs an opcode, and a jump runs code that
/// returns to the port.
pub fn execute(self: *Chip, i: u16, word: Word) error{NotWaitingForCode}!void {
    const n = &self.nodes[i];
    if (!waitsForCode(n)) return error.NotWaitingForCode;
    const ports = port.select(@bitCast(n.p.address)).?;
    // a word already delivered to the node is code it will run first, so
    // check every port before withdrawing the node's reads from any
    var it = ports.iterator();
    while (it.next()) |direction| {
        const link = n.ports[@backingInt(direction)];
        const p = link.port orelse continue;
        if (p.state == .delivered and p.state.delivered.side == link.side) return error.NotWaitingForCode;
    }
    it = ports.iterator();
    while (it.next()) |direction| {
        const link = n.ports[@backingInt(direction)];
        if (link.port) |p| p.cancelRead(link.side);
    }
    n.return_stack.push(n.p.toWord());
    n.i = word;
    n.word_address = n.p.address;
    n.slot = 0;
    n.state = .execution;
    n.suspended = false;
    self.wake(i);
}

/// Steps the chip until node `i` waits for code from a port, for at most
/// `limit` rounds. Returns false if it did not, because it was still
/// running or every node was waiting on something else.
pub fn runUntilWaiting(self: *Chip, i: u16, limit: usize) !bool {
    for (0..limit) |_| {
        if (waitsForCode(&self.nodes[i])) return true;
        if (!try self.advance()) break;
    }
    return waitsForCode(&self.nodes[i]);
}

/// Whether a node is waiting for code from a port, or is about to, such as
/// after reset before it has tried
pub fn waitsForCode(n: *const Computer) bool {
    return n.state == .fetch and port.select(@bitCast(n.p.address)) != null;
}

/// Attaches a console to a port of a node that faces off the array
pub fn attachConsole(self: *Chip, console: *Console, number: u16, direction: Direction) error{ NoSuchNode, PortConnected }!void {
    const i = self.layout.index(number) orelse return error.NoSuchNode;
    if (self.nodes[i].ports[@backingInt(direction)].port != null) return error.PortConnected;
    console.attach(&self.nodes[i], direction);
    self.console = .{ .device = console, .index = i };
}

/// Attaches a feeder to a port of a node that faces off the array. A node
/// still waiting for code after reset waits on the feeder too, so attach it
/// before stepping the chip.
pub fn attachFeeder(self: *Chip, feeder: *Feeder, number: u16, direction: Direction) error{ NoSuchNode, PortConnected }!void {
    const i = self.layout.index(number) orelse return error.NoSuchNode;
    const n = &self.nodes[i];
    const link = &n.ports[@backingInt(direction)];
    if (link.port != null) return error.PortConnected;
    link.* = .{ .port = &feeder.port, .side = Feeder.side.other() };
    const ports = self.layout.neighbourPorts(i);
    if (n.p.address == Address.fromWord(port.multiport(ports)))
        n.p.address = Address.fromWord(port.multiport(ports.unionWith(.initOne(direction))));
    if (self.reset_address[i] == Address.fromWord(port.multiport(ports)))
        self.reset_address[i] = Address.fromWord(port.multiport(ports.unionWith(.initOne(direction))));
    self.feeder = .{ .device = feeder, .index = i };
}

/// Attaches a UART to the pins of a node, the node driving `uart.tx_pin`
/// and the UART `uart.rx_pin`
pub fn attachUart(self: *Chip, uart: *Uart, number: u16) error{ NoSuchNode, NoPins }!void {
    const i = self.layout.index(number) orelse return error.NoSuchNode;
    const pins = self.nodes[i].pins;
    if (pins & uart.rx_pin == 0 or pins & uart.tx_pin == 0) return error.NoPins;
    self.attachUartPins(uart, .{ .node = number, .pin = @intCast(@ctz(uart.rx_pin)) }, .{ .node = number, .pin = @intCast(@ctz(uart.tx_pin)) }) catch
        return error.NoPins;
}

/// Attaches a UART to two pins, which may be of different nodes: it drives
/// `rx`, which the chip receives on, and listens to `tx`, which it sends
/// on. Either may be left out, as a board's jumper can leave a line
/// unconnected.
pub fn attachUartPins(self: *Chip, uart: *Uart, rx: ?PinRef, tx: ?PinRef) error{ NoSuchPin, TwoDevices, Full }!void {
    const rx_pin = if (rx) |r| try self.pinOf(r) else null;
    const tx_pin = if (tx) |t| try self.pinOf(t) else null;
    const wiring = self.wiring;
    for ([_]?*gpio.Pin{ rx_pin, tx_pin }) |p| if (p) |pin| if (wiring.nets[pin.net].device != null) return error.TwoDevices;
    if (rx_pin != null and tx_pin != null and rx_pin.?.net == tx_pin.?.net) return error.TwoDevices;
    const index = if (rx_pin orelse tx_pin) |p| p.node else return;
    if (self.uarts.len == max_uarts) return error.Full;
    self.uarts.items[self.uarts.len] = .{ .device = uart, .index = index, .rx_pin = if (rx_pin) |p| @intCast(p - wiring.pins.ptr) else null };
    self.uarts.len += 1;
    if (rx_pin) |p| {
        uart.rx_pin = p.bit;
        wiring.nets[p.net].device = uart.rxDevice();
        wiring.hook(p.node);
    }
    if (tx_pin) |p| {
        uart.tx_pin = p.bit;
        wiring.nets[p.net].device = uart.txDevice();
        wiring.hook(p.node);
    }
}

/// Puts a synchronous line's master on two pins: it drives `clock`, which
/// has to be the wakeup pin, pin 17, of its node, and `data`
pub fn attachSyncPins(self: *Chip, sync: *Sync, clock: PinRef, data: PinRef) error{ NoSuchPin, TwoDevices, NotWakeupPin }!void {
    if (clock.pin != 17) return error.NotWakeupPin;
    const clock_pin = try self.pinOf(clock);
    const data_pin = try self.pinOf(data);
    const wiring = self.wiring;
    if (self.sync != null or clock_pin.net == data_pin.net) return error.TwoDevices;
    for ([_]*gpio.Pin{ clock_pin, data_pin }) |p| if (wiring.nets[p.net].device != null) return error.TwoDevices;
    wiring.nets[clock_pin.net].device = sync.clockDevice();
    wiring.hook(clock_pin.node);
    wiring.nets[data_pin.net].device = sync.dataDevice();
    wiring.hook(data_pin.node);
    self.sync = .{ .device = sync, .index = clock_pin.node, .clock_pin = @intCast(clock_pin - wiring.pins.ptr) };
}

/// Puts a device on the net of pin `p`, which it listens to or drives
pub fn attachPin(self: *Chip, p: PinRef, device: gpio.Device) error{ NoSuchPin, TwoDevices }!void {
    const pin = try self.pinOf(p);
    if (self.wiring.nets[pin.net].device != null) return error.TwoDevices;
    self.wiring.nets[pin.net].device = device;
    self.wiring.hook(pin.node);
}

/// Puts a device on the parallel bus of node `number`, which it tells of
/// the node's bus as it is
pub fn attachBus(self: *Chip, number: u16, device: Computer.BusDevice) error{ NoSuchNode, NoBus, TwoDevices }!void {
    const n = &self.nodes[self.layout.index(number) orelse return error.NoSuchNode];
    if (!self.spec.node(number % Layout.chip_numbers).bus) return error.NoBus;
    if (n.bus_device != null) return error.TwoDevices;
    n.bus_device = device;
    device.written(device.context, n);
}

/// Puts an SPI flash on four pins, any of which can be left unconnected: it
/// listens to the clock, chip select and data out, and drives data in
pub fn attachFlashPins(self: *Chip, flash: *Flash, clock: ?PinRef, select: ?PinRef, data_out: ?PinRef, data_in: ?PinRef) error{ NoSuchPin, TwoDevices }!void {
    var found: [4]?*gpio.Pin = undefined;
    for ([_]?PinRef{ clock, select, data_out, data_in }, &found) |ref, *pin| pin.* = if (ref) |r| try self.pinOf(r) else null;
    const wiring = self.wiring;
    for (found, 0..) |p, k| if (p) |pin| {
        if (wiring.nets[pin.net].device != null) return error.TwoDevices;
        for (found[0..k]) |q| if (q) |other| if (other.net == pin.net) return error.TwoDevices;
    };
    for (found, [_]gpio.Device{ flash.clockDevice(), flash.selectDevice(), flash.dataOutDevice(), flash.dataInDevice() }) |p, device| if (p) |pin| {
        wiring.nets[pin.net].device = device;
        wiring.hook(pin.node);
    };
}

/// Links two SERDES nodes, as the EVB002 links host node 701 to target
/// node 001: each node's up port, which faces off its chip, sends to the
/// other's. Link nodes before stepping the chip.
pub fn attachSerdes(self: *Chip, a: u16, b: u16) error{ NoSuchNode, NotSerdes, PortConnected, Full }!void {
    const ends = [2]u16{ self.layout.index(a) orelse return error.NoSuchNode, self.layout.index(b) orelse return error.NoSuchNode };
    if (ends[0] == ends[1]) return error.NotSerdes;
    for (ends) |i| {
        const n = &self.nodes[i];
        // a node with pins has them on its pin device, and one with a
        // parallel bus its data register on the bus
        if (n.data == null or n.bus or n.pins != 0) return error.NotSerdes;
        if (n.ports[@backingInt(Direction.up)].port != null or self.layout.neighbour(i, .up) != null) return error.PortConnected;
    }
    if (self.serdes.len == max_serdes) return error.Full;
    const link = &self.serdes.items[self.serdes.len];
    self.serdes.len += 1;
    link.* = .init(ends[0], ends[1]);
    for (&link.ends) |*end| {
        const n = &self.nodes[end.index];
        n.ports[@backingInt(Direction.up)] = .{ .port = &end.port, .side = Serdes.side.other() };
        n.pin_device = Serdes.pinDevice(end);
        end.written(n);
    }
}

/// Wires chip `chip`'s RESET- pin to the net of pin `by`, which holds the
/// chip in reset while it is low, pulled up if `pulled`, as by a board's
/// reset circuit. RESET- has no pulldown of its own (DB002 5.5.2). Attach
/// before stepping the chip.
pub fn attachReset(self: *Chip, chip: u8, by: PinRef, pulled: bool) error{ NoSuchChip, NoSuchPin, TwoDevices, ConflictingPulls, Full }!void {
    if (chip >= self.layout.chips) return error.NoSuchChip;
    const p = try self.pinOf(by);
    const net = &self.wiring.nets[p.net];
    if (net.device != null) return error.TwoDevices;
    if (pulled) if (net.pull) |high| if (!high) return error.ConflictingPulls;
    if (self.resets.len == max_resets) return error.Full;
    const line = &self.resets.items[self.resets.len];
    self.resets.len += 1;
    line.* = .{ .chip = chip };
    if (pulled) net.pull = true;
    net.device = line.device();
    var it = self.wiring.members(p.net);
    while (it.next()) |q| self.wiring.hook(q.node);
    // held from the start if it starts low
    if (!self.wiring.level(p.net, 0)) {
        line.high = false;
        self.holdChip(chip, 0);
    }
}

/// a GPIO pin of a node, by its number, out of 17, 5, 3 and 1
pub const PinRef = struct { node: u16, pin: u5 };

/// Joins the nets of two pins, as a wire between them. Connect pins before
/// stepping the chip.
pub fn wire(self: *Chip, a: PinRef, b: PinRef) error{ NoSuchPin, TwoDevices, ConflictingPulls }!void {
    const pa = try self.pinOf(a);
    const pb = try self.pinOf(b);
    try self.wiring.connect(pa, pb);
    var it = self.wiring.members(pa.net);
    while (it.next()) |p| self.wiring.hook(p.node);
}

/// Puts a resistor from a pin's net to high or low, which outweighs a
/// node's weak pulldown but not a pin driven either way
pub fn pull(self: *Chip, p: PinRef, high: bool) error{NoSuchPin}!void {
    const pin = try self.pinOf(p);
    self.wiring.nets[pin.net].pull = high;
    var it = self.wiring.members(pin.net);
    while (it.next()) |other| self.wiring.hook(other.node);
}

fn pinOf(self: *Chip, p: PinRef) error{NoSuchPin}!*gpio.Pin {
    const i = self.layout.index(p.node) orelse return error.NoSuchPin;
    switch (p.pin) {
        17, 5, 3, 1 => {},
        else => return error.NoSuchPin,
    }
    return self.wiring.pin(i, @as(u18, 1) << p.pin) orelse error.NoSuchPin;
}

/// feeds the next word, waking the node that takes it
fn feed(self: *Chip) bool {
    const feeder = self.feeder orelse return false;
    if (!feeder.device.service()) return false;
    self.wake(feeder.index);
    return true;
}

/// Takes as many steps as there are nodes queued, each of the node furthest
/// behind in time then, which may be the same node again. Returns false
/// when every node is suspended, and stepping would do nothing.
pub fn step(self: *Chip) bool {
    if (self.hasEvents()) self.fireEvents();
    if (self.queue_len == 0) return false;
    if (!self.started) {
        // a breakpoint on the first word a node runs
        for (self.nodes, 0..) |*n, i| if (self.hit == null and !n.suspended and n.state == .fetch) {
            self.hit = self.breakpointAt(@intCast(i));
        };
        self.started = true;
        if (self.hit != null) return true;
    }
    // a stop from before, which the caller has not cleared, does not stop
    // stepping again
    if (self.hit != null) return self.roundAfterStop();
    for (0..self.queue_len) |_| {
        // a node that stopped may be the earliest still, and a node waiting
        // on something outside the nodes wakes when the earliest gets to it
        if (self.hit != null) break;
        if (self.next_event) |time| if (self.nodes[self.queue[0]].time >= time) self.fireEvents();
        self.stepQueued(self.dequeue().?);
    }
    return true;
}

/// `step`'s round, with `hit` set already
noinline fn roundAfterStop(self: *Chip) bool {
    for (0..self.queue_len) |_| {
        if (self.next_event) |time| if (self.nodes[self.queue[0]].time >= time) self.fireEvents();
        self.stepQueued(self.dequeue().?);
    }
    return true;
}

/// Wakes the nodes waiting on what happens outside them by the time the
/// earliest node that is running gets there, and notes when the next thing
/// does (`next_event`)
noinline fn fireEvents(self: *Chip) void {
    self.next_event = null;
    if (self.uarts.len > 0) self.wakeOnPins();
    if (self.sync) |link| _ = self.wakeOnEdge(link.index, 1 << 17, link.clock_pin, link.device, Sync.nextClockEdge);
    if (self.serdes.len > 0) self.arrivals();
}

/// whether anything outside the nodes happens on its own time
inline fn hasEvents(self: *const Chip) bool {
    return self.uarts.len > 0 or self.sync != null or self.serdes.len > 0;
}

fn schedule(self: *Chip, time: u64) void {
    self.next_event = @min(self.next_event orelse time, time);
}

fn wakeOnPins(self: *Chip) void {
    for (self.uarts.slice()) |uart| self.wakeOnPin(uart);
}

/// Wakes the node with a UART if it waits on its wakeup pin, and the pin
/// is already as it waits for, such as when input arrives, or changes before
/// any node that is running gets there, so the node wakes at its time
fn wakeOnPin(self: *Chip, uart: UartLink) void {
    const rx_pin = uart.rx_pin orelse return;
    if (self.wakeOnEdge(uart.index, uart.device.rx_pin, rx_pin, uart.device, Uart.nextRxEdge)) uart.device.used = true;
}

/// Wakes node `index` if it waits on its wakeup pin, the pin with io bit
/// `bit` and index `pin` in `wiring.pins`, and the pin is already as it
/// waits for, or changes, as `nextEdge` of `device` says, before any node
/// that is running gets there. Returns whether it woke.
fn wakeOnEdge(self: *Chip, index: u16, bit: u18, pin: u16, device: anytype, comptime nextEdge: anytype) bool {
    const n = &self.nodes[index];
    if (self.queued[index] or !n.waitsOnPin()) return false;
    if (self.wiring.level(self.wiring.pins[pin].net, n.time)) n.pin_inputs |= bit else n.pin_inputs &= ~bit;
    if (!n.pinAwake()) {
        const edge = nextEdge(device, n.time) orelse return false;
        if (self.queue_len > 0 and self.nodes[self.queue[0]].time < edge) {
            self.schedule(edge);
            return false;
        }
        n.time = edge;
    }
    self.wake(index);
    return true;
}

/// Lands the words on SERDES links that arrive before any node that is
/// running gets there, waking the nodes that read them, at their arrival if
/// they were behind it. With every node waiting, the next word lands.
fn arrivals(self: *Chip) void {
    for (self.serdes.slice()) |*link| for (0..2) |k| {
        const from: u1 = @intCast(k);
        while (link.ends[from].nextArrival()) |time| {
            if (self.queue_len > 0 and self.nodes[self.queue[0]].time < time) {
                self.schedule(time);
                break;
            }
            link.land(from);
            self.deliver(&link.ends[1 - from]);
        }
    };
}

/// hands a SERDES node the word it received, if it is reading up
fn deliver(self: *Chip, end: *Serdes.End) void {
    const arrival = end.deliver() orelse return;
    if (self.nodes[end.index].time < arrival) self.later(end.index, arrival);
    self.wake(end.index);
}

/// A SERDES node's up port changed: a word it writes is taken if it is
/// sending, the node going on when the word starts to be sent, and a word it
/// received is delivered if it reads
noinline fn serdesPortChanged(self: *Chip, i: u16) void {
    for (self.serdes.slice()) |*link| for (&link.ends, 0..) |*end, k| if (end.index == i) {
        // words that arrived by the node's time, which only a node stepped
        // by hand, out of turn, gets to before they land
        while (end.nextArrival()) |time| {
            if (time > self.nodes[i].time) break;
            link.land(@intCast(k));
            self.deliver(&link.ends[1 - k]);
        }
        if (end.take(self.nodes[i].time)) |start| {
            if (self.nodes[i].time < start) self.later(i, start);
            self.wake(i);
            self.schedule(end.nextArrival().?);
        } else self.deliver(end);
    };
}

/// Wakes the nodes waiting on pin 17 whose nets node `i` changed in its
/// step, if the change is what they wait for, at the time of the change if
/// they were behind it
noinline fn wakeOnNets(self: *Chip, i: u16) void {
    const wiring = self.wiring;
    for (wiring.pinsOf(i)) |*p| {
        const net = &wiring.nets[p.net];
        if (net.changed == null) continue;
        net.changed = null;
        var it = wiring.members(p.net);
        while (it.next()) |q| if (q.node != i and q.bit == 1 << 17) self.wakeOnNet(q.node);
    }
}

/// Wakes node `j` if it waits on pin 17, on a shared net, and the net is
/// as it waits for at its time, or at the first change the other pins on
/// the net have made since that is: each change is looked at, so a pulse
/// shorter than a step is not missed
fn wakeOnNet(self: *Chip, j: u16) void {
    const n = &self.nodes[j];
    if (self.queued[j] or n.shared_pins & 1 << 17 == 0 or !n.waitsOnPin()) return;
    const wiring = self.wiring;
    const own = wiring.pin(j, 1 << 17).?;
    var time = n.time;
    while (true) {
        if (wiring.level(own.net, time)) n.pin_inputs |= own.bit else n.pin_inputs &= ~own.bit;
        if (n.pinAwake()) break;
        var next: ?u64 = null;
        var it = wiring.members(own.net);
        while (it.next()) |q| if (q != own) if (q.history.nextChange(time)) |t| {
            next = @min(next orelse t, t);
        };
        time = next orelse return;
    }
    n.time = time;
    self.wake(j);
}

/// takes the node earliest in time from the queue
fn dequeue(self: *Chip) ?u16 {
    if (self.queue_len == 0) return null;
    const i = self.queue[0];
    self.queue_len -= 1;
    self.queued[i] = false;
    if (self.queue_len > 0) {
        self.queue[0] = self.queue[self.queue_len];
        self.siftDown(0);
    }
    return i;
}

/// Steps a node and wakes the neighbours on any port it changed, since a
/// suspended node can only continue once one of its ports changes.
pub fn stepNode(self: *Chip, i: u16) void {
    if (self.hasEvents()) self.fireEvents();
    const queued = self.queued[i];
    self.stepQueued(i);
    // stepped while queued, as by hand, so later in time than its place
    if (queued) self.later(i, self.nodes[i].time);
}

/// `stepNode` for a node that is not in the queue
fn stepQueued(self: *Chip, i: u16) void {
    const n = &self.nodes[i];
    var before: [4]Port.State = undefined;
    for (n.ports, &before) |link, *state| state.* = if (link.port) |p| p.state else .idle;

    const fetching = n.state == .fetch;
    const retrying = n.suspended;
    // the devices on the pins' nets, told the nets' levels as the node
    // writes io during the step (`pin_device`), and at its end, as time has
    // passed for them
    const wired = n.pin_device != null;
    n.step();
    self.steps += 1;
    self.started = true;
    if (wired) {
        self.wiring.tell(i);
        self.wakeOnNets(i);
        // a change that a node ahead of it made after the time it waits from
        if (n.waitsOnPin()) self.wakeOnNet(i);
        // a read of the wakeup pin, not a device on its port, that did not
        // have to wait for it
        if (n.wake_port) |w| if (n.transfers.read.contains(w) and n.ports[@backingInt(w)].port == null) self.pinRead(i);
        // a word a SERDES node started to send, setting io bit 17
        if (self.serdes.len > 0) self.serdesSent(i);
        // a chip's RESET- it changed. A node that resets its own chip is
        // traced as reset.
        if (self.resets.len > 0) self.resetLines();
    }
    if (!n.suspended) self.wake(i);
    // unless the node is still waiting for a word to execute, or still
    // waiting on the same port
    const waited = n.suspended and !n.transfers.any() and (retrying or (fetching and n.state == .fetch));
    if (self.trace) |writer| if (!waited and (self.trace_only == null or self.trace_only == i)) {
        self.writeTrace(writer, i) catch {
            self.trace = null;
        };
    };
    if (self.hit == null and self.breakpoints.len + self.watches.len > 0) self.hit = self.stopAt(i);

    for (n.ports, before, 0..) |link, state, d| {
        const p = link.port orelse continue;
        if (std.meta.eql(state, p.state)) continue;
        self.portChanged(i, @fromBackingInt(@intCast(d)), state);
    }
}

/// Acts on the changes of chips' RESET- pins: a chip is held in reset from
/// a fall, and starts again as after reset from a rise. A node of the chip
/// that ran past the time keeps what it did, such as a byte it sent.
noinline fn resetLines(self: *Chip) void {
    // resetting moves the chip's pins, which can change any line again
    var acted = true;
    while (acted) {
        acted = false;
        for (self.resets.slice()) |*line| {
            const edges = line.edges;
            const len = line.edges_len;
            line.edges_len = 0;
            for (edges[0..len]) |edge| {
                acted = true;
                if (edge.high) self.releaseChip(line.chip, edge.time) else self.holdChip(line.chip, edge.time);
            }
        }
    }
}

fn holdChip(self: *Chip, chip: u8, time: u64) void {
    const bit = @as(u8, 1) << @intCast(chip);
    if (self.held & bit != 0) return;
    self.held |= bit;
    self.resetChip(chip, time, true);
}

fn releaseChip(self: *Chip, chip: u8, time: u64) void {
    const bit = @as(u8, 1) << @intCast(chip);
    if (self.held & bit == 0) return;
    self.held &= ~bit;
    self.resetChip(chip, time, false);
}

/// whether chip `chip` is held in reset
pub fn isHeld(self: *const Chip, chip: u8) bool {
    return self.held & @as(u8, 1) << @intCast(chip) != 0;
}

/// Puts a chip's nodes as after reset at `time`, keeping their memory, and
/// the ports between them and off the chip idle: starting where they start
/// after reset, or, if `hold`, waiting until released
fn resetChip(self: *Chip, chip: u8, time: u64, hold: bool) void {
    const per = self.layout.chipCount();
    const first = chip * per;
    const ports = self.layout.portCount() / self.layout.chips;
    @memset(self.ports[chip * ports ..][0..ports], .{});
    // words already sent go on their way
    for (self.serdes.slice()) |*link| for (&link.ends) |*end| if (end.index >= first and end.index < first + per) {
        end.port = .{};
        end.sending = false;
        end.latch = null;
        end.free = @max(end.free, time);
    };
    for (first..first + per) |index| {
        const i: u16 = @intCast(index);
        const n = &self.nodes[i];
        // a device's port off the chip
        for (n.ports, 0..) |link, d| if (link.port) |p| if (self.layout.neighbour(i, @fromBackingInt(@intCast(d))) == null) {
            p.* = .{};
        };
        const before = n.*;
        n.* = .reset;
        n.mem = before.mem;
        n.ports = before.ports;
        n.pins = before.pins;
        n.wake_port = before.wake_port;
        n.pin_device = before.pin_device;
        n.bus = before.bus;
        n.bus_device = before.bus_device;
        n.shared_pins = before.shared_pins;
        if (before.data != null) n.data = 0;
        n.p.address = if (hold) held_address else self.reset_address[i];
        n.suspended = hold;
        n.time = time;
        // what its pins did after the time is undone
        for (self.wiring.pinsOf(i)) |*p| p.history.truncate(time);
        // its pins as after reset, and a SERDES node not sending
        if (n.pin_device) |device| device.written(device.context, n);
    }
    // the queue in order of the nodes' new times. A node held in reset that
    // is queued waits at once when stepped.
    var k = self.queue_len / 2;
    while (k > 0) {
        k -= 1;
        self.siftDown(k);
    }
    if (!hold) for (first..first + per) |i| {
        self.wake(@intCast(i));
        // a breakpoint on where it starts, as `step` checks at the start
        if (self.hit == null) self.hit = self.breakpointAt(@intCast(i));
    };
    for (first..first + per) |i| if (self.nodes[i].shared_pins != 0) self.wakeOnNets(@intCast(i));
}

/// notes that node `i` read the rx pin of a UART, which uses it
noinline fn pinRead(self: *Chip, i: u16) void {
    for (self.uarts.slice()) |u| if (u.index == i and u.rx_pin != null) {
        u.device.used = true;
    };
}

/// notes when the word a SERDES node is sending arrives
noinline fn serdesSent(self: *Chip, i: u16) void {
    for (self.serdes.slice()) |*link| for (&link.ends) |*end| if (end.index == i) {
        if (end.nextArrival()) |time| self.schedule(time);
    };
}

/// Wakes the neighbour on a port of node `i` that changed from `state`, but
/// not if it is still waiting after the change, such as when it reads the
/// port too: a later change that lets it go on wakes it then. Stepped at
/// once, as it is behind, it would only wait again. Out of line, as most
/// steps change no port.
noinline fn portChanged(self: *Chip, i: u16, direction: Direction, state: Port.State) void {
    const j = self.layout.neighbour(i, direction) orelse {
        if (direction == .up and self.serdes.len > 0) self.serdesPortChanged(i);
        return;
    };
    const n = &self.nodes[i];
    const other = &self.nodes[j];
    // a word passes between neighbours when the second of them gets to the
    // port, at the later of their times, and not when the first wakes to
    // finish, as the second may have run on by then
    const transfers = n.transfers.read.unionWith(n.transfers.written);
    if (transfers.contains(direction) and (state == .reading or state == .writing)) {
        const time = @max(n.time, other.time);
        // either may be queued already, at its time before
        if (n.time < time) self.later(i, time);
        if (other.time < time) self.later(j, time);
    }
    if (other.suspended and other.retryWaits()) return;
    self.wake(j);
}

/// Writes the node, the word it executed, where from, and its stacks after,
/// such as `000 003 2c9b2 @+ for @+ !b  T 0000d S 00000 R 00000`
fn writeTrace(self: *const Chip, writer: *Io.Writer, i: u16) Io.Writer.Error!void {
    const n = &self.nodes[i];
    const address: u9 = @bitCast(n.word_address);
    if (self.trace_json) {
        try writer.print("{{\"node\":\"{f}\",\"address\":\"{x:0>3}\",\"word\":\"{x:0>5}\",\"code\":\"", .{ nodeName(self.layout.nodeNumber(i)), address, @as(u18, @bitCast(n.i)) });
        try disassembler.write(writer, n.i, address);
        return writer.print("\",\"t\":\"{x:0>5}\",\"s\":\"{x:0>5}\",\"r\":\"{x:0>5}\",\"waiting\":{}}}\n", .{
            @as(u18, @bitCast(n.data_stack.t)),
            @as(u18, @bitCast(n.data_stack.s)),
            @as(u18, @bitCast(n.return_stack.t)),
            n.suspended,
        });
    }
    try writer.print("{f} {x:0>3} {x:0>5} ", .{ nodeName(self.layout.nodeNumber(i)), address, @as(u18, @bitCast(n.i)) });
    try disassembler.write(writer, n.i, address);
    try writer.print("  T {x:0>5} S {x:0>5} R {x:0>5}{s}\n", .{
        @as(u18, @bitCast(n.data_stack.t)),
        @as(u18, @bitCast(n.data_stack.s)),
        @as(u18, @bitCast(n.return_stack.t)),
        if (n.suspended) "  waiting" else "",
    });
}

/// a breakpoint the node has reached, or a watched transfer it made, in the
/// step it just took
fn stopAt(self: *const Chip, i: u16) ?Stop {
    const n = &self.nodes[i];
    if (!n.suspended and n.state == .fetch) if (self.breakpointAt(i)) |stop| return stop;
    for (self.watches.items()) |w| if (w.index == i) {
        const t = n.transfers;
        if (if (w.write) t.written.contains(w.direction) else t.read.contains(w.direction))
            return .{ .watch = .{ .watch = w, .value = if (w.write) t.value_written else t.value_read } };
    };
    return null;
}

/// a breakpoint on the word a node is about to fetch
fn breakpointAt(self: *const Chip, i: u16) ?Stop {
    if (self.breakpoints.len == 0) return null;
    const here: Breakpoint = .init(i, @bitCast(self.nodes[i].p.address));
    return if (self.breakpoints.contains(here)) .{ .breakpoint = here } else null;
}

/// queues a node to be stepped
pub fn wake(self: *Chip, i: u16) void {
    if (self.queued[i]) return;
    self.queued[i] = true;
    self.queue[self.queue_len] = i;
    self.queue_len += 1;
    self.siftUp(self.queue_len - 1);
}

/// Moves a node's time on, keeping the queue in order
noinline fn later(self: *Chip, i: u16, time: u64) void {
    self.nodes[i].time = time;
    if (!self.queued[i]) return;
    const k = std.mem.indexOfScalar(u16, self.queue[0..self.queue_len], i).?;
    self.siftDown(k);
}

/// whether node `a` steps before node `b`: the earlier in time, or the
/// lower index at the same time, so that the order is the same each run
fn stepsFirst(self: *const Chip, a: u16, b: u16) bool {
    const ta = self.nodes[a].time;
    const tb = self.nodes[b].time;
    return ta < tb or (ta == tb and a < b);
}

fn siftUp(self: *Chip, start: usize) void {
    var k = start;
    while (k > 0) {
        const parent = (k - 1) / 2;
        if (!self.stepsFirst(self.queue[k], self.queue[parent])) break;
        std.mem.swap(u16, &self.queue[k], &self.queue[parent]);
        k = parent;
    }
}

fn siftDown(self: *Chip, start: usize) void {
    var k = start;
    while (true) {
        var first = k;
        for ([_]usize{ 2 * k + 1, 2 * k + 2 }) |child| {
            if (child < self.queue_len and self.stepsFirst(self.queue[child], self.queue[first])) first = child;
        }
        if (first == k) break;
        std.mem.swap(u16, &self.queue[k], &self.queue[first]);
        k = first;
    }
}

/// rounds without console output after which pending output is flushed
const flush_after_rounds = 1000;

/// Gives the devices anything they have for their nodes, without waiting
/// for input, then takes a round of steps (see `step`). Returns false when
/// nothing happened: every node is waiting, and the devices have nothing
/// for them.
pub fn advance(self: *Chip) !bool {
    const serviced = try self.service();
    const stepped = self.step();
    return stepped or serviced;
}

/// Gives the devices anything they have for their nodes, without waiting
/// for input, then steps the next runnable node, returning its index. Returns
/// null when every node is waiting.
pub fn stepNext(self: *Chip) !?u16 {
    _ = try self.service();
    if (self.hasEvents()) self.fireEvents();
    const i = self.dequeue() orelse return null;
    self.stepNode(i);
    return i;
}

/// Gives the devices anything they have for their nodes, without waiting
/// for input. Returns false when they had nothing.
pub inline fn service(self: *Chip) !bool {
    var serviced = false;
    if (self.console) |console| if (try console.device.service(false)) {
        self.wake(console.index);
        serviced = true;
    };
    for (self.uarts.slice()) |uart| if (try uart.device.service(self.nodes[uart.index].time)) {
        serviced = true;
    };
    if (self.feed()) serviced = true;
    return serviced;
}

/// Runs until every node is suspended on something the console or UART
/// cannot complete, a node reaches a breakpoint or makes a watched transfer,
/// or the console or UART is interrupted. Breakpoints and watches stop the
/// run at once, with the round unfinished, leaving `hit` set. Reaching
/// `step_limit` or `time_limit` stops it too, setting `limited`.
pub fn run(self: *Chip) !void {
    self.hit = null;
    self.limited = false;
    if (self.console == null and self.uarts.len == 0) {
        while (self.hit == null and !self.pastLimit() and (self.feed() or self.step())) {}
        return;
    }
    var quiet_rounds: u16 = 0;
    while (self.hit == null and !self.pastLimit() and !self.interrupted()) {
        const pending = self.pendingOutput();
        _ = try self.service();
        // flush once output stops for a while, so a busy node does not hold
        // it up while a steady stream of output is still written in blocks
        if (pending == 0 or self.pendingOutput() != pending) {
            quiet_rounds = 0;
        } else if (quiet_rounds == flush_after_rounds) {
            try self.flushOutput();
        } else quiet_rounds += 1;
        if (self.step()) continue;
        // with nothing else to do, wait for input
        if (!try self.waitForInput()) break;
    }
    try self.flushOutput();
}

/// Waits for input for a node waiting on the console, or on a UART's pin.
/// Returns false if no node can take any more. With a doorbell, as for a
/// board whose serial ports a program may connect to and send on at any
/// time, waits for it to ring, for input to any UART, which the next round
/// takes, even with no node waiting for it, until it is closed.
fn waitForInput(self: *Chip) !bool {
    if (self.console) |console| if (try console.device.service(true)) {
        self.wake(console.index);
        return true;
    };
    // without one, only one UART's input can be waited for: that of one
    // whose node waits on its pin, for input that can reach it on an rx line
    const bell = self.doorbell orelse {
        for (self.uarts.slice()) |uart| if (uart.rx_pin != null and self.nodes[uart.index].waitsOnPin())
            return uart.device.waitForInput(self.nodes[uart.index].time);
        return false;
    };
    try self.flushOutput();
    const first = self.uarts.items[0].device;
    first.waiting.store(true, .release);
    defer first.waiting.store(false, .release);
    var ring: [64]u8 = undefined;
    _ = bell.queue.get(bell.io, &ring, 1) catch |err| switch (err) {
        error.Closed => return false,
        else => |e| return e,
    };
    return true;
}

/// whether a limit is reached, noting that it was
inline fn pastLimit(self: *Chip) bool {
    if (self.steps < self.step_limit and (self.queue_len == 0 or self.nodes[self.queue[0]].time < self.time_limit)) return false;
    self.limited = true;
    return true;
}

pub fn interrupted(self: *const Chip) bool {
    if (self.console) |console| if (console.device.interrupted.load(.monotonic)) return true;
    for (self.uarts.slice()) |uart| if (uart.device.interrupted.load(.monotonic)) return true;
    return false;
}

/// output written but not yet flushed, by the console and UARTs
fn pendingOutput(self: *const Chip) usize {
    var pending: usize = 0;
    if (self.console) |console| pending += console.device.output.end;
    for (self.uarts.slice()) |uart| pending += uart.device.output.end;
    return pending;
}

pub fn flushOutput(self: *Chip) !void {
    if (self.console) |console| try console.device.output.flush();
    for (self.uarts.slice()) |uart| try uart.device.output.flush();
}

/// Assembles `source` onto a GA144 sized chip with a console on the up port
/// of node 000, and checks what it outputs given `input`
pub fn expectOutput(source: []const u8, input: []const u8, expected: []const u8) !void {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);

    var programs: [8]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes(source, &programs, &diagnostic)) |program| try chip.load(program);
    try expectRun(&chip, input, expected);
}

/// As `expectOutput`, for arrayForth 3 source, with each bin loaded into its
/// own node unless boot descriptors say otherwise
pub fn expectArrayForthOutput(source: []const u8, input: []const u8, expected: []const u8) !void {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);

    var programs: [8]assembler.Program = undefined;
    var descriptors: [8]boot.Descriptor = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try arrayforth.assembleNodes(source, &programs, &descriptors, &diagnostic);
    if (assembled.descriptors.len > 0) {
        for (assembled.descriptors) |descriptor| try chip.setUp(descriptor, assembled.programs);
    } else for (assembled.programs) |program| if (program.bin == null) try chip.setUp(.ofProgram(program), assembled.programs);
    try expectRun(&chip, input, expected);
}

/// Compiles colorForth blocks from block 0, runs them with the console on
/// node 000's up port, with `input`, and checks its output
pub fn expectColorForthOutput(blocks: []const u8, input: []const u8, expected: []const u8) !void {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);

    var programs: [8]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try arrayforth.assembleColorForth(blocks, &.{0}, &programs, &.{}, &diagnostic);
    for (assembled.programs) |program| if (program.bin == null) try chip.setUp(.ofProgram(program), assembled.programs);
    try expectRun(&chip, input, expected);
}

/// runs a chip with the console on node 000's up port, with `input`, and
/// checks its output
fn expectRun(chip: *Chip, input: []const u8, expected: []const u8) !void {
    var input_buffer: [256]u8 = undefined;
    var input_queue = try Console.testInput(&input_buffer, input);
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .input = .{ .io = std.testing.io, .queue = &input_queue }, .output = &writer };
    try chip.attachConsole(&console, 0, .up);

    try chip.run();
    try expectEqualStrings(expected, writer.buffered());
}

test Layout {
    try expectEqual(Layout{ .rows = 12, .columns = 20 }, try Layout.parse("12x20"));
    try expectError(error.InvalidLayout, Layout.parse("12"));
    try expectError(error.InvalidLayout, Layout.parse("0x4"));
    try expectError(error.InvalidLayout, Layout.parse("101x4"));
    try expectError(error.InvalidLayout, Layout.parse("4x"));

    const layout: Layout = .ga144;
    try expectEqual(144, layout.count());
    try expectEqual(17, layout.index(17));
    try expectEqual(18, layout.index(100));
    try expectEqual(143, layout.index(717));
    try expectEqual(null, layout.index(18));
    try expectEqual(null, layout.index(800));
    try expectEqual(717, layout.nodeNumber(143));
}

test "a node drives its parallel bus from its data register, or reads it as inputs, as DB in io says" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    const Probe = struct {
        driven: [4]?u18 = @splat(null),
        count: usize = 0,

        fn read(_: *anyopaque, _: *const Computer) ?u18 {
            return 0x2a;
        }

        fn written(context: *anyopaque, computer: *const Computer) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.count < self.driven.len) self.driven[self.count] = if (computer.drivesBus()) @bitCast(computer.data.?) else null;
            self.count += 1;
        }
    };
    var probe: Probe = .{};
    try chip.attachBus(9, .{ .context = &probe, .read = Probe.read, .written = Probe.written });
    try std.testing.expectError(error.TwoDevices, chip.attachBus(9, .{ .context = &probe, .read = Probe.read, .written = Probe.written }));
    try std.testing.expectError(error.NoBus, chip.attachBus(8, .{ .context = &probe, .read = Probe.read, .written = Probe.written }));

    // 009 drives 5, as from reset, and reads it back from the register,
    // then clears DB and reads what the device drives; 007, with no device,
    // reads its register driven, and as inputs the charge the bus keeps
    var programs: [2]assembler.Program = undefined;
    var descriptors: [0]boot.Descriptor = .{};
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = try arrayforth.assembleNodes(
        \\ ASM[ # 9 NODE ERS # 0 org : main  5. data a! !  @  x14555. io b! !b  @  begin end  >BIN
        \\      # 7 NODE ERS # 0 org : main  6. data a! !  @  x14555. io b! !b  @  begin end  >BIN ]ASM
    , &programs, &descriptors, &diagnostic);
    for (assembled.programs) |program| try chip.load(program);
    for (0..200) |_| _ = chip.step();
    const n9 = chip.node(9).?;

    try std.testing.expectEqual(0x2a, n9.data_stack.t);
    try std.testing.expectEqual(5, n9.data_stack.s);
    // the device told of the bus as it is when attached, driven with 0
    try std.testing.expectEqualSlices(?u18, &.{ 0, 5, null }, probe.driven[0..3]);
    const n7 = chip.node(7).?;
    try std.testing.expectEqual(6, n7.data_stack.t);
    try std.testing.expectEqual(6, n7.data_stack.s);
}

test "chips after the first" {
    const layout: Layout = .{ .rows = 8, .columns = 18, .chips = 2 };
    try expectEqual(288, layout.count());
    try expectEqual(2 * Layout.ga144.portCount(), layout.portCount());
    try expectEqual(144 + 134, layout.index(10708));
    try expectEqual(null, layout.index(20000));
    try expectEqual(null, layout.index(10018));
    try expectEqual(10708, layout.nodeNumber(144 + 134));
    try expectEqual(8, layout.column(144 + 134));
    try expectEqual(7, layout.row(144 + 134));
    // neighbours are on the same chip
    try expectEqual(null, layout.neighbour(144 + 17, .left));
    try expectEqual(null, layout.neighbour(144, .up));
    try expectEqual(144 + 18, layout.neighbour(144, .down));

    try expectEqual(10708, try parseNode("1.708"));
    try expectEqual(708, try parseNode("708"));
    try expectEqual(708, try parseNode("0.708"));
    try expectError(error.InvalidNode, parseNode("1.10000"));
    try expectError(error.InvalidNode, parseNode("1."));
    try expectError(error.InvalidNode, parseNode("7.000"));
    var buffer: [8]u8 = undefined;
    try expectEqualStrings("1.008", try std.fmt.bufPrint(&buffer, "{f}", .{nodeName(10008)}));
    try expectEqualStrings("008", try std.fmt.bufPrint(&buffer, "{f}", .{nodeName(8)}));

    var chip: Chip = try .initChips(std.testing.allocator, .ga144, 2);
    defer chip.deinit(std.testing.allocator);
    // each chip's nodes are as the spec says
    try expectEqual(1 << 17 | 1 << 1, chip.node(10708).?.pins);
    try expect(chip.node(10001).?.data != null);
    try expectEqual(Direction.up, chip.node(10708).?.wake_port);
    try expectEqual(null, chip.node(10017).?.ports[@backingInt(Direction.left)].port);
}

/// two chips of a SERDES node each, 000 and 1.000, linked, with `source`
/// loaded
fn serdesPair(source: []const u8) !Chip {
    const spec: Spec = .{ .rows = 1, .columns = 1, .nodes = &.{.{ .node = 0, .rom = .serdes_boot }} };
    var chip: Chip = try .initChips(std.testing.allocator, spec, 2);
    errdefer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [2]assembler.Program = undefined;
    for (try assembler.assembleNodes(source, &programs, &diagnostic)) |program| try chip.load(program);
    try chip.attachSerdes(0, 10000);
    return chip;
}

test "words sent on a SERDES link arrive a word's time apart" {
    // 000 writes 5 to data and sets io bit 17, then writes 7 to up, while
    // 1.000 reads up twice
    var chip = try serdesPair(
        \\ 0x141 a! 5 ! io b! 0x20000 !b up b! 7 !b left b! @b
        \\ node 1.000 up b! @b @b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    const n = chip.node(10000).?;
    try expectEqual(7, n.data_stack.t);
    try expectEqual(5, n.data_stack.s);
    // 000 went on as its second word started to be sent, which 1.000 took
    // a word's time later, and both then ran the same words
    try expectEqual(chip.node(0).?.time + Serdes.word_time, n.time);
}

test "a word sent on a SERDES link that is not read before the next is lost" {
    var chip = try serdesPair(
        \\ 0x141 a! 1 ! io b! 0x20000 !b up b! 2 !b 3 !b left b! @b
        \\ node 1.000 999 for unext up b! @b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    try expectEqual(3, chip.node(10000).?.data_stack.t);
}

test "a SERDES node waiting on up and another port takes what comes first" {
    // 1.000's multiport read takes the SERDES word, as its ROM's cold does
    var chip = try serdesPair(
        \\ 99 for unext 0x141 a! 9 ! io b! 0x20000 !b left b! @b
        \\ node 1.000 0x125 b! @b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    const n = chip.node(10000).?;
    try expectEqual(9, n.data_stack.t);
    // at the word's arrival, not before
    try expect(n.time >= 99 * 2400 + Serdes.word_time);
}

test "a SERDES node that is not sending does not send" {
    var chip = try serdesPair(
        \\ up b! 4 !b
        \\ node 1.000 up b! @b
    );
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    try expect(chip.node(0).?.suspended and chip.node(10000).?.suspended);
    try expectEqual(0, chip.node(10000).?.data_stack.t);
}

test "the target's SERDES boot ROM runs code the host sends it" {
    var roms: [144]ga144.NodeRom = undefined;
    var chip: Chip = try .initChips(std.testing.allocator, .ga144, 2);
    defer chip.deinit(std.testing.allocator);
    try chip.loadRom(try testRom(&roms));
    try chip.attachSerdes(701, 10001);
    // 701 sends 1.001 an instruction to push a literal, then the literal
    const push: u18 = @bitCast(comptime Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }));
    var diagnostic: assembler.Diagnostic = .{};
    try chip.load(try assembler.assemble(std.fmt.comptimePrint("node 701 0x141 a! {d} ! io b! 0x20000 !b up b! 42 !b left b! @b", .{push}), &diagnostic));

    try chip.run();
    try expectEqual(42, chip.node(10001).?.data_stack.t);
}

test "a SERDES node stepped by hand, out of turn, sends every word" {
    var chip = try serdesPair(
        \\ 0x141 a! 1 ! io b! 0x20000 !b up b! 2 !b 3 !b 4 !b left b! @b
        \\ node 1.000 up b! @b @b @b @b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    for (0..40) |_| chip.stepNode(0);
    try chip.run();
    const n = chip.node(10000).?;
    try expectEqual(4, n.data_stack.t);
    try expectEqual(3, n.data_stack.s);
}

/// two chips of two nodes, 000 and 001, with 000.17 on chip 1's RESET-,
/// pulled up if `pulled`, and `source` loaded
fn resetPair(source: []const u8, pulled: bool) !Chip {
    const spec: Spec = .{ .rows = 1, .columns = 2, .nodes = &.{.{ .node = 0, .pins = &.{17} }} };
    var chip: Chip = try .initChips(std.testing.allocator, spec, 2);
    errdefer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [2]assembler.Program = undefined;
    for (try assembler.assembleNodes(source, &programs, &diagnostic)) |program| try chip.load(program);
    try chip.attachReset(1, .{ .node = 0, .pin = 17 }, pulled);
    return chip;
}

test "a chip reset by its RESET- starts again as after reset when it is released" {
    // 000 drives its pin low at about 2.4 us and high at about 4.8 us,
    // while 1.000 pushes 7 and waits on right
    var chip = try resetPair(
        \\ io b! 999 for unext 0x20000 !b 999 for unext 0x30000 !b right b! @b
        \\ node 1.000 7 right b! @b
    , true);
    defer chip.deinit(std.testing.allocator);
    const code = chip.node(10000).?.mem[0];
    try chip.run();
    try expect(!chip.isHeld(1));
    const n = chip.node(10000).?;
    // as after reset, waiting for code from its neighbour, at the release
    try expectEqual(0, n.data_stack.t);
    try expect(waitsForCode(n));
    try expect(n.time >= 4_800_000 and n.time < 4_900_000);
    // with its RAM as it was
    try expectEqual(code, n.mem[0]);
}

test "a chip whose RESET- stays low is held in reset" {
    var chip = try resetPair(
        \\ io b! 999 for unext 0x20000 !b right b! @b
        \\ node 1.000 7 right b! @b
    , true);
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    try expect(chip.isHeld(1));
    const n = chip.node(10000).?;
    try expect(n.suspended and n.p.address == held_address);
    try expectEqual(0, n.data_stack.t);
    try expect(n.time >= 2_400_000 and n.time < 2_500_000);
}

test "a breakpoint where a released chip's node starts stops it" {
    var chip = try resetPair(
        \\ io b! 999 for unext 0x20000 !b 999 for unext 0x30000 !b right b! @b
        \\ node 1.000 7 right b! @b
    , true);
    defer chip.deinit(std.testing.allocator);
    const i = chip.layout.index(10000).?;
    _ = try chip.breakpoints.toggle(.init(i, @bitCast(chip.reset_address[i])));
    try chip.run();
    try expectEqual(Stop{ .breakpoint = .init(i, @bitCast(chip.reset_address[i])) }, chip.hit.?);
}

test "a chip held in reset takes a program's RAM, and stays held" {
    var chip = try resetPair("", false);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    const program = try assembler.assemble("node 1.000 7 right b! @b", &diagnostic);
    try chip.setUp(.ofProgram(program), &.{program});
    try chip.load(program);
    try chip.run();
    const n = chip.node(10000).?;
    try expect(chip.isHeld(1) and n.p.address == held_address);
    try expectEqual(0, n.data_stack.t);
    try expectEqual(program.ram[0], n.mem[0]);
}

test "a chip whose RESET- only a pin's pulldown drives is held from the start" {
    var chip = try resetPair("node 1.000 7 right b! @b", false);
    defer chip.deinit(std.testing.allocator);
    try expect(chip.isHeld(1));
    try chip.run();
    try expectEqual(0, chip.node(10000).?.data_stack.t);
    // until the pin drives it high
    var released = try resetPair(
        \\ io b! 0x30000 !b right b! @b
        \\ node 1.000 7 right b! @b
    , false);
    defer released.deinit(std.testing.allocator);
    try released.run();
    try expect(!released.isHeld(1));
}

test attachSyncPins {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var sync: Sync = .init(&.{});
    try expectError(error.NotWakeupPin, chip.attachSyncPins(&sync, .{ .node = 300, .pin = 1 }, .{ .node = 300, .pin = 17 }));
    try expectError(error.NoSuchPin, chip.attachSyncPins(&sync, .{ .node = 300, .pin = 17 }, .{ .node = 300, .pin = 3 }));
    try chip.attachSyncPins(&sync, .{ .node = 300, .pin = 17 }, .{ .node = 300, .pin = 1 });
    try expectEqual(chip.layout.index(300).?, chip.sync.?.index);
    try expectError(error.TwoDevices, chip.attachSyncPins(&sync, .{ .node = 708, .pin = 17 }, .{ .node = 708, .pin = 1 }));
}

test attachSerdes {
    var chip: Chip = try .initChips(std.testing.allocator, .ga144, 2);
    defer chip.deinit(std.testing.allocator);
    try expectError(error.NotSerdes, chip.attachSerdes(701, 10708));
    try expectError(error.NoSuchNode, chip.attachSerdes(701, 20001));
    try expectError(error.NotSerdes, chip.attachSerdes(701, 701));
    // a parallel bus node, with a data register, no pins and no node up
    try expectError(error.NotSerdes, chip.attachSerdes(7, 9));
    try chip.attachSerdes(701, 10001);
    try expectError(error.PortConnected, chip.attachSerdes(1, 10001));
}

test "going back to a snapshot takes back words on a SERDES link" {
    var chip = try serdesPair(
        \\ 0x141 a! 5 ! io b! 0x20000 !b left b! @b
        \\ node 1.000 999 for unext up b! @b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    var snapshot: Snapshot = try .init(std.testing.allocator, chip.layout);
    defer snapshot.deinit(std.testing.allocator);
    chip.save(&snapshot);
    try chip.run();
    try expectEqual(5, chip.node(10000).?.data_stack.t);
    chip.restore(&snapshot);
    try expect(chip.matches(&snapshot));
    try chip.run();
    try expectEqual(5, chip.node(10000).?.data_stack.t);
}

test "neighbours share port names" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);

    // 000 and 001 share right, 001 and 002 share left
    try expectEqual(chip.node(0).?.ports[@backingInt(Direction.right)].port, chip.node(1).?.ports[@backingInt(Direction.right)].port);
    try expectEqual(chip.node(1).?.ports[@backingInt(Direction.left)].port, chip.node(2).?.ports[@backingInt(Direction.left)].port);
    // 000 and 100 share down, 100 and 200 share up
    try expectEqual(chip.node(0).?.ports[@backingInt(Direction.down)].port, chip.node(100).?.ports[@backingInt(Direction.down)].port);
    try expectEqual(chip.node(100).?.ports[@backingInt(Direction.up)].port, chip.node(200).?.ports[@backingInt(Direction.up)].port);

    // edge ports are unconnected
    try expectEqual(null, chip.node(0).?.ports[@backingInt(Direction.left)].port);
    try expectEqual(null, chip.node(0).?.ports[@backingInt(Direction.up)].port);
    try expectEqual(null, chip.node(717).?.ports[@backingInt(Direction.up)].port);
    try expectEqual(null, chip.node(717).?.ports[@backingInt(Direction.left)].port);

    for (0..144) |i| {
        const n = &chip.nodes[i];
        var connected: u3 = 0;
        for (n.ports) |link| connected += @intFromBool(link.port != null);
        const x = i % 18;
        const y = i / 18;
        const edges = @as(u3, @intFromBool(x == 0 or x == 17)) + @intFromBool(y == 0 or y == 7);
        try expectEqual(4 - edges, connected);
    }
}

test "portToward and facing are inverses" {
    for (0..4) |x| {
        for (0..4) |y| {
            for ([_]Cardinal{ .north, .east, .south, .west }) |cardinal| {
                try expectEqual(cardinal, facing(@intCast(x), @intCast(y), portToward(@intCast(x), @intCast(y), cardinal)));
            }
        }
    }
    // node 708 faces off the chip to the north through up
    try expectEqual(Direction.up, portToward(8, 7, .north));
}

test "nodes without a program wait for code" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 2, .columns = 2 });
    defer chip.deinit(std.testing.allocator);

    try expect(chip.step());
    // every node suspends reading its ports
    try expect(!chip.step());
    for (chip.nodes) |n| try expect(n.suspended);
}

test "a node can send code to a neighbour" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 2 });
    defer chip.deinit(std.testing.allocator);

    // node 000 sends node 001 an instruction to push a literal, then the
    // literal, and waits on its unconnected left port
    const push: u18 = @bitCast(comptime Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }));
    var diagnostic: assembler.Diagnostic = .{};
    try chip.load(try assembler.assemble(std.fmt.comptimePrint("right b! {d} !b 5 !b left b! @b", .{push}), &diagnostic));

    try chip.run();
    try expectEqual(5, chip.node(1).?.data_stack.t);
    // node 001 goes back to waiting on its ports
    try expect(chip.node(1).?.suspended);
}

test "a word arrives at the time it was written" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 3 });
    defer chip.deinit(std.testing.allocator);

    // node 001 writes to node 000, which waits for it, and then reads at
    // once from node 002, which is far ahead by then
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [3]assembler.Program = undefined;
    for (try assembler.assembleNodes(
        \\ right b! @b @b
        \\ node 001 100 for unext right b! 5 !b left b! @b @b
        \\ node 002 10000 for unext left b! 7 !b @b
    , &programs, &diagnostic)) |program| try chip.load(program);

    try chip.run();
    try expectEqual(5, chip.node(0).?.data_stack.t);
    try expectEqual(7, chip.node(1).?.data_stack.t);
    // 000 takes the word at 001's time, not at 002's
    try expect(chip.node(0).?.time < chip.node(2).?.time / 10);
}

/// that the queue is a heap of the nodes queued
fn expectHeap(chip: *const Chip) !void {
    var count: usize = 0;
    for (chip.queued) |q| count += @intFromBool(q);
    try expectEqual(count, chip.queue_len);
    for (chip.queue[0..chip.queue_len], 0..) |i, k| {
        try expect(chip.queued[i]);
        if (k > 0) try expect(!chip.stepsFirst(i, chip.queue[(k - 1) / 2]));
    }
}

test "a breakpoint stops a node that is the earliest again and again" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 5 });
    defer chip.deinit(std.testing.allocator);
    // node 000 runs short words, so it is the earliest in time again and
    // again in a round, while the others run long ones
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [5]assembler.Program = undefined;
    for (try assembler.assembleNodes(
        \\ : main dup dup dup dup dup dup dup dup dup dup dup dup dup dup dup dup main ;
        \\ node 001 : main 400 for unext main ;
        \\ node 002 : main 400 for unext main ;
        \\ node 003 : main 400 for unext main ;
        \\ node 004 : main 400 for unext main ;
    , &programs, &diagnostic)) |program| try chip.load(program);
    _ = try chip.breakpoints.toggle(.init(0, 3));

    try chip.run();
    try expectEqual(Stop{ .breakpoint = .init(0, 3) }, chip.hit.?);
    try expectEqual(Address.fromWord(3), chip.node(0).?.p.address);
}

test "stepping goes on past a stop no one cleared" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 2 });
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [2]assembler.Program = undefined;
    // as arrayForth's remote words step the chip, without looking at `hit`
    for (try assembler.assembleNodes(
        \\ : main dup dup dup dup dup dup dup dup main ;
        \\ node 001 : main 99 for unext main ;
    , &programs, &diagnostic)) |program| try chip.load(program);
    _ = try chip.breakpoints.toggle(.init(0, 1));

    for (0..100) |_| try expect(try chip.advance());
    try expectEqual(Stop{ .breakpoint = .init(0, 1) }, chip.hit.?);
    try expect(chip.steps > 100);
}

test "a node stepped while queued keeps the queue in order" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 4 });
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [4]assembler.Program = undefined;
    for (try assembler.assembleNodes(
        \\ : main 99 for unext main ;
        \\ node 001 : main 99 for unext main ;
        \\ node 002 : main 99 for unext main ;
        \\ node 003 : main 99 for unext main ;
    , &programs, &diagnostic)) |program| try chip.load(program);

    // the earliest, by hand, as from the TUI, while it is queued
    for (0..8) |_| {
        chip.stepNode(chip.queue[0]);
        try expectHeap(&chip);
    }
}

test "the node furthest behind in time steps first" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 3 });
    defer chip.deinit(std.testing.allocator);

    // 001 passes words from 000, which is slower, on to 002, which is
    // slower still, so times jump as each waits for the other
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [3]assembler.Program = undefined;
    for (try assembler.assembleNodes(
        \\ right b! 9 for 50 for unext dup !b next left b! @b
        \\ node 001 left a! right b! 9 for @ !b next left b! @b
        \\ node 002 left b! 9 for @b drop 200 for unext next left b! @b
    , &programs, &diagnostic)) |program| try chip.load(program);

    var steps: usize = 0;
    while (chip.queue_len > 0) : (steps += 1) {
        try expect(steps < 10_000);
        const next = chip.queue[0];
        for (chip.queue[0..chip.queue_len]) |i| try expect(chip.nodes[next].time <= chip.nodes[i].time);
        try expectEqual(next, (try chip.stepNext()).?);
    }
    for (chip.nodes) |n| try expect(n.suspended);
}

test "a chip of a size alone has basic nodes with no pins" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 9, .columns = 18 });
    defer chip.deinit(std.testing.allocator);
    // 708 and 001 are not the GA144's
    try expectEqual(0, chip.node(708).?.pins);
    try expectEqual(null, chip.node(708).?.wake_port);
    try expectEqual(null, chip.node(1).?.data);
}

test "a node gets the ROM of a GA144 node of its type" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);
    var chip: Chip = try .init(std.testing.allocator, .{
        .rows = 2,
        .columns = 2,
        .nodes = &.{.{ .node = 100, .rom = .async_boot, .pins = &.{ 17, 1 }, .reset = .cold }},
    });
    defer chip.deinit(std.testing.allocator);
    try chip.loadRom(parsed);

    // 708's ROM, starting at cold; and 101, basic, 404's, waiting on its ports
    try expectEqualSlices(Word, &findRom(parsed, 708).?.words, chip.node(100).?.mem[64..]);
    try expectEqual(Address.fromWord(0xaa), chip.node(100).?.p.address);
    try expectEqualSlices(Word, &findRom(parsed, 404).?.words, chip.node(101).?.mem[64..]);
    try expect(chip.node(101).?.p.address.io);
}

test "warm in ROM goes to the ports each node is wired to" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    const reset_addresses = try std.testing.allocator.alloc(Address, chip.nodes.len);
    defer std.testing.allocator.free(reset_addresses);
    for (chip.nodes, reset_addresses) |n, *address| address.* = n.p.address;

    try chip.loadRom(parsed);
    for (chip.nodes, reset_addresses, 0..) |*n, reset_address, i| {
        // warm is a slot 0 jump at x0a9
        const warm = n.fetch(Address.fromWord(0xa9));
        try expectEqual(Opcode.jump, Instruction.decode(warm).slot_0);
        try expectEqual(@as(u9, @bitCast(reset_address)), @as(u9, @intCast(warm & 0x1ff)));
        // boot nodes start at cold instead
        const number = chip.layout.nodeNumber(@intCast(i));
        if (Spec.ga144.resetAddress(number) == null) try expectEqual(reset_address, n.p.address);
    }
}

test "boot nodes missing from a ROM dump wait for code" {
    var roms: [1]ga144.NodeRom = .{.{ .node = ga144.basic_node, .words = @splat(0) }};

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    const reset_addresses = .{ chip.node(1).?.p.address, chip.node(200).?.p.address };
    try chip.loadRom(&roms);
    try expectEqual(reset_addresses[0], chip.node(1).?.p.address);
    try expectEqual(reset_addresses[1], chip.node(200).?.p.address);
}

test "the chip settles after reset with ROM" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try testRom(&roms);

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    try chip.loadRom(parsed);

    // with no pins driven, every node ends up waiting for code from a port
    var rounds: usize = 0;
    while (chip.step()) : (rounds += 1) try expect(rounds < 1_000_000);
    for (chip.nodes) |n| {
        try expect(n.suspended);
        try expect(n.p.address.io or n.state != .fetch);
    }
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

test "runs until every node is suspended" {
    // node 717 is busy for a while, then waits on a port facing off the chip
    try expectOutput(
        \\ up b! 1 !b 2 !b
        \\ node 717 1000 for . next left b! @b
    , "", "\x01\x02");
}

test attachConsole {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 2 });
    defer chip.deinit(std.testing.allocator);

    var input: Io.Queue(u8) = .init(&.{});
    var writer: Io.Writer = .fixed(&.{});
    var console: Console = .{ .input = .{ .io = std.testing.io, .queue = &input }, .output = &writer };
    try expectError(error.PortConnected, chip.attachConsole(&console, 0, .right));
    try expectError(error.NoSuchNode, chip.attachConsole(&console, 100, .up));
    try chip.attachConsole(&console, 1, .left);
}

test "init frees what it allocated when it runs out of memory" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn initChip(gpa: Allocator) !void {
            var chip: Chip = try .init(gpa, .ga144);
            chip.deinit(gpa);
        }
    }.initChip, .{});
}

test "output is flushed once it has been quiet for a while" {
    // node 000 outputs, then stays busy for longer than the console waits
    try expectOutput(
        \\ up b! 1 !b 1999 for . next left b! @b
    , "", "\x01");
}

test "waits for input that has not arrived" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    try chip.load(try assembler.assemble("up b! @b !b", &diagnostic));

    var input_buffer: [1]u8 = undefined;
    var input: Io.Queue(u8) = .init(&input_buffer);
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .input = .{ .io = std.testing.io, .queue = &input }, .output = &writer };
    try chip.attachConsole(&console, 0, .up);

    // input arrives once the chip is waiting for it
    var typing = try std.testing.io.concurrent(struct {
        fn typeKey(io: Io, queue: *Io.Queue(u8), c: *Console) !void {
            while (!c.waiting.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
            try queue.putOne(io, 'k');
            queue.close(io);
        }
    }.typeKey, .{ std.testing.io, &input, &console });
    defer typing.cancel(std.testing.io) catch {};

    try chip.run();
    try typing.await(std.testing.io);
    try expectEqualStrings("k", writer.buffered());
}

/// a chip of two nodes, each with pin 17, wired together, running `source`
fn wiredPair(source: []const u8) !Chip {
    var chip: Chip = try .init(std.testing.allocator, .{
        .rows = 1,
        .columns = 2,
        .nodes = &.{ .{ .node = 0, .pins = &.{17} }, .{ .node = 1, .pins = &.{17} } },
    });
    errdefer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [2]assembler.Program = undefined;
    for (try assembler.assembleNodesFor(&chip.spec, source, &programs, &diagnostic)) |program| try chip.load(program);
    try chip.wire(.{ .node = 0, .pin = 17 }, .{ .node = 1, .pin = 17 });
    return chip;
}

test "a node reads a pin another node drives as it was at its time" {
    // 000 drives the net high at the end of a 2.4 us loop, in one step,
    // while 001 reads it at about 30 ns and again at about 4.8 us
    var chip = try wiredPair(
        \\ io b! 0x30000 999 for unext !b left b! @b
        \\ node 001 9 for unext io b! @b 1999 for unext @b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    const n = chip.node(1).?;
    try expectEqual(0, @as(u18, @bitCast(n.data_stack.s)) & 1 << 17);
    try expectEqual(1 << 17, @as(u18, @bitCast(n.data_stack.t)) & 1 << 17);
    try expectEqual(null, chip.wiring.contention);
}

test "a node waiting on pin 17 wakes as another node drives it" {
    var chip = try wiredPair(
        \\ io b! 0x30000 999 for unext !b left b! @b
        \\ node 001 up a! @ drop io b! @b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    const n = chip.node(1).?;
    try expectEqual(1 << 17, @as(u18, @bitCast(n.data_stack.t)) & 1 << 17);
    // at the time 000 drove it, not before
    try expect(n.time >= 2_400_000 and n.time < 2_500_000);
}

test "a pull-up outweighs a pin's weak pulldown and a pin no one drives, not one driven low" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 1, .nodes = &.{.{ .node = 0, .pins = &.{17} }} });
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    // as after reset, weakly pulled down; then not driven; then low
    try chip.load(try assembler.assemble("io b! @b 0 !b @b 0x20000 !b @b left b! @b", &diagnostic));
    try chip.pull(.{ .node = 0, .pin = 17 }, true);
    try chip.run();
    const n = chip.node(0).?;
    try expectEqual(1 << 17, @as(u18, @bitCast(n.data_stack.stack[n.data_stack.index])) & 1 << 17);
    try expectEqual(1 << 17, @as(u18, @bitCast(n.data_stack.s)) & 1 << 17);
    try expectEqual(0, @as(u18, @bitCast(n.data_stack.t)) & 1 << 17);
}

test "a node waiting on pin 17 wakes at a change a node ahead of it made" {
    // 000 drives the net high at about 2.4 us in one long step, before 001,
    // behind it, gets to wait on its pin
    var chip = try wiredPair(
        \\ io b! 0x30000 999 for unext !b left b! @b
        \\ node 001 19 for unext up a! @ drop io b! @b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    const n = chip.node(1).?;
    try expectEqual(1 << 17, @as(u18, @bitCast(n.data_stack.t)) & 1 << 17);
    try expect(n.time >= 2_400_000 and n.time < 2_500_000);
}

test "a node waiting on pin 17 wakes at a pulse shorter than a step" {
    // 000 drives the net high, then low, in one word
    var chip = try wiredPair(
        \\ io b! 0x20000 0x30000 999 for unext !b !b left b! @b
        \\ node 001 up a! @ drop left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    const n = chip.node(1).?;
    try expect(!n.waitsOnPin());
    try expect(n.time >= 2_400_000 and n.time < 2_500_000);
}

test "going back to a snapshot forgets the pins' future" {
    var chip = try wiredPair(
        \\ io b! 0x30000 999 for unext !b left b! @b
        \\ node 001 up a! @ drop io b! @b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    var snapshot: Snapshot = try .init(std.testing.allocator, chip.layout);
    defer snapshot.deinit(std.testing.allocator);
    chip.save(&snapshot);
    try chip.run();
    const woken = chip.node(1).?.time;
    chip.restore(&snapshot);
    try chip.run();
    try expectEqual(woken, chip.node(1).?.time);
    try expectEqual(1 << 17, @as(u18, @bitCast(chip.node(1).?.data_stack.t)) & 1 << 17);
}

test "two nodes driving a net both ways is contention" {
    var chip = try wiredPair(
        \\ io b! 0x30000 !b left b! @b
        \\ node 001 io b! 0x20000 !b left b! @b
    );
    defer chip.deinit(std.testing.allocator);
    try chip.run();
    try expect(chip.wiring.contention != null);
    try expectError(error.NoSuchPin, chip.wire(.{ .node = 0, .pin = 17 }, .{ .node = 1, .pin = 5 }));
    try expectError(error.NoSuchPin, chip.pull(.{ .node = 0, .pin = 20 }, true));
}

test attachUart {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);

    var writer: Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &writer);
    try expectError(error.NoSuchNode, chip.attachUart(&uart, 999));
    try expectError(error.NoPins, chip.attachUart(&uart, 410));
    try chip.attachUart(&uart, 708);
}

test "a node waiting on its pin wakes as the line changes" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [2]assembler.Program = undefined;
    // node 708 waits for pin 17 to go high, then on node 709, while node
    // 000 is busy until after the line changes, so 708 waits for it
    for (try assembler.assembleNodes(
        \\ 2999 for unext left b! @b
        \\ node 708 : main up a! @ drop right b! @b
    , &programs, &diagnostic)) |program| try chip.load(program);

    // a start bit at 5 us, the line idle low until then
    var writer: Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &writer);
    uart.preload = "\x00";
    uart.arrived = 5_000_000;
    try chip.attachUart(&uart, 708);

    try chip.run();
    const n = chip.node(708).?;
    try expect(n.suspended and !n.waitsOnPin());
    try expect(n.time >= 5_000_000 and n.time < 5_100_000);
    try expect(chip.node(0).?.time > 6_000_000);
}

test "pins are read at the node's time, after a unext loop in the same word" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    // `unext @b` is one word, which reads io 7.2 us in
    try chip.load(try assembler.assemble("node 708 : main io b! 2999 for unext @b left b! @b", &diagnostic));

    // the line goes high with a start bit at 5 us, and stays high for the
    // data bits of 0
    var writer: Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &writer);
    uart.preload = "\x00";
    uart.arrived = 5_000_000;
    try chip.attachUart(&uart, 708);

    try chip.run();
    const io: u18 = @bitCast(chip.node(708).?.data_stack.t);
    try expect(io & 1 << 17 != 0);
}

test "pins are driven at the node's time, in a unext loop" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    // `dup !b unext` drives pin 1 high, a start bit, as the 7.3 us loop
    // begins, and again on each pass
    try chip.load(try assembler.assemble("node 708 : main io b! 3 999 for dup !b unext left b! @b", &diagnostic));

    var writer: Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &writer);
    try chip.attachUart(&uart, 708);

    try chip.run();
    try expect(uart.receiving.?.start < 100_000);
}

test "a byte the node sends is received without a write after it" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    // a start bit and data bits of 0 for 0xff, then the line idle, low,
    // with no write of a stop bit after the last data bit, while the node
    // runs on
    try chip.load(try assembler.assemble("node 708 : main io b! 3 !b 428 for unext 2 !b 4999 for unext left b! @b", &diagnostic));

    var buffer: [4]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var uart: Uart = .init(921600, &writer);
    try chip.attachUart(&uart, 708);

    try chip.run();
    try expectEqualStrings("\xff", writer.buffered());
}

test "a node that reads its pin once input has arrived uses the UART" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [2]assembler.Program = undefined;
    // node 708 is busy until the start bit has begun, so its read of the
    // pin does not wait
    for (try assembler.assembleNodes(
        \\ left b! @b
        \\ node 708 : main 999 for unext up a! @ drop right b! @b
    , &programs, &diagnostic)) |program| try chip.load(program);

    var writer: Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &writer);
    uart.preload = "\x00";
    try chip.attachUart(&uart, 708);

    try chip.run();
    try expect(!chip.node(708).?.waitsOnPin());
    try expect(uart.used);
}

test "waits for UART input that has not arrived" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    try chip.load(try assembler.assemble("node 708 : main up a! @ drop right b! @b", &diagnostic));

    var input_buffer: [1]u8 = undefined;
    var input: Io.Queue(u8) = .init(&input_buffer);
    var writer: Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &writer);
    uart.input = .{ .io = std.testing.io, .queue = &input };
    try chip.attachUart(&uart, 708);

    // input arrives once the chip is waiting for it, and its start bit
    // wakes node 708 at once
    var typing = try std.testing.io.concurrent(struct {
        fn typeKey(io: Io, queue: *Io.Queue(u8), u: *Uart) !void {
            while (!u.waiting.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
            try queue.putOne(io, 'k');
            queue.close(io);
        }
    }.typeKey, .{ std.testing.io, &input, &uart });
    defer typing.cancel(std.testing.io) catch {};

    try chip.run();
    try typing.await(std.testing.io);
    const n = chip.node(708).?;
    try expect(n.suspended and !n.waitsOnPin());
    try expect(uart.used);
}

test advance {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    try chip.load(try assembler.assemble("up b! @b !b", &diagnostic));

    var input_buffer: [1]u8 = undefined;
    var input: Io.Queue(u8) = .init(&input_buffer);
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .input = .{ .io = std.testing.io, .queue = &input }, .output = &writer };
    try chip.attachConsole(&console, 0, .up);

    // the node settles waiting for input, without advance waiting for it
    while (try chip.advance()) {}
    try expect(chip.nodes[0].suspended);

    // input that arrives later is given to the node
    try input.putOne(std.testing.io, 'x');
    while (try chip.advance()) {}
    try expectEqualStrings("x", writer.buffered());
}

test stepNext {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 2 });
    defer chip.deinit(std.testing.allocator);

    // nodes run in turn, until both wait on their ports for code
    try expectEqual(0, try chip.stepNext());
    try expectEqual(1, try chip.stepNext());
    try expectEqual(null, try chip.stepNext());
    try expectEqual(2, chip.steps);
}

test "stops at breakpoints" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    // loops forever, from x000
    try chip.load(try assembler.assemble("begin dup drop again", &diagnostic));

    // x040 is the same word as x000, as RAM repeats. The node starts there.
    try expectEqual(true, try chip.breakpoints.toggle(.init(0, 0x40)));
    try chip.run();
    try expectEqual(Stop{ .breakpoint = .{ .index = 0, .address = 0 } }, chip.hit);
    try expectEqual(0, chip.steps);
    // running again goes past it, and around the loop to it again
    const steps = chip.steps;
    try chip.run();
    try expect(chip.hit != null and chip.steps > steps);

    // clearing it, and filling them up
    try expectEqual(false, try chip.breakpoints.toggle(.init(0, 0)));
    try expect(!chip.breakpoints.contains(.init(0, 0)));
    for (0..max_breakpoints) |i| _ = try chip.breakpoints.toggle(.init(0, @intCast(0x80 + i)));
    try expectError(error.Full, chip.breakpoints.toggle(.init(0, 0)));
    try expectError(error.Full, chip.breakpoints.insert(.init(0, 0)));
    // adding one that is there already
    try chip.breakpoints.insert(.init(0, 0x80));
    try expectEqual(max_breakpoints, chip.breakpoints.len);
}

test "stops at watched transfers" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 2 });
    defer chip.deinit(std.testing.allocator);
    var programs: [2]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    // node 000 writes 1, 2, 3 to node 001, which adds them up
    for (try assembler.assembleNodes(
        \\node 000 right b! 1 !b 2 !b 3 !b
        \\node 001 right b! @b @b + @b +
    , &programs, &diagnostic)) |program| try chip.load(program);

    _ = try chip.watches.toggle(.{ .index = 1, .direction = .right, .write = false });
    try chip.run();
    try expectEqual(Stop{ .watch = .{ .watch = .{ .index = 1, .direction = .right, .write = false }, .value = 1 } }, chip.hit);
    try chip.run();
    try expectEqual(2, chip.hit.?.watch.value);

    // writes are watched separately: node 000 finishes writing 2 as it
    // goes on, as the run stopped once 001 read it
    chip.watches = .{};
    _ = try chip.watches.toggle(.{ .index = 0, .direction = .right, .write = true });
    try chip.run();
    try expectEqual(2, chip.hit.?.watch.value);
    try chip.run();
    try expectEqual(3, chip.hit.?.watch.value);
    try expectEqual(0, chip.hit.?.index());

    var buffer: [64]u8 = undefined;
    try expectEqualStrings("node 000 wrote 00003 to right", try std.fmt.bufPrint(&buffer, "{f}", .{chip.hit.?.describe(chip.layout)}));
    try expectEqualStrings("node 000 reached 03f", try std.fmt.bufPrint(&buffer, "{f}", .{(Stop{ .breakpoint = .init(0, 0x3f) }).describe(chip.layout)}));
}

test "goes back to a snapshot" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 2 });
    defer chip.deinit(std.testing.allocator);
    var snapshot: Snapshot = try .init(std.testing.allocator, chip.layout);
    defer snapshot.deinit(std.testing.allocator);
    var programs: [2]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes(
        \\node 000 right b! 1 !b 2 !b 3 !b
        \\node 001 right b! @b @b + @b +
    , &programs, &diagnostic)) |program| try chip.load(program);
    _ = try chip.watches.toggle(.{ .index = 1, .direction = .right, .write = false });

    try chip.run();
    chip.save(&snapshot);
    const steps = chip.steps;
    try chip.run();
    try chip.run();
    try expectEqual(3, chip.hit.?.watch.value);

    try expect(!chip.matches(&snapshot));
    // the same transfers happen again
    chip.restore(&snapshot);
    try expect(chip.matches(&snapshot));
    try expectEqual(steps, chip.steps);
    try expectEqual(1, chip.nodes[1].data_stack.t);
    try chip.run();
    try expectEqual(2, chip.hit.?.watch.value);
    try chip.run();
    try expectEqual(3, chip.hit.?.watch.value);
}

test "traces each step" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    try chip.load(try assembler.assemble("5 dup drop left b! @b", &diagnostic));
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    chip.trace = &writer;

    // literals are skipped, and the node waits on a port nothing writes to
    while (chip.step()) {}
    try expectEqualStrings(
        \\000 000 04def @p dup drop @p  T 00175 S 00005 R 00000
        \\000 003 29fb2 b! @b . .  T 00005 S 00000 R 00000  waiting
        \\
    , writer.buffered());
}

test "traces as JSON, and one node" {
    for ([_]u16{ 1, 0 }, [_][]const u8{ "", "{\"node\":\"000\",\"address\":\"000\",\"word\":" }) |only, start| {
        var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 2 });
        defer chip.deinit(std.testing.allocator);
        var diagnostic: assembler.Diagnostic = .{};
        try chip.load(try assembler.assemble("5 dup drop left b! @b", &diagnostic));
        var buffer: [512]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        chip.trace = &writer;
        chip.trace_json = true;
        chip.trace_only = only;

        while (chip.step()) {}
        try expect(std.mem.startsWith(u8, writer.buffered(), start));
        if (start.len == 0) try expectEqualStrings("", writer.buffered());
    }
}

test "running stops at a limit" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    // a loop that never waits
    try chip.load(try assembler.assemble(": loop loop ;", &diagnostic));

    chip.step_limit = 100;
    try chip.run();
    try expect(chip.limited);
    try expect(chip.steps >= 100);

    // going on from there, to a time
    chip.step_limit = std.math.maxInt(u64);
    chip.time_limit = chip.nodes[0].time + 100_000;
    try chip.run();
    try expect(chip.limited);
    try expect(chip.nodes[0].time >= chip.time_limit);
}

test "traces a node waiting on a port once" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 3 });
    defer chip.deinit(std.testing.allocator);
    var programs: [3]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    // node 000 waits forever on a port facing off the chip. Node 001 offers
    // a word to both neighbours, and withdraws it from node 000 once node
    // 002 takes it, which wakes node 000.
    for (try assembler.assembleNodes(
        \\node 000 left b! @b
        \\node 001 r-l- b! 5 !b right b! @b
        \\node 002 left b! @b @b
    , &programs, &diagnostic)) |program| try chip.load(program);
    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    chip.trace = &writer;

    while (chip.step()) {}
    try expectEqualStrings(
        \\000 000 04b02 @p b! @b .  T 00000 S 00000 R 00000  waiting
        \\001 000 04b12 @p b! @p .  T 00005 S 00000 R 00000
        \\002 000 04b02 @p b! @b .  T 00000 S 00000 R 00000  waiting
        \\001 003 09da2 !b @p b! .  T 00000 S 00000 R 00000
        \\001 005 009b2 @b . . .  T 00000 S 00000 R 00000  waiting
        \\002 000 04b02 @p b! @b .  T 00005 S 00000 R 00000
        \\002 002 009b2 @b . . .  T 00005 S 00000 R 00000  waiting
        \\
    , writer.buffered());
}

test "executes words from a port, as the IDE does" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    const program = try assembler.assemble(": inc 1 + ; : spin begin again", &diagnostic);
    // node 000 executes from its left port, which faces off the chip
    var descriptor: boot.Descriptor = .ofProgram(program);
    descriptor.p = 0x175;
    try chip.setUp(descriptor, &.{program});
    // about to fetch from the port, which is as good as waiting on it
    const i = chip.layout.index(0).?;
    try expectEqual(.running, chip.nodes[i].status());
    try expect(try chip.runUntilWaiting(i, 0));

    // code jumped to returns to the port, where the node waits for code
    // again, with its return stack as it was
    chip.nodes[i].data_stack.push(5);
    chip.nodes[i].return_stack.push(9);
    try chip.execute(i, Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }, 0, 0));
    try expect(try chip.runUntilWaiting(i, 100));
    try expectEqual(6, chip.nodes[i].data_stack.t);
    try expectEqual(9, chip.nodes[i].return_stack.t);
    try expectEqual(0x175, @as(u9, @bitCast(chip.nodes[i].p.address)));

    // as does an opcode followed by returns
    try chip.execute(i, Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }));
    try expect(try chip.runUntilWaiting(i, 100));
    try expectEqual(6, chip.nodes[i].data_stack.s);
    try expectEqual(9, chip.nodes[i].return_stack.t);

    // code that does not come back leaves the node running
    try chip.execute(i, Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }, 0, 2));
    try expect(!try chip.runUntilWaiting(i, 100));
    try expectError(error.NotWaitingForCode, chip.execute(i, 0));
}

test "words are only refused for code delivered to the node" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    // node 101 waits for code on all four of its ports
    try chip.setUp(.{ .node = 101, .p = 0x1a5 }, &.{});
    const i = chip.layout.index(101).?;
    try expect(try chip.runUntilWaiting(i, 10));
    // so it has tried to fetch, and is reading its ports
    chip.stepNode(i);
    const n = &chip.nodes[i];
    const right = n.ports[@backingInt(Direction.right)];
    const left = n.ports[@backingInt(Direction.left)];

    // a word delivered to the node's neighbour is not code for it
    right.port.?.state = .{ .delivered = .{ .side = right.side.other(), .value = 1 } };
    try chip.execute(i, 0x15555);
    try expectEqual(right.side.other(), right.port.?.state.delivered.side);

    // but one delivered to it is, and its other reads are left as they were
    try expect(try chip.runUntilWaiting(i, 10));
    chip.stepNode(i);
    right.port.?.state = .{ .delivered = .{ .side = right.side, .value = 1 } };
    const before = left.port.?.state;
    try expect(before == .reading);
    try expectError(error.NotWaitingForCode, chip.execute(i, 0x15555));
    try expectEqual(before, left.port.?.state);
}

test "stops when interrupted" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(std.testing.allocator);

    var diagnostic: assembler.Diagnostic = .{};
    try chip.load(try assembler.assemble("up b! 1 !b begin again", &diagnostic));

    var input = try Console.testInput(&.{}, "");
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .input = .{ .io = std.testing.io, .queue = &input }, .output = &writer };
    try chip.attachConsole(&console, 0, .up);

    // run the program up to its endless loop
    for (0..4) |_| {
        _ = chip.step();
        if (try console.service(false)) chip.wake(0);
    }
    console.interrupted.store(true, .monotonic);
    try chip.run();
    try expectEqualStrings("\x01", writer.buffered());
}

const arrayforth = @import("arrayforth.zig");
const assembler = @import("assembler.zig");
const boot = @import("boot.zig");
const disassembler = @import("disassembler.zig");
const ga144 = @import("ga144.zig");
const Spec = @import("Spec.zig");
const testRom = @import("rom.zig").testRom;
const Console = @import("Console.zig");
const Uart = @import("Uart.zig");
const Sync = @import("Sync.zig");
const Flash = @import("Flash.zig");
const f18 = @import("f18.zig");
const Address = f18.Address;
const Computer = f18.Computer;
const Instruction = f18.Instruction;
const Word = f18.Word;
const Opcode = @import("opcodes.zig").Opcode;
const gpio = @import("pins.zig");
const Serdes = @import("Serdes.zig");
const port = @import("port.zig");
const Direction = port.Direction;
const Port = port.Port;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
