pub const Opcode = enum(u5) {
    // zig fmt: off

    // Transfer of Program Control
    @";"    = 0x00, // return
    ex      = 0x01, // execute (swap P and R)
    jump    = 0x02, // *name ;* - jump to *name*
    call    = 0x03, // *name* - call to *name*
    unext   = 0x04, // loop within I (decrement R)
    next    = 0x05, // loop to address (decrement R)
    @"if"   = 0x06, // jump if T=0
    @"-if"  = 0x07, // jump if T>=0

    // Memory Access
    @"@p"   = 0x08, // literal (autoincrement P)
    @"@+"   = 0x09, // fetch via A (autoincrement A)
    @"@b"   = 0x0a, // fetch via B
    @"@"    = 0x0b, // fetch via A
    @"!p"   = 0x0c, // store via P (autoincrement P)
    @"!+"   = 0x0d, // store via A (autoincrement A)
    @"!b"   = 0x0e, // store via B
    @"!"    = 0x0f, // store via A

    // Arithmetic, Logic and Register Manipulation
    @"+*"   = 0x10, // multiply step
    @"2*"   = 0x11, // left shift
    @"2/"   = 0x12, // right shift (signed)
    inv     = 0x13, // invert all bits
    @"+"    = 0x14, // add (or add with carry)
    @"and"  = 0x15, // replace T with S & T
    xor     = 0x16, // exclusive or
    drop    = 0x17, // drop T
    dup     = 0x18, // duplicate T
    @"r>"   = 0x19, // pop R push T
    over    = 0x1a, // move T to S, move old S to T
    a       = 0x1b, // fetch from A
    @"."    = 0x1c, // nop
    @">r"   = 0x1d, // pop T push R
    @"b!"   = 0x1e, // store *into* B
    @"a!"   = 0x1f, // store *into* A

    // zig fmt: on
};

test {
    try std.testing.expectEqual(32, @typeInfo(Opcode).@"enum".fields.len);
}

const std = @import("std");
