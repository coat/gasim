//! A chip and what is around it as a file, to go on from later in another
//! process. A file starts with what the machine is, to build it again as it
//! was: `Machine`. What it holds after that goes over the fields of each
//! type, so that a field added to a node is saved with no more said here. A
//! field that does not belong, such as a pointer a new process makes for
//! itself, is named in the type's `snapshot_skip`, and a pointer that is not
//! does not compile. The file's first words hash those types, so that a file
//! that a gasim with other fields wrote is refused rather than misread.

pub const Error = Io.Writer.Error || Io.Reader.Error || Allocator.Error || error{
    /// not a snapshot, or one cut short
    Invalid,
    /// a snapshot of other fields, from another gasim
    OtherVersion,
    /// the machine built from it does not have what it holds
    OtherMachine,
};

const magic = "gasimsnp";

/// what `write` writes by hand, beyond the fields of types the hash covers:
/// raise it when that changes
const format_version = 2;

/// What to build again before reading a chip's state: what chip or board it
/// was, and how its devices were attached
pub const Machine = struct {
    /// the board's name, as --board gives it, and its file unless it is the
    /// EVB002's, if there is a board
    board: []const u8 = "",
    board_text: []const u8 = "",
    /// the chip's file, or its size if it is only that, or the GA144
    chip_text: []const u8 = "",
    rows: u8 = 0,
    columns: u8 = 0,
    settings: []const Setting = &.{},
    console_node: u16 = 0,
    console_port: Direction = .up,
    uart_node: ?u16 = null,
    uart_baud: u32 = 921600,
    usb: []const u8 = "",
    /// a boot stream was being fed to node 001, or clocked into node 300,
    /// and the board's flash is attached
    feeder: bool = false,
    sync: bool = false,
    flash: bool = false,
    /// the board's SRAM is attached
    sram: bool = false,

    pub const Setting = struct { name: []const u8, on: bool };
};

/// the hash of the fields a type is saved with
pub fn typeHash(comptime T: type) u64 {
    @setEvalBranchQuota(2_000_000);
    return comptime hash: {
        var h: std.hash.Fnv1a_64 = .init();
        hashType(&h, T, 0);
        break :hash h.final();
    };
}

fn hashType(comptime h: *std.hash.Fnv1a_64, comptime T: type, comptime depth: usize) void {
    if (depth > 12) return;
    switch (@typeInfo(T)) {
        .int, .bool, .void => h.update(@typeName(T)),
        .@"enum" => |e| {
            h.update(@typeName(e.tag_type));
            for (e.field_names) |name| h.update(name);
        },
        .optional => |o| {
            h.update("?");
            hashType(h, o.child, depth + 1);
        },
        .array => |a| {
            h.update(std.fmt.comptimePrint("[{d}]", .{a.len}));
            hashType(h, a.child, depth + 1);
        },
        .pointer => |p| {
            h.update("[]");
            hashType(h, p.child, depth + 1);
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") h.update(@typeName(s.backing_integer.?));
            for (s.field_names, s.field_types) |name, field| if (!skipped(T, name)) {
                h.update(name);
                hashType(h, field, depth + 1);
            };
        },
        .@"union" => |u| {
            for (u.field_names, u.field_types) |name, field| {
                h.update(name);
                hashType(h, field, depth + 1);
            }
        },
        else => @compileError("no way to save a " ++ @typeName(T)),
    }
}

fn skipped(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, "snapshot_skip")) return false;
    for (T.snapshot_skip) |skip| if (std.mem.eql(u8, skip, name)) return true;
    return false;
}

/// Writes a value, field by field
pub fn put(writer: *Io.Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => |info| {
            // the same on any machine
            const Bytes = @Int(.unsigned, if (T == usize) 64 else (info.bits + 7) / 8 * 8);
            const U = @Int(.unsigned, info.bits);
            try writer.writeInt(Bytes, @as(U, @bitCast(value)), .little);
        },
        .bool => try writer.writeByte(@intFromBool(value)),
        .void => {},
        .@"enum" => try put(writer, @backingInt(value)),
        .optional => if (value) |v| {
            try writer.writeByte(1);
            try put(writer, v);
        } else try writer.writeByte(0),
        .array => for (value) |item| try put(writer, item),
        .pointer => |p| {
            if (p.size != .slice) @compileError("a pointer in a snapshot: " ++ @typeName(T));
            try writer.writeInt(u64, value.len, .little);
            for (value) |item| try put(writer, item);
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return put(writer, @as(s.backing_integer.?, @bitCast(value)));
            inline for (s.field_names) |name| if (!comptime skipped(T, name)) try put(writer, @field(value, name));
        },
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("an untagged union in a snapshot: " ++ @typeName(T));
            const tag: Tag = value;
            try put(writer, tag);
            switch (value) {
                inline else => |payload| try put(writer, payload),
            }
        },
        else => @compileError("no way to save a " ++ @typeName(T)),
    }
}

/// Reads a value into `out`, leaving the fields that are not saved as they
/// are, with slices in `arena`
pub fn get(reader: *Io.Reader, arena: Allocator, out: anytype) Error!void {
    const T = @typeInfo(@TypeOf(out)).pointer.child;
    switch (@typeInfo(T)) {
        .int => |info| {
            const Bytes = @Int(.unsigned, if (T == usize) 64 else (info.bits + 7) / 8 * 8);
            const U = @Int(.unsigned, info.bits);
            const value = try reader.takeInt(Bytes, .little);
            out.* = @bitCast(std.math.cast(U, value) orelse return error.Invalid);
        },
        .bool => out.* = try reader.takeByte() != 0,
        .void => {},
        .@"enum" => |e| {
            var tag: e.tag_type = undefined;
            try get(reader, arena, &tag);
            out.* = std.enums.fromInt(T, tag) orelse return error.Invalid;
        },
        .optional => |o| {
            if (try reader.takeByte() == 0) {
                out.* = null;
                return;
            }
            var value: o.child = if (out.*) |v| v else undefined;
            try get(reader, arena, &value);
            out.* = value;
        },
        .array => for (out) |*item| try get(reader, arena, item),
        .pointer => |p| {
            const len = try reader.takeInt(u64, .little);
            if (len > reader.bufferedLen()) return error.Invalid;
            const items = try arena.alloc(p.child, @intCast(len));
            for (items) |*item| try get(reader, arena, item);
            out.* = items;
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                var bits: s.backing_integer.? = undefined;
                try get(reader, arena, &bits);
                out.* = @bitCast(bits);
                return;
            }
            inline for (s.field_names) |name| if (!comptime skipped(T, name)) try get(reader, arena, &@field(out, name));
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            var tag: Tag = undefined;
            try get(reader, arena, &tag);
            switch (tag) {
                inline else => |t| {
                    const Payload = @FieldType(T, @tagName(t));
                    var payload: Payload = undefined;
                    try get(reader, arena, &payload);
                    out.* = @unionInit(T, @tagName(t), payload);
                },
            }
        },
        else => @compileError("no way to read a " ++ @typeName(T)),
    }
}

/// what the file's fields are, to refuse a file of others
const format_hash = hash: {
    var h = typeHash(Machine) +% format_version;
    for (.{ Computer, Port, Serdes, Chip.ResetLine, pins.History, pins.Net, pins.Contention }) |T|
        h = h *% 31 +% typeHash(T);
    break :hash h;
};

/// Writes the machine and the chip's state
pub fn write(writer: *Io.Writer, machine: Machine, chip: *const Chip) Error!void {
    try writer.writeAll(magic);
    try writer.writeInt(u64, format_hash, .little);
    try put(writer, machine);

    try put(writer, chip.nodes);
    try put(writer, chip.ports);
    // what is past the end of the queue is left from nodes gone from it
    try writer.writeInt(u64, chip.queue.len, .little);
    for (chip.queue, 0..) |index, k| try put(writer, if (k < chip.queue_len) index else @as(u16, 0));
    try put(writer, chip.queued);
    try put(writer, chip.queue_len);
    try put(writer, chip.steps);
    try put(writer, chip.started);
    try put(writer, chip.next_event);
    try put(writer, chip.held);
    try put(writer, chip.reset_address);
    try put(writer, chip.serdes.items);
    try put(writer, chip.serdes.len);
    try put(writer, chip.resets.items);
    try put(writer, chip.resets.len);
    for (chip.wiring.pins) |p| try put(writer, p.history);
    for (chip.wiring.nets) |n| {
        try put(writer, n.high);
        try put(writer, n.changed);
    }
    try put(writer, chip.wiring.contention);

    // each device after the hash of its fields
    for (chip.devices.slice()) |d| {
        const state = d.device.vtable.state;
        try writer.writeInt(u64, state.hash, .little);
        try state.write(d.device.context, writer);
    }
}

/// Reads what the machine was, for it to be built before `readChip`
pub fn readMachine(reader: *Io.Reader, arena: Allocator) Error!Machine {
    const start = reader.take(magic.len) catch return error.Invalid;
    if (!std.mem.eql(u8, start, magic)) return error.Invalid;
    if (try reader.takeInt(u64, .little) != format_hash) return error.OtherVersion;
    var machine: Machine = .{};
    try get(reader, arena, &machine);
    return machine;
}

/// reads a slice into one the chip already has, of the same length
fn getInto(reader: *Io.Reader, arena: Allocator, slice: anytype) Error!void {
    if (try reader.takeInt(u64, .little) != slice.len) return error.OtherMachine;
    for (slice) |*item| try get(reader, arena, item);
}

/// Reads a chip's state, after `readMachine`, into a chip built as it says,
/// with its devices attached
pub fn readChip(reader: *Io.Reader, arena: Allocator, chip: *Chip) Error!void {
    try getInto(reader, arena, chip.nodes);
    try getInto(reader, arena, chip.ports);
    try getInto(reader, arena, chip.queue);
    try getInto(reader, arena, chip.queued);
    try get(reader, arena, &chip.queue_len);
    try get(reader, arena, &chip.steps);
    try get(reader, arena, &chip.started);
    try get(reader, arena, &chip.next_event);
    try get(reader, arena, &chip.held);
    try getInto(reader, arena, chip.reset_address);
    try get(reader, arena, &chip.serdes.items);
    try get(reader, arena, &chip.serdes.len);
    try get(reader, arena, &chip.resets.items);
    try get(reader, arena, &chip.resets.len);
    for (chip.wiring.pins) |*p| try get(reader, arena, &p.history);
    for (chip.wiring.nets) |*n| {
        try get(reader, arena, &n.high);
        try get(reader, arena, &n.changed);
    }
    try get(reader, arena, &chip.wiring.contention);

    for (chip.devices.slice()) |d| {
        const state = d.device.vtable.state;
        // a chip built as the file's machine says has the file's devices,
        // so this is a device of other fields, from another gasim
        if (try reader.takeInt(u64, .little) != state.hash) return error.OtherVersion;
        try state.read(d.device.context, reader, arena);
    }
}

/// a console that writes nowhere, for a test's chip
fn testConsole(writer: *Io.Writer) Console {
    return .{ .output = writer };
}

/// Runs `source` to a breakpoint with its console's output in `first`, saves
/// it, and goes on from there on another chip, with its output in `second`.
/// Returns the steps of that, for comparing with a run with no stop.
fn runInTwo(arena: Allocator, source: []const u8, input: []const u8, at: u9, first: *Io.Writer, second: *Io.Writer) !u64 {
    var file: Io.Writer.Allocating = .init(arena);
    {
        var chip: Chip = try .init(std.testing.allocator, .ga144);
        defer chip.deinit(std.testing.allocator);
        var console = testConsole(first);
        console.preload = input;
        try console.attach(&chip, 0, .up);
        var diagnostic: assembler.Diagnostic = .{};
        var programs: [1]assembler.Program = undefined;
        for (try assembler.assembleNodes(source, &programs, &diagnostic)) |program| try chip.load(program);
        try chip.breakpoints.insert(.init(0, at));
        try chip.run();
        try std.testing.expect(chip.hit != null);
        try write(&file.writer, .{}, &chip);
    }
    var reader: Io.Reader = .fixed(file.written());
    _ = try readMachine(&reader, arena);
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var console = testConsole(second);
    try console.attach(&chip, 0, .up);
    try readChip(&reader, arena, &chip);
    try chip.run();
    return chip.steps;
}

test "a run goes on from a file as if it had not stopped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\: main up b!
        \\: loop @b dup !b -if done ; then loop ;
        \\: done 0 !b left b! @b
    ;
    var whole_buffer: [64]u8 = undefined;
    var whole: Io.Writer = .fixed(&whole_buffer);
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var console = testConsole(&whole);
    console.preload = "abc";
    try console.attach(&chip, 0, .up);
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [1]assembler.Program = undefined;
    for (try assembler.assembleNodes(source, &programs, &diagnostic)) |program| try chip.load(program);
    try chip.run();

    var first_buffer: [64]u8 = undefined;
    var first: Io.Writer = .fixed(&first_buffer);
    var second_buffer: [64]u8 = undefined;
    var second: Io.Writer = .fixed(&second_buffer);
    const steps = try runInTwo(arena.allocator(), source, "abc", 2, &first, &second);
    try std.testing.expectEqual(chip.steps, steps);
    var both_buffer: [64]u8 = undefined;
    const both = try std.fmt.bufPrint(&both_buffer, "{s}{s}", .{ first.buffered(), second.buffered() });
    try std.testing.expectEqualStrings(whole.buffered(), both);
}

test "a file of other fields is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var other: Io.Reader = .fixed("gasimsnp\x00\x00\x00\x00\x00\x00\x00\x00");
    try std.testing.expectError(error.OtherVersion, readMachine(&other, arena.allocator()));
    var nothing: Io.Reader = .fixed("not one");
    try std.testing.expectError(error.Invalid, readMachine(&nothing, arena.allocator()));
}

test "the machine reads back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var chip: Chip = try .init(std.testing.allocator, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(std.testing.allocator);
    const setting: Machine.Setting = .{ .name = "J26", .on = false };
    try write(&writer, .{ .board = "evb002", .settings = &.{setting}, .uart_node = 708, .sync = true }, &chip);
    var reader: Io.Reader = .fixed(writer.buffered());
    const machine = try readMachine(&reader, arena.allocator());
    try std.testing.expectEqualStrings("evb002", machine.board);
    try std.testing.expectEqualStrings("J26", machine.settings[0].name);
    try std.testing.expectEqual(708, machine.uart_node.?);
    try std.testing.expect(machine.sync and !machine.flash);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const assembler = @import("assembler.zig");
const Chip = @import("Chip.zig");
const Computer = @import("f18.zig").Computer;
const Console = @import("Console.zig");
const Direction = @import("port.zig").Direction;
const pins = @import("pins.zig");
const Port = @import("port.zig").Port;
const Serdes = @import("Serdes.zig");
