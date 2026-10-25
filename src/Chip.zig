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

/// the console, and the index of the node it is attached to
console: ?struct { device: *Console, index: u16 } = null,
/// words fed into a node, such as a boot stream
feeder: ?struct { device: *Feeder, index: u16 } = null,

const Chip = @This();

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
    const ports = try gpa.alloc(Port, rows * (columns - 1) + (rows - 1) * columns);
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
    // nodes woken during this round run in the next one
    for (0..self.queue_len) |_| {
        const i = self.queue[self.queue_head];
        self.queue_head = (self.queue_head + 1) % self.queue.len;
        self.queue_len -= 1;
        self.queued[i] = false;
        self.stepNode(i);
    }
    return true;
}

/// Steps a node and wakes the neighbours on any port it changed, since a
/// suspended node can only continue once one of its ports changes.
fn stepNode(self: *Chip, i: u16) void {
    const n = &self.nodes[i];
    var before: [4]Port.State = undefined;
    for (n.ports, &before) |link, *state| state.* = if (link.port) |p| p.state else .idle;

    n.step();
    if (!n.suspended) self.wake(i);

    for (n.ports, before, 0..) |link, state, d| {
        const p = link.port orelse continue;
        if (std.meta.eql(state, p.state)) continue;
        if (self.layout.neighbour(i, @fromBackingInt(@intCast(d)))) |other| self.wake(other);
    }
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

/// Runs until every node is suspended on something the console cannot
/// complete, or the console is interrupted.
pub fn run(self: *Chip) !void {
    const console = self.console orelse {
        while (self.feed() or self.step()) {}
        return;
    };
    const output = console.device.output;
    var quiet_rounds: u16 = 0;
    while (!console.device.interrupted.load(.monotonic)) {
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
