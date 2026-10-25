//! Packs opcodes, literals and data into the instruction words of one node's
//! RAM, and resolves references to labels once they are all defined. Front
//! ends such as assembler.zig and arrayforth.zig turn source into calls to it.

const Builder = @This();

ram: [64]Word = @splat(0),
/// the source line each word was assembled from, or 0 for an unused word
lines: [64]u16 = @splat(0),
/// next free address, up to 64, or up to x7f when wrapping
here: u7 = 0,
len: u7 = 0,
/// the source line being assembled
line: usize = 1,
/// P9 of the location counter, so that code assembled while it is set runs
/// in Extended Arithmetic Mode when jumped to
extended: bool = false,

/// Leave the unused slots of a word that ends with a return, ex or jump, or
/// at the end of the code, as returns rather than nops, as arrayForth 3 does
returns: bool = false,
/// Let the location counter run on past the end of RAM as P does, through
/// x40 to x7f, which address RAM from 0 again, and then around to 0
wrap: bool = false,
/// Let forward jumps go in slot 2, whose 3 bit destination only reaches
/// within the same 8 words, failing at `then` if it is too far
short_forward: bool = false,
/// Build a single instruction word, which may not need a second word for a
/// literal or a jump that does not fit
single_word: bool = false,
/// P when a single instruction word runs, such as the address of the port
/// it is executed from, or null if it is not known
p: ?u10 = null,

/// address of the instruction word being packed
word: ?u6 = null,
/// the next slot to fill, 4 once all are filled
slot: u3 = 0,
instruction: Instruction = nops,
/// the call that a following return turns into a jump
last_call: ?Location = null,

labels: [64]Label = undefined,
label_count: u8 = 0,
fixups: [64]Fixup = undefined,
fixup_count: u8 = 0,

pub const Error = error{
    NumberOutOfRange,
    ProgramTooLarge,
    TooManyLabels,
    DuplicateLabel,
    UndefinedLabel,
    /// the body of a for unext loop must fit in one instruction word
    UnextBodyTooLong,
    /// a then too far for its forward jump's destination field to reach
    UnreachableThen,
    /// a single instruction word with too many opcodes, or a literal
    InlineTooLong,
};

/// where a jump is, to patch its destination
pub const Location = struct {
    address: u6,
    slot: Slot,
    /// P when the jump runs, past its word and any literals before it
    p: u10 = 0,
};

const nops: Instruction = .{ .slot_0 = .@".", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 };
const all_returns: Instruction = .{ .slot_0 = .@";", .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 };

const Label = struct {
    name: []const u8,
    /// null until the label is defined. A label at the end of a full RAM is
    /// at 64, which P reaches by running off the end.
    address: ?u7,
};

/// a reference to a label that is resolved once all labels are defined
const Fixup = struct {
    /// a jump in a slot, or a literal word
    slot: ?Slot,
    address: u6,
    label: u8,
    line: usize,
};

/// Compiles an opcode into the next slot, starting a new word when needed.
/// Returns and ex end their word, since the slots after them never run.
pub fn emit(self: *Builder, opcode: Opcode) Error!void {
    self.last_call = null;
    if (self.word == null) try self.startWord();
    // only opcodes with their two low bits clear fit in slot 3
    if (self.slot == 3 and @backingInt(opcode) & 3 != 0) {
        self.finishWord(.nops);
        try self.startWord();
    }
    self.setSlot(opcode);
    self.slot += 1;
    if (opcode == .@";" or opcode == .ex) {
        self.finishWord(.blank);
    } else if (self.slot == 4) self.finishWord(.nops);
}

/// Compiles a return, or turns a call just before it into a jump
pub fn ret(self: *Builder) Error!void {
    const jump = self.last_call orelse return self.emit(.@";");
    self.last_call = null;
    self.ram[jump.address] ^= switch (jump.slot) {
        0 => 1 << 13,
        1 => 1 << 8,
        else => 1 << 3,
    };
}

/// Compiles a call to an address, such as a ROM word
pub fn call(self: *Builder, destination: u10) Error!void {
    const jump = try self.emitJump(.call, destination);
    self.last_call = jump;
}

/// Compiles a call to a label, which may be defined later
pub fn callLabel(self: *Builder, name: []const u8) Error!void {
    const label = try self.reference(name);
    const known = self.labels[label].address;
    const jump = try self.emitJump(.call, if (known) |a| a else null);
    if (self.labels[label].address == null) {
        try self.addFixup(.{ .slot = jump.slot, .address = jump.address, .label = label, .line = self.line });
    }
    self.last_call = jump;
}

/// Compiles @p followed by the value
pub fn literal(self: *Builder, value: Word) Error!void {
    try self.emit(.@"@p");
    self.ram[try self.alloc()] = value;
}

/// Compiles @p followed by the address of a label, which may be defined later
pub fn literalLabel(self: *Builder, name: []const u8) Error!void {
    try self.emit(.@"@p");
    const word = try self.alloc();
    const label = try self.reference(name);
    if (self.labels[label].address) |destination| {
        self.ram[word] = destination;
    } else try self.addFixup(.{ .slot = null, .address = word, .label = label, .line = self.line });
}

/// Compiles a word of data after the instruction word being packed
pub fn data(self: *Builder, value: Word) Error!void {
    self.last_call = null;
    self.finishWord(.nops);
    self.ram[try self.alloc()] = value;
}

/// Continues assembling at an address
pub fn org(self: *Builder, destination: Word) Error!void {
    self.last_call = null;
    self.finishWord(.nops);
    if (destination < 0 or destination >= @as(Word, if (self.wrap) 0x80 else 64)) return error.NumberOutOfRange;
    self.here = @intCast(destination);
}

/// Ends the instruction word being packed, leaving its unused slots as nops
pub fn alignWord(self: *Builder) void {
    self.last_call = null;
    self.finishWord(.nops);
}

/// the address of the next word, with P9 when extended
pub fn location(self: Builder) u10 {
    return @as(u10, self.here) | @as(u10, @intFromBool(self.extended)) << 9;
}

/// Makes sure the next opcode goes in a slot before `slot`, ending the
/// instruction word being packed if it would not
pub fn limitSlot(self: *Builder, slot: Word) Error!void {
    if (slot < 1 or slot > 4) return error.NumberOutOfRange;
    if (self.word != null and self.slot >= slot) self.alignWord();
}

/// Defines a label at the next instruction word
pub fn define(self: *Builder, name: []const u8) Error!void {
    self.last_call = null;
    self.finishWord(.nops);
    const label = &self.labels[try self.reference(name)];
    if (label.address != null) return error.DuplicateLabel;
    label.address = self.here;
}

/// the address of a defined label
pub fn labelAddress(self: Builder, name: []const u8) ?u7 {
    return self.labels[self.find(name) orelse return null].address;
}

/// Starts a new instruction word to jump back to, returning its address
pub fn begin(self: *Builder) Error!u6 {
    self.last_call = null;
    self.finishWord(.nops);
    return self.address();
}

/// Compiles a jump, next, if or other opcode that goes back to an address
pub fn back(self: *Builder, opcode: Opcode, destination: u10) Error!void {
    self.last_call = null;
    _ = try self.emitJump(opcode, destination);
}

/// Compiles unext, which goes back to the start of its own instruction word
pub fn unext(self: *Builder, destination: u6) Error!void {
    if ((self.word orelse @as(u6, @truncate(self.here))) != destination) return error.UnextBodyTooLong;
    try self.emit(.unext);
}

/// Compiles an if, jump, call or other opcode that goes forward, to be
/// patched by `then`
pub fn forward(self: *Builder, opcode: Opcode) Error!Location {
    self.last_call = null;
    return self.emitJump(opcode, null);
}

/// Makes a forward jump go to the next instruction word
pub fn then(self: *Builder, jump: Location) Error!void {
    self.last_call = null;
    self.finishWord(.nops);
    const destination = self.location();
    if (!lands(jump.slot, jump.p, destination)) return error.UnreachableThen;
    self.patch(jump, destination);
}

/// Resolves references once all of the words are assembled. An undefined
/// label is reported with the line it was used on.
pub fn finish(self: *Builder, diagnostic: *Diagnostic) Error!void {
    self.finishWord(.blank);
    for (self.fixups[0..self.fixup_count]) |fixup| {
        const label = self.labels[fixup.label];
        const destination = label.address orelse {
            diagnostic.* = .{ .line = fixup.line, .token = label.name };
            return error.UndefinedLabel;
        };
        if (fixup.slot) |slot| {
            self.patch(.{ .address = fixup.address, .slot = slot }, destination);
        } else {
            self.ram[fixup.address] = destination;
        }
    }
}

/// where in RAM the next word is, which must exist
fn address(self: *Builder) Error!u6 {
    if (!self.wrap and self.here >= 64) return error.ProgramTooLarge;
    return @truncate(self.here);
}

fn alloc(self: *Builder) Error!u6 {
    if (self.single_word and self.len > 0) return error.InlineTooLong;
    const result = try self.address();
    self.lines[result] = @intCast(@min(self.line, std.math.maxInt(u16)));
    self.here = if (self.wrap) self.here +% 1 else self.here + 1;
    self.len = @max(self.len, @as(u7, result) + 1);
    return result;
}

fn startWord(self: *Builder) Error!void {
    self.word = try self.alloc();
    self.slot = 0;
    self.instruction = if (self.returns) all_returns else nops;
}

/// what to leave in the unused slots of a finished word
const Fill = enum {
    /// for execution that continues into the next word
    nops,
    /// nops, or returns as arrayForth 3 leaves them
    blank,
};

/// stores the instruction word being packed
fn finishWord(self: *Builder, fill: Fill) void {
    const word = self.word orelse return;
    if (fill == .nops) while (self.slot < 4) : (self.slot += 1) self.setSlot(.@".");
    self.ram[word] = self.instruction.encode();
    self.word = null;
}

fn setSlot(self: *Builder, opcode: Opcode) void {
    switch (self.slot) {
        0 => self.instruction.slot_0 = opcode,
        1 => self.instruction.slot_1 = opcode,
        2 => self.instruction.slot_2 = opcode,
        3 => self.instruction.slot_3 = @intCast(@backingInt(opcode) >> 2),
        else => unreachable,
    }
}

/// Compiles an opcode whose destination field fills the rest of the
/// instruction word, starting a new word if the destination is not
/// reachable from the current slot. A null destination is patched later.
fn emitJump(self: *Builder, opcode: Opcode, destination: ?u10) Error!Location {
    if (self.word == null) try self.startWord();
    if (!self.reachable(destination)) {
        self.finishWord(.nops);
        try self.startWord();
    }
    self.setSlot(opcode);
    const jump: Location = .{ .address = self.word.?, .slot = @intCast(self.slot), .p = self.pc() };
    const field = (destination orelse 0) & Instruction.destinationMask(jump.slot);
    self.ram[jump.address] = self.instruction.encodeJump(jump.slot, @intCast(field));
    self.word = null;
    return jump;
}

/// P when the word being packed runs, which has been incremented past the
/// word and its literals
fn pc(self: Builder) u10 {
    return self.p orelse self.location();
}

/// Whether a jump from the current slot reaches the destination, or for an
/// unknown destination, whether it may go there to be patched later.
/// Unknown destinations are forward in RAM. When P is not known, a slot 1
/// jump still reaches below x100, as it keeps only P9, which is assumed
/// clear.
fn reachable(self: Builder, destination: ?u10) bool {
    const slot: Slot = switch (self.slot) {
        0 => return true,
        1, 2 => @intCast(self.slot),
        else => return false,
    };
    const d = destination orelse return slot == 1 or self.short_forward;
    if (self.single_word and self.p == null) return slot == 1 and lands(slot, 0, d);
    return lands(slot, self.pc(), d);
}

/// whether a jump in `slot` taken with P at `p` can go to the destination
fn lands(slot: Slot, p: u10, destination: u10) bool {
    var counter: ProgramCounter = @bitCast(p);
    counter.jump(slot, destination & Instruction.destinationMask(slot));
    return @as(u10, @bitCast(counter)) == destination;
}

fn patch(self: *Builder, jump: Location, destination: u10) void {
    const mask = Instruction.destinationMask(jump.slot);
    const word = &self.ram[jump.address];
    word.* = (word.* & ~mask) | (destination & mask);
}

fn find(self: Builder, name: []const u8) ?u8 {
    for (self.labels[0..self.label_count], 0..) |label, i| {
        if (std.mem.eql(u8, label.name, name)) return @intCast(i);
    }
    return null;
}

/// returns the label with `name`, adding it as undefined if needed
fn reference(self: *Builder, name: []const u8) Error!u8 {
    if (self.find(name)) |label| return label;
    if (self.label_count == self.labels.len) return error.TooManyLabels;
    self.labels[self.label_count] = .{ .name = name, .address = null };
    self.label_count += 1;
    return self.label_count - 1;
}

fn addFixup(self: *Builder, fixup: Fixup) Error!void {
    if (self.fixup_count == self.fixups.len) return error.TooManyLabels;
    self.fixups[self.fixup_count] = fixup;
    self.fixup_count += 1;
}

const Diagnostic = @import("assembler.zig").Diagnostic;
const f18 = @import("f18.zig");
const Instruction = f18.Instruction;
const ProgramCounter = f18.ProgramCounter;
const Slot = f18.Slot;
const Word = f18.Word;
const Opcode = @import("opcodes.zig").Opcode;

const std = @import("std");
