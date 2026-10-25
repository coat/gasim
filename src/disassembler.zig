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

/// The address a jump in `slot` of the word at `address` goes to, assuming P
/// has only been incremented past the word itself
pub fn destination(word: Word, address: u9, slot: Slot) u10 {
    var p: ProgramCounter = .{ .address = @bitCast(address), .extended_arithmetic = false };
    p.increment();
    p.jump(slot, word);
    return @bitCast(p);
}

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

const f18 = @import("f18.zig");
const Instruction = f18.Instruction;
const ProgramCounter = f18.ProgramCounter;
const Slot = f18.Slot;
const Word = f18.Word;

const std = @import("std");
const Io = std.Io;
