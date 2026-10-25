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
//! Nodes are configured like the GA144 node of the same number, with its
//! GPIO pins and, once loaded, its ROM. See `ga144`.

layout: Layout,
nodes: []Computer,
/// ports between neighbours
ports: []Port,

/// nodes to step, in order. Each node is in the queue at most once.
queue: []u16,
queue_head: usize = 0,
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

/// the console, and the index of the node it is attached to
console: ?struct { device: *Console, index: u16 } = null,
/// words fed into a node, such as a boot stream
feeder: ?struct { device: *Feeder, index: u16 } = null,

const Chip = @This();

pub const max_breakpoints = 32;
pub const max_watches = 32;

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
                .breakpoint => |b| try writer.print("node {d:0>3} reached {x:0>3}", .{ number, b.address }),
                .watch => |w| try writer.print("node {d:0>3} {s} {x:0>5} {s} {t}", .{
                    number,
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
    queue_head: usize = 0,
    queue_len: usize = 0,
    steps: u64 = 0,
    started: bool = false,
    console_port: Port = .{},
    feeder_port: Port = .{},
    feeder_next: usize = 0,

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

pub const Layout = struct {
    rows: u8,
    columns: u8,

    pub const ga144: Layout = .{ .rows = 8, .columns = 18 };

    /// Parses rows and columns such as 8x18. Node numbers limit both to 100.
    pub fn parse(text: []const u8) error{InvalidLayout}!Layout {
        const x = std.mem.indexOfScalar(u8, text, 'x') orelse return error.InvalidLayout;
        const rows = std.fmt.parseInt(u8, text[0..x], 10) catch return error.InvalidLayout;
        const columns = std.fmt.parseInt(u8, text[x + 1 ..], 10) catch return error.InvalidLayout;
        if (rows == 0 or rows > 100 or columns == 0 or columns > 100) return error.InvalidLayout;
        return .{ .rows = rows, .columns = columns };
    }

    pub fn count(self: Layout) usize {
        return @as(usize, self.rows) * self.columns;
    }

    /// the number of ports between neighbours
    pub fn portCount(self: Layout) usize {
        const rows: usize = self.rows;
        const columns: usize = self.columns;
        return rows * (columns - 1) + (rows - 1) * columns;
    }

    /// index into `Chip.nodes` of a node number, if the node exists
    pub fn index(self: Layout, number: u16) ?u16 {
        const x = number % 100;
        const y = number / 100;
        if (x >= self.columns or y >= self.rows) return null;
        return y * self.columns + x;
    }

    pub fn nodeNumber(self: Layout, i: u16) u16 {
        return i / self.columns * 100 + i % self.columns;
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
        const x = i % self.columns;
        const y = i / self.columns;
        return switch (facing(x, y, direction)) {
            .north => if (y + 1 < self.rows) i + self.columns else null,
            .south => if (y > 0) i - self.columns else null,
            .east => if (x + 1 < self.columns) i + 1 else null,
            .west => if (x > 0) i - 1 else null,
        };
    }
};

pub const Cardinal = enum { north, east, south, west };

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
pub fn init(gpa: Allocator, layout: Layout) Allocator.Error!Chip {
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

    var chip: Chip = .{ .layout = layout, .nodes = nodes, .ports = ports, .queue = queue, .queued = queued };
    @memset(ports, .{});
    @memset(queued, false);
    for (nodes, 0..) |*n, i| {
        const number = layout.nodeNumber(@intCast(i));
        n.* = .reset;
        n.pins = ga144.pins(number);
        if (ga144.hasData(number)) n.data = 0;
        n.p.address = Address.fromWord(port.multiport(layout.neighbourPorts(@intCast(i))));
        chip.wake(@intCast(i));
    }

    // the west or south node of each pair takes side a
    var next_port: usize = 0;
    for (0..rows) |y| {
        for (0..columns) |x| {
            const i = y * columns + x;
            if (x + 1 < columns) {
                chip.connect(i, i + 1, portToward(@intCast(x), @intCast(y), .east), &ports[next_port]);
                next_port += 1;
            }
            if (y + 1 < rows) {
                chip.connect(i, i + columns, portToward(@intCast(x), @intCast(y), .north), &ports[next_port]);
                next_port += 1;
            }
        }
    }
    std.debug.assert(next_port == ports.len);
    return chip;
}

pub fn deinit(self: *Chip, gpa: Allocator) void {
    gpa.free(self.nodes);
    gpa.free(self.ports);
    gpa.free(self.queue);
    gpa.free(self.queued);
    self.* = undefined;
}

/// Saves the chip into a snapshot allocated for its layout
pub fn save(self: Chip, snapshot: *Snapshot) void {
    @memcpy(snapshot.nodes, self.nodes);
    @memcpy(snapshot.ports, self.ports);
    @memcpy(snapshot.queue, self.queue);
    @memcpy(snapshot.queued, self.queued);
    snapshot.queue_head = self.queue_head;
    snapshot.queue_len = self.queue_len;
    snapshot.steps = self.steps;
    snapshot.started = self.started;
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
    self.queue_head = snapshot.queue_head;
    self.queue_len = snapshot.queue_len;
    self.steps = snapshot.steps;
    self.started = snapshot.started;
    self.hit = null;
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
        self.queue_head != snapshot.queue_head or
        self.queue_len != snapshot.queue_len) return false;
    if (self.console) |console| if (!std.meta.eql(console.device.port, snapshot.console_port)) return false;
    if (self.feeder) |feeder| if (!std.meta.eql(feeder.device.port, snapshot.feeder_port) or feeder.device.next != snapshot.feeder_next) return false;
    return true;
}

/// connects two neighbours, which use the same name for their common port
fn connect(self: *Chip, a: usize, b: usize, direction: Direction, p: *Port) void {
    self.nodes[a].ports[@backingInt(direction)] = .{ .port = p, .side = .a };
    self.nodes[b].ports[@backingInt(direction)] = .{ .port = p, .side = .b };
}

pub fn node(self: Chip, number: u16) ?*Computer {
    return &self.nodes[self.layout.index(number) orelse return null];
}

/// Loads each node's ROM from a dump, by node number, and starts the boot
/// nodes in ROM as after reset. Nodes missing from the dump get the ROM of a
/// basic node, and wait for code on their ports as basic nodes do. Load ROM
/// before programs, and before stepping the chip.
pub fn loadRom(self: *Chip, roms: []const ga144.NodeRom) error{MissingRom}!void {
    const basic = findRom(roms, ga144.basic_node);
    for (self.nodes, 0..) |*n, i| {
        const number = self.layout.nodeNumber(@intCast(i));
        const own = findRom(roms, number);
        const rom = own orelse basic orelse return error.MissingRom;
        @memcpy(n.mem[64..], &rom.words);
        // cold and warm are where they are only in the node's own ROM
        if (own != null) if (ga144.resetAddress(number)) |address| {
            n.p.address = Address.fromWord(address);
        };
    }
}

fn findRom(roms: []const ga144.NodeRom, number: u16) ?*const ga144.NodeRom {
    for (roms) |*rom| if (rom.node == number) return rom;
    return null;
}

/// Loads a program into its node. Load programs before stepping the chip.
pub fn load(self: *Chip, program: assembler.Program) error{NoSuchNode}!void {
    program.load(self.node(program.node) orelse return error.NoSuchNode);
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
    if (descriptor.io) |io| n.io = io;
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
    if (n.status() != .code) return error.NotWaitingForCode;
    const ports = port.select(@bitCast(n.p.address)) orelse return error.NotWaitingForCode;
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
        if (self.nodes[i].status() == .code) return true;
        if (!try self.advance()) break;
    }
    return self.nodes[i].status() == .code;
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
    self.feeder = .{ .device = feeder, .index = i };
}

/// feeds the next word, waking the node that takes it
fn feed(self: *Chip) bool {
    const feeder = self.feeder orelse return false;
    if (!feeder.device.service()) return false;
    self.wake(feeder.index);
    return true;
}

/// Steps each runnable node once. Returns false when every node is
/// suspended, and stepping would do nothing.
pub fn step(self: *Chip) bool {
    if (self.queue_len == 0) return false;
    if (!self.started) {
        // a breakpoint on the first word a node runs
        for (self.nodes, 0..) |*n, i| if (self.hit == null and !n.suspended and n.state == .fetch) {
            self.hit = self.breakpointAt(@intCast(i));
        };
        self.started = true;
        if (self.hit != null) return true;
    }
    // nodes woken during this round run in the next one
    for (0..self.queue_len) |_| self.stepNode(self.dequeue().?);
    return true;
}

/// takes the next node to step from the queue
fn dequeue(self: *Chip) ?u16 {
    if (self.queue_len == 0) return null;
    const i = self.queue[self.queue_head];
    self.queue_head = (self.queue_head + 1) % self.queue.len;
    self.queue_len -= 1;
    self.queued[i] = false;
    return i;
}

/// Steps a node and wakes the neighbours on any port it changed, since a
/// suspended node can only continue once one of its ports changes.
pub fn stepNode(self: *Chip, i: u16) void {
    const n = &self.nodes[i];
    var before: [4]Port.State = undefined;
    for (n.ports, &before) |link, *state| state.* = if (link.port) |p| p.state else .idle;

    const fetching = n.state == .fetch;
    const retrying = n.suspended;
    n.step();
    self.steps += 1;
    self.started = true;
    if (!n.suspended) self.wake(i);
    // unless the node is still waiting for a word to execute, or still
    // waiting on the same port
    const waited = n.suspended and !n.transfers.any() and (retrying or (fetching and n.state == .fetch));
    if (self.trace) |writer| if (!waited) {
        self.writeTrace(writer, i) catch {
            self.trace = null;
        };
    };
    if (self.hit == null and self.breakpoints.len + self.watches.len > 0) self.hit = self.stopAt(i);

    for (n.ports, before, 0..) |link, state, d| {
        const p = link.port orelse continue;
        if (std.meta.eql(state, p.state)) continue;
        if (self.layout.neighbour(i, @fromBackingInt(@intCast(d)))) |other| self.wake(other);
    }
}

/// Writes the node, the word it executed, where from, and its stacks after,
/// such as `000 003 2c9b2 @+ for @+ !b  T 0000d S 00000 R 00000`
fn writeTrace(self: *const Chip, writer: *Io.Writer, i: u16) Io.Writer.Error!void {
    const n = &self.nodes[i];
    const address: u9 = @bitCast(n.word_address);
    try writer.print("{d:0>3} {x:0>3} {x:0>5} ", .{ self.layout.nodeNumber(i), address, @as(u18, @bitCast(n.i)) });
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
    self.queue[(self.queue_head + self.queue_len) % self.queue.len] = i;
    self.queue_len += 1;
}

/// rounds without console output after which pending output is flushed
const flush_after_rounds = 1000;

/// Gives the devices anything they have for their nodes, without waiting
/// for input, then steps each runnable node once. Returns false when nothing
/// happened: every node is waiting, and the devices have nothing for them.
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
    const i = self.dequeue() orelse return null;
    self.stepNode(i);
    return i;
}

/// Gives the devices anything they have for their nodes, without waiting
/// for input. Returns false when they had nothing.
pub fn service(self: *Chip) !bool {
    var serviced = false;
    if (self.console) |console| if (try console.device.service(false)) {
        self.wake(console.index);
        serviced = true;
    };
    if (self.feed()) serviced = true;
    return serviced;
}

/// Runs until every node is suspended on something the console cannot
/// complete, a node reaches a breakpoint or makes a watched transfer, or the
/// console is interrupted. Breakpoints and watches stop the run at the end of
/// the round, leaving `hit` set.
pub fn run(self: *Chip) !void {
    self.hit = null;
    const console = self.console orelse {
        while (self.hit == null and (self.feed() or self.step())) {}
        return;
    };
    const output = console.device.output;
    var quiet_rounds: u16 = 0;
    while (self.hit == null and !console.device.interrupted.load(.monotonic)) {
        const pending = output.end;
        if (try console.device.service(false)) self.wake(console.index);
        // flush once output stops for a while, so a busy node does not hold
        // it up while a steady stream of output is still written in blocks
        if (pending == 0 or output.end != pending) {
            quiet_rounds = 0;
        } else if (quiet_rounds == flush_after_rounds) {
            try output.flush();
        } else quiet_rounds += 1;
        _ = self.feed();
        if (self.step()) continue;
        // with nothing else to do, wait for input
        if (!try console.device.service(true)) break;
        self.wake(console.index);
    }
    try console.device.output.flush();
}

/// Assembles `source` onto a GA144 sized chip with a console on the up port
/// of node 000, and checks what it outputs given `input`
pub fn expectOutput(source: []const u8, input: []const u8, expected: []const u8) !void {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);

    var programs: [8]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes(source, &programs, &diagnostic)) |program| try chip.load(program);

    var input_buffer: [256]u8 = undefined;
    var input_queue = try Console.testInput(&input_buffer, input);
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .io = std.testing.io, .input = &input_queue, .output = &writer };
    try chip.attachConsole(&console, 0, .up);

    try chip.run();
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test Layout {
    try expectEqual(Layout{ .rows = 12, .columns = 20 }, try Layout.parse("12x20"));
    try std.testing.expectError(error.InvalidLayout, Layout.parse("12"));
    try std.testing.expectError(error.InvalidLayout, Layout.parse("0x4"));
    try std.testing.expectError(error.InvalidLayout, Layout.parse("101x4"));
    try std.testing.expectError(error.InvalidLayout, Layout.parse("4x"));

    const layout: Layout = .ga144;
    try expectEqual(144, layout.count());
    try expectEqual(17, layout.index(17));
    try expectEqual(18, layout.index(100));
    try expectEqual(143, layout.index(717));
    try expectEqual(null, layout.index(18));
    try expectEqual(null, layout.index(800));
    try expectEqual(717, layout.nodeNumber(143));
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

    try std.testing.expect(chip.step());
    // every node suspends reading its ports
    try std.testing.expect(!chip.step());
    for (chip.nodes) |n| try std.testing.expect(n.suspended);
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
    try std.testing.expect(chip.node(1).?.suspended);
}

test "warm in ROM goes to the ports each node is wired to" {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = try ga144.testRom(&roms);

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
        if (ga144.resetAddress(number) == null) try expectEqual(reset_address, n.p.address);
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
    const parsed = try ga144.testRom(&roms);

    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    try chip.loadRom(parsed);

    // with no pins driven, every node ends up waiting for code from a port
    var rounds: usize = 0;
    while (chip.step()) : (rounds += 1) try std.testing.expect(rounds < 1_000_000);
    for (chip.nodes) |n| {
        try std.testing.expect(n.suspended);
        try std.testing.expect(n.p.address.io or n.state != .fetch);
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
    var console: Console = .{ .io = std.testing.io, .input = &input, .output = &writer };
    try std.testing.expectError(error.PortConnected, chip.attachConsole(&console, 0, .right));
    try std.testing.expectError(error.NoSuchNode, chip.attachConsole(&console, 100, .up));
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
    var console: Console = .{ .io = std.testing.io, .input = &input, .output = &writer };
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
    try std.testing.expectEqualStrings("k", writer.buffered());
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
    var console: Console = .{ .io = std.testing.io, .input = &input, .output = &writer };
    try chip.attachConsole(&console, 0, .up);

    // the node settles waiting for input, without advance waiting for it
    while (try chip.advance()) {}
    try std.testing.expect(chip.nodes[0].suspended);

    // input that arrives later is given to the node
    try input.putOne(std.testing.io, 'x');
    while (try chip.advance()) {}
    try std.testing.expectEqualStrings("x", writer.buffered());
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
    try std.testing.expect(chip.hit != null and chip.steps > steps);

    // clearing it, and filling them up
    try expectEqual(false, try chip.breakpoints.toggle(.init(0, 0)));
    try std.testing.expect(!chip.breakpoints.contains(.init(0, 0)));
    for (0..max_breakpoints) |i| _ = try chip.breakpoints.toggle(.init(0, @intCast(0x80 + i)));
    try std.testing.expectError(error.Full, chip.breakpoints.toggle(.init(0, 0)));
    try std.testing.expectError(error.Full, chip.breakpoints.insert(.init(0, 0)));
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

    // writes are watched separately
    chip.watches = .{};
    _ = try chip.watches.toggle(.{ .index = 0, .direction = .right, .write = true });
    try chip.run();
    try expectEqual(3, chip.hit.?.watch.value);
    try expectEqual(0, chip.hit.?.index());

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("node 000 wrote 00003 to right", try std.fmt.bufPrint(&buffer, "{f}", .{chip.hit.?.describe(chip.layout)}));
    try std.testing.expectEqualStrings("node 000 reached 03f", try std.fmt.bufPrint(&buffer, "{f}", .{(Stop{ .breakpoint = .init(0, 0x3f) }).describe(chip.layout)}));
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

    try std.testing.expect(!chip.matches(&snapshot));
    // the same transfers happen again
    chip.restore(&snapshot);
    try std.testing.expect(chip.matches(&snapshot));
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
    try std.testing.expectEqualStrings(
        \\000 000 04def @p dup drop @p  T 00175 S 00005 R 00000
        \\000 003 29fb2 b! @b . .  T 00005 S 00000 R 00000  waiting
        \\
    , writer.buffered());
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
    try std.testing.expectEqualStrings(
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
    const i = chip.layout.index(0).?;
    try std.testing.expect(try chip.runUntilWaiting(i, 10));

    // code jumped to returns to the port, where the node waits for code
    // again, with its return stack as it was
    chip.nodes[i].data_stack.push(5);
    chip.nodes[i].return_stack.push(9);
    try chip.execute(i, Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }, 0, 0));
    try std.testing.expect(try chip.runUntilWaiting(i, 100));
    try std.testing.expectEqual(6, chip.nodes[i].data_stack.t);
    try std.testing.expectEqual(9, chip.nodes[i].return_stack.t);
    try std.testing.expectEqual(0x175, @as(u9, @bitCast(chip.nodes[i].p.address)));

    // as does an opcode followed by returns
    try chip.execute(i, Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }));
    try std.testing.expect(try chip.runUntilWaiting(i, 100));
    try std.testing.expectEqual(6, chip.nodes[i].data_stack.s);
    try std.testing.expectEqual(9, chip.nodes[i].return_stack.t);

    // code that does not come back leaves the node running
    try chip.execute(i, Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }, 0, 2));
    try std.testing.expect(!try chip.runUntilWaiting(i, 100));
    try std.testing.expectError(error.NotWaitingForCode, chip.execute(i, 0));
}

test "words are only refused for code delivered to the node" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    // node 101 waits for code on all four of its ports
    try chip.setUp(.{ .node = 101, .p = 0x1a5 }, &.{});
    const i = chip.layout.index(101).?;
    try std.testing.expect(try chip.runUntilWaiting(i, 10));
    const n = &chip.nodes[i];
    const right = n.ports[@backingInt(Direction.right)];
    const left = n.ports[@backingInt(Direction.left)];

    // a word delivered to the node's neighbour is not code for it
    right.port.?.state = .{ .delivered = .{ .side = right.side.other(), .value = 1 } };
    try chip.execute(i, 0x15555);
    try std.testing.expectEqual(right.side.other(), right.port.?.state.delivered.side);

    // but one delivered to it is, and its other reads are left as they were
    try std.testing.expect(try chip.runUntilWaiting(i, 10));
    right.port.?.state = .{ .delivered = .{ .side = right.side, .value = 1 } };
    try std.testing.expectEqual(Port.State{ .reading = left.side }, left.port.?.state);
    try std.testing.expectError(error.NotWaitingForCode, chip.execute(i, 0x15555));
    try std.testing.expectEqual(Port.State{ .reading = left.side }, left.port.?.state);
}

test "stops when interrupted" {
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(std.testing.allocator);

    var diagnostic: assembler.Diagnostic = .{};
    try chip.load(try assembler.assemble("up b! 1 !b begin again", &diagnostic));

    var input = try Console.testInput(&.{}, "");
    var buffer: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var console: Console = .{ .io = std.testing.io, .input = &input, .output = &writer };
    try chip.attachConsole(&console, 0, .up);

    // run the program up to its endless loop
    for (0..4) |_| {
        _ = chip.step();
        if (try console.service(false)) chip.wake(0);
    }
    console.interrupted.store(true, .monotonic);
    try chip.run();
    try std.testing.expectEqualStrings("\x01", writer.buffered());
}

const assembler = @import("assembler.zig");
const boot = @import("boot.zig");
const disassembler = @import("disassembler.zig");
const ga144 = @import("ga144.zig");
const Console = @import("Console.zig");
const f18 = @import("f18.zig");
const Address = f18.Address;
const Computer = f18.Computer;
const Instruction = f18.Instruction;
const Word = f18.Word;
const Opcode = @import("opcodes.zig").Opcode;
const port = @import("port.zig");
const Direction = port.Direction;
const Port = port.Port;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const expectEqual = std.testing.expectEqual;
