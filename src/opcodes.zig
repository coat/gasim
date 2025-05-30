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
        return @enumFromInt(full_code);
    }
};

test {
    try std.testing.expectEqual(32, @typeInfo(Opcode).@"enum".fields.len);

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
    nop,
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
fn ret(self: *Computer) void {
    self.p.address = @bitCast(@as(u9, @intCast(self.return_stack.pop() & 0x1ff)));
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
fn ex(self: *Computer) void {
    const current_address = self.p.address;
    self.p.address = Address.fromWord(self.return_stack.t);
    self.return_stack.t = current_address.toWord();
}

test ex {
    var computer: Computer = .reset;
    computer.return_stack.push(0x123);

    ex(&computer);
    try expectEqual(@as(Address, @bitCast(@as(u9, 0x123))), computer.p.address);
    try expectEqual(0xc2, computer.return_stack.t);
}

/// name ;
///
/// **Jump**. Sets P to destination address and fetches next instruction word.
fn jump(self: *Computer) void {
    self.p.jump(self.slot, self.i);
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
    computer.slot = 1;
    const expected_dest: u7 = 0b1111101;
    computer.i = @bitCast(f18.Jump{ .destination = expected_dest });

    jump(&computer);
    try expectEqual(expected_dest, computer.p.address.local);
}

test "slot 2 jump" {
    var computer: Computer = .reset;
    computer.slot = 2;
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
    c.return_stack.push(c.p.address.toWord());
    c.p.jump(c.slot, c.i);
}

test call {
    var computer: Computer = .reset;
    computer.i = @bitCast(f18.LongJump{ .destination = 0x123 });

    call(&computer);
    try expectEqual(0x23, computer.p.address.local);
    try expectEqual(0xc2, computer.return_stack.t);
}

/// unext
///
/// Micronext. If R is zero, pops the return stack and continues with the next
/// opcode. If R is nonzero, decrements R by 1 and causes execution to continue
/// with slot 0 of the current instruction word without re-fetching the word.
pub fn unext(self: *Computer) void {
    self.return_stack.t -= 1;
}

test unext {
    var computer: Computer = .reset;
    computer.return_stack.push(0x123);

    unext(&computer);
    try expectEqual(0x122, computer.return_stack.t);
}

/// next
///
/// **Next**. If R is zero, pops the return stack and continues with the next
/// instruction word addressed by P. If R is nonzero, decrements R by 1 and
/// jumps
pub fn next(self: *Computer) void {
    if (self.return_stack.t == 0) {
        _ = self.return_stack.pop();
    } else {
        self.return_stack.t -= 1;
        self.p.jump(self.slot, self.i);
    }
}

test next {
    var computer: Computer = .reset;
    computer.i = @bitCast(f18.Jump{ .destination = 0x44 });
    computer.slot = 1;
    computer.return_stack.push(0x123);

    next(&computer);
    try expectEqual(0x122, computer.return_stack.t);
    computer.step();
    try expectEqual(0x22, computer.p.address.local);
}

/// if
///
/// **If**. If T is nonzero, continues with the next instruction word addressed by P. If T is zero, jumps
pub fn _if(self: *Computer) void {
    if (self.data_stack.t == 0) {
        self.p.jump(self.slot, self.i);
    }
}

test _if {
    var computer: Computer = .reset;
    computer.i = @bitCast(f18.Jump{ .destination = 0x44 });
    computer.slot = 1;
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
pub fn minus_if(self: *Computer) void {
    if (self.data_stack.t >= 0) {
        self.p.jump(self.slot, self.i);
    }
}

test minus_if {
    var computer: Computer = .reset;
    computer.i = @bitCast(f18.Jump{ .destination = 0x44 });
    computer.slot = 1;
    computer.data_stack.t = 1;

    minus_if(&computer);
    try expectEqual(0x44, computer.p.address.local);
    computer.step();
    try expectEqual(0, computer.p.address.local);
}

/// @p
///
/// Pushes data stack, reads [P] into T, and increments P
pub fn fetchP(self: *Computer) void {
    self.data_stack.push(self.fetch(self.p.address));
    self.p.increment();
}

test fetchP {
    var computer: Computer = .reset;
    computer.p.address.rom = false;
    computer.mem[2] = 0x456;

    fetchP(&computer);
    try expectEqual(0x456, computer.data_stack.t);
    try expectEqual(0x43, computer.p.address.local);
}

/// @+
///
/// **Fetch-plus**. Pushes data stack, reads [A] into T, and increments A
pub fn fetchPlus(self: *Computer) void {
    var address = Address.fromWord(self.a);
    self.data_stack.push(self.fetch(address));
    address.local +%= 1;
    self.a = address.toWord();
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
pub fn storeP(self: *Computer) void {
    self.store(self.p.address, self.data_stack.pop());
    self.p.increment();
}

test storeP {
    var computer: Computer = .reset;
    computer.p.address.rom = false;
    computer.data_stack.push(0x456);

    storeP(&computer);
    try expectEqual(0x456, computer.mem[2]);
    try expectEqual(0x43, computer.p.address.local);
    try expectEqual(0, computer.data_stack.t);
}

/// !+
///
/// **Store-plus**. Writes T into [A], pops the data stack, and increments A
pub fn storePlus(self: *Computer) void {
    var address = Address.fromWord(self.a);
    self.store(address, self.data_stack.pop());

    address.local +%= 1;
    self.a = address.toWord();
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
pub fn storeB(self: *Computer) void {
    self.store(Address.fromWord(self.b), self.data_stack.pop());
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
pub fn store(self: *Computer) void {
    self.store(Address.fromWord(self.a), self.data_stack.pop());
}

test store {
    var computer: Computer = .reset;
    computer.a = 0x03f;
    computer.data_stack.push(0x456);

    store(&computer);
    try expectEqual(0x456, computer.mem[63]);
    try expectEqual(0, computer.data_stack.t);
}

/// 2*
///
/// **Two-Star**. Shifts T left one bit logically (shifts zero into T0, discards T17) thus multiplying a signed or unsigned value by two.
pub fn shl(self: *Computer) void {
    self.data_stack.t <<= 1;
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
pub fn shr(self: *Computer) void {
    self.data_stack.t >>= 1;
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
pub fn inv(self: *Computer) void {
    self.data_stack.t = ~self.data_stack.t;
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
pub fn add(self: *Computer) void {
    var result: f18.Word = 0;
    if (self.p.extended_arithmetic) {
        result, self.carry = @addWithOverflow(self.data_stack.s + self.carry, self.data_stack.pop());
    } else {
        result = self.data_stack.s + self.data_stack.pop();
    }
    self.data_stack.push(result);
}

test add {
    var computer: Computer = .reset;
    computer.data_stack.push(0x123);
    computer.data_stack.push(0x456);

    add(&computer);
    try expectEqual(0x579, computer.data_stack.t);
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
    try expectEqual(-2, computer.data_stack.t);
    try expectEqual(1, computer.carry);
}

/// and
///
/// Replaces T with the Boolean AND of S and T. Pops data stack.
pub fn _and(self: *Computer) void {
    self.data_stack.push(self.data_stack.s & self.data_stack.pop());
}

test _and {
    var computer: Computer = .reset;
    computer.data_stack.push(0b101);
    computer.data_stack.push(0b110);

    _and(&computer);
    try expectEqual(0b100, computer.data_stack.t);
}

/// xor
///
/// **Exclusive Or**. Replaces T with the Boolean XOR of S and T. Pops data stack.
pub fn xor(self: *Computer) void {
    self.data_stack.push(self.data_stack.s ^ self.data_stack.pop());
}

test xor {
    var computer: Computer = .reset;
    computer.data_stack.push(0b101);
    computer.data_stack.push(0b110);

    xor(&computer);
    try expectEqual(0b011, computer.data_stack.t);
}

/// drop
///
/// Drops the top item from the data stack by copying S into T and popping the data stack.
pub fn drop(self: *Computer) void {
    _ = self.data_stack.pop();
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
pub fn dup(self: *Computer) void {
    self.data_stack.push(self.data_stack.t);
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
pub fn pop(self: *Computer) void {
    self.data_stack.push(self.return_stack.pop());
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
pub fn over(self: *Computer) void {
    self.data_stack.push(self.data_stack.s);
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
pub fn a(self: *Computer) void {
    self.data_stack.push(self.a);
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
pub fn push(self: *Computer) void {
    self.return_stack.push(self.data_stack.pop());
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
pub fn bStore(self: *Computer) void {
    self.b = @intCast(self.data_stack.pop() & 0x1ff);
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
pub fn aStore(self: *Computer) void {
    self.a = self.data_stack.pop();
}

test aStore {
    var computer: Computer = .reset;
    computer.data_stack.push(0x123);

    aStore(&computer);
    try expectEqual(0x123, computer.a);
    try expectEqual(0, computer.data_stack.t);
}

const f18 = @import("f18.zig");
const Address = f18.Address;
const Computer = f18.Computer;

const std = @import("std");
const expectEqual = std.testing.expectEqual;
