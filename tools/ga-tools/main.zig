//! Boots node 708 from its ROM with async boot streams that ga-tools
//! compiles, through a UART as on the evaluation board, and checks that the
//! programs send what their source says they will, and that each node's RAM
//! holds what ga-tools compiled for it. ga-tools is run as a command, `ga`,
//! for each program and baud.
//!
//! usage: ga-tools-check <ga> <rom> <program.ga>...
//!
//! <rom> is arrayForth 3's disk (a .blk file) or a ROM dump, or an empty
//! argument for rom/pFDISK.blk if there is one, then the ROM gasim saves.
//! Programs say what they send in a comment line such as
//! `\ expect: 0x7c 3`, and send it as tests/ga-tools/serial.ga does. RAM is
//! compared once they have run, so they should not store into it.

const bauds = [_]u32{ 921600, 460800, 115200 };

/// what ga-tools' --json gives, of what is checked
const Compiled = struct {
    nodes: std.json.ArrayHashMap(struct { ram: []const ?u18 }),
    bootstream: struct { stream: []const u8 },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) fatal("usage: ga-tools-check <ga> <rom> <program.ga>...", .{});
    const roms = try readRom(io, arena, init.environ_map, args[2]);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var failed = false;
    for (args[3..]) |program| for (bauds) |baud| {
        const name = std.fs.path.basename(program);
        switch (try check(io, init.gpa, arena, args[1], program, baud, roms)) {
            .ok => |ram| try out.print("{s} at {d} baud: ok, and the RAM of {d} node{s} ({d} words)\n", .{ name, baud, ram.nodes, if (ram.nodes == 1) "" else "s", ram.words }),
            .failed => |why| {
                try out.print("{s} at {d} baud: {s}\n", .{ name, baud, why });
                failed = true;
            },
        }
    };
    try out.flush();
    if (failed) std.process.exit(1);
}

const Result = union(enum) {
    /// how much RAM was checked
    ok: struct { nodes: usize, words: usize },
    failed: []const u8,

    fn fail(arena: Allocator, comptime format: []const u8, args: anytype) !Result {
        return .{ .failed = try std.fmt.allocPrint(arena, format, args) };
    }
};

fn check(io: Io, gpa: Allocator, arena: Allocator, ga: []const u8, program: []const u8, baud: u32, roms: []const ga144.NodeRom) !Result {
    const source = try Io.Dir.cwd().readFileAlloc(io, program, arena, .limited(1 << 20));
    const expected = try expectedWords(arena, source) orelse return .{ .failed = "no '\\ expect:' line" };

    // ga-tools finds included files beside the file that includes them
    const result = std.process.run(arena, io, .{
        .argv = &.{ ga, "--bootstream", "708", "--baud", try std.fmt.allocPrint(arena, "{d}", .{baud}), "--json", program },
    }) catch |err| fatal("{s}: {t}", .{ ga, err });
    if (!result.term.success()) return .fail(arena, "ga failed: {s}", .{std.mem.trim(u8, result.stderr, "\n")});
    // its compile errors go to stdout, before any JSON
    const json = std.mem.trim(u8, result.stdout, " \n");
    if (!std.mem.startsWith(u8, json, "{")) return .fail(arena, "ga: {s}", .{json});
    const compiled = std.json.parseFromSliceLeaky(Compiled, arena, json, .{ .ignore_unknown_fields = true }) catch |err|
        return .fail(arena, "ga's JSON: {t}", .{err});

    var chip: Chip = try .init(gpa, .ga144);
    defer chip.deinit(gpa);
    chip.loadRom(roms) catch return .{ .failed = "the ROM has no node 708" };
    var output: Io.Writer.Allocating = .init(arena);
    var uart: Uart = .init(baud, &output.writer);
    uart.preload = compiled.bootstream.stream;
    try chip.attachUart(&uart, 708);
    // as Chip.run does, but with no input to wait for, and stopping a
    // program that never settles: twice the stream's time, and a tenth of
    // a second for the program, is plenty
    const limit = 2 * compiled.bootstream.stream.len * 10 * uart.bit_time + 100_000_000_000;
    var rounds: usize = 0;
    while (try chip.advance()) : (rounds += 1) {
        if (rounds % 4096 != 0) continue;
        for (chip.nodes) |n| if (n.time > limit)
            return .fail(arena, "still running after {d} ms of the chip's time", .{limit / 1_000_000_000});
    }

    const sent = try decode(arena, output.written());
    if (sent.trailing > 0) return .fail(arena, "sent {d} bytes after the end", .{sent.trailing});
    if (!std.mem.eql(u18, sent.words, expected) or !sent.done)
        return .fail(arena, "sent {f}, expected {f}", .{ Words{ .words = sent.words, .done = sent.done }, Words{ .words = expected, .done = true } });

    var words: usize = 0;
    var it = compiled.nodes.map.iterator();
    while (it.next()) |entry| {
        const number = std.fmt.parseInt(u16, entry.key_ptr.*, 10) catch return .{ .failed = "ga gave a node that is not a number" };
        const n = chip.node(number) orelse return .fail(arena, "no node {d:0>3}", .{number});
        const ram = entry.value_ptr.ram;
        if (ram.len > 64) return .fail(arena, "ga compiled {d} words for node {d:0>3}, which has 64", .{ ram.len, number });
        for (ram, 0..) |word, address| {
            const want = word orelse continue;
            const have: u18 = @bitCast(n.mem[address]);
            if (have != want) return .fail(arena, "node {d:0>3} has {x:0>5} at {x:0>2}, compiled as {x:0>5}", .{ number, have, address, want });
            words += 1;
        }
    }
    return .{ .ok = .{ .nodes = compiled.nodes.map.count(), .words = words } };
}

/// the words after `\ expect:` in a program's source
fn expectedWords(arena: Allocator, source: []const u8) !?[]const u18 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const prefix = "\\ expect:";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var words: std.ArrayList(u18) = .empty;
        var tokens = std.mem.tokenizeAny(u8, line[prefix.len..], " \t\r");
        while (tokens.next()) |token| try words.append(arena, std.fmt.parseInt(u18, token, 0) catch fatal("expect: '{s}' is not a word", .{token}));
        return words.items;
    }
    return null;
}

/// Reads what a program sent as ga-tools' host side does: a byte of 0 and
/// then a word in three bytes, lowest first, or a byte of 1 at the end,
/// and how many bytes followed that
fn decode(arena: Allocator, bytes: []const u8) !struct { words: []const u18, done: bool, trailing: usize = 0 } {
    var words: std.ArrayList(u18) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        switch (bytes[i]) {
            0 => {
                if (i + 4 > bytes.len) break;
                try words.append(arena, @truncate(std.mem.readInt(u24, bytes[i + 1 ..][0..3], .little)));
                i += 4;
            },
            1 => return .{ .words = words.items, .done = true, .trailing = bytes.len - i - 1 },
            else => break,
        }
    }
    return .{ .words = words.items, .done = false };
}

/// words as a program's `\ expect:` line gives them, and whether it ended
const Words = struct {
    words: []const u18,
    done: bool,

    pub fn format(self: Words, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.words.len == 0) try writer.writeAll("nothing");
        for (self.words, 0..) |word, i| try writer.print("{s}0x{x}", .{ if (i > 0) " " else "", word });
        if (!self.done) try writer.writeAll(" without an end");
    }
};

fn readRom(io: Io, arena: Allocator, environ: *const std.process.Environ.Map, path: []const u8) ![]const ga144.NodeRom {
    const roms = try arena.alloc(ga144.NodeRom, 144);
    var candidates: [3]?[]const u8 = .{ if (path.len > 0) path else null, null, null };
    if (path.len == 0) {
        candidates[1] = "rom/pFDISK.blk";
        candidates[2] = if (environ.get("XDG_DATA_HOME")) |data|
            try std.fs.path.join(arena, &.{ data, "gasim", "ga144.txt" })
        else if (environ.get("HOME")) |home|
            try std.fs.path.join(arena, &.{ home, ".local", "share", "gasim", "ga144.txt" })
        else
            null;
    }
    for (candidates) |candidate| {
        const p = candidate orelse continue;
        const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => if (path.len > 0) fatal("{s}: not found", .{p}) else continue,
            else => |e| return e,
        };
        if (std.mem.endsWith(u8, p, ".blk")) {
            var diagnostic: gasim.assembler.Diagnostic = .{};
            return gasim.rom.assemble(arena, text, roms[0..144], &diagnostic) catch |err|
                fatal("{s}: {t}, assembling the ROM", .{ p, err });
        }
        return ga144.parseRom(text, roms) catch |err| fatal("{s}: {t}", .{ p, err });
    }
    fatal("no ROM, for node 708 to boot from: give arrayForth 3's disk or a dump of it, put the disk in rom/, or run gasim once with --rom", .{});
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

const gasim = @import("gasim");
const Chip = gasim.Chip;
const Uart = gasim.Uart;
const ga144 = gasim.ga144;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
