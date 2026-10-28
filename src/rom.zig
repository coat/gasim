//! The ROM of a GA144's nodes, assembled from its source in arrayForth 3's
//! disk as arrayForth 3 does, and kept as a dump of its words in text: for
//! each node, its number on a line followed by its 64 ROM words, for
//! addresses x080 to x0bf, in decimal, one per line, as stored in memory.

/// where arrayForth 3's disk, with the ROM's source, is in its distribution
pub const disk_path = "sF/pFDISK.blk";

/// SHA-256 of a G144A12's ROM as `write` writes it, as read from a chip by
/// Michael Schuldt (raw-rom-dump.txt of mschuldt/ga144-sim)
pub const g144a12_digest: [Sha256.digest_length]u8 = .{
    0x32, 0xf9, 0x6c, 0xae, 0x71, 0x2d, 0xdc, 0x23, 0xda, 0x21, 0x1d, 0xe3, 0xae, 0x43, 0x6e, 0x56,
    0x2a, 0x05, 0x98, 0x4a, 0x4d, 0xf6, 0xa0, 0x1b, 0x8f, 0x4f, 0xc5, 0x76, 0xdc, 0xde, 0xd1, 0x56,
};

pub const Error = arrayforth.Error || Allocator.Error || error{MissingRom};

/// Assembles every GA144 node's ROM from arrayForth 3's disk, in the order
/// of the nodes of a GA144 layout
pub fn assemble(gpa: Allocator, disk: []const u8, roms: *[144]ga144.NodeRom, diagnostic: *assembler.Diagnostic) Error![]ga144.NodeRom {
    const layout: Chip.Layout = .ga144;

    // what block 2221 does with host code: names the blocks of the pieces
    // the ROMs share, then loads each node's ROM block with its number,
    // and then the blocks of the nodes with SDRAM and eForth ROMs
    var script: std.Io.Writer.Allocating = .init(gpa);
    defer script.deinit();
    const writer = &script.writer;
    for ([_][]const u8{ "POLY", "INTERP", "FILTER", "RELAY", "MPLY", "SHIFT", "TRIANG", ".MULT", "DIVIDE" }, 2232..) |name, block| {
        writer.print("{d} CONSTANT {s}\n", .{ block, name }) catch return error.OutOfMemory;
    }
    for (0..layout.count()) |i| {
        const node = layout.nodeNumber(@intCast(i));
        const block: u32 = switch (ga144.romType(node)) {
            .basic => 2222,
            .serdes_boot => 2223,
            .sync_boot => 2224,
            .async_boot => 2225,
            .spi_boot => 2227,
            .analog => 2229,
            .one_wire => 2230,
            .special => continue,
        };
        writer.print("{d} {d} LOAD\n", .{ node, block }) catch return error.OutOfMemory;
    }
    writer.writeAll("2241 LOAD\n") catch return error.OutOfMemory;

    const programs = try gpa.alloc(assembler.Program, 160);
    defer gpa.free(programs);
    const assembled = try arrayforth.assembleScript(script.written(), disk, programs, &.{}, diagnostic);

    for (roms, 0..) |*rom, i| {
        const node = layout.nodeNumber(@intCast(i));
        const program = for (assembled.programs) |*p| {
            if (p.node == node and p.bin == null) break p;
        } else return error.MissingRom;
        rom.* = .{ .node = node, .words = (program.rom orelse return error.MissingRom).words };
    }
    return roms;
}

/// Writes ROMs as a dump, which `ga144.parseRom` reads
pub fn write(writer: *std.Io.Writer, roms: []const ga144.NodeRom) std.Io.Writer.Error!void {
    for (roms) |rom| {
        try writer.print("{d}\n", .{rom.node});
        for (rom.words) |word| try writer.print("{d}\n", .{@as(u18, @bitCast(word))});
    }
}

/// SHA-256 of ROMs as `write` writes them
pub fn digest(roms: []const ga144.NodeRom) [Sha256.digest_length]u8 {
    var buffer: [256]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(Sha256) = .init(&buffer);
    write(&hashing.writer, roms) catch unreachable;
    hashing.writer.flush() catch unreachable;
    return hashing.hasher.finalResult();
}

/// whether ROMs are a G144A12's
pub fn isG144A12(roms: []const ga144.NodeRom) bool {
    return std.mem.eql(u8, &digest(roms), &g144a12_digest);
}

/// Assembles the GA144's ROM from arrayForth 3's disk in rom/, skipping the
/// test if it is missing, as it is GreenArrays' and not part of gasim
pub fn testRom(roms: *[144]ga144.NodeRom) ![]ga144.NodeRom {
    const gpa = std.testing.allocator;
    const disk = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer gpa.free(disk);
    var diagnostic: assembler.Diagnostic = .{};
    return assemble(gpa, disk, roms, &diagnostic) catch |err| {
        std.debug.print("{t} at block {d} line {d} '{s}'\n", .{ err, (diagnostic.line -| 1) / 16, (diagnostic.line -| 1) % 16, diagnostic.token });
        return err;
    };
}

test "the ROM source assembles to the chip's ROM" {
    var roms: [144]ga144.NodeRom = undefined;
    const assembled = try testRom(&roms);
    try std.testing.expect(isG144A12(assembled));
}

test write {
    var roms: [2]ga144.NodeRom = .{
        .{ .node = 708, .words = @splat(1) },
        .{ .node = 9, .words = @splat(@bitCast(@as(u18, 0x3ffff))) },
    };
    var text: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    try write(&writer, &roms);
    var parsed: [2]ga144.NodeRom = undefined;
    try std.testing.expectEqualDeep(&roms, (try ga144.parseRom(writer.buffered(), &parsed))[0..2]);
    try std.testing.expect(!isG144A12(&roms));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const arrayforth = @import("arrayforth.zig");
const assembler = @import("assembler.zig");
const Chip = @import("Chip.zig");
const ga144 = @import("ga144.zig");
