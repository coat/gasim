//! What a board puts around its chip: serial ports wired to the chip's pins,
//! pull resistors, wires between pins, and the jumpers that connect some of
//! them. The EVB002's is `boards/evb002.zon`; other boards are described the
//! same way, in a board file read on the host side (see `parse`). A board
//! has one chip for now.

/// for messages, such as EVB002
name: []const u8 = "",
/// the chip's file, relative to the board's, or ga144 for the GA144
chip: []const u8 = "ga144",
jumpers: []const Jumper = &.{},
serial: []const Serial = &.{},
pulls: []const Pull = &.{},
wires: []const Wire = &.{},

const Board = @This();

/// A jumper, which connects the things that name it when it is on
pub const Jumper = struct {
    name: []const u8,
    /// as the board is shipped
    on: bool,
};

/// A GPIO pin of the chip, connected only while `jumper` is on, if it names
/// one
pub const Terminal = struct {
    node: u16,
    pin: u5,
    jumper: ?[]const u8 = null,

    fn ref(self: Terminal) Chip.PinRef {
        return .{ .node = self.node, .pin = self.pin };
    }
};

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
    node: u16,
    pin: u5,
    high: bool,
    jumper: ?[]const u8 = null,
};

/// A wire between two pins, through a jumper if `jumper` names one
pub const Wire = struct {
    a: Terminal,
    b: Terminal,
    jumper: ?[]const u8 = null,
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
};

/// what `check` found at fault, for messages
pub const Fault = union(enum) {
    none,
    name: []const u8,
    pin: Chip.PinRef,
};

/// Checks what a board file cannot say by its types alone, against the
/// chip it is for, reporting what is at fault in `fault`
pub fn check(self: Board, spec: Spec, fault: *Fault) Error!void {
    fault.* = .none;
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
        if (s.rx.node == s.tx.node and s.rx.pin == s.tx.pin) return error.SerialPinsTheSame;
    }
    for (self.pulls, 0..) |p, k| {
        try self.checkTerminal(spec, .{ .node = p.node, .pin = p.pin, .jumper = p.jumper }, fault);
        for (self.pulls[0..k]) |other| if (other.node == p.node and other.pin == p.pin) return error.PullListedTwice;
    }
    for (self.wires) |w| {
        try self.checkTerminal(spec, w.a, fault);
        try self.checkTerminal(spec, w.b, fault);
        try self.checkJumper(w.jumper, fault);
        if (w.a.node == w.b.node and w.a.pin == w.b.pin) return error.WireToItself;
        for ([_]Terminal{ w.a, w.b }) |t| for (self.serial) |s| {
            fault.* = .{ .pin = t.ref() };
            if (t.node == s.rx.node and t.pin == s.rx.pin or t.node == s.tx.node and t.pin == s.tx.pin) return error.SerialPinWired;
        };
    }
    fault.* = .none;
}

fn checkTerminal(self: Board, spec: Spec, t: Terminal, fault: *Fault) Error!void {
    fault.* = .{ .pin = t.ref() };
    if (spec.layout().index(t.node) == null or t.pin > 17 or spec.pins(t.node) & @as(u18, 1) << t.pin == 0) return error.NoSuchPin;
    try self.checkJumper(t.jumper, fault);
}

fn checkJumper(self: Board, name: ?[]const u8, fault: *Fault) Error!void {
    const jumper = name orelse return;
    for (self.jumpers) |j| if (std.mem.eql(u8, j.name, jumper)) return;
    fault.* = .{ .name = jumper };
    return error.NoSuchJumper;
}

/// Puts the board around `chip`, whose spec it was checked against: its
/// pulls and wires, and `uart` on serial port `port`, each through jumpers
/// as `settings` set them. The other serial ports are left unconnected, as
/// their lines idle: low on a line inverted as a USB serial chip's is,
/// which a pin's pulldown reads as.
/// What fails is reported in `fault`.
pub fn apply(self: Board, chip: *Chip, uart: ?*Uart, port: ?Serial, settings: []const Setting, fault: *Fault) error{ NoSuchPin, TwoDevices, ConflictingPulls }!void {
    for (self.pulls) |p| if (self.jumperOn(p.jumper, settings)) {
        fault.* = .{ .pin = .{ .node = p.node, .pin = p.pin } };
        try chip.pull(.{ .node = p.node, .pin = p.pin }, p.high);
    };
    for (self.wires) |w| if (self.jumperOn(w.jumper, settings) and self.jumperOn(w.a.jumper, settings) and self.jumperOn(w.b.jumper, settings)) {
        fault.* = .{ .pin = w.b.ref() };
        try chip.wire(w.a.ref(), w.b.ref());
    };
    const u = uart orelse return;
    const s = port orelse return;
    fault.* = .{ .name = s.name };
    try chip.attachUartPins(
        u,
        if (self.jumperOn(s.rx.jumper, settings)) s.rx.ref() else null,
        if (self.jumperOn(s.tx.jumper, settings)) s.tx.ref() else null,
    );
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
}

test "the EVB002 sends what node 708 sends on USB port A" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var programs: [1]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes(test_uart, &programs, &diagnostic)) |program| try chip.load(program);

    var buffer: [32]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    var uart: Uart = .init(921600, &output);
    var fault: Fault = .none;
    try evb002.apply(&chip, &uart, evb002.serialPort("A"), &.{}, &fault);
    try chip.run();
    try std.testing.expectEqualStrings("Hi\n", output.buffered());

    // NO BOOT pulls 705.17 high; the flash's and SRAM's chip enables too
    try std.testing.expect(chip.node(705).?.pinHigh(1 << 17));
    try std.testing.expect(chip.node(705).?.pinHigh(1 << 3));
    try std.testing.expect(chip.node(8).?.pinHigh(1 << 1) and chip.node(8).?.pinHigh(1 << 3));
}

test "the EVB002's USB port B sends to node 200's pin 17" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var diagnostic: assembler.Diagnostic = .{};
    // node 200, on the west edge, waits on pin 17 through left
    try chip.load(try assembler.assemble("node 200 : main left a! @ drop right b! @b", &diagnostic));

    var output: std.Io.Writer = .fixed(&.{});
    var uart: Uart = .init(921600, &output);
    uart.preload = "\x00";
    uart.arrived = 5_000_000;
    var fault: Fault = .none;
    try evb002.apply(&chip, &uart, evb002.serialPort("B"), &.{}, &fault);
    try chip.run();
    const n = chip.node(200).?;
    try std.testing.expect(!n.waitsOnPin());
    try std.testing.expect(n.time >= 5_000_000 and n.time < 5_100_000);
}

test "a jumper off leaves its line unconnected" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var programs: [1]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes(test_uart, &programs, &diagnostic)) |program| try chip.load(program);

    var buffer: [32]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    var uart: Uart = .init(921600, &output);
    var fault: Fault = .none;
    try evb002.apply(&chip, &uart, evb002.serialPort("A"), &.{ .{ .name = "J23.3-4", .on = false }, .{ .name = "J26", .on = false } }, &fault);
    try chip.run();
    try std.testing.expectEqualStrings("", output.buffered());
    try std.testing.expect(!chip.node(705).?.pinHigh(1 << 17));
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
const Chip = @import("Chip.zig");
const Spec = @import("Spec.zig");
const Uart = @import("Uart.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
