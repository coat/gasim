pub const Address = f18.Address;
pub const Computer = f18.Computer;
pub const Instruction = f18.Instruction;
pub const Word = f18.Word;

pub const Direction = port.Direction;
pub const Port = port.Port;

pub const arrayforth = @import("arrayforth.zig");
pub const assembler = @import("assembler.zig");
pub const colorforth = @import("colorforth.zig");
pub const boot = @import("boot.zig");
pub const Chip = @import("Chip.zig");
pub const Console = @import("Console.zig");
pub const Editor = @import("Editor.zig");
pub const Tail = @import("Tail.zig");
pub const disassembler = @import("disassembler.zig");
pub const ga144 = @import("ga144.zig");
pub const rom = @import("rom.zig");

const f18 = @import("f18.zig");
pub const port = @import("port.zig");

test {
    _ = @import("arrayforth.zig");
    _ = @import("assembler.zig");
    _ = @import("boot.zig");
    _ = @import("Builder.zig");
    _ = @import("Chip.zig");
    _ = @import("colorforth.zig");
    _ = @import("Console.zig");
    _ = @import("Editor.zig");
    _ = @import("disassembler.zig");
    _ = @import("ga144.zig");
    _ = @import("opcodes.zig");
    _ = @import("port.zig");
    _ = @import("rom.zig");
    _ = @import("stack.zig");
    _ = @import("Tail.zig");
}
