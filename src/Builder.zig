//! Packs opcodes, literals and data into the instruction words of one node's
//! RAM, and resolves references to labels once they are all defined. Front
//! ends such as assembler.zig turn source into calls to it.

const Builder = @This();

ram: [64]Word = @splat(0),
/// the source line each word was assembled from, or 0 for an unused word
lines: [64]u16 = @splat(0),
/// next free address, up to 64
here: u7 = 0,
len: u7 = 0,
/// the source line being assembled
line: usize = 1,

/// address of the instruction word being packed
word: ?u6 = null,
slot: u2 = 0,
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
};

/// where a jump is, to patch its destination
pub const Location = struct { address: u6, slot: Slot };

const nops: Instruction = .{ .slot_0 = .@".", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 };

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
        self.finishWord();
        try self.startWord();
    }
    self.setSlot(opcode);
    if (self.slot == 3) self.finishWord() else self.slot += 1;
    if (opcode == .@";" or opcode == .ex) self.finishWord();
}

/// Compiles a return, or turns a call just before it into a jump
pub fn ret(self: *Builder) Error!void {
    const location = self.last_call orelse return self.emit(.@";");
    self.last_call = null;
    self.ram[location.address] ^= switch (location.slot) {
        0 => 1 << 13,
        1 => 1 << 8,
        else => 1 << 3,
    };
}

/// Compiles a call to an address, such as a ROM word
pub fn call(self: *Builder, destination: u10) Error!void {
    const location = try self.emitJump(.call, destination);
    self.last_call = location;
}

/// Compiles a call to a label, which may be defined later
pub fn callLabel(self: *Builder, name: []const u8) Error!void {
    const label = try self.reference(name);
    const known = self.labels[label].address;
    const location = try self.emitJump(.call, if (known) |a| a else null);
    if (self.labels[label].address == null) {
        try self.addFixup(.{ .slot = location.slot, .address = location.address, .label = label, .line = self.line });
    }
    self.last_call = location;
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
    self.finishWord();
    self.ram[try self.alloc()] = value;
}

/// Continues assembling at an address
pub fn org(self: *Builder, destination: Word) Error!void {
    self.last_call = null;
    self.finishWord();
    if (destination < 0 or destination >= 64) return error.NumberOutOfRange;
    self.here = @intCast(destination);
}

/// Defines a label at the next instruction word
pub fn define(self: *Builder, name: []const u8) Error!void {
    self.last_call = null;
    self.finishWord();
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
    self.finishWord();
    return self.address();
}

/// Compiles a jump, next or other opcode that goes back to an address
pub fn back(self: *Builder, opcode: Opcode, destination: u6) Error!void {
    self.last_call = null;
    _ = try self.emitJump(opcode, destination);
}

/// Compiles unext, which goes back to the start of its own instruction word
pub fn unext(self: *Builder, destination: u6) Error!void {
    if ((self.word orelse self.here) != destination) return error.UnextBodyTooLong;
    try self.emit(.unext);
}

/// Compiles an if or other jump forward, to be patched by `then`
pub fn forward(self: *Builder, opcode: Opcode) Error!Location {
    self.last_call = null;
    return self.emitJump(opcode, null);
}

/// Makes a forward jump go to the next instruction word
pub fn then(self: *Builder, location: Location) void {
    self.last_call = null;
    self.finishWord();
    self.patch(location, self.here);
}

/// Resolves references once all of the words are assembled. An undefined
/// label is reported with the line it was used on.
pub fn finish(self: *Builder, diagnostic: *Diagnostic) Error!void {
    self.finishWord();
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

/// address of the next word, which must exist
fn address(self: *Builder) Error!u6 {
    if (self.here >= 64) return error.ProgramTooLarge;
    return @intCast(self.here);
}

fn alloc(self: *Builder) Error!u6 {
    const result = try self.address();
    self.lines[result] = @intCast(@min(self.line, std.math.maxInt(u16)));
    self.here += 1;
    self.len = @max(self.len, self.here);
    return result;
}

fn startWord(self: *Builder) Error!void {
    self.word = try self.alloc();
    self.slot = 0;
    self.instruction = nops;
}

/// stores the instruction word being packed, leaving unused slots as nops
fn finishWord(self: *Builder) void {
    const word = self.word orelse return;
    self.ram[word] = self.instruction.encode();
    self.word = null;
}

fn setSlot(self: *Builder, opcode: Opcode) void {
    switch (self.slot) {
        0 => self.instruction.slot_0 = opcode,
        1 => self.instruction.slot_1 = opcode,
        2 => self.instruction.slot_2 = opcode,
        3 => self.instruction.slot_3 = @intCast(@backingInt(opcode) >> 2),
    }
}

/// Compiles an opcode whose destination field fills the rest of the
/// instruction word, starting a new word if the destination is not
/// reachable from the current slot. A null destination is patched later.
fn emitJump(self: *Builder, opcode: Opcode, destination: ?u10) Error!Location {
    if (self.word == null) try self.startWord();
    if (!self.reachable(destination)) {
        self.finishWord();
        try self.startWord();
    }
    self.setSlot(opcode);
    const location: Location = .{ .address = self.word.?, .slot = self.slot };
    self.ram[location.address] = self.instruction.encodeJump(location.slot, destination orelse 0);
    self.word = null;
    return location;
}

/// Unknown destinations are labels, which are in RAM
fn reachable(self: Builder, destination: ?u10) bool {
    return switch (self.slot) {
        0 => true,
        // slot 1 replaces the low 8 bits of P, reaching RAM and ROM but
        // not Extended Arithmetic Mode
        1 => if (destination) |d| d < 0x100 else true,
        // slot 2 replaces the low 3 bits of P, which has been incremented
        // past this word and its literals
        2 => if (destination) |d| d < 0x100 and d >> 3 == self.here >> 3 else false,
        3 => false,
    };
}

fn patch(self: *Builder, location: Location, destination: u7) void {
    const word = &self.ram[location.address];
    word.* = (word.* & ~Instruction.destinationMask(location.slot)) | destination;
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
const Slot = f18.Slot;
const Word = f18.Word;
const Opcode = @import("opcodes.zig").Opcode;

const std = @import("std");
