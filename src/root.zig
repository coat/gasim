pub const Address = f18.Address;
pub const Computer = f18.Computer;
pub const Word = f18.Word;

const f18 = @import("f18.zig");

test {
    _ = @import("opcodes.zig");
    _ = @import("stack.zig");
}
