//! A minimal assembler for the RAM of F18A nodes. It packs opcodes into
//! instruction words
//!
//! Source is a sequence of whitespace separated words:
//!
//!     : name          define a label at the next instruction word
//!     name            call a label or ROM word, or jump to it when followed by ;
//!     'name           push the address of a label or ROM word
//!     123 -1 0x7b     push a number (@p followed by the number)
//!     123 ,           compile a number into memory as data
//!     "text"          compile each byte of text into memory as data
//!     0x10 org        continue assembling at an address
//!     begin again     loop forever
//!     for next        loop R+1 times
//!     for unext       loop R+1 times within a single instruction word
//!     if then         skip ahead when T is zero
//!     -if then        skip ahead when T is positive
//!     io right rdlu   push the address of the io register, a port or multiport
//!     \ comment       comment to the end of the line
//!     ( comment )     comment
//!     node 708        assemble the following words for node 708
//!
//! along with the opcodes ; ex @p @+ @b @ !p !+ !b ! +* 2* 2/ inv + and xor
//! drop dup r> over a . >r b! a!
//!
//! Words before the first node directive are for node 000. Each node has its
//! own labels, and execution starts at its label `main` if there is one,
//! otherwise at 0.

pub const Program = struct {
    /// node number, yxx
    node: u16 = 0,
    ram: [64]Word,
    /// number of words used, from address 0
    len: u7,
    /// the source line each word was assembled from, or 0 for an unused
    /// word. Lines past the largest number that fits get that number.
    lines: [64]u16 = @splat(0),
    entry: Address,
    /// where the program first calls a ROM word, which needs the node's ROM
    rom_word: ?Diagnostic = null,

    /// Copies the program into the RAM of `node` and starts it at the entry
    pub fn load(self: Program, node: *Computer) void {
        @memcpy(node.mem[0..64], &self.ram);
        node.p.address = self.entry;
    }
};

/// Describes where assembly failed
pub const Diagnostic = struct {
    line: usize = 0,
    token: []const u8 = "",
};

pub const Error = error{
    UnknownWord,
    MissingLabelName,
    UnterminatedComment,
    UnterminatedString,
    NumberOutOfRange,
    ProgramTooLarge,
    TooManyLabels,
    DuplicateLabel,
    /// a label named like an opcode, port, number or other word
    ReservedLabel,
    UndefinedLabel,
    /// a control structure word without its matching begin, for or if
    UnmatchedControl,
    /// begin, for or if without its closing word
    UnclosedControl,
    /// begin, for and if nested too deeply
    ControlTooDeep,
    /// the body of a for unext loop must fit in one instruction word
    UnextBodyTooLong,
    /// node without a number from 0 to 9999
    InvalidNode,
    DuplicateNode,
    /// more nodes than the space given for their programs
    TooManyNodes,
};

/// Assembles source for a single node, which is node 000 unless a node
/// directive picks another. Code for more than one node is TooManyNodes.
pub fn assemble(source: []const u8, diagnostic: *Diagnostic) Error!Program {
    var programs: [1]Program = undefined;
    const assembled = try assembleNodes(source, &programs, diagnostic);
    return if (assembled.len == 1) assembled[0] else .{ .ram = @splat(0), .len = 0, .entry = .{ .io = false, .rom = false, .local = 0 } };
}

/// Assembles source for any number of nodes into `programs`, returning the
/// programs of the nodes that have code.
pub fn assembleNodes(source: []const u8, programs: []Program, diagnostic: *Diagnostic) Error![]Program {
    var tokens: Tokenizer = .{ .source = source };
    var count: usize = 0;
    var node: Directive = .{ .number = 0 };
    while (true) {
        var assembler: Assembler = .{ .tokens = &tokens, .diagnostic = diagnostic, .node = node.number };
        const next_node = try assembler.run();
        if (assembler.len > 0) {
            errdefer diagnostic.* = node.diagnostic;
            for (programs[0..count]) |program| if (program.node == node.number) return error.DuplicateNode;
            if (count == programs.len) return error.TooManyNodes;
            programs[count] = assembler.program(node.number);
            count += 1;
        }
        node = next_node orelse return programs[0..count];
    }
}

/// a node directive, and where it is for errors about its node
const Directive = struct {
    number: u16,
    diagnostic: Diagnostic = .{},
};

/// port and register addresses
const constants = [_]struct { []const u8, u9 }{
    .{ "io", 0x15d },
    .{ "right", 0x1d5 },
    .{ "down", 0x115 },
    .{ "left", 0x175 },
    .{ "up", 0x145 },
    .{ "---u", 0x145 },
    .{ "--l-", 0x175 },
    .{ "--lu", 0x165 },
    .{ "-d--", 0x115 },
    .{ "-d-u", 0x105 },
    .{ "-dl-", 0x135 },
    .{ "-dlu", 0x125 },
    .{ "r---", 0x1d5 },
    .{ "r--u", 0x1c5 },
    .{ "r-l-", 0x1f5 },
    .{ "r-lu", 0x1e5 },
    .{ "rd--", 0x195 },
    .{ "rd-u", 0x185 },
    .{ "rdl-", 0x1b5 },
    .{ "rdlu", 0x1a5 },
};

const nops: Instruction = .{ .slot_0 = .@".", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 };

const Location = struct { address: u6, slot: Slot };

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

const Control = union(enum) {
    /// address jumped back to by again, next and unext
    begin: u6,
    /// jump patched by then
    forward: Location,
};

const Assembler = struct {
    tokens: *Tokenizer,
    diagnostic: *Diagnostic,
    /// number of the node being assembled, which decides its ROM words
    node: u16,

    ram: [64]Word = @splat(0),
    lines: [64]u16 = @splat(0),
    /// next free address, up to 64
    here: u7 = 0,
    len: u7 = 0,

    /// address of the instruction word being packed
    word: ?u6 = null,
    slot: u2 = 0,
    instruction: Instruction = nops,
    /// the call that a following ; turns into a jump
    last_call: ?Location = null,
    rom_word: ?Diagnostic = null,

    labels: [64]Label = undefined,
    label_count: u8 = 0,
    fixups: [64]Fixup = undefined,
    fixup_count: u8 = 0,
    control: [16]Control = undefined,
    control_count: u8 = 0,

    /// Assembles one node's words, returning the directive for the next
    /// node if one ended them.
    fn run(self: *Assembler) Error!?Directive {
        while (try self.next()) |token| {
            if (eql(token, "node")) {
                const start = self.tokens.start;
                const line = self.tokens.start_line;
                const next_node: Directive = .{
                    .number = try self.nodeNumber(),
                    .diagnostic = .{ .line = line, .token = self.tokens.source[start..self.tokens.index] },
                };
                try self.finish();
                return next_node;
            }
            try self.compile(token);
        }
        try self.finish();
        return null;
    }

    fn nodeNumber(self: *Assembler) Error!u16 {
        const token = try self.next() orelse return error.InvalidNode;
        const value = number(token) catch return error.InvalidNode;
        if (value == null or value.? < 0 or value.? > 9999) return error.InvalidNode;
        return @intCast(value.?);
    }

    fn program(self: Assembler, node: u16) Program {
        return .{
            .node = node,
            .ram = self.ram,
            .len = self.len,
            .lines = self.lines,
            .entry = .{
                .io = false,
                .rom = false,
                .local = if (self.find("main")) |main| self.labels[main].address orelse 0 else 0,
            },
            .rom_word = self.rom_word,
        };
    }

    /// resolves references once all of a node's words are assembled
    fn finish(self: *Assembler) Error!void {
        self.finishWord();

        if (self.control_count != 0) {
            self.diagnostic.* = .{ .line = self.tokens.line };
            return error.UnclosedControl;
        }

        for (self.fixups[0..self.fixup_count]) |fixup| {
            const label = self.labels[fixup.label];
            const destination = label.address orelse {
                self.diagnostic.* = .{ .line = fixup.line, .token = label.name };
                return error.UndefinedLabel;
            };
            if (fixup.slot) |slot| {
                self.patch(.{ .address = fixup.address, .slot = slot }, destination);
            } else {
                self.ram[fixup.address] = destination;
            }
        }
    }

    fn next(self: *Assembler) Error!?[]const u8 {
        const token = self.tokens.next() catch |err| return self.tokenError(self.tokens.*, err);
        self.diagnostic.* = .{ .line = self.tokens.start_line, .token = token orelse return null };
        return token;
    }

    fn peek(self: *Assembler) Error!?[]const u8 {
        var copy = self.tokens.*;
        return copy.next() catch |err| self.tokenError(copy, err);
    }

    /// reports a malformed token at its opening delimiter
    fn tokenError(self: *Assembler, tokens: Tokenizer, err: Error) Error {
        self.diagnostic.* = .{ .line = tokens.start_line, .token = tokens.source[tokens.start..][0..1] };
        return err;
    }

    fn compile(self: *Assembler, token: []const u8) Error!void {
        const call = self.last_call;
        self.last_call = null;

        if (eql(token, ":")) {
            const name = try self.next() orelse return error.MissingLabelName;
            try self.define(name);
        } else if (eql(token, ";")) {
            if (call) |location| {
                // tail call: jump instead of call and return
                self.ram[location.address] ^= switch (location.slot) {
                    0 => 1 << 13,
                    1 => 1 << 8,
                    else => 1 << 3,
                };
            } else {
                try self.emit(.@";");
                self.finishWord();
            }
        } else if (eql(token, "ex")) {
            try self.emit(.ex);
            self.finishWord();
        } else if (eql(token, "begin")) {
            try self.begin();
        } else if (eql(token, "again")) {
            _ = try self.emitJump(.jump, try self.popBegin());
        } else if (eql(token, "for")) {
            try self.emit(.@">r");
            try self.begin();
        } else if (eql(token, "next")) {
            _ = try self.emitJump(.next, try self.popBegin());
        } else if (eql(token, "unext")) {
            const begin_address = try self.popBegin();
            if ((self.word orelse self.here) != begin_address) return error.UnextBodyTooLong;
            try self.emit(.unext);
        } else if (eql(token, "if") or eql(token, "-if")) {
            const location = try self.emitJump(if (eql(token, "if")) .@"if" else .@"-if", null);
            try self.pushControl(.{ .forward = location });
        } else if (eql(token, "then")) {
            if (self.control_count == 0 or self.control[self.control_count - 1] != .forward) {
                return error.UnmatchedControl;
            }
            self.control_count -= 1;
            self.finishWord();
            self.patch(self.control[self.control_count].forward, self.here);
        } else if (token[0] == '"') {
            self.finishWord();
            for (token[1 .. token.len - 1]) |byte| self.ram[try self.alloc()] = byte;
        } else if (token[0] == '\'' and token.len > 1) {
            try self.emit(.@"@p");
            const word = try self.alloc();
            if (self.romWord(token[1..])) |destination| {
                self.ram[word] = destination;
                return;
            }
            const label = try self.reference(token[1..]);
            if (self.labels[label].address) |destination| {
                self.ram[word] = destination;
            } else try self.addFixup(.{ .slot = null, .address = word, .label = label, .line = self.tokens.line });
        } else if (constant(token)) |value| {
            try self.literal(value);
        } else if (std.meta.stringToEnum(Opcode, token)) |opcode| switch (opcode) {
            .jump, .call => return error.UnknownWord,
            else => try self.emit(opcode),
        } else if (try number(token)) |value| {
            const following = try self.peek();
            if (following != null and eql(following.?, ",")) {
                _ = try self.next();
                self.finishWord();
                self.ram[try self.alloc()] = value;
            } else if (following != null and eql(following.?, "org")) {
                _ = try self.next();
                self.finishWord();
                if (value < 0 or value >= 64) return error.NumberOutOfRange;
                self.here = @intCast(value);
            } else try self.literal(value);
        } else {
            if (self.romWord(token)) |destination| {
                self.last_call = try self.emitJump(.call, destination);
                return;
            }
            const label = try self.reference(token);
            const known = self.labels[label].address;
            const location = try self.emitJump(.call, if (known) |a| a else null);
            if (self.labels[label].address == null) {
                try self.addFixup(.{ .slot = location.slot, .address = location.address, .label = label, .line = self.tokens.line });
            }
            self.last_call = location;
        }
    }

    /// address of the next word, which must exist
    fn address(self: *Assembler) Error!u6 {
        if (self.here >= 64) return error.ProgramTooLarge;
        return @intCast(self.here);
    }

    fn alloc(self: *Assembler) Error!u6 {
        const result = try self.address();
        self.lines[result] = @intCast(@min(self.tokens.start_line, std.math.maxInt(u16)));
        self.here += 1;
        self.len = @max(self.len, self.here);
        return result;
    }

    fn startWord(self: *Assembler) Error!void {
        self.word = try self.alloc();
        self.slot = 0;
        self.instruction = nops;
    }

    /// stores the instruction word being packed, leaving unused slots as nops
    fn finishWord(self: *Assembler) void {
        const word = self.word orelse return;
        self.ram[word] = self.instruction.encode();
        self.word = null;
    }

    fn setSlot(self: *Assembler, opcode: Opcode) void {
        switch (self.slot) {
            0 => self.instruction.slot_0 = opcode,
            1 => self.instruction.slot_1 = opcode,
            2 => self.instruction.slot_2 = opcode,
            3 => self.instruction.slot_3 = @intCast(@backingInt(opcode) >> 2),
        }
    }

    fn emit(self: *Assembler, opcode: Opcode) Error!void {
        if (self.word == null) try self.startWord();
        // only opcodes with their two low bits clear fit in slot 3
        if (self.slot == 3 and @backingInt(opcode) & 3 != 0) {
            self.finishWord();
            try self.startWord();
        }
        self.setSlot(opcode);
        if (self.slot == 3) self.finishWord() else self.slot += 1;
    }

    /// Compiles an opcode whose destination field fills the rest of the
    /// instruction word, starting a new word if the destination is not
    /// reachable from the current slot. A null destination is patched later.
    fn emitJump(self: *Assembler, opcode: Opcode, destination: ?u10) Error!Location {
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
    fn reachable(self: Assembler, destination: ?u10) bool {
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

    fn patch(self: *Assembler, location: Location, destination: u7) void {
        const word = &self.ram[location.address];
        word.* = (word.* & ~Instruction.destinationMask(location.slot)) | destination;
    }

    fn literal(self: *Assembler, value: Word) Error!void {
        try self.emit(.@"@p");
        self.ram[try self.alloc()] = value;
    }

    fn begin(self: *Assembler) Error!void {
        self.finishWord();
        try self.pushControl(.{ .begin = try self.address() });
    }

    fn pushControl(self: *Assembler, control: Control) Error!void {
        if (self.control_count == self.control.len) return error.ControlTooDeep;
        self.control[self.control_count] = control;
        self.control_count += 1;
    }

    fn popBegin(self: *Assembler) Error!u6 {
        if (self.control_count == 0 or self.control[self.control_count - 1] != .begin) {
            return error.UnmatchedControl;
        }
        self.control_count -= 1;
        return self.control[self.control_count].begin;
    }

    fn find(self: Assembler, name: []const u8) ?u8 {
        for (self.labels[0..self.label_count], 0..) |label, i| {
            if (eql(label.name, name)) return @intCast(i);
        }
        return null;
    }

    /// the address of a ROM word of the node, noting the first one used
    fn romWord(self: *Assembler, name: []const u8) ?u10 {
        const destination = ga144.romWord(self.node, name) orelse return null;
        if (self.rom_word == null) self.rom_word = .{ .line = self.tokens.start_line, .token = name };
        return destination;
    }

    /// returns the label with `name`, adding it as undefined if needed
    fn reference(self: *Assembler, name: []const u8) Error!u8 {
        if (self.find(name)) |label| return label;
        if (self.label_count == self.labels.len) return error.TooManyLabels;
        self.labels[self.label_count] = .{ .name = name, .address = null };
        self.label_count += 1;
        return self.label_count - 1;
    }

    fn define(self: *Assembler, name: []const u8) Error!void {
        if (reserved(name) or ga144.romWord(self.node, name) != null) return error.ReservedLabel;
        self.finishWord();
        const label = &self.labels[try self.reference(name)];
        if (label.address != null) return error.DuplicateLabel;
        label.address = self.here;
    }

    fn addFixup(self: *Assembler, fixup: Fixup) Error!void {
        if (self.fixup_count == self.fixups.len) return error.TooManyLabels;
        self.fixups[self.fixup_count] = fixup;
        self.fixup_count += 1;
    }
};

fn constant(token: []const u8) ?Word {
    for (constants) |c| if (eql(c[0], token)) return c[1];
    return null;
}

/// words other than opcodes and constants that compile takes before labels
const keywords = [_][]const u8{ ":", ",", "org", "begin", "again", "for", "then", "node" };

/// True for names that would compile as something other than a label
fn reserved(name: []const u8) bool {
    if (name[0] == '"' or name[0] == '\'') return true;
    for (keywords) |keyword| if (eql(keyword, name)) return true;
    if (constant(name) != null or std.meta.stringToEnum(Opcode, name) != null) return true;
    return (number(name) catch return true) != null;
}

/// Parses decimal and 0x prefixed numbers, which may be negative or up to
/// 18 unsigned bits.
fn number(token: []const u8) Error!?Word {
    const value = std.fmt.parseInt(i32, token, 0) catch |err| switch (err) {
        error.InvalidCharacter => return null,
        error.Overflow => return error.NumberOutOfRange,
    };
    if (value < -0x20000 or value > 0x3ffff) return error.NumberOutOfRange;
    return @bitCast(@as(u18, @truncate(@as(u32, @bitCast(value)))));
}

const Tokenizer = struct {
    source: []const u8,
    index: usize = 0,
    line: usize = 1,
    /// where the last token, or the malformed one, starts
    start: usize = 0,
    start_line: usize = 1,

    fn next(self: *Tokenizer) Error!?[]const u8 {
        while (true) {
            while (self.index < self.source.len and isSpace(self.source[self.index])) self.advance();
            if (self.index == self.source.len) return null;

            const start = self.index;
            self.start = start;
            self.start_line = self.line;
            if (self.source[start] == '"') {
                self.advance();
                while (self.index < self.source.len and self.source[self.index] != '"') self.advance();
                if (self.index == self.source.len) return error.UnterminatedString;
                self.advance();
                return self.source[start..self.index];
            }

            while (self.index < self.source.len and !isSpace(self.source[self.index])) self.advance();
            const token = self.source[start..self.index];
            if (eql(token, "\\")) {
                while (self.index < self.source.len and self.source[self.index] != '\n') self.advance();
            } else if (eql(token, "(")) {
                while (self.index < self.source.len and self.source[self.index] != ')') self.advance();
                if (self.index == self.source.len) return error.UnterminatedComment;
                self.advance();
            } else return token;
        }
    }

    fn advance(self: *Tokenizer) void {
        if (self.source[self.index] == '\n') self.line += 1;
        self.index += 1;
    }

    fn isSpace(byte: u8) bool {
        return std.ascii.isWhitespace(byte);
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn expectAssembles(source: []const u8, expected: []const Word) !void {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(source, &diagnostic);
    try expectEqualSlices(Word, expected, program.ram[0..program.len]);
}

fn repeat(comptime text: []const u8, comptime count: usize) []const u8 {
    comptime var result: []const u8 = "";
    inline for (0..count) |_| result = result ++ text;
    return result;
}

fn expectError(expected: Error, source: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(expected, assemble(source, &diagnostic));
}

test "opcodes are packed four to a word" {
    try expectAssembles("dup drop over . a b! 2* +", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .drop, .slot_2 = .over, .slot_3 = 7 }),
        Instruction.encode(.{ .slot_0 = .a, .slot_1 = .@"b!", .slot_2 = .@"2*", .slot_3 = 5 }),
    });
}

test "slot 3 only holds some opcodes" {
    try expectAssembles("dup dup dup drop", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .dup, .slot_2 = .dup, .slot_3 = 7 }),
        Instruction.encode(.{ .slot_0 = .drop, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
    });
}

test "literals follow their instruction word" {
    try expectAssembles("1 2 + 0x3ffff -1", &.{
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@"@p", .slot_2 = .@"+", .slot_3 = 2 }),
        1,
        2,
        -1,
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        -1,
    });
}

test "data, strings and org" {
    try expectAssembles("dup 5 , \"hi\" 7 org 1 ,", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        5,
        'h',
        'i',
        0,
        0,
        0,
        1,
    });
}

test "source lines" {
    var diagnostic: Diagnostic = .{};
    // an instruction word is from the line it starts on
    const program = try assemble("5 dup\ndrop\n\n7 ,", &diagnostic);
    try std.testing.expectEqualSlices(u16, &.{ 1, 1, 4, 0 }, program.lines[0..4]);
}

test "labels, calls and tail calls" {
    const program =
        \\ : main dup two ( a comment )
        \\ : two drop \ another comment
        \\   main ;
    ;
    try expectAssembles(program, &.{
        Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .call, .slot_2 = .@".", .slot_3 = 7 }, 1, 1),
        Instruction.encodeJump(.{ .slot_0 = .drop, .slot_1 = .jump, .slot_2 = .@".", .slot_3 = 7 }, 1, 0),
    });

    var diagnostic: Diagnostic = .{};
    try expectEqual(0, (try assemble(program, &diagnostic)).entry.local);
    try expectEqual(1, (try assemble(": x ; : main x", &diagnostic)).entry.local);
}

test "label addresses" {
    try expectAssembles("'data : data", &.{
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        2,
    });
    // a label already defined
    try expectAssembles(": data 'data", &.{
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        0,
    });
}

test "ex ends its instruction word" {
    try expectAssembles("dup ex drop", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .ex, .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encode(.{ .slot_0 = .drop, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
    });
}

test "control structures" {
    try expectAssembles("begin dup again", &.{
        Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .jump, .slot_2 = .@".", .slot_3 = 7 }, 1, 0),
    });
    try expectAssembles("3 for dup unext", &.{
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@">r", .slot_2 = .@".", .slot_3 = 7 }),
        3,
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .unext, .slot_2 = .@".", .slot_3 = 7 }),
    });
    try expectAssembles("dup for drop next", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@">r", .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encodeJump(.{ .slot_0 = .drop, .slot_1 = .next, .slot_2 = .@".", .slot_3 = 7 }, 1, 1),
    });
    try expectAssembles("if dup then drop", &.{
        Instruction.encodeJump(.{ .slot_0 = .@"if", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 2),
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encode(.{ .slot_0 = .drop, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
    });
}

test "jumps move to a new word when the destination is out of reach" {
    // a forward reference needs at least slot 1
    try expectAssembles("dup dup -if then", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .dup, .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encodeJump(.{ .slot_0 = .@"-if", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 2),
    });
    // slot 2 can reach its own word
    try expectAssembles("begin dup dup again", &.{
        Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .dup, .slot_2 = .jump, .slot_3 = 0 }, 2, 0),
    });
    // but not an address outside the 8 word block P is in
    try expectAssembles("7 org begin dup dup again", &.{
        0,                                                                                     0,                                                                                                 0, 0, 0, 0, 0,
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .dup, .slot_2 = .@".", .slot_3 = 7 }), Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 7),
    });
}

test "port names" {
    try expectAssembles("up b!", &.{
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@"b!", .slot_2 = .@".", .slot_3 = 7 }),
        0x145,
    });
}

test "errors" {
    try expectError(error.UnknownWord, "jump");
    try expectError(error.UndefinedLabel, "nowhere");
    try expectError(error.DuplicateLabel, ": x : x");
    try expectError(error.MissingLabelName, ":");
    try expectError(error.UnterminatedComment, "( dup");
    try expectError(error.UnterminatedString, "\"dup");
    try expectError(error.NumberOutOfRange, "0x40000");
    try expectError(error.NumberOutOfRange, "0x100000000");
    try expectError(error.NumberOutOfRange, "64 org");
    try expectError(error.ProgramTooLarge, "63 org 1 ,  2 ,");
    try expectError(error.UnmatchedControl, "then");
    try expectError(error.UnmatchedControl, "if next");
    try expectError(error.UnclosedControl, "begin");
    try expectError(error.UnextBodyTooLong, "for dup dup dup dup unext");
    try expectError(error.ControlTooDeep, repeat("begin ", 17));
    try expectError(error.ReservedLabel, ": up");
    try expectError(error.ReservedLabel, ": dup");
    try expectError(error.ReservedLabel, ": begin");
    try expectError(error.ReservedLabel, ": 0x10");

    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.UnknownWord, assemble("dup\n  jump", &diagnostic));
    try expectEqual(2, diagnostic.line);
    try std.testing.expectEqualStrings("jump", diagnostic.token);
}

test "malformed tokens are reported where they start" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.UnterminatedComment, assemble("dup\n\n\n( never closed", &diagnostic));
    try expectEqual(4, diagnostic.line);
    try std.testing.expectEqualStrings("(", diagnostic.token);

    // found while looking for a , or org after a number
    try std.testing.expectError(error.UnterminatedString, assemble("1\n\"text", &diagnostic));
    try expectEqual(2, diagnostic.line);
    try std.testing.expectEqualStrings("\"", diagnostic.token);
}

test "nesting up to the control stack depth" {
    var diagnostic: Diagnostic = .{};
    _ = try assemble(comptime repeat("begin ", 16) ++ repeat("again ", 16), &diagnostic);
}

test "labels and then at the end of RAM" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble("'end 63 org 5 , : end", &diagnostic);
    try expectEqual(64, program.ram[1]);

    const branch = try assemble("63 org if then", &diagnostic);
    try expectEqual(
        Instruction.encodeJump(.{ .slot_0 = .@"if", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 64),
        branch.ram[63],
    );
}

const f18 = @import("f18.zig");
const ga144 = @import("ga144.zig");
const Address = f18.Address;
const Computer = f18.Computer;
const Instruction = f18.Instruction;
const Slot = f18.Slot;
const Word = f18.Word;
const Opcode = @import("opcodes.zig").Opcode;

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "node directive" {
    const source =
        \\ dup
        \\ node 101 : x ; : main x
        \\ node 717 : x drop
    ;
    var programs: [3]Program = undefined;
    var diagnostic: Diagnostic = .{};
    const assembled = try assembleNodes(source, &programs, &diagnostic);
    try expectEqual(3, assembled.len);

    try expectEqual(0, assembled[0].node);
    try expectEqual(1, assembled[0].len);

    // each node has its own labels
    try expectEqual(101, assembled[1].node);
    try expectEqual(1, assembled[1].entry.local);
    try expectEqual(717, assembled[2].node);
    try expectEqual(0, assembled[2].entry.local);

    // nodes without code have no program
    try expectEqual(1, (try assembleNodes("node 5 node 6 dup", &programs, &diagnostic)).len);

    // errors about a node point at its directive
    try std.testing.expectError(error.DuplicateNode, assembleNodes("dup\nnode 0 dup", &programs, &diagnostic));
    try expectEqual(2, diagnostic.line);
    try std.testing.expectEqualStrings("node 0", diagnostic.token);
    try std.testing.expectError(error.TooManyNodes, assemble("dup node 1 dup", &diagnostic));
    try std.testing.expectEqualStrings("node 1", diagnostic.token);
    // a single node can be any node
    try expectEqual(5, (try assemble("node 5 dup", &diagnostic)).node);
    try std.testing.expectError(error.UndefinedLabel, assemble("node 1 : x node 2 x", &diagnostic));
    try expectError(error.InvalidNode, "node");
    try expectError(error.InvalidNode, "node 10000");
    try expectError(error.InvalidNode, "node up");
    try expectError(error.ReservedLabel, ": node");
}

test "ROM words" {
    // calls into ROM from slot 1, and a tail call to warm
    try expectAssembles("dup *.17 warm ;", &.{
        Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .call, .slot_2 = .@".", .slot_3 = 7 }, 1, 0xb0),
        Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 0xa9),
    });
    // entering Extended Arithmetic Mode needs a slot 0 call
    try expectAssembles("dup -u/mod", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encodeJump(.{ .slot_0 = .call, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 0x2d6),
    });

    // ROM words depend on the node
    var programs: [1]Program = undefined;
    var diagnostic: Diagnostic = .{};
    const assembled = try assembleNodes("node 300 *.17", &programs, &diagnostic);
    try expectEqual(0xcc, assembled[0].ram[0] & 0x3ff);
    try std.testing.expectError(error.UndefinedLabel, assemble("node 708 *.17", &diagnostic));

    // programs note where they first need ROM
    try expectEqual(null, (try assemble(": x dup ; x", &diagnostic)).rom_word);
    const rom_word = (try assemble("dup\n dup warm *.17", &diagnostic)).rom_word.?;
    try expectEqual(2, rom_word.line);
    try std.testing.expectEqualStrings("warm", rom_word.token);

    // the address of a ROM word, such as a return to warm
    try expectAssembles("'warm >r", &.{
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@">r", .slot_2 = .@".", .slot_3 = 7 }),
        0xa9,
    });
    try std.testing.expectEqualStrings("warm", (try assemble("'warm", &diagnostic)).rom_word.?.token);

    try expectError(error.ReservedLabel, ": warm");
    try expectError(error.ReservedLabel, ": *.17");
}
