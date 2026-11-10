//! Where the words in the nodes' memory came from: the line of source each
//! was assembled from and the label defined at it, and the names of ROM
//! words. A word is only described while memory still holds what was
//! assembled there, as code can be loaded or changed while the chip runs,
//! and a ROM word labels its row only once the ROM is loaded. Each address
//! keeps the last word mapped to it, so of bins loaded over each other,
//! only the last is described.

const SourceMap = @This();

/// the words of the nodes that programs were loaded into, by node index
nodes: std.AutoArrayHashMapUnmanaged(u16, Words) = .empty,
/// the source, which must last as long as the map, and its file's name
source: []const u8,
path: []const u8,
kind: Kind,

/// how the source's line numbers count
pub const Kind = enum {
    /// lines of text, from 1
    text,
    /// polyFORTH blocks of 16 lines of 64 characters, from line 1 of block 0
    blocks,
    /// colorForth blocks, by the place of a token, as `colorforth.line`
    colorforth,
};

/// a word as it was assembled
pub const Entry = struct {
    word: Word,
    /// 0 if it was not assembled from a line, such as a word org skipped
    line: u32 = 0,
    name: Name = .{},
};

/// RAM, then ROM from x080
const Words = [128]?Entry;

/// Maps the words of `programs` to the nodes they are loaded into: the bins
/// that `descriptors` load, or without any, each node's own program
pub fn init(gpa: Allocator, layout: Chip.Layout, programs: []const Program, descriptors: []const boot.Descriptor, source: []const u8, path: []const u8, kind: Kind) Allocator.Error!SourceMap {
    var self: SourceMap = .{ .source = source, .path = path, .kind = kind };
    errdefer self.deinit(gpa);
    if (descriptors.len == 0) for (programs) |*program| if (program.bin == null) {
        const i = layout.index(program.node) orelse continue;
        const words = try self.wordsOf(gpa, i);
        for (0..program.len) |k| words[k] = .{ .word = program.ram[k], .line = program.lines[k], .name = program.names[k] };
        if (program.rom) |rom| for (0..rom.len) |k| {
            words[64 + k] = .{ .word = rom.words[k], .line = rom.lines[k], .name = rom.names[k] };
        };
    };
    for (descriptors) |descriptor| {
        const i = layout.index(descriptor.node) orelse continue;
        for (descriptor.loads[0..descriptor.load_count]) |load| {
            const program = boot.findBin(programs, load.bin) orelse continue;
            const words = try self.wordsOf(gpa, i);
            for (0..load.len) |k| {
                const from = load.source + k;
                const to = load.destination + k;
                if (from >= 64 or to >= 64) break;
                words[to] = .{ .word = program.ram[from], .line = program.lines[from], .name = program.names[from] };
            }
        }
    }
    return self;
}

pub fn deinit(self: *SourceMap, gpa: Allocator) void {
    self.nodes.deinit(gpa);
}

fn wordsOf(self: *SourceMap, gpa: Allocator, i: u16) Allocator.Error!*Words {
    const entry = try self.nodes.getOrPut(gpa, i);
    if (!entry.found_existing) entry.value_ptr.* = @splat(null);
    return entry.value_ptr;
}

/// What was assembled at `address` of node `i`, a listing's address from
/// 000 to 03f or 080 to 0bf, if memory still holds it
pub fn at(self: *const SourceMap, chip: *const Chip, i: u16, address: u9) ?*const Entry {
    const index = memoryIndex(address) orelse return null;
    const words = self.nodes.getPtr(i) orelse return null;
    if (words[index]) |*entry| if (chip.nodes[i].mem[index] == entry.word) return entry;
    return null;
}

/// The name of `address` in node `i`, as a jump goes to it: the label of
/// the code assembled there, or otherwise the name of the ROM word entered
/// there, even when the ROM is not loaded. Addresses past 0bf are named as
/// the words they repeat.
pub fn name(self: ?*const SourceMap, chip: *const Chip, i: u16, address: u10) ?[]const u8 {
    const local: u9 = @truncate(address);
    // RAM and ROM repeat at x040 and x0c0
    const listed: u9 = local & 0x1bf;
    if (self) |map| if (map.at(chip, i, listed)) |entry| return if (entry.name.len > 0) entry.name.slice() else null;
    const rom = chip.spec.node(chip.layout.nodeNumber(i)).rom;
    // an entry point that sets extended arithmetic, such as clc, only for
    // a jump with P9
    for (ga144.romWords(rom)) |word| if (word[1] & 0x200 == address & 0x200 and
        @as(u9, @truncate(word[1])) & 0x1bf == listed) return word[0];
    return null;
}

/// The label at a listing's address of node `i`: the label of the code
/// assembled there, or otherwise the name of the ROM word there, if the ROM
/// is loaded
pub fn label(self: ?*const SourceMap, chip: *const Chip, i: u16, address: u9) ?[]const u8 {
    if (self) |map| if (map.at(chip, i, address)) |entry| return if (entry.name.len > 0) entry.name.slice() else null;
    // a ROM that is not loaded is zeros
    const index = memoryIndex(address) orelse return null;
    if (chip.nodes[i].mem[index] == 0) return null;
    return romName(chip, i, address);
}

/// Names for the disassembler, of the destinations of node `i`'s jumps
pub const Namer = struct {
    map: ?*const SourceMap,
    chip: *const Chip,
    i: u16,

    pub fn names(self: *const Namer) disassembler.Names {
        return .{ .context = self, .get = get };
    }

    fn get(context: *const anyopaque, address: u10) ?[]const u8 {
        const self: *const Namer = @ptrCast(@alignCast(context));
        return name(self.map, self.chip, self.i, address);
    }
};

/// the name of the ROM word at `address` of node `i`, a listing's address
pub fn romName(chip: *const Chip, i: u16, address: u9) ?[]const u8 {
    if (address < 0x80 or address >= 0xc0) return null;
    const rom = chip.spec.node(chip.layout.nodeNumber(i)).rom;
    for (ga144.romWords(rom)) |word| {
        const at_: u9 = @as(u9, @truncate(word[1])) & 0x1bf;
        if (at_ == address) return word[0];
    }
    return null;
}

/// Writes where `line` is, such as `hello.ga:9`, `app.blk: block 2 line 5`
/// or `boot.cf: block 12 word 3`, or without a path, `line 9`, `block 2
/// line 5` or `block 12 word 3`
pub fn writeWhere(self: *const SourceMap, writer: *Io.Writer, line: u32) Io.Writer.Error!void {
    const named = self.path.len > 0;
    if (named) try writer.writeAll(self.path);
    switch (self.kind) {
        .text => try writer.print("{s}{d}", .{ if (named) ":" else "line ", line }),
        .blocks => try writer.print("{s}block {d} line {d}", .{ if (named) ": " else "", (line -| 1) / 16, (line -| 1) % 16 }),
        .colorforth => {
            const place = colorforth.place(line);
            try writer.print("{s}block {d} word {d}", .{ if (named) ": " else "", place.block, place.token });
        },
    }
}

/// the text of `line`, trimmed, or empty for colorForth blocks, whose
/// lines are not text
pub fn text(self: *const SourceMap, line: u32) []const u8 {
    if (line == 0) return "";
    const found = switch (self.kind) {
        .text => text: {
            var lines = std.mem.splitScalar(u8, self.source, '\n');
            for (1..line) |_| _ = lines.next() orelse return "";
            break :text lines.next() orelse "";
        },
        .blocks => text: {
            const start = @as(usize, line - 1) * 64;
            if (start >= self.source.len) return "";
            break :text self.source[start..@min(start + 64, self.source.len)];
        },
        .colorforth => "",
    };
    return std.mem.trim(u8, found, " \t\r");
}

/// the index into a node's memory of a listing's address
fn memoryIndex(address: u9) ?u7 {
    return switch (address) {
        0x00...0x3f => @intCast(address),
        0x80...0xbf => @intCast(address - 0x80 + 64),
        else => null,
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const assembler = @import("assembler.zig");
const boot = @import("boot.zig");
const Chip = @import("Chip.zig");
const colorforth = @import("colorforth.zig");
const disassembler = @import("disassembler.zig");
const f18 = @import("f18.zig");
const ga144 = @import("ga144.zig");
const Name = assembler.Name;
const Program = assembler.Program;
const Spec = @import("Spec.zig");
const Word = f18.Word;

test "finds the line and label of words still in memory" {
    const source =
        \\: main
        \\    dup emit ;
        \\: emit
        \\    drop warm
    ;
    var diagnostic: assembler.Diagnostic = .{};
    var programs: [1]Program = undefined;
    const assembled = try assembler.assembleNodesFor(&Spec.ga144, source, &programs, &diagnostic);
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    for (assembled) |program| try chip.load(program);
    var map: SourceMap = try .init(std.testing.allocator, chip.layout, assembled, &.{}, source, "test.ga", .text);
    defer map.deinit(std.testing.allocator);

    const i = chip.layout.index(0).?;
    const first = map.at(&chip, i, 0).?;
    try expectEqualStrings("main", first.name.slice());
    try expectEqual(2, first.line);
    try expectEqualStrings("dup emit ;", map.text(first.line));
    try expectEqualStrings("emit", SourceMap.name(&map, &chip, i, 1).?);
    // ROM words by name, also where they repeat
    try expectEqualStrings("warm", SourceMap.name(&map, &chip, i, 0xa9).?);
    try expectEqualStrings("interp", SourceMap.name(null, &chip, i, 0xc4).?);
    try expectEqualStrings("clc", SourceMap.name(null, &chip, i, 0x2d3).?);
    try expectEqual(null, SourceMap.name(null, &chip, i, 0x0d3));
    // a ROM word labels its row only once the ROM is loaded
    try expectEqual(null, SourceMap.label(&map, &chip, i, 0xa9));
    chip.nodes[i].mem[64 + 0x29] = 1;
    try expectEqualStrings("warm", SourceMap.label(&map, &chip, i, 0xa9).?);
    try expectEqualStrings("main", SourceMap.label(&map, &chip, i, 0).?);

    var buffer: [32]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try map.writeWhere(&writer, first.line);
    try expectEqualStrings("test.ga:2", writer.buffered());

    // a word changed since is not described
    chip.nodes[i].mem[0] = 0;
    try expectEqual(null, map.at(&chip, i, 0));
}
