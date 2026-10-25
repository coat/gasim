//! Turns instruction words back into opcode names

/// Writes the opcodes of the instruction word at `address`, such as
/// `@p dup . +`, with the destination of a jump in hex such as `call 0a9`.
/// Slots after a return or a jump are not written, since they never run.
pub fn write(writer: *Io.Writer, word: Word, address: u9) Io.Writer.Error!void {
    const instruction: Instruction = .decode(word);
    for (0..4) |i| {
        const slot: Slot = @intCast(i);
        const opcode = instruction.getSlot(slot);
        if (i > 0) try writer.writeByte(' ');
        try writer.writeAll(@tagName(opcode));
        switch (opcode) {
            .@";", .ex => return,
            .jump, .call, .next, .@"if", .@"-if" => {
                if (slot == 3) return;
                try writer.print(" {x:0>3}", .{destination(word, address, slot)});
                return;
            },
            else => {},
        }
    }
}

/// Writes a literal, naming I/O addresses such as `literal right`, and
/// writing other values as numbers such as `literal -1`
pub fn writeLiteral(writer: *Io.Writer, word: Word) Io.Writer.Error!void {
    const value: u18 = @bitCast(word);
    if (value >= 0x100 and value < 0x200) {
        try writer.print("literal {s}", .{ioName(@intCast(value))});
    } else try writer.print("literal {d}", .{word});
}

/// Writes each word of a program with its address, the raw word, its
/// opcodes or literal value, and the source line it was assembled from, such
/// as
///
///     003 29fb2  b! @b . .                   1  left b! @b
///
/// Each source line is written next to the first word assembled from it.
pub fn listing(writer: *Io.Writer, program: Program, source: []const u8) Io.Writer.Error!void {
    const data = literals(&program.ram);
    var lines: Lines = .{ .source = source };
    var previous: usize = 0;
    for (program.ram[0..program.len], program.lines[0..program.len], 0..) |word, line, i| {
        var buffer: [48]u8 = undefined;
        var text: Io.Writer = .fixed(&buffer);
        // a word skipped by org is neither code nor a literal
        if (line != 0) {
            if (data & (@as(u64, 1) << @intCast(i)) != 0) {
                try writeLiteral(&text, word);
            } else try write(&text, word, @intCast(i));
        }
        try writer.print("{x:0>3} {x:0>5}", .{ i, @as(u18, @bitCast(word)) });
        if (line != 0 and line != previous) {
            try writer.print("  {s:<24}{d:>4}  {s}", .{ text.buffered(), line, lines.get(line) });
        } else if (text.end != 0) try writer.print("  {s}", .{text.buffered()});
        try writer.writeByte('\n');
        previous = line;
    }
}

/// finds lines of source by number, quickly when they are found in order
const Lines = struct {
    source: []const u8,
    /// where line `number` starts
    start: usize = 0,
    number: usize = 1,

    fn get(self: *Lines, number: usize) []const u8 {
        if (number < self.number) self.* = .{ .source = self.source };
        while (self.number < number) : (self.number += 1) {
            self.start = (std.mem.findScalarPos(u8, self.source, self.start, '\n') orelse return "") + 1;
        }
        const end = std.mem.findScalarPos(u8, self.source, self.start, '\n') orelse self.source.len;
        return std.mem.trimEnd(u8, self.source[self.start..end], " \t\r");
    }
};

/// The address a jump in `slot` of the word at `address` goes to, assuming P
/// has only been incremented past the word itself
pub fn destination(word: Word, address: u9, slot: Slot) u10 {
    var p: ProgramCounter = .{ .address = @bitCast(address), .extended_arithmetic = false };
    p.increment();
    p.jump(slot, word);
    return @bitCast(p);
}

/// Finds the words of RAM or ROM that are literals read by @p, or written by
/// !p, following the code from its first word. Data that is never reached
/// this way looks like code.
pub fn literals(words: *const [64]Word) u64 {
    var data: u64 = 0;
    var i: u7 = 0;
    while (i < 64) : (i += 1) {
        if (data & (@as(u64, 1) << @intCast(i)) != 0) continue;
        const instruction: Instruction = .decode(words[i]);
        var next = i + 1;
        for (0..4) |slot| switch (instruction.getSlot(@intCast(slot))) {
            .@"@p", .@"!p" => {
                if (next < 64) data |= @as(u64, 1) << @intCast(next);
                next += 1;
            },
            // the rest of the word does not run, or holds a destination
            .@";", .ex, .jump, .call, .next, .@"if", .@"-if" => break,
            else => {},
        };
    }
    return data;
}

/// the name of an I/O address, such as right, rd-u or io
pub fn ioName(address: u9) []const u8 {
    if (address == Computer.io_address) return "io";
    if (address == Computer.data_address) return "data";
    const ports = port.select(address) orelse return "an undefined address";
    return port_names[ports.bits.mask];
}

/// names of each set of ports, by their bits in a `port.Select`
const port_names = names: {
    var names: [16][]const u8 = undefined;
    for (0..16) |bits| {
        const single = [_][]const u8{ "right", "down", "left", "up" };
        if (@popCount(bits) == 1) {
            names[bits] = single[@ctz(bits)];
        } else {
            var name: [4]u8 = "----".*;
            for ("rdlu", 0..) |letter, i| if (bits & (1 << i) != 0) {
                name[i] = letter;
            };
            const final = name;
            names[bits] = &final;
        }
    }
    break :names names;
};

fn expectWrite(expected: []const u8, word: Word, address: u9) !void {
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try write(&writer, word, address);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test write {
    try expectWrite(". . . .", Instruction.encode(.{ .slot_0 = .@".", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }), 0);
    try expectWrite("@p dup + unext", Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .dup, .slot_2 = .@"+", .slot_3 = 1 }), 0);
    try expectWrite("dup ;", Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@";", .slot_2 = .dup, .slot_3 = 0 }), 0);
    // slot 0 jumps reach anywhere, including I/O space
    try expectWrite("jump 1a5", Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }, 0, 0x1a5), 0xa9);
    // slot 1 jumps replace the low 8 bits of P
    try expectWrite("dup call 0b0", Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .call, .slot_2 = .@";", .slot_3 = 0 }, 1, 0xb0), 0x10);
    // slot 2 jumps replace the low 3 bits of P, which is past the word
    try expectWrite("dup dup next 0aa", Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .dup, .slot_2 = .next, .slot_3 = 0 }, 2, 2), 0xa9);
    // a jump opcode in slot 3 has no destination
    try expectWrite("dup dup dup ;", Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .dup, .slot_2 = .dup, .slot_3 = 0 }), 0);
}

test listing {
    const source =
        \\: main 5 dup
        \\  right b! !b ;
        \\
        \\6 org 7 ,
    ;
    var diagnostic: assembler.Diagnostic = .{};
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try listing(&writer, try assembler.assemble(source, &diagnostic), source);
    // the words org skips are left empty, and data looks like code
    try std.testing.expectEqualStrings(
        \\000 04d12  @p dup @p .                1  : main 5 dup
        \\001 00005  literal 5
        \\002 001d5  literal right              2    right b! !b ;
        \\003 29b52  b! !b ;
        \\004 00000
        \\005 00000
        \\006 00007  @b and @b @p               4  6 org 7 ,
        \\
    , writer.buffered());
}

test literals {
    var words: [64]Word = @splat(Instruction.encode(.{ .slot_0 = .@".", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }));
    // two literals after the first word, which look like a return
    words[0] = Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@"@p", .slot_2 = .@"+", .slot_3 = 7 });
    words[1] = 0;
    words[2] = 0;
    // a literal after a jump does not count, nor one after the end
    words[3] = Instruction.encode(.{ .slot_0 = .jump, .slot_1 = .@"@p", .slot_2 = .@".", .slot_3 = 7 });
    words[63] = Instruction.encode(.{ .slot_0 = .@"!p", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 });
    try std.testing.expectEqual(0b110, literals(&words));
}

test ioName {
    try std.testing.expectEqualStrings("io", ioName(0x15d));
    try std.testing.expectEqualStrings("right", ioName(0x1d5));
    try std.testing.expectEqualStrings("up", ioName(0x145));
    try std.testing.expectEqualStrings("rd-u", ioName(0x185));
    try std.testing.expectEqualStrings("rdlu", ioName(0x1a5));
    try std.testing.expectEqualStrings("an undefined address", ioName(0x100));
}

const assembler = @import("assembler.zig");
const Program = assembler.Program;
const f18 = @import("f18.zig");
const Computer = f18.Computer;
const Instruction = f18.Instruction;
const ProgramCounter = f18.ProgramCounter;
const Slot = f18.Slot;
const Word = f18.Word;
const port = @import("port.zig");

const std = @import("std");
const Io = std.Io;
