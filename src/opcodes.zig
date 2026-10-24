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

    pub fn fromInt(value: u3) Opcode {
        const full_code = @as(u5, @intCast(value)) << 2;
        return @fromBackingInt(@intCast(full_code));
    }
};

test {
    try std.testing.expectEqual(32, @typeInfo(Opcode).@"enum".field_names.len);

    try expectEqual(.@";", Opcode.fromInt(0));
    try expectEqual(.unext, Opcode.fromInt(1));
    try expectEqual(.@"@p", Opcode.fromInt(2));
    try expectEqual(.@"!p", Opcode.fromInt(3));
    try expectEqual(.@"+*", Opcode.fromInt(4));
    try expectEqual(.@"+", Opcode.fromInt(5));
    try expectEqual(.dup, Opcode.fromInt(6));
    try expectEqual(.@".", Opcode.fromInt(7));
}

const OpCodeFn = *const fn (*Computer) void;

pub const opcodes = [_]OpCodeFn{
    ret,
    ex,
    jump,
    call,
    unext,
    next,
    _if,
    minus_if,
    fetchP,
    fetchPlus,
    fetchB,
    fetch,
    storeP,
    storePlus,
    storeB,
    store,
    multiplyStep,
    shl,
    shr,
    inv,
    add,
    _and,
    xor,
    drop,
    dup,
    pop,
    over,
    a,
    nop,
    push,
    bStore,
    aStore,
};

/// ;
///
/// **Return**. Moves R into P, popping the return stack. Skips any remaining slots
/// and fetches next instruction word.
fn ret(c: *Computer) void {
    c.p = .fromWord(c.return_stack.pop());
}

test ret {
    var computer: Computer = .reset;
    computer.return_stack.push(0x123);

    ret(&computer);
    try expectEqual(@as(Address, @bitCast(@as(u9, 0x123))), computer.p.address);
}

/// ex
///
/// **Execute**. Exchanges R and P, skips any remaining slots and fetches next instruction word.
fn ex(c: *Computer) void {
    const current = c.p;
    c.p = .fromWord(c.return_stack.t);
    c.return_stack.t = current.toWord();
}

test ex {
    var computer: Computer = .reset;
    computer.return_stack.push(0x123);

    ex(&computer);
    try expectEqual(@as(Address, @bitCast(@as(u9, 0x123))), computer.p.address);
    try expectEqual(0xaa, computer.return_stack.t);
}

/// name ;
///
/// **Jump**. Sets P to destination address and fetches next instruction word.
fn jump(c: *Computer) void {
    c.p.jump(c.slot, c.i);
}

test "slot 0 jump" {
    var computer: Computer = .reset;
    const expected_dest: u9 = 0b101111101;
    computer.i = @bitCast(f18.LongJump{ .destination = expected_dest });

    jump(&computer);
    try expectEqual(expected_dest, @as(u9, @bitCast(computer.p.address)));
}

test "slot 1 jump" {
    var computer: Computer = .reset;
    computer.slot = .slot(1);
    const expected_dest: u7 = 0b1111101;
    computer.i = @bitCast(f18.Jump{ .destination = expected_dest });

    jump(&computer);
    try expectEqual(expected_dest, computer.p.address.local);
}

test "slot 2 jump" {
    var computer: Computer = .reset;
    computer.slot = .slot(2);
    const expected_dest: u3 = 0b101;
    computer.i = @bitCast(f18.ShortJump{ .destination = expected_dest });

    jump(&computer);
    try expectEqual(expected_dest, computer.p.address.local & 0b111);
}

/// name
///
/// **Call**. Moves P into R, pushing an item onto the return stack, sets P to
/// destination address and fetches next instruction word.
pub fn call(c: *Computer) void {
    c.return_stack.push(c.p.toWord());
    c.p.jump(c.slot, c.i);
}

test "call and return preserve extended arithmetic mode" {
    var computer: Computer = .reset;
    computer.p.extended_arithmetic = true;
    computer.slot = .slot(1);
    computer.i = @bitCast(f18.Jump{ .destination = 0x10 });

    call(&computer);
    try expectEqual(true, computer.p.extended_arithmetic);
    try expectEqual(0x2aa, computer.return_stack.t);

    computer.p.extended_arithmetic = false;
    ret(&computer);
    try expectEqual(true, computer.p.extended_arithmetic);
    try expectEqual(Address.reset, computer.p.address);
}

test "ex preserves extended arithmetic mode" {
    var computer: Computer = .reset;
    computer.p.extended_arithmetic = true;
    computer.return_stack.push(0x010);

    ex(&computer);
    try expectEqual(false, computer.p.extended_arithmetic);
    try expectEqual(0x2aa, computer.return_stack.t);

    ex(&computer);
    try expectEqual(true, computer.p.extended_arithmetic);
    try expectEqual(0x010, computer.return_stack.t);
}

test call {
    var computer: Computer = .reset;
    computer.i = @bitCast(f18.LongJump{ .destination = 0x123 });

    call(&computer);
    try expectEqual(0x23, computer.p.address.local);
    try expectEqual(0xaa, computer.return_stack.t);
}

/// unext
///
/// Micronext. If R is zero, pops the return stack and continues with the next
/// opcode. If R is nonzero, decrements R by 1 and causes execution to continue
/// with slot 0 of the current instruction word without re-fetching the word.
pub fn unext(c: *Computer) void {
    if (c.return_stack.t == 0) {
        _ = c.return_stack.pop();
        c.state = .execution;
    } else {
        c.return_stack.t -%= 1;
    }
}

test unext {
    var computer: Computer = .reset;
    computer.return_stack.push(0x55);
    computer.return_stack.push(1);

    computer.state = .unext;
    unext(&computer);
    try expectEqual(0, computer.return_stack.t);
    try expectEqual(.unext, computer.state);

    unext(&computer);
    try expectEqual(0x55, computer.return_stack.t);
    try expectEqual(.execution, computer.state);
}

/// next
///
/// **Next**. If R is zero, pops the return stack and continues with the next
/// instruction word addressed by P. If R is nonzero, decrements R by 1 and
/// jumps
pub fn next(c: *Computer) void {
    if (c.return_stack.t == 0) {
        _ = c.return_stack.pop();
    } else {
        c.return_stack.t -%= 1;
        c.p.jump(c.slot, c.i);
    }
}

test next {
    var computer: Computer = .reset;
    computer.i = @bitCast(f18.Jump{ .destination = 0x44 });
    computer.slot = .slot(1);
    computer.return_stack.push(0x123);

    next(&computer);
    try expectEqual(0x122, computer.return_stack.t);
    computer.step();
    try expectEqual(0x22, computer.p.address.local);
}

/// if
///
/// **If**. If T is nonzero, continues with the next instruction word addressed by P. If T is zero, jumps
pub fn _if(c: *Computer) void {
    if (c.data_stack.t == 0) {
        c.p.jump(c.slot, c.i);
    }
}

test _if {
    var computer: Computer = .reset;
    computer.i = @bitCast(f18.Jump{ .destination = 0x44 });
    computer.slot = .slot(1);
    computer.data_stack.t = 0;

    _if(&computer);
    try expectEqual(0x44, computer.p.address.local);
    computer.step();
    try expectEqual(0, computer.p.address.local);
}

/// -if
///
/// Minus-if. If T is negative (T17 set), continues with the next instruction
/// word addressed by P. If T is positive, jumps
pub fn minus_if(c: *Computer) void {
    if (c.data_stack.t >= 0) {
        c.p.jump(c.slot, c.i);
    }
}

test minus_if {
    var computer: Computer = .reset;
    computer.i = @bitCast(f18.Jump{ .destination = 0x44 });
    computer.slot = .slot(1);
    computer.data_stack.t = 1;

    minus_if(&computer);
    try expectEqual(0x44, computer.p.address.local);
    computer.step();
    try expectEqual(0, computer.p.address.local);
}

/// @p
///
/// Pushes data stack, reads [P] into T, and increments P
pub fn fetchP(c: *Computer) void {
    c.data_stack.push(c.fetch(c.p.address));
    c.p.increment();
}

test fetchP {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0x42 };
    computer.mem[2] = 0x456;

    fetchP(&computer);
    try expectEqual(0x456, computer.data_stack.t);
    try expectEqual(0x43, computer.p.address.local);
}

/// @+
///
/// **Fetch-plus**. Pushes data stack, reads [A] into T, and increments A
pub fn fetchPlus(c: *Computer) void {
    c.data_stack.push(c.fetch(Address.fromWord(c.a)));
    incrementA(c);
}

/// Increments A the same way as P: only the low 7 bits change, wrapping from
/// x07F to x000, and A is not incremented at all when it addresses I/O space.
fn incrementA(c: *Computer) void {
    const value: u18 = @bitCast(c.a);
    if (value & 0x100 != 0) return;
    c.a = @bitCast((value & ~@as(u18, 0x7f)) | ((value +% 1) & 0x7f));
}

test incrementA {
    var computer: Computer = .reset;

    // high bits are preserved and the low 7 bits wrap
    computer.a = @bitCast(@as(u18, 0x3fe7f));
    incrementA(&computer);
    try expectEqual(@as(Word, @bitCast(@as(u18, 0x3fe00))), computer.a);

    // ROM addresses stay in ROM
    computer.a = 0x0ff;
    incrementA(&computer);
    try expectEqual(0x080, computer.a);

    // I/O addresses are not incremented
    computer.a = 0x15d;
    incrementA(&computer);
    try expectEqual(0x15d, computer.a);
}

test fetchPlus {
    var computer: Computer = .reset;
    computer.a = 0x03f;
    computer.mem[63] = 0x456;

    fetchPlus(&computer);
    try expectEqual(0x456, computer.data_stack.t);
    try expectEqual(0x040, computer.a);
}

/// @b
///
/// Fetch-B. Pushes data stack and reads [B] into T.
pub fn fetchB(c: *Computer) void {
    c.data_stack.push(c.fetch(Address.fromWord(c.b)));
}

test fetchB {
    var computer: Computer = .reset;
    computer.b = 0x03f;
    computer.mem[63] = 0x456;

    fetchB(&computer);
    try expectEqual(0x456, computer.data_stack.t);
}

/// @
///
/// **Fetch**. Pushes data stack and reads [A] into T.
pub fn fetch(c: *Computer) void {
    c.data_stack.push(c.fetch(Address.fromWord(c.a)));
}

test fetch {
    var computer: Computer = .reset;
    computer.a = 0x03f;
    computer.mem[63] = 0x456;

    fetch(&computer);
    try expectEqual(0x456, computer.data_stack.t);
}

/// !p
///
/// **Store-P**. Writes T into [P], pops the data stack, and increments P
pub fn storeP(c: *Computer) void {
    c.store(c.p.address, c.data_stack.pop());
    c.p.increment();
}

test storeP {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0x42 };
    computer.data_stack.push(0x456);

    storeP(&computer);
    try expectEqual(0x456, computer.mem[2]);
    try expectEqual(0x43, computer.p.address.local);
    try expectEqual(0, computer.data_stack.t);
}

/// !+
///
/// **Store-plus**. Writes T into [A], pops the data stack, and increments A
pub fn storePlus(c: *Computer) void {
    c.store(Address.fromWord(c.a), c.data_stack.pop());
    incrementA(c);
}

test storePlus {
    var computer: Computer = .reset;
    computer.a = 0x03f;
    computer.data_stack.push(0x456);

    storePlus(&computer);
    try expectEqual(0x456, computer.mem[63]);
    try expectEqual(0x040, computer.a);
    try expectEqual(0, computer.data_stack.t);
}

/// !b
///
/// **Store-B**. Writes T into [B] and pops the data stack.
pub fn storeB(c: *Computer) void {
    c.store(Address.fromWord(c.b), c.data_stack.pop());
}

test storeB {
    var computer: Computer = .reset;
    computer.b = 0x03f;
    computer.data_stack.push(0x456);

    storeB(&computer);
    try expectEqual(0x456, computer.mem[63]);
    try expectEqual(0, computer.data_stack.t);
}

/// !
///
/// **Store**. Writes T into [A] and pops the data stack.
pub fn store(c: *Computer) void {
    c.store(Address.fromWord(c.a), c.data_stack.pop());
}

test store {
    var computer: Computer = .reset;
    computer.a = 0x03f;
    computer.data_stack.push(0x456);

    store(&computer);
    try expectEqual(0x456, computer.mem[63]);
    try expectEqual(0, computer.data_stack.t);
}

/// +*
///
/// **Multiply step**.
/// Signed Multiplicand is in S, unsigned multiplier in A, T=0 at start of a
/// step sequence. Uses T:A as a 36-bit shift register with multiplier in A.
/// Does the following:
/// 1. If bit A0 is zero, shifts the 36-bit register T:A right one bit
///    arithmetically (T17 is not changed and is copied into T16. T0 is copied
///    to A17 and A0 is discarded.)
/// 2. If bit A0 is one, S and T are added as though they had both been
///    extended to be 19 bit signed numbers, and the 37-bit concatenation of
///    this sum and A is shifted right one bit to replace T:A. Overflow may
///    occur if S and T are both nonzero and their signs differ; this can only
///    occur through improper initialization of T.
///
/// This instruction is affected in Extended Arithmetic Mode by including the
/// latched carry in the sum in case (2) above, and by latching the carry out
/// from bit 17 of the sum.
pub fn multiplyStep(c: *Computer) void {
    const multiplier: u18 = @bitCast(c.a);
    // the 19-bit signed value that becomes the high part of T:A after the
    // shift: T alone in case (1), or the sum of S and T in case (2)
    const high: i19 = if (multiplier & 1 == 0) c.data_stack.t else sum: {
        const s = c.data_stack.s;
        const t = c.data_stack.t;
        if (c.p.extended_arithmetic) {
            const carry_in = c.carry;
            const unsigned = @as(u19, @as(u18, @bitCast(s))) + @as(u18, @bitCast(t)) + carry_in;
            c.carry = @truncate(unsigned >> 18);
            break :sum @as(i19, s) + t + carry_in;
        }
        break :sum @as(i19, s) + t;
    };
    const low_bit: u1 = @truncate(@as(u19, @bitCast(high)));
    c.data_stack.t = @truncate(high >> 1);
    c.a = @bitCast(@as(u18, low_bit) << 17 | multiplier >> 1);
}

test "multiplyStep with A0 clear shifts T:A right" {
    var computer: Computer = .reset;
    computer.data_stack.push(0x123);
    computer.data_stack.push(@bitCast(@as(u18, 0x20001)));
    computer.a = 0b10;

    multiplyStep(&computer);
    // T17 is copied into T16, T0 into A17
    try expectEqual(@as(u18, 0x30000), @as(u18, @bitCast(computer.data_stack.t)));
    try expectEqual(@as(u18, 0x20001), @as(u18, @bitCast(computer.a)));
    try expectEqual(0x123, computer.data_stack.s);
}

test "multiplyStep with A0 set adds S to T before shifting" {
    var computer: Computer = .reset;
    computer.data_stack.push(5);
    computer.data_stack.push(2);
    computer.a = 0b11;

    // (5 + 2) = 0b111 shifted right, low bit goes to A17
    multiplyStep(&computer);
    try expectEqual(0b11, computer.data_stack.t);
    try expectEqual(@as(u18, 0x20001), @as(u18, @bitCast(computer.a)));
    try expectEqual(5, computer.data_stack.s);

    // sum is computed as 19 bits, so 0x1ffff + 0x1fffe does not overflow
    computer.data_stack.t = 0x1fffe;
    computer.data_stack.s = 0x1ffff;
    computer.a = 1;
    multiplyStep(&computer);
    try expectEqual(0x1fffe, computer.data_stack.t);
    try expectEqual(@as(u18, 0x20000), @as(u18, @bitCast(computer.a)));
}

test "18 multiply steps multiply signed S by unsigned A into T:A" {
    // a nonzero T at the start is added to the product
    const cases = [_]struct { s: Word, a: u18, t: Word = 0 }{
        .{ .s = 3, .a = 5 },
        .{ .s = -3, .a = 5 },
        .{ .s = 0x1ffff, .a = 0x3ffff },
        .{ .s = -0x20000, .a = 0x3ffff },
        .{ .s = -1, .a = 1 },
        .{ .s = 0x1234, .a = 0x2abcd },
        .{ .s = 0, .a = 0x3ffff },
        .{ .s = 3, .a = 5, .t = 7 },
        .{ .s = -3, .a = 0x3ffff, .t = -100 },
        .{ .s = 0x1ffff, .a = 0x3ffff, .t = 0x1ffff },
    };

    for (cases) |case| {
        var computer: Computer = .reset;
        computer.data_stack.push(case.s);
        computer.data_stack.push(case.t);
        computer.a = @bitCast(case.a);

        for (0..18) |_| multiplyStep(&computer);

        const product = @as(i36, case.s) * @as(i36, case.a) + case.t;
        try expectEqual(@as(Word, @truncate(product >> 18)), computer.data_stack.t);
        try expectEqual(@as(u18, @truncate(@as(u36, @bitCast(product)))), @as(u18, @bitCast(computer.a)));
        try expectEqual(case.s, computer.data_stack.s);
    }
}

test "multiplyStep in extended_arithmetic mode" {
    var computer: Computer = .reset;
    computer.p.extended_arithmetic = true;

    // latched carry is included in the sum: 2 + 4 + 1 = 0b111
    computer.carry = 1;
    computer.data_stack.push(2);
    computer.data_stack.push(4);
    computer.a = 1;
    multiplyStep(&computer);
    try expectEqual(0b11, computer.data_stack.t);
    try expectEqual(@as(u18, 0x20000), @as(u18, @bitCast(computer.a)));
    try expectEqual(0, computer.carry);

    // carry out of bit 17 is latched: -1 + 1 = 0 with carry
    computer.data_stack.t = 1;
    computer.data_stack.s = -1;
    computer.a = 1;
    multiplyStep(&computer);
    try expectEqual(0, computer.data_stack.t);
    try expectEqual(0, computer.a);
    try expectEqual(1, computer.carry);

    // carry is left alone when A0 is clear
    computer.data_stack.t = 0b10;
    computer.a = 0;
    multiplyStep(&computer);
    try expectEqual(1, computer.data_stack.t);
    try expectEqual(1, computer.carry);
}

test "multiplyStep in extended_arithmetic mode carries between steps" {
    var computer: Computer = .reset;
    computer.p.extended_arithmetic = true;
    computer.carry = 0;
    computer.data_stack.push(1);
    computer.data_stack.push(-1);
    computer.a = 0b11;

    // 1 + -1 = 0, latching a carry out of bit 17
    multiplyStep(&computer);
    try expectEqual(0, computer.data_stack.t);
    try expectEqual(1, computer.a);
    try expectEqual(1, computer.carry);

    // the latched carry feeds the next step: 1 + 0 + 1 = 0b10
    multiplyStep(&computer);
    try expectEqual(1, computer.data_stack.t);
    try expectEqual(0, computer.a);
    try expectEqual(0, computer.carry);
}

/// 2*
///
/// **Two-Star**. Shifts T left one bit logically (shifts zero into T0, discards T17) thus multiplying a signed or unsigned value by two.
pub fn shl(c: *Computer) void {
    c.data_stack.t <<= 1;
}

test shl {
    var computer: Computer = .reset;
    computer.data_stack.t = 0b00101010101010101;

    shl(&computer);
    try expectEqual(0b1010101010101010, computer.data_stack.t);
}

/// 2/
///
/// **Two-Slash**. Shifts T right one bit arithmetically (propagates T17 by leaving it unchanged; discards T0) thus dividing a signed value by two and discarding the positive remainder.
pub fn shr(c: *Computer) void {
    c.data_stack.t >>= 1;
}

test shr {
    var computer: Computer = .reset;
    computer.data_stack.t = 0b001010101010101010;

    shr(&computer);
    try expectEqual(0b101010101010101, computer.data_stack.t);
}

/// inv
///
/// **Invert**. Inverts each bit of T, replacing T with its ones complement.
pub fn inv(c: *Computer) void {
    c.data_stack.t = ~c.data_stack.t;
}

test inv {
    var computer: Computer = .reset;
    computer.data_stack.t = 0b001010101010101010;

    inv(&computer);
    try expectEqual(-0b1010101010101011, computer.data_stack.t);

    computer.data_stack.t = 0;
    inv(&computer);
    try expectEqual(-1, computer.data_stack.t);
}

/// +
///
/// **Plus**. Replaces T with the twos complement sum of S and T. Pops data stack into S. This instruction is affected in Extended Arithmetic Mode, becoming **Add with carry**. Includes the latched carry in the sum, and latches the carry out from bit 17.
pub fn add(c: *Computer) void {
    const t = c.data_stack.pop();
    if (c.p.extended_arithmetic) {
        const sum = @as(u19, @as(u18, @bitCast(c.data_stack.t))) + @as(u18, @bitCast(t)) + c.carry;
        c.carry = @truncate(sum >> 18);
        c.data_stack.t = @bitCast(@as(u18, @truncate(sum)));
    } else {
        c.data_stack.t +%= t;
    }
}

test add {
    var computer: Computer = .reset;
    computer.data_stack.push(0x99);
    computer.data_stack.push(0x123);
    computer.data_stack.push(0x456);

    add(&computer);
    try expectEqual(0x579, computer.data_stack.t);
    try expectEqual(0x99, computer.data_stack.s);
    try expectEqual(2, computer.data_stack.index);

    // wraps instead of overflowing
    computer.data_stack.push(0x1ffff);
    computer.data_stack.push(1);
    add(&computer);
    try expectEqual(-0x20000, computer.data_stack.t);
}

test "add in extended_arithmetic mode" {
    var computer: Computer = .reset;
    computer.p.extended_arithmetic = true;
    computer.data_stack.push(0x123);
    computer.data_stack.push(0x456);

    add(&computer);
    try expectEqual(0x579, computer.data_stack.t);
    try expectEqual(0, computer.carry);

    computer.data_stack.push(0x1ffff);
    computer.data_stack.push(0x1ffff);

    add(&computer);
    try expectEqual(0x3fffe, @as(u18, @bitCast(computer.data_stack.t)));
    try expectEqual(0, computer.carry);

    // carry out of bit 17 without signed overflow
    computer.data_stack.push(-1);
    computer.data_stack.push(1);
    add(&computer);
    try expectEqual(0, computer.data_stack.t);
    try expectEqual(1, computer.carry);

    // latched carry is included in the sum
    computer.data_stack.push(0x10);
    computer.data_stack.push(0x20);
    add(&computer);
    try expectEqual(0x31, computer.data_stack.t);
    try expectEqual(0, computer.carry);
}

/// and
///
/// Replaces T with the Boolean AND of S and T. Pops data stack.
pub fn _and(c: *Computer) void {
    const t = c.data_stack.pop();
    c.data_stack.t &= t;
}

test _and {
    var computer: Computer = .reset;
    computer.data_stack.push(0x99);
    computer.data_stack.push(0b101);
    computer.data_stack.push(0b110);

    _and(&computer);
    try expectEqual(0b100, computer.data_stack.t);
    try expectEqual(0x99, computer.data_stack.s);
    try expectEqual(2, computer.data_stack.index);
}

/// xor
///
/// **Exclusive Or**. Replaces T with the Boolean XOR of S and T. Pops data stack.
pub fn xor(c: *Computer) void {
    const t = c.data_stack.pop();
    c.data_stack.t ^= t;
}

test xor {
    var computer: Computer = .reset;
    computer.data_stack.push(0x99);
    computer.data_stack.push(0b101);
    computer.data_stack.push(0b110);

    xor(&computer);
    try expectEqual(0b011, computer.data_stack.t);
    try expectEqual(0x99, computer.data_stack.s);
    try expectEqual(2, computer.data_stack.index);
}

/// drop
///
/// Drops the top item from the data stack by copying S into T and popping the data stack.
pub fn drop(c: *Computer) void {
    _ = c.data_stack.pop();
}

test drop {
    var computer: Computer = .reset;
    computer.data_stack.push(0x123);
    computer.data_stack.push(0x456);

    drop(&computer);
    try expectEqual(0x123, computer.data_stack.t);
    try expectEqual(0, computer.data_stack.s);
}

/// dup
///
/// Duplicates the top item on the data stack by pushing the data stack and copying T into S.
pub fn dup(c: *Computer) void {
    c.data_stack.push(c.data_stack.t);
}

test dup {
    var computer: Computer = .reset;
    computer.data_stack.push(0x123);

    dup(&computer);
    try expectEqual(0x123, computer.data_stack.t);
    try expectEqual(0x123, computer.data_stack.s);
}

/// r>
///
/// Moves R into T, popping the return stack and pushing the data stack.
pub fn pop(c: *Computer) void {
    c.data_stack.push(c.return_stack.pop());
}

test pop {
    var computer: Computer = .reset;
    computer.return_stack.push(0x123);

    pop(&computer);
    try expectEqual(0x123, computer.data_stack.t);
    try expectEqual(0, computer.return_stack.t);
}

/// over
///
/// Makes a copy of S on top of the data stack by pushing S onto the stack,
/// moving T into S, and replacing T by the previous value of S.
pub fn over(c: *Computer) void {
    c.data_stack.push(c.data_stack.s);
}

test over {
    var computer: Computer = .reset;
    computer.data_stack.push(0x80);
    computer.data_stack.push(0x40);

    try expectEqual(0x40, computer.data_stack.t);
    try expectEqual(0x80, computer.data_stack.s);

    over(&computer);
    try expectEqual(0x80, computer.data_stack.t);
    try expectEqual(0x40, computer.data_stack.s);
    try expectEqual(0x80, computer.data_stack.stack[computer.data_stack.index -% 1]);
}

/// a
///
/// Fetches the contents of register A into T, pushing the data stack.
pub fn a(c: *Computer) void {
    c.data_stack.push(c.a);
}

test a {
    var computer: Computer = .reset;
    computer.a = 0x123;

    a(&computer);
    try expectEqual(0x123, computer.data_stack.t);
}

/// nop
///
/// **Nop**. Spends time while making no explicit state changes in registers or stacks.
fn nop(_: *Computer) void {}

/// >r
///
/// Moves T into R, pushing the return stack and popping the data stack.
pub fn push(c: *Computer) void {
    c.return_stack.push(c.data_stack.pop());
}

test push {
    var computer: Computer = .reset;
    computer.data_stack.push(0x123);

    push(&computer);
    try expectEqual(0x123, computer.return_stack.t);
    try expectEqual(0, computer.data_stack.t);
}

/// b!
///
/// **B-Store**. Stores T into register B, popping the data stack.
pub fn bStore(c: *Computer) void {
    c.b = @intCast(c.data_stack.pop() & 0x1ff);
}

test bStore {
    var computer: Computer = .reset;
    computer.data_stack.push(0x123);

    bStore(&computer);
    try expectEqual(0x123, computer.b);
    try expectEqual(0, computer.data_stack.t);
}

/// a!
///
/// **A-Store**. Stores T into register A, popping the data stack.
pub fn aStore(c: *Computer) void {
    c.a = c.data_stack.pop();
}

test aStore {
    var computer: Computer = .reset;
    computer.data_stack.push(0x123);

    aStore(&computer);
    try expectEqual(0x123, computer.a);
    try expectEqual(0, computer.data_stack.t);
}

const gasim = @import("root.zig");
const f18 = @import("f18.zig");

const Address = gasim.Address;
const Computer = gasim.Computer;
const Word = gasim.Word;

const std = @import("std");
const expectEqual = std.testing.expectEqual;
