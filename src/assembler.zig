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
//!     ..              fill the rest of the instruction word with nops
//!     2 <sl           make the next opcode go in slot 0 or 1, starting a new
//!                     instruction word if needed
//!     begin again     loop forever
//!     begin until     loop until T is nonzero
//!     begin -until    loop until T is negative
//!     begin while repeat
//!                     loop while T is nonzero, or with -while while T is
//!                     negative
//!     for next        loop R+1 times
//!     for unext       loop R+1 times within a single instruction word
//!     for -if *next then
//!                     loop R+1 times, leaving the loop when T is positive
//!     if then         skip ahead when T is zero
//!     -if then        skip ahead when T is positive
//!     zif then        skip ahead when R is nonzero, decrementing it, or
//!                     otherwise drop R
//!     ahead then      skip ahead
//!     leap then       call ahead
//!     if else then    skip ahead to after else, which skips ahead to then
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
    /// the bin arrayForth 3's BIN saved the program as, or null for the
    /// node's own bin. Only programs in their node's own bin are loaded.
    bin: ?u32 = null,
    ram: [64]Word,
    /// number of words used, from address 0
    len: u7,
    /// the source line each word was assembled from, or 0 for an unused
    /// word. Lines past the largest number that fits get that number.
    lines: [64]u32 = @splat(0),
    entry: Address,
    /// where the program first calls a ROM word, which needs the node's ROM
    rom_word: ?Diagnostic = null,
    /// code assembled into ROM by arrayForth 3, as for checking a chip's ROM
    rom: ?Rom = null,

    pub const Rom = struct {
        /// x080 to x0bf
        words: [64]Word,
        lines: [64]u32,
        /// number of words used, from x080
        len: u7,
    };

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

pub const Error = Builder.Error || error{
    UnknownWord,
    MissingLabelName,
    UnterminatedComment,
    UnterminatedString,
    /// a label named like an opcode, port, number or other word
    ReservedLabel,
    /// a control structure word without its matching begin, for or if
    UnmatchedControl,
    /// begin, for or if without its closing word
    UnclosedControl,
    /// begin, for and if nested too deeply
    ControlTooDeep,
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
    return assembleNodesFor(&Spec.ga144, source, programs, diagnostic);
}

/// `assembleNodes` for a chip other than the GA144, whose nodes may have
/// other ROMs, and so other ROM words
pub fn assembleNodesFor(chip: *const Spec, source: []const u8, programs: []Program, diagnostic: *Diagnostic) Error![]Program {
    var tokens: Tokenizer = .{ .source = source };
    var count: usize = 0;
    var node: Directive = .{ .number = 0 };
    while (true) {
        var assembler: Assembler = .{ .tokens = &tokens, .diagnostic = diagnostic, .chip = chip, .node = node.number };
        const next_node = try assembler.run();
        if (assembler.builder.len > 0) {
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

const Control = union(enum) {
    /// address jumped back to by again, next and unext
    begin: u7,
    /// jump patched by then
    forward: Builder.Location,
};

const Assembler = struct {
    tokens: *Tokenizer,
    diagnostic: *Diagnostic,
    chip: *const Spec,
    /// number of the node being assembled, whose ROM decides its ROM words
    node: u16,

    builder: Builder = .{},
    rom_word: ?Diagnostic = null,

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
            .ram = self.builder.mem[0..64].*,
            .len = self.builder.len,
            .lines = self.builder.lines[0..64].*,
            .entry = .{ .io = false, .rom = false, .local = self.builder.labelAddress("main") orelse 0 },
            .rom_word = self.rom_word,
        };
    }

    /// resolves references once all of a node's words are assembled
    fn finish(self: *Assembler) Error!void {
        if (self.control_count != 0) {
            self.diagnostic.* = .{ .line = self.tokens.line };
            return error.UnclosedControl;
        }
        try self.builder.finish(self.diagnostic);
    }

    fn next(self: *Assembler) Error!?[]const u8 {
        const token = self.tokens.next() catch |err| return self.tokenError(self.tokens.*, err);
        self.diagnostic.* = .{ .line = self.tokens.start_line, .token = token orelse return null };
        self.builder.line = self.tokens.start_line;
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
        const b = &self.builder;
        if (eql(token, ":")) {
            const name = try self.next() orelse return error.MissingLabelName;
            if (reserved(name) or self.chip.romWord(self.node, name) != null) return error.ReservedLabel;
            try b.define(name);
        } else if (eql(token, ";")) {
            try b.ret();
        } else if (eql(token, "begin")) {
            try self.pushControl(.{ .begin = try b.begin() });
        } else if (eql(token, "again")) {
            try b.back(.jump, try self.popBegin());
        } else if (eql(token, "for")) {
            try b.emit(.@">r");
            try self.pushControl(.{ .begin = try b.begin() });
        } else if (eql(token, "next")) {
            try b.back(.next, try self.popBegin());
        } else if (eql(token, "unext")) {
            try b.unext(try self.popBegin());
        } else if (forwards.get(token)) |opcode| {
            try self.pushControl(.{ .forward = try b.forward(opcode) });
        } else if (eql(token, "then")) {
            try b.then(try self.popForward());
        } else if (eql(token, "else")) {
            const location = try self.popForward();
            try self.pushControl(.{ .forward = try b.forward(.jump) });
            try b.then(location);
        } else if (eql(token, "while") or eql(token, "-while")) {
            // the forward jump goes under the begin it leaves
            const destination = try self.popBegin();
            try self.pushControl(.{ .forward = try b.forward(if (eql(token, "while")) .@"if" else .@"-if") });
            try self.pushControl(.{ .begin = destination });
        } else if (eql(token, "until") or eql(token, "-until")) {
            try b.back(if (eql(token, "until")) .@"if" else .@"-if", try self.popBegin());
        } else if (eql(token, "repeat")) {
            try b.back(.jump, try self.popBegin());
            try b.then(try self.popForward());
        } else if (eql(token, "*next")) {
            // a next back past a forward jump, which stays unresolved
            const location = try self.popForward();
            try b.back(.next, try self.popBegin());
            try self.pushControl(.{ .forward = location });
        } else if (eql(token, "..")) {
            b.alignWord();
        } else if (token[0] == '"') {
            for (token[1 .. token.len - 1]) |byte| try b.data(byte);
        } else if (token[0] == '\'' and token.len > 1) {
            if (self.romWord(token[1..])) |destination| {
                try b.literal(destination);
            } else try b.literalLabel(token[1..]);
        } else if (constant(token)) |value| {
            try b.literal(value);
        } else if (std.meta.stringToEnum(Opcode, token)) |opcode| switch (opcode) {
            .jump, .call => return error.UnknownWord,
            else => try b.emit(opcode),
        } else if (try number(token)) |value| {
            const following = try self.peek();
            if (following != null and eql(following.?, ",")) {
                _ = try self.next();
                try b.data(value);
            } else if (following != null and eql(following.?, "org")) {
                _ = try self.next();
                try b.org(value);
            } else if (following != null and eql(following.?, "<sl")) {
                _ = try self.next();
                try b.limitSlot(value);
            } else try b.literal(value);
        } else if (self.romWord(token)) |destination| {
            try b.call(destination);
        } else try b.callLabel(token);
    }

    fn pushControl(self: *Assembler, control: Control) Error!void {
        if (self.control_count == self.control.len) return error.ControlTooDeep;
        self.control[self.control_count] = control;
        self.control_count += 1;
    }

    fn popBegin(self: *Assembler) Error!u7 {
        if (self.control_count == 0 or self.control[self.control_count - 1] != .begin) {
            return error.UnmatchedControl;
        }
        self.control_count -= 1;
        return self.control[self.control_count].begin;
    }

    fn popForward(self: *Assembler) Error!Builder.Location {
        if (self.control_count == 0 or self.control[self.control_count - 1] != .forward) {
            return error.UnmatchedControl;
        }
        self.control_count -= 1;
        return self.control[self.control_count].forward;
    }

    /// the address of a ROM word of the node, noting the first one used
    fn romWord(self: *Assembler, name: []const u8) ?u10 {
        const destination = self.chip.romWord(self.node, name) orelse return null;
        if (self.rom_word == null) self.rom_word = .{ .line = self.tokens.start_line, .token = name };
        return destination;
    }
};

fn constant(token: []const u8) ?Word {
    for (constants) |c| if (eql(c[0], token)) return c[1];
    return null;
}

/// words that jump forward to a then, with the opcode they compile
const forwards: std.StaticStringMap(Opcode) = .initComptime(.{
    .{ "if", .@"if" },
    .{ "-if", .@"-if" },
    .{ "zif", .next },
    .{ "ahead", .jump },
    .{ "leap", .call },
});

/// words other than opcodes and constants that compile takes before labels
const keywords = [_][]const u8{
    ":",     ",",      "org",   "<sl",    "..",     "begin", "again", "for",   "then", "else",
    "while", "-while", "until", "-until", "repeat", "*next", "zif",   "ahead", "leap", "node",
};

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

fn expectAssembleError(expected: Error, source: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    try expectError(expected, assemble(source, &diagnostic));
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
    try expectEqualSlices(u32, &.{ 1, 1, 4, 0 }, program.lines[0..4]);
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

test "loops that end on a condition" {
    try expectAssembles("begin dup until", &.{
        Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .@"if", .slot_2 = .@".", .slot_3 = 7 }, 1, 0),
    });
    try expectAssembles("begin dup -until", &.{
        Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .@"-if", .slot_2 = .@".", .slot_3 = 7 }, 1, 0),
    });
    try expectAssembles("begin dup while drop repeat dup", &.{
        Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .@"if", .slot_2 = .@".", .slot_3 = 7 }, 1, 2),
        Instruction.encodeJump(.{ .slot_0 = .drop, .slot_1 = .jump, .slot_2 = .@".", .slot_3 = 7 }, 1, 0),
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
    });
    try expectAssembles("begin -while again then", &.{
        Instruction.encodeJump(.{ .slot_0 = .@"-if", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 2),
        Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 0),
    });
    // a next back to the start of the loop, past a -if out of it
    try expectAssembles("for dup -if *next then drop", &.{
        Instruction.encode(.{ .slot_0 = .@">r", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .@"-if", .slot_2 = .@".", .slot_3 = 7 }, 1, 3),
        Instruction.encodeJump(.{ .slot_0 = .next, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 1),
        Instruction.encode(.{ .slot_0 = .drop, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
    });
}

test "jumps ahead" {
    try expectAssembles("ahead dup then", &.{
        Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 2),
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
    });
    // zif is next going forward
    try expectAssembles("zif then", &.{
        Instruction.encodeJump(.{ .slot_0 = .next, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 1),
    });
    // leap calls ahead, so a return after it is not a tail call
    try expectAssembles("leap ; then dup ;", &.{
        Instruction.encodeJump(.{ .slot_0 = .call, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 2),
        Instruction.encode(.{ .slot_0 = .@";", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@";", .slot_2 = .@".", .slot_3 = 7 }),
    });
    try expectAssembles("if dup else drop then", &.{
        Instruction.encodeJump(.{ .slot_0 = .@"if", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 2),
        Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .jump, .slot_2 = .@".", .slot_3 = 7 }, 1, 3),
        Instruction.encode(.{ .slot_0 = .drop, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
    });
}

test "slot alignment" {
    try expectAssembles("dup .. dup", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
    });
    try expectAssembles("dup dup 2 <sl drop", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .dup, .slot_2 = .@".", .slot_3 = 7 }),
        Instruction.encode(.{ .slot_0 = .drop, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }),
    });
    try expectAssembles("dup 2 <sl drop", &.{
        Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .drop, .slot_2 = .@".", .slot_3 = 7 }),
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
    try expectAssembleError(error.UnknownWord, "jump");
    try expectAssembleError(error.UndefinedLabel, "nowhere");
    try expectAssembleError(error.DuplicateLabel, ": x : x");
    try expectAssembleError(error.MissingLabelName, ":");
    try expectAssembleError(error.UnterminatedComment, "( dup");
    try expectAssembleError(error.UnterminatedString, "\"dup");
    try expectAssembleError(error.NumberOutOfRange, "0x40000");
    try expectAssembleError(error.NumberOutOfRange, "0x100000000");
    try expectAssembleError(error.NumberOutOfRange, "64 org");
    try expectAssembleError(error.ProgramTooLarge, "63 org 1 ,  2 ,");
    try expectAssembleError(error.UnmatchedControl, "then");
    try expectAssembleError(error.UnmatchedControl, "if next");
    try expectAssembleError(error.UnmatchedControl, "else");
    try expectAssembleError(error.UnmatchedControl, "if while");
    try expectAssembleError(error.UnmatchedControl, "begin repeat");
    try expectAssembleError(error.UnmatchedControl, "begin *next");
    try expectAssembleError(error.UnclosedControl, "begin");
    try expectAssembleError(error.UnclosedControl, "begin while again");
    try expectAssembleError(error.NumberOutOfRange, "0 <sl");
    try expectAssembleError(error.NumberOutOfRange, "5 <sl");
    try expectAssembleError(error.ReservedLabel, ": while");
    try expectAssembleError(error.ReservedLabel, ": ..");
    try expectAssembleError(error.UnextBodyTooLong, "for dup dup dup dup unext");
    try expectAssembleError(error.ControlTooDeep, repeat("begin ", 17));
    try expectAssembleError(error.ReservedLabel, ": up");
    try expectAssembleError(error.ReservedLabel, ": dup");
    try expectAssembleError(error.ReservedLabel, ": begin");
    try expectAssembleError(error.ReservedLabel, ": 0x10");

    var diagnostic: Diagnostic = .{};
    try expectError(error.UnknownWord, assemble("dup\n  jump", &diagnostic));
    try expectEqual(2, diagnostic.line);
    try expectEqualStrings("jump", diagnostic.token);
}

test "malformed tokens are reported where they start" {
    var diagnostic: Diagnostic = .{};
    try expectError(error.UnterminatedComment, assemble("dup\n\n\n( never closed", &diagnostic));
    try expectEqual(4, diagnostic.line);
    try expectEqualStrings("(", diagnostic.token);

    // found while looking for a , or org after a number
    try expectError(error.UnterminatedString, assemble("1\n\"text", &diagnostic));
    try expectEqual(2, diagnostic.line);
    try expectEqualStrings("\"", diagnostic.token);
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

const Builder = @import("Builder.zig");
const f18 = @import("f18.zig");
const Spec = @import("Spec.zig");
const Address = f18.Address;
const Computer = f18.Computer;
const Instruction = f18.Instruction;
const Slot = f18.Slot;
const Word = f18.Word;
const Opcode = @import("opcodes.zig").Opcode;

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

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
    try expectError(error.DuplicateNode, assembleNodes("dup\nnode 0 dup", &programs, &diagnostic));
    try expectEqual(2, diagnostic.line);
    try expectEqualStrings("node 0", diagnostic.token);
    try expectError(error.TooManyNodes, assemble("dup node 1 dup", &diagnostic));
    try expectEqualStrings("node 1", diagnostic.token);
    // a single node can be any node
    try expectEqual(5, (try assemble("node 5 dup", &diagnostic)).node);
    try expectError(error.UndefinedLabel, assemble("node 1 : x node 2 x", &diagnostic));
    try expectAssembleError(error.InvalidNode, "node");
    try expectAssembleError(error.InvalidNode, "node 10000");
    try expectAssembleError(error.InvalidNode, "node up");
    try expectAssembleError(error.ReservedLabel, ": node");
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
    try expectError(error.UndefinedLabel, assemble("node 708 *.17", &diagnostic));

    // programs note where they first need ROM
    try expectEqual(null, (try assemble(": x dup ; x", &diagnostic)).rom_word);
    const rom_word = (try assemble("dup\n dup warm *.17", &diagnostic)).rom_word.?;
    try expectEqual(2, rom_word.line);
    try expectEqualStrings("warm", rom_word.token);

    // the address of a ROM word, such as a return to warm
    try expectAssembles("'warm >r", &.{
        Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@">r", .slot_2 = .@".", .slot_3 = 7 }),
        0xa9,
    });
    try expectEqualStrings("warm", (try assemble("'warm", &diagnostic)).rom_word.?.token);

    try expectAssembleError(error.ReservedLabel, ": warm");
    try expectAssembleError(error.ReservedLabel, ": *.17");
}

/// Any source assembles or fails to, without crashing
fn fuzzAssemble(_: void, smith: *std.testing.Smith) !void {
    var source: [4096]u8 = undefined;
    const len = smith.slice(&source);
    var programs: [16]Program = undefined;
    var diagnostic: Diagnostic = .{};
    _ = assembleNodes(source[0..len], &programs, &diagnostic) catch return;
}

test "fuzz assembling" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var seeds: std.ArrayList([]const u8) = .empty;
    try fuzz.addFiles(arena.allocator(), &seeds, &.{ "examples/echo.ga", "examples/hello.ga", "examples/upcase.ga" }, null, 4096);
    try std.testing.fuzz({}, fuzzAssemble, .{ .corpus = seeds.items });
}

const fuzz = @import("fuzz.zig");
