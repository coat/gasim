//! What a chip is made of: the size of its array, and for each node that is
//! not a basic node with no pins, which ROM it has, its GPIO pins and where
//! it starts after reset. The GA144's is
//! `chips/ga144.zon`; other chips are described the same way, in a chip
//! file read on the host side (see `parse`).

/// for messages, such as GA144
name: []const u8 = "",
rows: u8,
columns: u8,
/// the nodes that are not basic nodes with no pins, by node number
nodes: []const Node = &.{},

const Spec = @This();

pub const Node = struct {
    node: u16,
    rom: roms.RomType = .basic,
    /// GPIO pins, out of 17, 5, 3 and 1. Pin 17 is also a wakeup pin, read
    /// through up on the top and bottom rows and left on the others, if
    /// that port faces off the array.
    pins: []const u5 = &.{},
    /// the word of its ROM it starts at after reset, rather than waiting
    /// for code on its ports
    reset: ?Reset = null,
};

pub const Reset = enum { cold, warm };

pub const ga144: Spec = @import("chips/ga144.zon");

pub fn layout(self: Spec) Chip.Layout {
    return .{ .rows = self.rows, .columns = self.columns };
}

/// what node `number` has, a basic node with no pins if it is not listed
pub fn node(self: Spec, number: u16) Node {
    for (self.nodes) |n| if (n.node == number) return n;
    return .{ .node = number };
}

/// io bits of the GPIO pins of node `number`
pub fn pins(self: Spec, number: u16) u18 {
    var bits: u18 = 0;
    for (self.node(number).pins) |pin| bits |= @as(u18, 1) << pin;
    return bits;
}

/// address of a named ROM word in node `number`
pub fn romWord(self: Spec, number: u16, name: []const u8) ?u10 {
    return roms.romWordOf(self.node(number).rom, name);
}

/// where node `number` starts after reset, in its ROM, if it does
pub fn resetAddress(self: Spec, number: u16) ?u9 {
    const reset = self.node(number).reset orelse return null;
    return @intCast(self.romWord(number, @tagName(reset)).?);
}

/// whether node `number` has a data register, which a SERDES node has, as
/// its ROM writes to it
pub fn hasData(self: Spec, number: u16) bool {
    return self.node(number).rom == .serdes_boot;
}

pub const Error = error{
    InvalidSize,
    NoSuchNode,
    NodeListedTwice,
    InvalidPin,
    PinListedTwice,
    NoSuchResetWord,
};

/// Checks what a chip file cannot say by its types alone, reporting the
/// node at fault, if one is, in `bad_node`
pub fn check(self: Spec, bad_node: *?u16) Error!void {
    bad_node.* = null;
    if (self.rows == 0 or self.rows > 100 or self.columns == 0 or self.columns > 100) return error.InvalidSize;
    for (self.nodes, 0..) |n, k| {
        bad_node.* = n.node;
        if (self.layout().index(n.node) == null) return error.NoSuchNode;
        for (self.nodes[0..k]) |other| if (other.node == n.node) return error.NodeListedTwice;
        for (n.pins, 0..) |pin, p| {
            switch (pin) {
                17, 5, 3, 1 => {},
                else => return error.InvalidPin,
            }
            if (std.mem.indexOfScalar(u5, n.pins[0..p], pin) != null) return error.PinListedTwice;
        }
        if (n.reset) |reset| if (roms.romWordOf(n.rom, @tagName(reset)) == null) return error.NoSuchResetWord;
    }
    bad_node.* = null;
}

/// Parses a chip file, allocating what it names in `arena`. On
/// `error.ParseZon`, `diagnostics` describes what is wrong.
pub fn parse(gpa: Allocator, arena: Allocator, source: [:0]const u8, diagnostics: *std.zon.parse.Diagnostics) error{ OutOfMemory, ParseZon }!Spec {
    return std.zon.parse.fromSlice(Spec, .{ .gpa = gpa, .arena = arena, .source = source, .diagnostics = diagnostics });
}

test ga144 {
    var bad_node: ?u16 = null;
    try ga144.check(&bad_node);
    try std.testing.expectEqual(Chip.Layout.ga144, ga144.layout());
    try std.testing.expectEqual(.async_boot, ga144.node(708).rom);
    try std.testing.expectEqual(1 << 17 | 1 << 1, ga144.pins(708));
    try std.testing.expectEqual(0xaa, ga144.resetAddress(708));
    try std.testing.expectEqual(0xa9, ga144.resetAddress(200));
    try std.testing.expectEqual(null, ga144.resetAddress(404));
    try std.testing.expect(ga144.hasData(1) and ga144.hasData(701) and !ga144.hasData(708));
    try std.testing.expectEqual(Node{ .node = 404 }, ga144.node(404));
    try std.testing.expectEqual(0xaa, ga144.romWord(708, "cold"));
    try std.testing.expectEqual(null, ga144.romWord(404, "cold"));
}

test "the GA144's chip file parses at run time as at compile time" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const spec = try parse(std.testing.allocator, arena_state.allocator(), @embedFile("chips/ga144.zon"), &diagnostics);
    try std.testing.expectEqualDeep(ga144, spec);
}

test parse {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const spec = try parse(std.testing.allocator, arena_state.allocator(),
        \\.{
        \\    .name = "two by two",
        \\    .rows = 2,
        \\    .columns = 2,
        \\    .nodes = .{
        \\        .{ .node = 101, .rom = .async_boot, .pins = .{ 17, 1 }, .reset = .cold },
        \\    },
        \\}
    , &diagnostics);
    var bad_node: ?u16 = null;
    try spec.check(&bad_node);
    try std.testing.expectEqual(1 << 17 | 1 << 1, spec.pins(101));
    try std.testing.expectEqual(0, spec.pins(0));

    try std.testing.expectError(error.ParseZon, parse(std.testing.allocator, arena_state.allocator(), ".{ .rows = 2 }", &diagnostics));
}

test check {
    var bad_node: ?u16 = null;
    try std.testing.expectError(error.InvalidSize, (Spec{ .rows = 0, .columns = 2 }).check(&bad_node));
    try std.testing.expectError(error.NoSuchNode, (Spec{ .rows = 2, .columns = 2, .nodes = &.{.{ .node = 2 }} }).check(&bad_node));
    try std.testing.expectEqual(2, bad_node);
    try std.testing.expectError(error.NodeListedTwice, (Spec{ .rows = 2, .columns = 2, .nodes = &.{ .{ .node = 1 }, .{ .node = 1 } } }).check(&bad_node));
    try std.testing.expectError(error.InvalidPin, (Spec{ .rows = 2, .columns = 2, .nodes = &.{.{ .node = 1, .pins = &.{2} }} }).check(&bad_node));
    try std.testing.expectError(error.PinListedTwice, (Spec{ .rows = 2, .columns = 2, .nodes = &.{.{ .node = 1, .pins = &.{ 17, 1, 17 } }} }).check(&bad_node));
    // a basic ROM has warm but no cold
    try (Spec{ .rows = 2, .columns = 2, .nodes = &.{.{ .node = 1, .reset = .warm }} }).check(&bad_node);
    try std.testing.expectError(error.NoSuchResetWord, (Spec{ .rows = 2, .columns = 2, .nodes = &.{.{ .node = 1, .reset = .cold }} }).check(&bad_node));
}

const Chip = @import("Chip.zig");
const roms = @import("ga144.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
