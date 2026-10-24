pub const Address = f18.Address;
pub const Computer = f18.Computer;
pub const Instruction = f18.Instruction;
pub const Word = f18.Word;

pub const Direction = port.Direction;
pub const Port = port.Port;

pub const assembler = @import("assembler.zig");
pub const Console = @import("Console.zig");

const f18 = @import("f18.zig");
const port = @import("port.zig");

test {
    _ = @import("assembler.zig");
    _ = @import("Console.zig");
    _ = @import("opcodes.zig");
    _ = @import("port.zig");
    _ = @import("stack.zig");
}
