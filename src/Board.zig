//! What a board puts around its chips: serial ports wired to the chips'
//! pins, pull resistors, wires between pins, SERDES links between chips,
//! pins wired to chips' RESET- pins, and the jumpers that connect some of
//! them. The EVB002's is
//! `boards/evb002.zon`; other boards are described the same way, in a board
//! file read on the host side (see `parse`). A board's chips are alike, and
//! chip k's nodes are numbered k.yxx, as in `Chip.Layout`.

/// for messages, such as EVB002
name: []const u8 = "",
/// the chips' file, relative to the board's, or ga144 for the GA144
chip: []const u8 = "ga144",
/// how many chips there are of it
chips: u8 = 1,
jumpers: []const Jumper = &.{},
serial: []const Serial = &.{},
pulls: []const Pull = &.{},
wires: []const Wire = &.{},
serdes: []const Link = &.{},
resets: []const Reset = &.{},

const Board = @This();

/// A jumper, which connects the things that name it when it is on
pub const Jumper = struct {
    name: []const u8,
    /// as the board is shipped
    on: bool,
};

/// A GPIO pin of a chip, the first unless `chip` says, connected only while
/// `jumper` is on, if it names one
pub const Terminal = struct {
    chip: u8 = 0,
    node: u16,
    pin: u5,
    jumper: ?[]const u8 = null,

    pub fn ref(self: Terminal) Chip.PinRef {
        return .{ .node = number(self.chip, self.node), .pin = self.pin };
    }
};

/// A node of a chip, the first unless `chip` says
pub const Node = struct {
    chip: u8 = 0,
    node: u16,

    pub fn number(self: Node) u16 {
        return Board.number(self.chip, self.node);
    }
};

/// the node number of node `node` of chip `chip`, such as 10708 for 1.708
fn number(chip: u8, node: u16) u16 {
    return @as(u16, chip) *| Chip.Layout.chip_numbers +| node;
}

/// A serial port, such as a USB serial chip's, which sends on `rx`, the
/// chip's pin that receives, and listens on `tx`, the one that sends
pub const Serial = struct {
    name: []const u8,
    rx: Terminal,
    tx: Terminal,
    baud: u32 = 921600,
};

/// A resistor from a pin to high or low
pub const Pull = struct {
    chip: u8 = 0,
    node: u16,
    pin: u5,
    high: bool,
    jumper: ?[]const u8 = null,

    fn terminal(self: Pull) Terminal {
        return .{ .chip = self.chip, .node = self.node, .pin = self.pin, .jumper = self.jumper };
    }
};

/// A wire between two pins, through a jumper if `jumper` names one
pub const Wire = struct {
    a: Terminal,
    b: Terminal,
    jumper: ?[]const u8 = null,
};

/// A SERDES link between two SERDES nodes, usually of different chips
pub const Link = struct {
    a: Node,
    b: Node,
};

/// A pin wired to chip `chip`'s RESET- pin, which holds the chip in reset
/// while it is low, and the board's reset circuit, which holds it high
/// through a resistor while `circuit` is on, if it names a jumper. RESET-
/// has no pulldown, so without the circuit a pin's pulldown holds it low.
pub const Reset = struct {
    chip: u8,
    by: Terminal,
    circuit: ?[]const u8 = null,
};

pub const evb002: Board = @import("boards/evb002.zon");

/// A jumper set otherwise than as the board is shipped
pub const Setting = struct {
    name: []const u8,
    on: bool,
};

/// Whether jumper `name` is on, as `settings` set it or else as shipped;
/// no jumper at all is on
pub fn jumperOn(self: Board, name: ?[]const u8, settings: []const Setting) bool {
    const jumper = name orelse return true;
    var k = settings.len;
    while (k > 0) {
        k -= 1;
        if (std.mem.eql(u8, settings[k].name, jumper)) return settings[k].on;
    }
    for (self.jumpers) |j| if (std.mem.eql(u8, j.name, jumper)) return j.on;
    return false;
}

/// the serial port named `name`
pub fn serialPort(self: Board, name: []const u8) ?Serial {
    for (self.serial) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

pub const Error = error{
    /// no chips, or more than node numbers can tell apart
    InvalidChips,
    NoSuchJumper,
    JumperListedTwice,
    SerialListedTwice,
    NoSuchPin,
    NoBaud,
    /// a serial port's rx and tx on one pin
    SerialPinsTheSame,
    PullListedTwice,
    WireToItself,
    /// a wire to a serial port's pin, which the port's input would not
    /// wake the other pin's node through yet
    SerialPinWired,
    NoSuchNode,
    /// a SERDES link's node that has no SERDES: no data register, as a
    /// SERDES ROM's node has, pins, or a neighbour on its up port
    NotSerdes,
    /// a node on two SERDES links, or a link to itself
    SerdesListedTwice,
    TooManySerdes,
    NoSuchChip,
    /// a chip's RESET- wired to two pins
    ResetListedTwice,
    /// a pin wired to two chips' RESET-
    ResetPinShared,
    TooManyResets,
};

/// what `check` found at fault, for messages
pub const Fault = union(enum) {
    none,
    name: []const u8,
    pin: Chip.PinRef,
    node: u16,
    /// a SERDES link, by its nodes
    link: [2]u16,
};

/// Checks what a board file cannot say by its types alone, against the
/// chip it is for, reporting what is at fault in `fault`
pub fn check(self: Board, spec: Spec, fault: *Fault) Error!void {
    fault.* = .none;
    if (self.chips == 0 or self.chips > Chip.Layout.max_chips) return error.InvalidChips;
    for (self.jumpers, 0..) |j, k| {
        fault.* = .{ .name = j.name };
        for (self.jumpers[0..k]) |other| if (std.mem.eql(u8, other.name, j.name)) return error.JumperListedTwice;
    }
    for (self.serial, 0..) |s, k| {
        fault.* = .{ .name = s.name };
        for (self.serial[0..k]) |other| if (std.mem.eql(u8, other.name, s.name)) return error.SerialListedTwice;
        if (s.baud == 0) return error.NoBaud;
        try self.checkTerminal(spec, s.rx, fault);
        try self.checkTerminal(spec, s.tx, fault);
        if (std.meta.eql(s.rx.ref(), s.tx.ref())) return error.SerialPinsTheSame;
    }
    for (self.pulls, 0..) |p, k| {
        try self.checkTerminal(spec, p.terminal(), fault);
        for (self.pulls[0..k]) |other| if (std.meta.eql(other.terminal().ref(), p.terminal().ref())) return error.PullListedTwice;
    }
    for (self.wires) |w| {
        try self.checkTerminal(spec, w.a, fault);
        try self.checkTerminal(spec, w.b, fault);
        try self.checkJumper(w.jumper, fault);
        if (std.meta.eql(w.a.ref(), w.b.ref())) return error.WireToItself;
        for ([_]Terminal{ w.a, w.b }) |t| for (self.serial) |s| {
            fault.* = .{ .pin = t.ref() };
            if (std.meta.eql(t.ref(), s.rx.ref()) or std.meta.eql(t.ref(), s.tx.ref())) return error.SerialPinWired;
        };
    }
    if (self.serdes.len > Chip.max_serdes) return error.TooManySerdes;
    for (self.serdes, 0..) |link, k| for ([_]Node{ link.a, link.b }) |n| {
        fault.* = .{ .node = n.number() };
        if (n.chip >= self.chips or n.node >= Chip.Layout.chip_numbers) return error.NoSuchNode;
        const i = self.layout(spec).index(n.number()) orelse return error.NoSuchNode;
        if (!spec.hasData(n.node) or spec.pins(n.node) != 0 or self.layout(spec).neighbour(i, .up) != null) return error.NotSerdes;
        if (link.a.number() == link.b.number()) return error.SerdesListedTwice;
        for (self.serdes[0..k]) |other| if (other.a.number() == n.number() or other.b.number() == n.number()) return error.SerdesListedTwice;
    };
    if (self.resets.len > Chip.max_resets) return error.TooManyResets;
    for (self.resets, 0..) |r, k| {
        try self.checkTerminal(spec, r.by, fault);
        try self.checkJumper(r.circuit, fault);
        if (r.chip >= self.chips) return error.NoSuchChip;
        for (self.resets[0..k]) |other| if (other.chip == r.chip) return error.ResetListedTwice;
        // a net has one device, one chip's RESET-
        for (self.resets[0..k]) |other| if (std.meta.eql(other.by.ref(), r.by.ref())) return error.ResetPinShared;
        for (self.serial) |port| if (std.meta.eql(r.by.ref(), port.rx.ref()) or std.meta.eql(r.by.ref(), port.tx.ref())) return error.SerialPinWired;
    }
    fault.* = .none;
}

/// the layout of the board's chips, of `spec`
pub fn layout(self: Board, spec: Spec) Chip.Layout {
    var l = spec.layout();
    l.chips = self.chips;
    return l;
}

fn checkTerminal(self: Board, spec: Spec, t: Terminal, fault: *Fault) Error!void {
    fault.* = .{ .pin = t.ref() };
    if (t.chip >= self.chips or t.node >= Chip.Layout.chip_numbers) return error.NoSuchPin;
    if (self.layout(spec).index(t.ref().node) == null or t.pin > 17 or spec.pins(t.node) & @as(u18, 1) << t.pin == 0) return error.NoSuchPin;
    try self.checkJumper(t.jumper, fault);
}

fn checkJumper(self: Board, name: ?[]const u8, fault: *Fault) Error!void {
    const jumper = name orelse return;
    for (self.jumpers) |j| if (std.mem.eql(u8, j.name, jumper)) return;
    fault.* = .{ .name = jumper };
    return error.NoSuchJumper;
}

/// A UART on one of a board's serial ports
pub const Attachment = struct {
    uart: *Uart,
    port: Serial,
};

/// Puts the board around `chip`, made with its chips of the spec it was
/// checked against (`Chip.initChips`): its SERDES links, pulls, wires and
/// resets, and the UARTs on their serial ports, each through jumpers as
/// `settings` set them. The other serial ports are left unconnected, as
/// their lines idle: low on a line inverted as a USB serial chip's is,
/// which a pin's pulldown reads as. What fails is reported in `fault`.
pub fn apply(self: Board, chip: *Chip, ports: []const Attachment, settings: []const Setting, fault: *Fault) error{ NoSuchPin, TwoDevices, ConflictingPulls, NoSuchNode, NotSerdes, PortConnected, Full, NoSuchChip }!void {
    for (self.serdes) |link| {
        fault.* = .{ .link = .{ link.a.number(), link.b.number() } };
        try chip.attachSerdes(link.a.number(), link.b.number());
    }
    for (self.pulls) |p| if (self.jumperOn(p.jumper, settings)) {
        fault.* = .{ .pin = p.terminal().ref() };
        try chip.pull(p.terminal().ref(), p.high);
    };
    for (self.wires) |w| if (self.jumperOn(w.jumper, settings) and self.jumperOn(w.a.jumper, settings) and self.jumperOn(w.b.jumper, settings)) {
        fault.* = .{ .pin = w.b.ref() };
        try chip.wire(w.a.ref(), w.b.ref());
    };
    for (self.resets) |r| if (self.jumperOn(r.by.jumper, settings)) {
        fault.* = .{ .pin = r.by.ref() };
        try chip.attachReset(r.chip, r.by.ref(), self.jumperOn(r.circuit, settings));
    };
    for (ports) |attachment| {
        const s = attachment.port;
        fault.* = .{ .name = s.name };
        try chip.attachUartPins(
            attachment.uart,
            if (self.jumperOn(s.rx.jumper, settings)) s.rx.ref() else null,
            if (self.jumperOn(s.tx.jumper, settings)) s.tx.ref() else null,
        );
    }
}

/// Parses a board file, allocating what it names in `arena`. On
/// `error.ParseZon`, `diagnostics` describes what is wrong.
pub fn parse(gpa: Allocator, arena: Allocator, source: [:0]const u8, diagnostics: *std.zon.parse.Diagnostics) error{ OutOfMemory, ParseZon }!Board {
    return std.zon.parse.fromSlice(Board, .{ .gpa = gpa, .arena = arena, .source = source, .diagnostics = diagnostics });
}

test evb002 {
    var fault: Fault = .none;
    try evb002.check(.ga144, &fault);
    try std.testing.expectEqualStrings("ga144", evb002.chip);
    try std.testing.expect(evb002.jumperOn("J26", &.{}));
    try std.testing.expect(!evb002.jumperOn("J26", &.{.{ .name = "J26", .on = false }}));
    try std.testing.expectEqual(708, evb002.serialPort("A").?.rx.node);
    try std.testing.expectEqual(100, evb002.serialPort("B").?.tx.node);
    try std.testing.expectEqual(10708, evb002.serialPort("C").?.rx.ref().node);
}

test "the EVB002's board file parses at run time as at compile time" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const board = try parse(std.testing.allocator, arena_state.allocator(), @embedFile("boards/evb002.zon"), &diagnostics);
    try std.testing.expectEqualDeep(evb002, board);
}

test check {
    var fault: Fault = .none;
    const two: Board = .{ .jumpers = &.{ .{ .name = "J1", .on = true }, .{ .name = "J1", .on = false } } };
    try std.testing.expectError(error.JumperListedTwice, two.check(.ga144, &fault));
    const pin: Board = .{ .pulls = &.{.{ .node = 404, .pin = 17, .high = true }} };
    try std.testing.expectError(error.NoSuchPin, pin.check(.ga144, &fault));
    try std.testing.expectEqual(Fault{ .pin = .{ .node = 404, .pin = 17 } }, fault);
    const jumper: Board = .{ .pulls = &.{.{ .node = 705, .pin = 17, .high = true, .jumper = "J9" }} };
    try std.testing.expectError(error.NoSuchJumper, jumper.check(.ga144, &fault));
    const same: Board = .{ .serial = &.{.{ .name = "A", .rx = .{ .node = 708, .pin = 17 }, .tx = .{ .node = 708, .pin = 17 } }} };
    try std.testing.expectError(error.SerialPinsTheSame, same.check(.ga144, &fault));
    const pulled: Board = .{ .pulls = &.{ .{ .node = 705, .pin = 17, .high = true }, .{ .node = 705, .pin = 17, .high = false } } };
    try std.testing.expectError(error.PullListedTwice, pulled.check(.ga144, &fault));
    const itself: Board = .{ .wires = &.{.{ .a = .{ .node = 100, .pin = 17 }, .b = .{ .node = 100, .pin = 17 } }} };
    try std.testing.expectError(error.WireToItself, itself.check(.ga144, &fault));
    const wired: Board = .{
        .serial = &.{.{ .name = "A", .rx = .{ .node = 708, .pin = 17 }, .tx = .{ .node = 708, .pin = 1 } }},
        .wires = &.{.{ .a = .{ .node = 100, .pin = 17 }, .b = .{ .node = 708, .pin = 17 } }},
    };
    try std.testing.expectError(error.SerialPinWired, wired.check(.ga144, &fault));
    try std.testing.expectError(error.InvalidChips, (Board{ .chips = 0 }).check(.ga144, &fault));
    const other_chip: Board = .{ .pulls = &.{.{ .chip = 1, .node = 705, .pin = 17, .high = true }} };
    try std.testing.expectError(error.NoSuchPin, other_chip.check(.ga144, &fault));
    try std.testing.expectEqual(Fault{ .pin = .{ .node = 10705, .pin = 17 } }, fault);
    try (Board{ .chips = 2, .pulls = other_chip.pulls }).check(.ga144, &fault);
    const not_serdes: Board = .{ .chips = 2, .serdes = &.{.{ .a = .{ .node = 701 }, .b = .{ .chip = 1, .node = 708 } }} };
    try std.testing.expectError(error.NotSerdes, not_serdes.check(.ga144, &fault));
    try std.testing.expectEqual(Fault{ .node = 10708 }, fault);
    const no_chip: Board = .{ .chips = 2, .serdes = &.{.{ .a = .{ .node = 701 }, .b = .{ .chip = 2, .node = 1 } }} };
    try std.testing.expectError(error.NoSuchNode, no_chip.check(.ga144, &fault));
    // a node number past a chip's, which would be another chip's
    const past: Board = .{ .chips = 2, .pulls = &.{.{ .node = 10705, .pin = 17, .high = true }} };
    try std.testing.expectError(error.NoSuchPin, past.check(.ga144, &fault));
    const twice: Board = .{ .chips = 3, .serdes = &.{ .{ .a = .{ .node = 701 }, .b = .{ .chip = 1, .node = 1 } }, .{ .a = .{ .chip = 2, .node = 1 }, .b = .{ .node = 701 } } } };
    try std.testing.expectError(error.SerdesListedTwice, twice.check(.ga144, &fault));
    try std.testing.expectEqual(Fault{ .node = 701 }, fault);
}

test "the EVB002 sends what node 708 sends on USB port A" {
    var chip: Chip = try .initChips(std.testing.allocator, .ga144, evb002.chips);
    defer chip.deinit(std.testing.allocator);
    var programs: [1]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes(test_uart, &programs, &diagnostic)) |program| try chip.load(program);

    var buffer: [32]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    var uart: Uart = .init(921600, &output);
    var fault: Fault = .none;
    try evb002.apply(&chip, &.{.{ .uart = &uart, .port = evb002.serialPort("A").? }}, &.{}, &fault);
    try chip.run();
    try std.testing.expectEqualStrings("Hi\n", output.buffered());

    // NO BOOT pulls 705.17 high; the flash's and SRAM's chip enables too
    try std.testing.expect(chip.node(705).?.pinHigh(1 << 17));
    try std.testing.expect(chip.node(705).?.pinHigh(1 << 3));
    try std.testing.expect(chip.node(8).?.pinHigh(1 << 1) and chip.node(8).?.pinHigh(1 << 3));
}

test "the EVB002's USB port B sends to node 200's pin 17" {
    var chip: Chip = try .initChips(std.testing.allocator, .ga144, evb002.chips);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    // node 200, on the west edge, waits on pin 17 through left
    try chip.load(try assembler.assemble("node 200 : main left a! @ drop right b! @b", &diagnostic));

    var output: std.Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &output);
    uart.preload = "\x00";
    uart.arrived = 5_000_000;
    var fault: Fault = .none;
    try evb002.apply(&chip, &.{.{ .uart = &uart, .port = evb002.serialPort("B").? }}, &.{}, &fault);
    try chip.run();
    const n = chip.node(200).?;
    try std.testing.expect(!n.waitsOnPin());
    try std.testing.expect(n.time >= 5_000_000 and n.time < 5_100_000);
}

test "a jumper off leaves its line unconnected" {
    var chip: Chip = try .initChips(std.testing.allocator, .ga144, evb002.chips);
    defer chip.deinit(std.testing.allocator);
    var programs: [1]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes(test_uart, &programs, &diagnostic)) |program| try chip.load(program);

    var buffer: [32]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    var uart: Uart = .init(921600, &output);
    var fault: Fault = .none;
    try evb002.apply(&chip, &.{.{ .uart = &uart, .port = evb002.serialPort("A").? }}, &.{ .{ .name = "J23.3-4", .on = false }, .{ .name = "J26", .on = false } }, &fault);
    try chip.run();
    try std.testing.expectEqualStrings("", output.buffered());
    try std.testing.expect(!chip.node(705).?.pinHigh(1 << 17));
}

test "the EVB002's USB port C sends what target node 708 sends" {
    var chip: Chip = try .initChips(std.testing.allocator, .ga144, evb002.chips);
    defer chip.deinit(std.testing.allocator);
    var programs: [1]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes("node 1.708" ++ test_uart["node 708".len..], &programs, &diagnostic)) |program| try chip.load(program);

    var buffer: [32]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    var uart: Uart = .init(921600, &output);
    var fault: Fault = .none;
    try evb002.apply(&chip, &.{.{ .uart = &uart, .port = evb002.serialPort("C").? }}, &.{}, &fault);
    try chip.run();
    try std.testing.expectEqualStrings("Hi\n", output.buffered());
    // the target's 705.17 is pulled up, J26 or not
    try std.testing.expect(chip.node(10705).?.pinHigh(1 << 17));
}

test "the EVB002's USB ports A and C at once" {
    var chip: Chip = try .initChips(std.testing.allocator, .ga144, evb002.chips);
    defer chip.deinit(std.testing.allocator);
    var programs: [2]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes(test_uart ++ "\n" ++ "node 1.708" ++ test_uart["node 708".len..], &programs, &diagnostic)) |program| try chip.load(program);

    var buffers: [2][32]u8 = undefined;
    var outputs: [2]std.Io.Writer = .{ .fixed(&buffers[0]), .fixed(&buffers[1]) };
    var uarts: [2]Uart = .{ .init(921600, &outputs[0]), .init(921600, &outputs[1]) };
    var fault: Fault = .none;
    try evb002.apply(&chip, &.{
        .{ .uart = &uarts[0], .port = evb002.serialPort("A").? },
        .{ .uart = &uarts[1], .port = evb002.serialPort("C").? },
    }, &.{}, &fault);
    try chip.run();
    for (outputs) |output| try std.testing.expectEqualStrings("Hi\n", output.buffered());
}

test "the EVB002's J35 joins the chips' 300.17, and SERDES their 701 and 001" {
    for ([_]bool{ true, false }) |on| {
        var chip: Chip = try .initChips(std.testing.allocator, .ga144, evb002.chips);
        defer chip.deinit(std.testing.allocator);
        var programs: [4]assembler.Program = undefined;
        var diagnostic: assembler.Diagnostic = .{};
        // the host's 300 drives its pin 17 high, and the target's waits for
        // it through left; the host's 701 sends 5 to the target's 001
        for (try assembler.assembleNodes(
            \\node 300 io b! 0x30000 !b right b! @b
            \\node 1.300 left b! @b right b! @b
            \\node 701 0x141 a! 5 ! io b! 0x20000 !b left b! @b
            \\node 1.001 up b! @b left b! @b
        , &programs, &diagnostic)) |program| try chip.load(program);
        var fault: Fault = .none;
        try evb002.apply(&chip, &.{}, &.{.{ .name = "J35", .on = on }}, &fault);
        try chip.run();
        // past the wait on its pin, waiting on right, or still on left
        try std.testing.expectEqual(@as(u9, if (on) 0x1d5 else 0x175), chip.node(10300).?.b);
        try std.testing.expectEqual(5, chip.node(10001).?.data_stack.t);
    }
}

test "the EVB002's host 500 resets the target through J22" {
    var roms: [144]ga144.NodeRom = undefined;
    const rom = try testRom(&roms);
    {
        var chip: Chip = try .initChips(std.testing.allocator, .ga144, evb002.chips);
        defer chip.deinit(std.testing.allocator);
        try chip.loadRom(rom);
        // 1.708 runs a program until 500 drives 500.17 low at about 2.4 us,
        // and high at about 4.8 us
        var programs: [2]assembler.Program = undefined;
        var diagnostic: assembler.Diagnostic = .{};
        for (try assembler.assembleNodes(
            \\node 500 io b! 999 for unext 0x20000 !b 999 for unext 0x30000 !b right b! @b
            \\node 1.708 7 right b! @b
        , &programs, &diagnostic)) |program| try chip.load(program);
        var fault: Fault = .none;
        try evb002.apply(&chip, &.{}, &.{}, &fault);
        try chip.run();
        try std.testing.expect(!chip.isHeld(1));
        // back in its ROM, waiting at cold for a boot stream on its pin
        const n = chip.node(10708).?;
        try std.testing.expect(n.waitsOnPin() and n.word_address.rom);
        try std.testing.expectEqual(0, n.data_stack.t);
        try std.testing.expect(n.time >= 4_800_000);
    }
    {
        // without the reset circuit, 500.17's pulldown holds RESET- low
        var chip: Chip = try .initChips(std.testing.allocator, .ga144, evb002.chips);
        defer chip.deinit(std.testing.allocator);
        try chip.loadRom(rom);
        var fault: Fault = .none;
        try evb002.apply(&chip, &.{}, &.{.{ .name = "J22.5-6", .on = false }}, &fault);
        try chip.run();
        try std.testing.expect(chip.isHeld(1));
    }
}

test "a reset is checked" {
    var fault: Fault = .none;
    const no_chip: Board = .{ .resets = &.{.{ .chip = 1, .by = .{ .node = 500, .pin = 17 } }} };
    try std.testing.expectError(error.NoSuchChip, no_chip.check(.ga144, &fault));
    const twice: Board = .{ .chips = 2, .resets = &.{ .{ .chip = 1, .by = .{ .node = 500, .pin = 17 } }, .{ .chip = 1, .by = .{ .node = 600, .pin = 17 } } } };
    try std.testing.expectError(error.ResetListedTwice, twice.check(.ga144, &fault));
    const no_pin: Board = .{ .chips = 2, .resets = &.{.{ .chip = 1, .by = .{ .node = 404, .pin = 17 } }} };
    try std.testing.expectError(error.NoSuchPin, no_pin.check(.ga144, &fault));
    const shared: Board = .{ .chips = 3, .resets = &.{ .{ .chip = 1, .by = .{ .node = 500, .pin = 17 } }, .{ .chip = 2, .by = .{ .node = 500, .pin = 17 } } } };
    try std.testing.expectError(error.ResetPinShared, shared.check(.ga144, &fault));
    const serial: Board = .{
        .chips = 2,
        .serial = &.{.{ .name = "A", .rx = .{ .node = 708, .pin = 17 }, .tx = .{ .node = 708, .pin = 1 } }},
        .resets = &.{.{ .chip = 1, .by = .{ .node = 708, .pin = 1 } }},
    };
    try std.testing.expectError(error.SerialPinWired, serial.check(.ga144, &fault));
    const many: Board = .{ .chips = 6, .resets = &.{
        .{ .chip = 1, .by = .{ .node = 100, .pin = 17 } }, .{ .chip = 2, .by = .{ .node = 200, .pin = 17 } },
        .{ .chip = 3, .by = .{ .node = 500, .pin = 17 } }, .{ .chip = 4, .by = .{ .node = 600, .pin = 17 } },
        .{ .chip = 5, .by = .{ .node = 715, .pin = 17 } },
    } };
    try std.testing.expectError(error.TooManyResets, many.check(.ga144, &fault));
}

/// prints Hi on node 708's pins 17 and 1, as examples/uart.ga does
const test_uart =
    \\node 708
    \\: main io b! 'message a! @+ for @+ send next right a! @
    \\: bit ( level ) !b 428 for unext ;
    \\: send ( c ) 3 bit 7 for dup 1 and 1 xor 2 + bit 2/ next drop 2 bit ;
    \\: message 2 , "Hi" 10 ,
;

const assembler = @import("assembler.zig");
const ga144 = @import("ga144.zig");
const testRom = @import("rom.zig").testRom;
const Chip = @import("Chip.zig");
const Spec = @import("Spec.zig");
const Uart = @import("Uart.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
