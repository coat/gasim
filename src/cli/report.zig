//! How gasim says how a command ended: errors, the status it exits with, and
//! with `--json`, an object on stdout in place of text. Words are written in
//! hex as strings, as gasim writes them elsewhere, and counts as numbers.

/// that errors are objects on stdout
pub var json = false;
/// for writing them, set as `main` starts
pub var io: ?Io = null;

/// how a run ended, which is also what `stop` says in its object
pub const Stop = enum {
    settled,
    breakpoint,
    watch,
    limit,
    interrupted,
    /// the steps asked for are taken
    step,

    /// the status for a run that ended so, or that `signal` interrupted
    pub fn status(self: Stop, signal: u8) u8 {
        return switch (self) {
            .settled, .step => 0,
            .breakpoint => 3,
            .watch => 4,
            .limit => 5,
            .interrupted => 128 + signal,
        };
    }
};

pub const status_error = 1;
pub const status_usage = 2;

/// Ends gasim with an error, in a file, a program, or the chip
pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    fail(status_error, format, args);
}

/// Ends gasim with an error in how it was asked to do something
pub fn usage(comptime format: []const u8, args: anytype) noreturn {
    fail(status_usage, format, args);
}

fn fail(status: u8, comptime format: []const u8, args: anytype) noreturn {
    if (json) if (io) |file_io| {
        var buffer: [4096]u8 = undefined;
        var file_writer: Io.File.Writer = .initStreaming(.stdout(), file_io, &buffer);
        writeError(&file_writer.interface, format, args) catch {};
        file_writer.interface.flush() catch {};
        std.process.exit(status);
    };
    std.log.err(format, args);
    std.process.exit(status);
}

fn writeError(writer: *Io.Writer, comptime format: []const u8, args: anytype) Io.Writer.Error!void {
    var text: [2048]u8 = undefined;
    var jw: Stringify = .{ .writer = writer };
    try jw.beginObject();
    try jw.objectField("stop");
    try jw.write("error");
    try jw.objectField("message");
    try bytes(&jw, std.fmt.bufPrint(&text, format, args) catch &text);
    try jw.endObject();
    try writer.writeByte('\n');
}

/// Writes bytes as a string, each a character, as a node's output need not
/// be text
pub fn bytes(jw: *Stringify, data: []const u8) Stringify.Error!void {
    try jw.beginWriteRaw();
    const writer = jw.writer;
    try writer.writeByte('"');
    for (data) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        ' '...'!', '#'...'[', ']'...'~' => try writer.writeByte(byte),
        else => try writer.print("\\u{x:0>4}", .{byte}),
    };
    try writer.writeByte('"');
    jw.endWriteRaw();
}

/// Writes a word as a string of hex digits, `width` of them
pub fn hex(jw: *Stringify, value: anytype, comptime width: usize) Stringify.Error!void {
    var buffer: [16]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buffer, "{x:0>" ++ std.fmt.comptimePrint("{d}", .{width}) ++ "}", .{value}) catch unreachable);
}

/// Writes a node's number as a string, such as `105` or `1.708`
pub fn nodeNumber(jw: *Stringify, number: u16) Stringify.Error!void {
    var buffer: [16]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buffer, "{f}", .{Chip.nodeName(number)}) catch unreachable);
}

/// the address a node waits on, and how, if it does
fn waitingOn(status: Computer.Status) ?struct { kind: []const u8, address: u9 } {
    return switch (status) {
        .running => null,
        .code => |a| .{ .kind = "code", .address = a },
        .reading => |a| .{ .kind = "reading", .address = a },
        .writing => |a| .{ .kind = "writing", .address = a },
    };
}

/// Whether a node is only waiting on several ports, as nodes do after reset
pub fn isIdle(n: *const Computer) bool {
    const status = n.status();
    const on = waitingOn(status) orelse return false;
    const selected = gasim.port.select(on.address) orelse gasim.port.Select.empty;
    return selected.count() > 1 and (status == .code or n.word_address.rom);
}

/// the stack below its top, the next to be popped first
fn stackBelow(jw: *Stringify, entries: *const [8]Word, index: u3) Stringify.Error!void {
    try jw.beginArray();
    for (1..9) |depth| try hex(jw, @as(u18, @bitCast(entries[index -% @as(u3, @intCast(depth % 8))])), 5);
    try jw.endArray();
}

/// Writes what a node is doing, as an object's fields
pub fn statusFields(jw: *Stringify, n: *const Computer) Stringify.Error!void {
    const status = n.status();
    try jw.objectField("status");
    if (waitingOn(status)) |on| {
        try jw.write(on.kind);
        try jw.objectField("on");
        try jw.write(gasim.disassembler.ioName(on.address));
    } else try jw.write("running");
}

/// Writes a node's registers and stacks, as an object
pub fn node(jw: *Stringify, chip: *const Chip, i: u16) Stringify.Error!void {
    const n = &chip.nodes[i];
    try jw.beginObject();
    try jw.objectField("node");
    try nodeNumber(jw, chip.layout.nodeNumber(i));
    try statusFields(jw, n);
    try jw.objectField("p");
    try hex(jw, @as(u10, @bitCast(n.p)), 3);
    try jw.objectField("slot");
    try jw.write(n.slot);
    try jw.objectField("carry");
    try jw.write(n.carry);
    try jw.objectField("extended_arithmetic");
    try jw.write(n.p.extended_arithmetic);
    try jw.objectField("i");
    try hex(jw, @as(u18, @bitCast(n.i)), 5);
    try jw.objectField("a");
    try hex(jw, @as(u18, @bitCast(n.a)), 5);
    try jw.objectField("b");
    try hex(jw, n.b, 3);
    try jw.objectField("io");
    try hex(jw, @as(u18, @bitCast(n.io)), 5);
    try jw.objectField("t");
    try hex(jw, @as(u18, @bitCast(n.data_stack.t)), 5);
    try jw.objectField("s");
    try hex(jw, @as(u18, @bitCast(n.data_stack.s)), 5);
    try jw.objectField("data_stack");
    try stackBelow(jw, &n.data_stack.stack, n.data_stack.index);
    try jw.objectField("r");
    try hex(jw, @as(u18, @bitCast(n.return_stack.t)), 5);
    try jw.objectField("return_stack");
    try stackBelow(jw, &n.return_stack.stack, n.return_stack.index);
    try jw.objectField("time_ps");
    try jw.write(n.time);
    try jw.endObject();
}

/// Writes the nodes that are not only idle, with how many are, as `--why`
/// says them
pub fn waiting(jw: *Stringify, chip: *const Chip) Stringify.Error!void {
    var idle: usize = 0;
    try jw.beginArray();
    for (chip.nodes, 0..) |*n, i| {
        const number = chip.layout.nodeNumber(@intCast(i));
        if (chip.isHeld(@intCast(number / Chip.Layout.chip_numbers))) continue;
        if (isIdle(n)) {
            idle += 1;
            continue;
        }
        try jw.beginObject();
        try jw.objectField("node");
        try nodeNumber(jw, number);
        try statusFields(jw, n);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("idle");
    try jw.write(idle);
}

/// Writes what a node is doing, its registers and stacks, as lines
pub fn nodeText(writer: *Io.Writer, chip: *const Chip, i: u16) Io.Writer.Error!void {
    const n = &chip.nodes[i];
    const name = Chip.nodeName(chip.layout.nodeNumber(i));
    const ioName = gasim.disassembler.ioName;
    switch (n.status()) {
        .running => try writer.print("node {f} running\n", .{name}),
        .code => |a| try writer.print("node {f} waiting for code from {s}\n", .{ name, ioName(a) }),
        .reading => |a| try writer.print("node {f} waiting to read {s}\n", .{ name, ioName(a) }),
        .writing => |a| try writer.print("node {f} waiting to write {s}\n", .{ name, ioName(a) }),
    }
    try registersText(writer, n);
    try writer.writeAll("data");
    for (1..9) |depth| try writer.print(" {x:0>5}", .{@as(u18, @bitCast(n.data_stack.stack[n.data_stack.index -% @as(u3, @intCast(depth % 8))]))});
    try writer.writeAll("\nreturn");
    for (1..9) |depth| try writer.print(" {x:0>5}", .{@as(u18, @bitCast(n.return_stack.stack[n.return_stack.index -% @as(u3, @intCast(depth % 8))]))});
    try writer.print("\nslot {d}  carry {d}  io {x:0>5}  time {d} ps\n", .{ n.slot, n.carry, @as(u18, @bitCast(n.io)), n.time });
}

/// Writes a node's registers as a line
pub fn registersText(writer: *Io.Writer, n: *const Computer) Io.Writer.Error!void {
    try writer.print("P {x:0>3}  T {x:0>5}  S {x:0>5}  R {x:0>5}  A {x:0>5}  B {x:0>3}\n", .{
        @as(u10, @bitCast(n.p)),
        @as(u18, @bitCast(n.data_stack.t)),
        @as(u18, @bitCast(n.data_stack.s)),
        @as(u18, @bitCast(n.return_stack.t)),
        @as(u18, @bitCast(n.a)),
        n.b,
    });
}

/// a span of a node's memory: RAM from 0, or ROM from x80
pub const Span = struct {
    first: u9,
    count: u32,

    /// the word at the `k`th address of the span, and whether it is known to
    /// be data, wrapping within the 64 words of its RAM or ROM
    fn at(self: Span, n: *const Computer, k: usize) struct { address: u9, word: Word, literal: bool } {
        const rom = self.first & 0x80 != 0;
        const i: u6 = @truncate(self.first + k);
        const words = n.mem[if (rom) 64 else 0..][0..64];
        return .{
            .address = (self.first & 0x180) | i,
            .word = words[i],
            .literal = gasim.disassembler.literals(words) & (@as(u64, 1) << i) != 0,
        };
    }
};

/// Writes words of a node's memory, a line to each, as -ASM does
pub fn memoryText(writer: *Io.Writer, n: *const Computer, span: Span) Io.Writer.Error!void {
    for (0..span.count) |k| {
        const w = span.at(n, k);
        try writer.print("{x:0>3} {x:0>5}  ", .{ w.address, @as(u18, @bitCast(w.word)) });
        try code(writer, w.word, w.address, w.literal);
        try writer.writeByte('\n');
    }
}

fn code(writer: *Io.Writer, word: Word, address: u9, literal: bool) Io.Writer.Error!void {
    if (literal) return gasim.disassembler.writeLiteral(writer, word);
    return gasim.disassembler.write(writer, word, address);
}

/// Writes words of a node's memory, as an array of objects
pub fn memory(jw: *Stringify, n: *const Computer, span: Span) Stringify.Error!void {
    try jw.beginArray();
    for (0..span.count) |k| {
        const w = span.at(n, k);
        var buffer: [64]u8 = undefined;
        var text: Io.Writer = .fixed(&buffer);
        code(&text, w.word, w.address, w.literal) catch {};
        try jw.beginObject();
        try jw.objectField("address");
        try hex(jw, w.address, 3);
        try jw.objectField("word");
        try hex(jw, @as(u18, @bitCast(w.word)), 5);
        try jw.objectField("code");
        try jw.write(text.buffered());
        try jw.endObject();
    }
    try jw.endArray();
}

/// each port of a node with something happening on it, to `visit`
fn eachFlow(chip: *const Chip, i: u16, context: anytype, comptime visit: anytype) !void {
    for (std.enums.values(Chip.Cardinal)) |cardinal| {
        const flow = chip.flow(i, cardinal) orelse continue;
        try visit(context, cardinal, flow);
    }
}

/// Writes what the ports of a node are doing, a line to each
pub fn portsText(writer: *Io.Writer, chip: *const Chip, i: u16) Io.Writer.Error!void {
    const Visit = struct {
        writer: *Io.Writer,
        name: Chip.NodeName,
        fn visit(self: @This(), cardinal: Chip.Cardinal, flow: Chip.Flow) Io.Writer.Error!void {
            try self.writer.print("{f} {t} {s} {t}\n", .{ self.name, cardinal, if (flow.outward) "out" else "in", flow.kind });
        }
    };
    try eachFlow(chip, i, Visit{ .writer = writer, .name = Chip.nodeName(chip.layout.nodeNumber(i)) }, Visit.visit);
}

/// Writes what the ports of a node are doing, as objects of an array
pub fn ports(jw: *Stringify, chip: *const Chip, i: u16) Stringify.Error!void {
    const Visit = struct {
        jw: *Stringify,
        number: u16,
        fn visit(self: @This(), cardinal: Chip.Cardinal, flow: Chip.Flow) Stringify.Error!void {
            try self.jw.beginObject();
            try self.jw.objectField("node");
            try nodeNumber(self.jw, self.number);
            try self.jw.objectField("toward");
            try self.jw.write(@tagName(cardinal));
            try self.jw.objectField("outward");
            try self.jw.write(flow.outward);
            try self.jw.objectField("kind");
            try self.jw.write(@tagName(flow.kind));
            try self.jw.endObject();
        }
    };
    try eachFlow(chip, i, Visit{ .jw = jw, .number = chip.layout.nodeNumber(i) }, Visit.visit);
}

/// The time on the chip: as far as any node has got
pub fn chipTime(chip: *const Chip) u64 {
    var time: u64 = 0;
    for (chip.nodes) |n| time = @max(time, n.time);
    return time;
}

/// Writes why a run stopped, as an object's fields
pub fn stopFields(jw: *Stringify, chip: *const Chip, stop: Stop) Stringify.Error!void {
    try jw.objectField("stop");
    try jw.write(@tagName(stop));
    const hit = chip.hit orelse return;
    if (stop != .breakpoint and stop != .watch) return;
    try jw.objectField("node");
    try nodeNumber(jw, chip.layout.nodeNumber(hit.index()));
    switch (hit) {
        .breakpoint => |b| {
            try jw.objectField("address");
            try hex(jw, b.address, 3);
        },
        .watch => |w| {
            try jw.objectField("port");
            try jw.write(@tagName(w.watch.direction));
            try jw.objectField("transfer");
            try jw.write(if (w.watch.write) "write" else "read");
            try jw.objectField("value");
            try hex(jw, @as(u18, @bitCast(w.value)), 5);
        },
    }
}

test bytes {
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var jw: Stringify = .{ .writer = &writer };
    try bytes(&jw, "a\"\\\n\x00\xff~");
    try std.testing.expectEqualStrings("\"a\\\"\\\\\\n\\u0000\\u00ff~\"", writer.buffered());
}

test "a run's status says how it ended" {
    try std.testing.expectEqual(0, Stop.settled.status(0));
    try std.testing.expectEqual(3, Stop.breakpoint.status(0));
    try std.testing.expectEqual(4, Stop.watch.status(0));
    try std.testing.expectEqual(5, Stop.limit.status(0));
    try std.testing.expectEqual(143, Stop.interrupted.status(15));
}

const std = @import("std");
const Io = std.Io;
const Stringify = std.json.Stringify;

const gasim = @import("gasim");
const Chip = gasim.Chip;
const Computer = gasim.Computer;
const Word = gasim.Word;
