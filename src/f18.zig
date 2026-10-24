//! The F18A is an 18-bit computer designed by Chuck Moore.

pub const Word = i18;

const Slot = enum(u2) {
    _,

    pub fn slot(num: u2) Slot {
        return @fromBackingInt(@intCast(num));
    }
};

/// type used by the P register
const ProgramCounter = packed struct(u10) {
    /// holds the address of the next word in the instruction stream
    address: Address,
    /// P9 has no effect on memory decoding; it simply enables the Extended Arithmetic Mode when set.
    extended_arithmetic: bool,

    /// Within RAM or ROM, an address is incremented after each word is fetched,
    /// circularly within whichever storage class it currently points to. Within I/O
    /// space, it is not incremented. Incrementing never affects bits P8 or P9
    pub fn increment(self: *ProgramCounter) void {
        if (!self.address.io) self.address.local +%= 1;
    }

    /// The destination field replaces the low order bits of P. Slot 0 jumps can
    /// reach any address and set P9. Slot 1 and 2 jumps leave P9 unchanged and
    /// force P8 to zero, so they can never land in I/O space.
    pub fn jump(self: *ProgramCounter, slot: Slot, instruction: Word) void {
        const p: u10 = @bitCast(self.*);
        self.* = @bitCast(switch (slot) {
            .slot(0) => @as(LongJump, @bitCast(instruction)).destination,
            .slot(1) => (p & 0x200) | @as(Jump, @bitCast(instruction)).destination,
            .slot(2) => (p & 0x2f8) | @as(ShortJump, @bitCast(instruction)).destination,
            else => return,
        });
    }

    /// R holds all 10 bits of P, so Extended Arithmetic Mode survives call/return.
    pub fn toWord(self: ProgramCounter) Word {
        return @intCast(@as(u10, @bitCast(self)));
    }

    pub fn fromWord(word: Word) ProgramCounter {
        return @bitCast(@as(u10, @truncate(@as(u18, @bitCast(word)))));
    }

    pub const reset: ProgramCounter = .{
        .extended_arithmetic = false,
        .address = .reset,
    };
};

/// Address is a 9-bit value that points to a location in memory or
/// memory-mapped I/O.
pub const Address = packed struct(u9) {
    local: u7,
    rom: bool,
    io: bool,

    pub fn toWord(self: Address) Word {
        const word: u9 = @bitCast(self);
        return @intCast(word);
    }

    pub fn fromWord(word: Word) Address {
        return @bitCast(@as(u9, @intCast(word & 0x1ff)));
    }

    /// initial state on reset
    pub const reset: Address = .{
        .io = false,
        .rom = true,
        .local = 0x2a,
    };
};

pub const LongJump = packed struct(Word) {
    destination: u10,
    _: u8 = 0,
};

pub const Jump = packed struct(Word) {
    destination: u8,
    _: u10 = 0,
};

pub const ShortJump = packed struct(Word) {
    destination: u3,
    _: u15 = 0,
};

pub const Instruction = packed struct(Word) {
    slot_3: u3,
    slot_2: Opcode,
    slot_1: Opcode,
    slot_0: Opcode,

    pub fn getSlot(self: Instruction, slot: Slot) Opcode {
        return switch (slot) {
            .slot(0) => self.slot_0,
            .slot(1) => self.slot_1,
            .slot(2) => self.slot_2,
            .slot(3) => Opcode.fromInt(self.slot_3),
            else => unreachable,
        };
    }
};

/// An F18A computer
pub const Computer = struct {
    const State = enum {
        fetch,
        execution,
        unext,
        next,
    };
    /// control and status for communication ports and I/O logic.
    io: Word,
    /// serves as a "program counter" and extended arithmetic flag
    p: ProgramCounter,
    /// general purpose read/write address or data register
    a: Word,
    /// write only address register, on reset holds the address of io register
    b: u9,
    /// instruction words containing 1, 2, 3 or 4 opcodes for execution
    i: Word,
    /// top 64 words are RAM, bottom half are ROM
    mem: [128]Word,
    // 9 word stack
    return_stack: stack.ReturnStack,
    // 10 word stack
    data_stack: stack.DataStack,
    // involved in some Extended Arithmetic mode instructions
    carry: u1,

    state: State = .fetch,
    // keeps track of current slot to help address decoding
    slot: Slot,

    execution_time: f32,

    pub fn step(self: *Computer) void {
        var instruction: Instruction = undefined;

        current_state: switch (State.fetch) {
            .fetch => {
                self.i = self.fetch(self.p.address);
                instruction = @bitCast(self.i);

                self.p.increment();
                continue :current_state .execution;
            },
            .execution => {
                self.slot = .slot(0);
                self.state = .execution;
                current_slot: switch (@backingInt(self.slot)) {
                    0...2 => {
                        self.execute(instruction.getSlot(self.slot));
                        if (self.state != .execution) continue :current_state self.state;
                        continue :current_slot @backingInt(self.slot);
                    },
                    3 => {
                        self.execute(instruction.getSlot(self.slot));
                        if (self.state != .execution) continue :current_state self.state;
                        break :current_state;
                    },
                }
            },
            // unext with R nonzero loops back to slot 0 without re-fetching
            .unext => continue :current_state .execution,
            .next => return,
        }
    }

    pub fn execute(self: *Computer, opcode: Opcode) void {
        const code: u5 = @intCast(@backingInt(opcode));
        self.execution_time += time: switch (code) {
            0x00...0x03, 0x05...0x07 => {
                self.state = .next;
                opcodes.opcodes[code](self);

                break :time 5.1;
            },
            0x04 => {
                self.state = .unext;
                opcodes.opcodes[code](self);
                // loop is complete, continue with the following slot
                if (self.state == .execution) {
                    self.slot = @fromBackingInt(@intCast(@backingInt(self.slot) +% 1));
                }

                break :time 2.0;
            },
            else => {
                self.state = .execution;
                self.slot = @fromBackingInt(@intCast(@backingInt(self.slot) +% 1));
                opcodes.opcodes[code](self);

                // memory read and write (x08-x0F) are slower than ALU and register operations
                break :time if (code <= 0x0f) 5.1 else 1.5;
            },
        };
    }

    pub fn fetch(self: Computer, address: Address) Word {
        var local = address.local;
        if (local >= 0x40) {
            local -%= 0x40;
        }
        if (address.rom) {
            return self.mem[local + 64];
        }
        return self.mem[local];
    }

    pub fn store(self: *Computer, address: Address, value: Word) void {
        var local = address.local;
        if (local >= 0x40) {
            local -%= 0x40;
        }
        if (!address.rom) {
            self.mem[local] = value;
        }
    }

    pub const reset: Computer = .{
        .io = 0x15555,
        .p = .reset,
        .a = 0,
        .b = 0x15d,
        .i = 0,

        .return_stack = .empty,
        .data_stack = .empty,

        .carry = 0,

        .mem = @splat(0),

        .state = .fetch,
        .slot = .slot(0),
        .execution_time = 0.0,
    };
};

test "ProgramCounter is reset" {
    var p: ProgramCounter = .reset;
    try expectEqual(false, p.extended_arithmetic);
    try expectEqual(Address.reset, p.address);
    p.address.io = true;
    p.address.rom = false;
}

test "I/O address is not incremented" {
    const io_address: Address = .{ .io = true, .rom = false, .local = 0x00 };
    var p: ProgramCounter = .{ .address = io_address, .extended_arithmetic = false };
    p.increment();
    try expectEqual(0x00, p.address.local);
}

test "RAM address is incremented" {
    const ram_address: Address = .{ .io = false, .rom = false, .local = 0x0a };
    var p: ProgramCounter = .{ .address = ram_address, .extended_arithmetic = false };
    p.increment();
    try expectEqual(0x0b, p.address.local);

    // RAM address wraps
    p.address.local = 0x7f;
    p.increment();
    try expectEqual(0, p.address.local);
}

test "ROM address is incremented" {
    const rom_address: Address = .{ .io = false, .rom = true, .local = 0x0a };
    var p: ProgramCounter = .{ .address = rom_address, .extended_arithmetic = false };
    p.increment();
    try expectEqual(0x0b, p.address.local);

    // ROM address wraps
    p.address.local = 0x7f;
    p.increment();
    try expectEqual(0, p.address.local);
}

test "long jump" {
    var p: ProgramCounter = .reset;

    const instruction: Word = @bitCast(LongJump{ .destination = 0b1100000010 });
    p.jump(.slot(0), instruction);

    try expectEqual(true, p.extended_arithmetic);
    try expectEqual(true, p.address.io);
    try expectEqual(false, p.address.rom);
    try expectEqual(0b10, p.address.local);
}

test "jump" {
    var p: ProgramCounter = .reset;

    const instruction: Word = @bitCast(Jump{ .destination = 0b0101010 });
    p.jump(.slot(1), instruction);

    try expectEqual(false, p.extended_arithmetic);
    try expectEqual(false, p.address.io);
    try expectEqual(false, p.address.rom);
    try expectEqual(0b0101010, p.address.local);

    // slot 1 jumps replace P7 so they can move between RAM and ROM
    p.jump(.slot(1), @bitCast(Jump{ .destination = 0b10101010 }));
    try expectEqual(true, p.address.rom);
    try expectEqual(0b0101010, p.address.local);
}

test "slot 1 and 2 jumps force P8 to zero and preserve P9" {
    const io_address: Address = .{ .io = true, .rom = true, .local = 0x55 };
    var p: ProgramCounter = .{ .address = io_address, .extended_arithmetic = true };
    p.jump(.slot(1), @bitCast(Jump{ .destination = 0x12 }));
    try expectEqual(true, p.extended_arithmetic);
    try expectEqual(false, p.address.io);
    try expectEqual(false, p.address.rom);
    try expectEqual(0x12, p.address.local);

    p = .{ .address = io_address, .extended_arithmetic = true };
    p.jump(.slot(2), @bitCast(ShortJump{ .destination = 0b010 }));
    try expectEqual(true, p.extended_arithmetic);
    try expectEqual(false, p.address.io);
    try expectEqual(true, p.address.rom);
    try expectEqual(0x52, p.address.local);
}

test "ProgramCounter toWord and fromWord keep P9" {
    const p: ProgramCounter = .{ .address = .reset, .extended_arithmetic = true };
    try expectEqual(0x2aa, p.toWord());
    try expectEqual(p, ProgramCounter.fromWord(p.toWord()));
    // bits above P9 are ignored
    try expectEqual(p, ProgramCounter.fromWord(@bitCast(@as(u18, 0x3feaa))));
}

test "short jump" {
    var p: ProgramCounter = .reset;

    const instruction: Word = @bitCast(ShortJump{ .destination = 0b101 });
    p.jump(.slot(2), instruction);

    try expectEqual(false, p.extended_arithmetic);
    try expectEqual(false, p.address.io);
    try expectEqual(true, p.address.rom);
    // only the low 3 bits are replaced: x2A -> x2D
    try expectEqual(0x2d, p.address.local);
}

test "address is set on reset" {
    // reset
    const reset_address: Address = .reset;
    try expectEqual(reset_address.io, false);
    try expectEqual(reset_address.rom, true);
    try expectEqual(reset_address.local, 0x2a);
}

test "toWord" {
    const address: Address = .reset;

    try expectEqual(0xaa, address.toWord());
}

test "fromWord" {
    const word: Word = 0b0000000011100010;
    const address: Address = Address.fromWord(word);

    try expectEqual(false, address.io);
    try expectEqual(true, address.rom);
    try expectEqual(0b1100010, address.local);
}

test LongJump {
    const word: Word = 0b000000001111111101;

    const long_jump: LongJump = .{ .destination = 0b1111111101 };
    try expectEqual(word, @as(Word, @bitCast(long_jump)));
}

test Jump {
    const word: Word = 0b000000000001010101;

    const jump: Jump = .{ .destination = 0b1010101 };
    try expectEqual(word, @as(Word, @bitCast(jump)));
    try expectEqual(word, jump.destination);
    try expectEqual(0, jump._);
}

test ShortJump {
    const word: Word = 0b101;

    const short_jump: ShortJump = .{ .destination = 0b101 };
    try expectEqual(word, @as(Word, @bitCast(short_jump)));
}

test Instruction {
    const instruction: Instruction = .{
        .slot_0 = .@"@p",
        .slot_1 = .@";",
        .slot_2 = .@";",
        .slot_3 = 1,
    };

    try expectEqual(0b010000000000000001, @as(Word, @bitCast(instruction)));
    try expectEqual(instruction.getSlot(.slot(0)), instruction.slot_0);
    try expectEqual(instruction.getSlot(.slot(1)), instruction.slot_1);
    try expectEqual(instruction.getSlot(.slot(2)), instruction.slot_2);
    try expectEqual(instruction.getSlot(.slot(3)), .unext);
}

test "computer is initialized" {
    const computer: Computer = .reset;

    try expectEqual(0x15555, computer.io);
    try expectEqual(ProgramCounter.reset, computer.p);
    try expectEqual(0, computer.a);
    try expectEqual(0x15d, computer.b);
    try expectEqual(0, computer.i);
    try expectEqual(stack.ReturnStack.empty, computer.return_stack);
    try expectEqual(stack.DataStack.empty, computer.data_stack);
    try expectEqual(0, computer.carry);
    try expectEqual(.fetch, computer.state);
    try expectEqual(@as([128]Word, @splat(0)), computer.mem);
}

test "fetch" {
    var address: Address = .{ .io = false, .rom = false, .local = 0 };
    var computer: Computer = .reset;

    // RAM
    computer.mem[0] = 55;
    // ROM
    computer.mem[0x40] = 123;

    try expectEqual(55, computer.fetch(address));

    // RAM repeats
    address.local += 0x40;
    try expectEqual(55, computer.fetch(address));

    address.rom = true;
    try expectEqual(123, computer.fetch(address));

    var rom_address: Address = @bitCast(@as(u9, 0x080));
    try expectEqual(123, computer.fetch(rom_address));

    // ROM repeats
    rom_address = @bitCast(@as(u9, 0x0c0));
    try expectEqual(123, computer.fetch(rom_address));
}

test "store" {
    var address: Address = .{ .io = false, .rom = false, .local = 0 };
    var computer: Computer = .reset;

    // RAM
    computer.store(address, 55);
    try expectEqual(55, computer.mem[0]);

    // RAM repeats
    address.local += 0x40;
    computer.store(address, 123);
    try expectEqual(123, computer.mem[0]);
}

test "computer steps correctly" {
    var computer: Computer = .reset;
    computer.return_stack.push(1);

    const inst_1: Instruction = .{
        .slot_0 = .jump,
        .slot_1 = .@";",
        .slot_2 = .@";",
        .slot_3 = 0,
    };
    const inst_2: Instruction = .{
        .slot_0 = .@".",
        .slot_1 = .@".",
        .slot_2 = .@".",
        .slot_3 = 7,
    };
    const inst_3: Instruction = .{
        .slot_0 = .@"@p",
        .slot_1 = .@">r",
        .slot_2 = .@".",
        .slot_3 = 7,
    };

    const inst_4: Instruction = .{
        .slot_0 = .@"@b",
        .slot_1 = .@"!b",
        .slot_2 = .unext,
        .slot_3 = 7,
    };

    const inst_5: Instruction = .{
        .slot_0 = .@"@p",
        .slot_1 = .@">r",
        .slot_2 = .@".",
        .slot_3 = 7,
    };

    const inst_6: Instruction = .{
        .slot_0 = .next,
        .slot_1 = .@";",
        .slot_2 = .@";",
        .slot_3 = 0x6,
    };

    const nops: Instruction = .{
        .slot_0 = .@".",
        .slot_1 = .@".",
        .slot_2 = .@".",
        .slot_3 = 7,
    };
    computer.mem[64 + 0x2a] = @bitCast(inst_1);
    computer.mem[0] = @bitCast(inst_2);
    computer.mem[1] = @bitCast(inst_3);
    computer.mem[2] = 100;
    computer.mem[3] = @bitCast(inst_4);
    computer.mem[4] = @bitCast(inst_5);
    computer.mem[5] = 2;
    computer.mem[6] = @bitCast(nops);
    computer.mem[7] = @bitCast(inst_6);
    computer.mem[8] = @bitCast(nops);

    try expectEqual(0x2a, computer.p.address.local);
    try expectEqual(true, computer.p.address.rom);

    computer.step();
    try expectEqual(inst_1, @as(Instruction, @bitCast(computer.i)));
    try expectEqual(0, computer.p.address.local);
    try expectEqual(false, computer.p.address.rom);

    computer.step();
    try expectEqual(inst_2, @as(Instruction, @bitCast(computer.i)));
    try expectEqual(1, computer.p.address.local);

    computer.step();
    try expectEqual(inst_3, @as(Instruction, @bitCast(computer.i)));
    try expectEqual(3, computer.p.address.local);

    computer.step();
    try expectEqual(inst_4, @as(Instruction, @bitCast(computer.i)));
    try expectEqual(4, computer.p.address.local);

    computer.step();
    try expectEqual(inst_5, @as(Instruction, @bitCast(computer.i)));
    try expectEqual(6, computer.p.address.local);

    computer.step();
    try expectEqual(nops, @as(Instruction, @bitCast(computer.i)));
    try expectEqual(7, computer.p.address.local);

    computer.step();
    try expectEqual(inst_6, @as(Instruction, @bitCast(computer.i)));
    try expectEqual(6, computer.p.address.local);

    computer.step();
    computer.step();
    computer.step();
    computer.step();
}

test "step fetches through the memory map" {
    var computer: Computer = .reset;
    computer.data_stack.push(7);

    // RAM word 1 via its mirror at x041
    computer.p.address = .{ .io = false, .rom = false, .local = 0x41 };
    computer.mem[1] = @bitCast(Instruction{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 });
    computer.step();
    try expectEqual(7, computer.data_stack.s);
    try expectEqual(0x42, computer.p.address.local);

    // ROM word 5 lives at mem[64 + 5], not mem[5]
    computer.p.address = .{ .io = false, .rom = true, .local = 0x05 };
    computer.mem[64 + 5] = @bitCast(Instruction{ .slot_0 = .drop, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 });
    computer.step();
    try expectEqual(0, computer.data_stack.s);
}

test "unext loops R+1 times then continues with the next slot" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.return_stack.push(2);
    computer.data_stack.push(1);
    computer.mem[0] = @bitCast(Instruction{ .slot_0 = .dup, .slot_1 = .@"2*", .slot_2 = .unext, .slot_3 = 6 });

    computer.step();
    // dup 2* runs 3 times, then slot 3 dup runs once
    try expectEqual(8, computer.data_stack.t);
    try expectEqual(8, computer.data_stack.s);
    try expectEqual(0, computer.return_stack.t);
    try expectEqual(1, computer.p.address.local);
}

test "execution time depends on the opcode class" {
    var computer: Computer = .reset;
    computer.slot = .slot(1);

    computer.execute(.@".");
    try expectApproxEqAbs(1.5, computer.execution_time, 0.001);

    computer.execution_time = 0;
    computer.execute(.@"@b");
    try expectApproxEqAbs(5.1, computer.execution_time, 0.001);

    computer.execution_time = 0;
    computer.execute(.@"!");
    try expectApproxEqAbs(5.1, computer.execution_time, 0.001);

    computer.execution_time = 0;
    computer.execute(.@"+*");
    try expectApproxEqAbs(1.5, computer.execution_time, 0.001);
}

test "unext with R zero falls through without looping" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.return_stack.push(0x99);
    computer.return_stack.push(0);
    computer.data_stack.push(5);
    computer.mem[0] = @bitCast(Instruction{ .slot_0 = .@".", .slot_1 = .unext, .slot_2 = .dup, .slot_3 = 7 });

    computer.step();
    try expectEqual(5, computer.data_stack.t);
    try expectEqual(5, computer.data_stack.s);
    try expectEqual(0x99, computer.return_stack.t);
    try expectEqual(1, computer.p.address.local);
}

const opcodes = @import("opcodes.zig");
const Opcode = opcodes.Opcode;
const stack = @import("stack.zig");

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
