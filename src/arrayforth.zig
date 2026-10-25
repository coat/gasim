//! An assembler for arrayForth 3 source, as described in DB013 section 4.2.
//! F18 code is written between ASM[ and ]ASM, in bins of code for one node:
//!
//!     1600 708 ( title)  OVER .  ASM[ NODE BIN ERS  # 0 org
//!     : main ( n)  x3F. and  begin @b . -until ;
//!     >BIN ]ASM
//!
//! Outside ASM[, numbers go on the assembler's stack, along with a few
//! polyFORTH words to work with them. Inside it, a label calls the label, a
//! number written as a double, such as 5. or x3F., assembles a literal, and
//! # before either leaves it on the stack instead. Labels are found before
//! other words, and only their length and first 7 characters tell them apart.
//! Directives take their arguments from the stack:
//!
//!     # nn NODE         start assembling for node nn, with its ROM labels
//!     # nn BIN          save the code as bin nn instead of the node's
//!     ERS -ROM -SYM >ROM
//!                       erase RAM, erase everything, forget the ROM labels,
//!                       or treat the labels so far as the ROM's
//!     >BIN              save the code, as the program for its node
//!     # a org  here  ..  # n <sl  +cy -cy  : name  # n equ name
//!                       where to assemble, such as RAM or ROM from x080,
//!                       and labels
//!     d ,  d lit  n alit
//!     # nn its name     call a label of another bin, or its ROM
//!     begin for next unext until -until again end while -while repeat
//!     if -if zif ahead leap then else *next
//!     A[ # a =P ... ]]  build an instruction word, assuming P is a, and
//!                       leave it on the stack
//!     n NL name  d NDL name  n NC name  n CONSTANT name  FORGET name
//!                       define a named literal, double literal, call or
//!                       constant, or forget names back to one
//!     io right down left up data ldata warp center top side corner
//!     east south west north
//!                       named literals, the cardinal ones by node position
//!     ---u --l- ... rdlu await
//!                       named calls of multiports and the default one
//!     ASM FORTH ]ASM EXIT
//!     DUP DROP SWAP OVER ROT 2DUP 2DROP 2SWAP 2OVER AND OR XOR + - NEGATE
//!     D+ DNEGATE S>D . HEX DECIMAL
//!
//! Source may also be polyFORTH blocks of 1024 characters, 16 lines of 64,
//! numbered from 0, which these load:
//!
//!     n LOAD  first last THRU  n FH
//!                       interpret a block, or a range of them, and the
//!                       number of a block relative to the one being loaded
//!     EXIT              stop interpreting the block, which within ASM[
//!                       takes two
//!     t IF{ ... {ELSE} ... }
//!                       interpret the first part if t is nonzero, otherwise
//!                       the second
//!     { ... }           a comment
//!     nn ZAP            erase a bin, which NODE does anyway
//!
//! Boot descriptors, from section 6.1.1 of DB013, say which bins to load
//! into which nodes, and how to start them. Once a source has any, they
//! decide what is loaded instead of each bin going into its own node:
//!
//!     nn +NODE          describe node nn, which by default starts at warm
//!                       with B addressing IO
//!     bin /RAM  a n bin /PART  s d n bin /SOME
//!                       load all of a saved bin, n words of it at a, or n
//!                       words from s into RAM at d, up to three loads
//!     d /A  d /B  d /IO  a /P
//!                       set registers and where the node starts
//!     d.. n /STACK  d.. n /RSTACK  /RINF
//!                       push up to 10 values onto the data stack and 9 onto
//!                       the return stack, the last on top, or fill the
//!                       return stack with -1s
//!     nn !ND  a. b. p nn +ND  s d nn +wire
//!                       load a node's own bin, and set A, B and P, or make
//!                       it a wire from bin 1802
//!     nn ITS name       the value of a label in a saved bin
//!     UP DOWN LEFT RIGHT IO DATA LDATA NORTH SOUTH EAST WEST
//!                       addresses, the cardinal ones for the +NODE node
//!
//! along with the opcodes ; ex @p @+ @b @ !p !+ !b ! +* 2* 2/ inv + and xor
//! drop dup r> over a . >r b! a!, and ( ) and \ comments. Unused slots of a
//! word that ends with a return or jump are left as returns, as arrayForth
//! does, and unused RAM holds `call warm` as it does after ERS. Execution
//! starts at the label `main` if there is one, otherwise at 0. Code saved
//! in a node's own bin is loaded into the node, and code saved with BIN in
//! another bin is kept for `its`.

pub const Error = assembler.Error || error{
    StackUnderflow,
    StackOverflow,
    /// a literal written as a single number, which must be a double
    SingleLiteral,
    /// code or labels before a NODE
    NoNode,
    /// a NODE before the code of the one before it was saved with >BIN
    UnsavedBin,
    /// A[ inside another A[
    NestedInline,
    /// A[ without its ]]
    UnclosedInline,
    /// ]] or =P outside A[
    NotInline,
    /// a block LOAD or THRU cannot find, or FH outside a block
    NoSuchBlock,
    /// blocks loading blocks too deeply
    LoadTooDeep,
    /// a boot descriptor that loads a bin that has not been saved
    NoSuchBin,
    /// a boot descriptor such as /P before +NODE
    NoBootNode,
    /// boot descriptors for more nodes than there is space for
    TooManyDescriptors,
    /// more than three loads into one node's RAM
    TooManyLoads,
    /// a word that acts on the chip, such as UPD, without a chip
    NoChip,
    /// a word that acts on the target node, such as UPD, before NODE
    NoTarget,
    /// the target node is running, rather than waiting for code from a port
    NotWaitingForCode,
    /// R@ or R! of a comm port, which would wait
    PortAccess,
} || Io.Writer.Error;

/// An interpreter that keeps its stack, bins and labels from one source to
/// the next, as at an interactive prompt, and can act on a chip with words
/// of arrayForth 3's IDE (DB013 section 5.1.3):
///
///     nn NODE           select the target node, and the same as
///                       i nn HOOK, where the path i does not matter
///     UPD .STK          show the target's stacks
///     ?RAM ?ROM  a n -ASM
///                       show its RAM or ROM, or disassemble n words from a
///     d LIT             push onto its data stack
///     a R@  d a R!      read or write its memory or registers
///     d RINS            have it execute an instruction word, from its port
///     a CALL            have it jump to a, returning to its port
///     a n nn BOOT       load n words from a in bin nn into its RAM at a
///     RB! @B !B RA@ RA! @A !A @+ !+ R+ R+* R2* R2/ RINV RAND RXOR ROR
///     RDROP RDUP ROVER  have it execute one opcode
///     PATH -HOOK FOCUS VIRGIN
///                       accepted, as gasim reaches every node directly
///
/// Words given to the target run as if called from the port it is waiting
/// on, so they return to it, as `op ; ; ;` and code ending with `;` do. A
/// target must be waiting for code from a port, as nodes are in warm.
/// Numbers are shown in BASE by `.`, `U.`, `D.` and `.S`.
pub const Session = struct {
    interpreter: Interpreter,

    pub const Options = struct {
        /// where words such as . and UPD write
        out: *Io.Writer,
        /// the chip the IDE words act on
        chip: ?*Chip = null,
        /// blocks that LOAD and THRU can interpret
        blocks: ?[]const u8 = null,
    };

    pub fn init(programs: []Program, descriptors: []boot.Descriptor, diagnostic: *Diagnostic, options: Options) Session {
        return .{ .interpreter = .{
            .diagnostic = diagnostic,
            .programs = programs,
            .descriptors = descriptors,
            .blocks = options.blocks,
            .out = options.out,
            .chip = options.chip,
            .interactive = true,
        } };
    }

    /// Interprets `source`, which must last as long as the session, as
    /// labels and names refer to it. After an error the stack is emptied and
    /// interpreting goes back to outside ASM[, keeping bins and labels.
    pub fn interpret(self: *Session, source: []const u8) Error!void {
        const it = &self.interpreter;
        it.frames[0] = .{ .tokens = .{ .source = source } };
        it.frame_count = 1;
        it.run() catch |err| {
            it.depth = 0;
            it.frame_count = 1;
            it.assembling = false;
            it.asm_context = false;
            it.hash = false;
            it.inline_word = null;
            return err;
        };
    }

    /// the bins saved, and the boot descriptors given, so far
    pub fn assembled(self: Session) Assembled {
        return self.interpreter.assembled();
    }

    /// the values on the stack, the top last
    pub fn stack(self: *const Session) []const i32 {
        return self.interpreter.stack[0..self.interpreter.depth];
    }

    /// the node the IDE words act on
    pub fn target(self: Session) ?u16 {
        return self.interpreter.target;
    }

    /// Calls `completer.add(word)` for each word the session knows that
    /// starts with `prefix`: FORTH and ASM words, opcodes, named literals
    /// and calls, the labels of the bin being assembled, and defined names
    pub fn complete(self: *const Session, prefix: []const u8, completer: anytype) void {
        const it = &self.interpreter;
        inline for (.{ ForthWord, AsmWord, Opcode }) |Words| {
            for (std.enums.values(Words)) |word| add(prefix, @tagName(word), completer);
        }
        for (named_literals.keys()) |word| add(prefix, word, completer);
        for (named_calls.keys()) |word| add(prefix, word, completer);
        if (it.bin) |*bin| for (bin.labels[0..bin.label_count]) |label| add(prefix, label.name, completer);
        for (it.names[0..it.name_count]) |name| add(prefix, name.name, completer);
    }

    fn add(prefix: []const u8, word: []const u8, completer: anytype) void {
        if (std.mem.startsWith(u8, word, prefix)) completer.add(word);
    }
};

/// the programs saved in bins, and the boot descriptors for nodes
pub const Assembled = struct {
    programs: []Program,
    descriptors: []boot.Descriptor,
};

/// Assembles the bins in `source` into `programs`, returning the programs
/// saved with >BIN.
pub fn assembleNodes(source: []const u8, programs: []Program, descriptors: []boot.Descriptor, diagnostic: *Diagnostic) Error!Assembled {
    return assembleScript(source, null, programs, descriptors, diagnostic);
}

/// Assembles the bins in `source`, which may LOAD and THRU `blocks`, such as
/// a script that loads parts of a disk
pub fn assembleScript(source: []const u8, blocks: ?[]const u8, programs: []Program, descriptors: []boot.Descriptor, diagnostic: *Diagnostic) Error!Assembled {
    var interpreter: Interpreter = .{ .diagnostic = diagnostic, .programs = programs, .descriptors = descriptors, .blocks = blocks };
    interpreter.frames[0] = .{ .tokens = .{ .source = source } };
    try interpreter.run();
    return interpreter.assembled();
}

/// Assembles the bins of polyFORTH blocks, loading each of `loads` in turn,
/// such as a block of configuration and then the load block of an
/// application. The line numbers of the programs and the diagnostic count
/// 16 lines to a block, from line 1 of block 0.
pub fn assembleBlocks(blocks: []const u8, loads: []const u32, programs: []Program, descriptors: []boot.Descriptor, diagnostic: *Diagnostic) Error!Assembled {
    var interpreter: Interpreter = .{ .diagnostic = diagnostic, .programs = programs, .descriptors = descriptors, .blocks = blocks };
    for (loads) |load| {
        if (load >= blockCount(blocks)) {
            diagnostic.* = .{};
            return error.NoSuchBlock;
        }
        interpreter.frames[0] = .{ .tokens = blockTokens(blocks, load), .block = load, .last = load };
        interpreter.frame_count = 1;
        interpreter.assembling = false;
        try interpreter.run();
    }
    return interpreter.assembled();
}

pub const block_size = 1024;

/// the number of whole blocks
pub fn blockCount(blocks: []const u8) usize {
    return blocks.len / block_size;
}

fn blockTokens(blocks: []const u8, block: u32) Tokenizer {
    const line = @as(usize, block) * 16 + 1;
    return .{ .source = blocks[@as(usize, block) * block_size ..][0..block_size], .block_lines = true, .line = line, .start_line = line };
}

/// Writes blocks as text, each line of 64 characters followed by a newline,
/// so that line numbers count 16 to a block as assembleBlocks does. Control
/// characters, such as the zeros of blocks never written, become spaces.
/// `text` must hold 65 bytes for each 64 of the blocks.
pub fn blockText(blocks: []const u8, text: []u8) []u8 {
    const len = blockCount(blocks) * block_size;
    for (0..len / 64) |line| {
        const out = text[line * 65 ..][0..65];
        for (blocks[line * 64 ..][0..64], out[0..64]) |c, *o| o.* = if (c < ' ') ' ' else c;
        out[64] = '\n';
    }
    return text[0 .. len / 64 * 65];
}

/// a block being loaded, or the whole source when it is text
const Frame = struct {
    tokens: Tokenizer,
    /// the block being interpreted, and the last of the blocks THRU loads
    block: ?u32 = null,
    last: u32 = 0,
    /// whether ASM[ was interpreting when the block was loaded, which it
    /// goes back to once the blocks have been interpreted
    assembling: bool = false,
};

/// Assembles the single bin in `source`
pub fn assemble(source: []const u8, diagnostic: *Diagnostic) Error!Program {
    var programs: [1]Program = undefined;
    const assembled = (try assembleNodes(source, &programs, &.{}, diagnostic)).programs;
    return if (assembled.len == 1) assembled[0] else .{ .ram = @splat(erased), .len = 0, .entry = .{ .io = false, .rom = false, .local = 0 } };
}

/// what arrayForth leaves in erased RAM, a call to warm
const erased: Word = 0x134a9;

/// the most labels a bin can have, including its ROM's
const max_labels = 64;

const Label = struct {
    name: []const u8,
    value: u16,
};

/// Labels are told apart by their length and up to 7 characters
fn sameLabel(a: []const u8, b: []const u8) bool {
    return a.len == b.len and std.mem.eql(u8, a[0..@min(a.len, 7)], b[0..@min(b.len, 7)]);
}

fn sameLabels(a: []const Label, b: []const Label) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.value != y.value or !eql(x.name, y.name)) return false;
    return true;
}

/// the code and labels being assembled for a node
const Bin = struct {
    /// node number, yyxx
    node: u16,
    /// bin number, which is the node's unless BIN gives another
    number: u32,
    builder: Builder,
    labels: [max_labels]Label = undefined,
    label_count: u8 = 0,
    /// the first labels, up to this many, are the ROM's
    rom_count: u8 = 0,
    /// the ROM labels arrayForth 3 gives the node, which are the first
    /// labels until they are erased
    rom_labels: []const Label = &.{},
    rom_word: ?Diagnostic = null,
    /// where the NODE directive is, and whether code or labels have been
    /// assembled since the bin was last saved
    directive: Diagnostic = .{},
    changed: bool = false,

    fn init(node: u16, number: u32) Bin {
        var bin: Bin = .{ .node = node, .number = number, .builder = fresh() };
        for (romLabels(node)) |label| {
            bin.labels[bin.label_count] = label;
            bin.label_count += 1;
        }
        bin.rom_count = bin.label_count;
        bin.rom_labels = romLabels(node);
        return bin;
    }

    fn fresh() Builder {
        return .{ .mem = @splat(erased), .returns = true, .short_forward = true, .wrap = true };
    }

    fn find(self: *const Bin, name: []const u8) ?u16 {
        var i = self.label_count;
        while (i > 0) {
            i -= 1;
            if (sameLabel(self.labels[i].name, name)) return self.labels[i].value;
        }
        return null;
    }
};

/// a bin saved with >BIN, whose labels `its` can find: the ROM labels
/// arrayForth 3 gives its node, if it kept them, followed by its own
const SavedBin = struct {
    number: u32,
    rom_labels: []const Label,
    labels: []const Label,
};

/// a word defined by NL, NDL, NC or CONSTANT
const Name = struct {
    name: []const u8,
    kind: enum { literal, double_literal, call, constant },
    value: i64,
};

const Number = union(enum) { single: i32, double: i64 };

/// rounds the chip runs for a word given to the target to come back
const remote_rounds = 1_000_000;

const Interpreter = struct {
    /// the blocks being loaded, the first being the source
    frames: [16]Frame = undefined,
    frame_count: u8 = 1,
    /// all the blocks, when the source is blocks
    blocks: ?[]const u8 = null,
    diagnostic: *Diagnostic,
    programs: []Program,
    count: usize = 0,
    descriptors: []boot.Descriptor,
    descriptor_count: usize = 0,
    /// the descriptor that +NODE selected
    boot_node: ?usize = null,
    /// where words such as . and UPD write, if anywhere
    out: ?*Io.Writer = null,
    /// the chip that IDE words act on, and the node they target
    chip: ?*Chip = null,
    target: ?u16 = null,
    /// keep bins and labels unsaved at the end of a source, as a session
    /// goes on to the next
    interactive: bool = false,

    stack: [64]i32 = undefined,
    depth: usize = 0,
    base: u8 = 10,
    /// inside ASM[, where numbers and labels assemble code
    assembling: bool = false,
    /// the ASM vocabulary is searched before FORTH
    asm_context: bool = false,
    /// set by #, so that the next number, label, named literal or named call
    /// goes on the stack instead of being assembled
    hash: bool = false,

    bin: ?Bin = null,
    /// the instruction word being built by A[, and the state to go back to
    /// at ]]
    inline_word: ?Builder = null,
    outer: struct { assembling: bool, asm_context: bool } = undefined,

    names: [64]Name = undefined,
    name_count: u8 = 0,
    saved: [576]SavedBin = undefined,
    saved_count: u16 = 0,
    label_pool: [1024]Label = undefined,
    pool_len: u16 = 0,

    fn assembled(self: Interpreter) Assembled {
        return .{ .programs = self.programs[0..self.count], .descriptors = self.descriptors[0..self.descriptor_count] };
    }

    fn run(self: *Interpreter) Error!void {
        while (try self.next()) |token| {
            if (eql(token, "EXIT") and !self.assembling) {
                if (try self.endBlock()) continue else break;
            }
            try self.interpret(token);
        }
        if (self.interactive) return;
        if (self.inline_word != null) return error.UnclosedInline;
        try self.checkSaved();
    }

    /// fails if the bin has code or labels that were not saved
    fn checkSaved(self: *Interpreter) Error!void {
        const bin = self.bin orelse return;
        if (bin.changed) {
            self.diagnostic.* = bin.directive;
            return error.UnsavedBin;
        }
    }

    fn tokens(self: *Interpreter) *Tokenizer {
        return &self.frames[self.frame_count - 1].tokens;
    }

    /// the next word, going on to the next block or back to the one that
    /// loaded this one at the end of a block
    fn next(self: *Interpreter) Error!?[]const u8 {
        while (true) {
            const t = self.tokens();
            const token = t.next() catch |err| {
                self.diagnostic.* = .{ .line = t.start_line, .token = t.source[t.start..][0..1] };
                return err;
            };
            if (token) |word| {
                self.diagnostic.* = .{ .line = t.start_line, .token = word };
                return word;
            }
            if (!try self.endBlock()) return null;
        }
    }

    /// Moves on from a block that has ended, to the next one THRU loads or
    /// back to the block that loaded it. Returns false at the end of the
    /// source.
    fn endBlock(self: *Interpreter) Error!bool {
        const frame = &self.frames[self.frame_count - 1];
        if (frame.block) |block| if (block < frame.last) {
            frame.block = block + 1;
            frame.tokens = blockTokens(self.blocks.?, block + 1);
            self.assembling = false;
            return true;
        };
        if (self.frame_count == 1) return false;
        self.assembling = frame.assembling;
        self.frame_count -= 1;
        return true;
    }

    /// Interprets blocks `first` to `last`, then goes back to this one
    fn load(self: *Interpreter, first: i32, last: i32) Error!void {
        const blocks = self.blocks orelse return error.NoSuchBlock;
        if (first < 0 or last >= blockCount(blocks)) return error.NoSuchBlock;
        if (first > last) return;
        if (self.frame_count == self.frames.len) return error.LoadTooDeep;
        self.frames[self.frame_count] = .{
            .tokens = blockTokens(blocks, @intCast(first)),
            .block = @intCast(first),
            .last = @intCast(last),
            .assembling = self.assembling,
        };
        self.frame_count += 1;
        self.assembling = false;
    }

    /// the name following a defining word such as : or equ
    fn name(self: *Interpreter) Error![]const u8 {
        return try self.next() orelse error.MissingLabelName;
    }

    fn interpret(self: *Interpreter, token: []const u8) Error!void {
        if (self.assembling and self.bin != null) {
            if (self.bin.?.find(token)) |value| return self.callOrPush(value, true);
        }
        if (self.findName(token)) |i| return self.runName(self.names[i]);
        if (self.asm_context) {
            if (std.meta.stringToEnum(AsmWord, token)) |word| return self.runAsm(word);
            if (std.meta.stringToEnum(Opcode, token)) |opcode| switch (opcode) {
                .jump, .call, .next, .@"if", .@"-if", .unext => {},
                .@";" => return (try self.builder()).ret(),
                else => return (try self.builder()).emit(opcode),
            };
            if (named_literals.get(token)) |value| return self.namedLiteral(value);
            if (named_calls.get(token)) |value| return self.callOrPush(value, false);
        }
        if (std.meta.stringToEnum(ForthWord, token)) |word| return self.runForth(word);
        if (try parseNumber(token, self.base)) |value| return self.number(value);
        return error.UnknownWord;
    }

    fn number(self: *Interpreter, value: Number) Error!void {
        if (self.assembling and !self.hash) switch (value) {
            .single => return error.SingleLiteral,
            .double => |d| return (try self.builder()).literal(word18(d)),
        };
        self.hash = false;
        switch (value) {
            .single => |n| try self.push(n),
            .double => |d| try self.pushDouble(d),
        }
    }

    /// The builder of the inline word or of the bin. Code assembled into a
    /// bin marks it as changed.
    fn builder(self: *Interpreter) Error!*Builder {
        if (self.inline_word) |*word| return word;
        const bin = try self.currentBin();
        bin.changed = true;
        bin.builder.line = self.tokens().start_line;
        return &bin.builder;
    }

    fn callOrPush(self: *Interpreter, value: u16, label: bool) Error!void {
        if (self.hash) {
            self.hash = false;
            return self.push(value);
        }
        if (value > 0x3ff) return error.NumberOutOfRange;
        const b = try self.builder();
        // note the first call into ROM, which needs the node's ROM
        if (label and value & 0x180 == 0x080 and self.inline_word == null) {
            const bin = &self.bin.?;
            if (bin.rom_word == null) bin.rom_word = self.diagnostic.*;
        }
        try b.call(@intCast(value));
    }

    fn namedLiteral(self: *Interpreter, value: u18) Error!void {
        if (self.hash) {
            self.hash = false;
            return self.pushDouble(value);
        }
        try (try self.builder()).literal(@bitCast(value));
    }

    fn findName(self: *Interpreter, token: []const u8) ?u8 {
        var i = self.name_count;
        while (i > 0) {
            i -= 1;
            if (eql(self.names[i].name, token)) return i;
        }
        return null;
    }

    fn define(self: *Interpreter, kind: @FieldType(Name, "kind"), value: i64) Error!void {
        const new_name = try self.name();
        if (self.name_count == self.names.len) return error.TooManyLabels;
        self.names[self.name_count] = .{ .name = new_name, .kind = kind, .value = value };
        self.name_count += 1;
    }

    fn runName(self: *Interpreter, word: Name) Error!void {
        switch (word.kind) {
            .literal => try self.namedLiteral(@bitCast(word18(word.value))),
            .double_literal => if (self.hash) {
                self.hash = false;
                try self.pushDouble(word.value);
            } else try (try self.builder()).literal(word18(word.value)),
            .call => try self.callOrPush(@intCast(word.value & 0xffff), false),
            .constant => try self.push(@intCast(word.value)),
        }
    }

    fn currentBin(self: *Interpreter) Error!*Bin {
        if (self.bin) |*bin| return bin;
        return error.NoNode;
    }

    fn defineLabel(self: *Interpreter, label_name: []const u8, value: u16) Error!void {
        const bin = try self.currentBin();
        if (bin.label_count == max_labels) return error.TooManyLabels;
        bin.labels[bin.label_count] = .{ .name = label_name, .value = value };
        bin.label_count += 1;
        bin.changed = true;
    }

    fn runAsm(self: *Interpreter, word: AsmWord) Error!void {
        switch (word) {
            .ex => try (try self.builder()).emit(.ex),
            .@"#" => self.hash = true,
            .@".." => (try self.builder()).alignWord(),
            .@"<sl" => {
                const slot = try self.pop();
                if (slot < 1 or slot > 4) return error.NumberOutOfRange;
                try (try self.builder()).limitSlot(@intCast(slot));
            },
            .here => {
                const b = try self.builder();
                b.alignWord();
                try self.push(b.location());
            },
            .org => {
                const address = try self.pop();
                if (address < 0 or address & ~@as(i32, 0x2ff) != 0) return error.NumberOutOfRange;
                const b = try self.builder();
                try b.org(@intCast(address & 0xff));
                b.extended = address & 0x200 != 0;
            },
            .@"+cy", .@"-cy" => {
                const b = try self.builder();
                b.alignWord();
                b.extended = word == .@"+cy";
            },
            .@"," => {
                const value = try self.popDouble();
                try (try self.builder()).data(word18(value));
            },
            .lit => try self.lit(),
            .alit => {
                try self.push(0);
                try self.lit();
            },
            .@":" => {
                const label_name = try self.name();
                const b = try self.builder();
                b.alignWord();
                try self.defineLabel(label_name, b.location());
            },
            .equ => {
                const value = try self.pop();
                if (value < 0 or value > 0xffff) return error.NumberOutOfRange;
                try self.defineLabel(try self.name(), @intCast(value));
            },
            .its => {
                const number_of_bin = try self.pop();
                const label_name = try self.name();
                try self.callOrPush(try self.labelOf(number_of_bin, label_name), true);
            },
            .call => {
                const address = try self.pop();
                if (address < 0 or address > 0x3ff) return error.NumberOutOfRange;
                try (try self.builder()).call(@intCast(address));
            },
            .await => try self.callOrPush(idle((try self.currentBin()).node), false),
            .avail => try self.push(idle((try self.currentBin()).node)),
            .NODE => try self.node(),
            .BIN => {
                const number_of_bin = try self.pop();
                if (number_of_bin < 0 or number_of_bin > 999999) return error.InvalidNode;
                const bin = try self.currentBin();
                bin.number = @intCast(number_of_bin);
                try bin.builder.org(0);
            },
            .ERS => {
                // erases RAM, but not ROM
                const bin = try self.currentBin();
                var fresh = Bin.fresh();
                fresh.mem[64..].* = bin.builder.mem[64..].*;
                fresh.lines[64..].* = bin.builder.lines[64..].*;
                fresh.rom_len = bin.builder.rom_len;
                bin.builder = fresh;
                bin.label_count = bin.rom_count;
                if (bin.label_count < bin.rom_labels.len) bin.rom_labels = &.{};
            },
            .@"-ROM" => {
                const bin = try self.currentBin();
                bin.builder = Bin.fresh();
                bin.label_count = 0;
                bin.rom_count = 0;
                bin.rom_labels = &.{};
            },
            .@"-SYM" => (try self.currentBin()).rom_count = 0,
            .@">ROM" => {
                const bin = try self.currentBin();
                bin.rom_count = bin.label_count;
            },
            .@">BIN" => try self.save(),
            .@"]ASM" => {
                self.assembling = false;
                self.asm_context = false;
            },
            .EXIT => self.assembling = false,
            .@"]]" => {
                var b = self.inline_word orelse return error.NotInline;
                b.alignWord();
                const value: Word = if (b.len == 0) @bitCast(@as(u18, 0x15555)) else b.mem[0];
                self.inline_word = null;
                self.assembling = self.outer.assembling;
                self.asm_context = self.outer.asm_context;
                try self.pushDouble(@as(u18, @bitCast(value)));
            },
            .@"=P" => {
                const p = try self.pop();
                if (p < 0 or p > 0x3ff) return error.NumberOutOfRange;
                if (self.inline_word) |*b| b.p = @intCast(p) else return error.NotInline;
            },
            .NL => try self.define(.literal, try self.pop()),
            .NDL => try self.define(.double_literal, try self.popDouble()),
            .NC => try self.define(.call, try self.pop()),
            .begin => try self.begin(),
            .@"for" => {
                try (try self.builder()).emit(.@">r");
                try self.begin();
            },
            .next => try self.back(.next),
            .until => try self.back(.@"if"),
            .@"-until" => try self.back(.@"-if"),
            .again, .end => try self.back(.jump),
            .unext => {
                const destination = try self.pop();
                try (try self.builder()).unext(@intCast(destination & 0x3ff));
            },
            .@"if" => try self.forward(.@"if"),
            .@"-if" => try self.forward(.@"-if"),
            .zif => try self.forward(.next),
            .ahead => try self.forward(.jump),
            .leap => try self.forward(.call),
            .then => try self.then(),
            .@"while", .@"-while" => {
                try self.forward(if (word == .@"while") .@"if" else .@"-if");
                try self.swap();
            },
            .repeat => {
                try self.back(.jump);
                try self.then();
            },
            .@"else" => {
                try self.forward(.jump);
                try self.swap();
                try self.then();
            },
            .@"*next" => {
                try self.swap();
                try self.back(.next);
            },
            .east, .west, .north, .south => {
                const node_number = (try self.currentBin()).node;
                const odd = if (word == .east or word == .west) node_number % 2 == 1 else node_number / 100 % 2 == 1;
                const value: u18 = switch (word) {
                    .east => if (odd) 0x175 else 0x1d5,
                    .west => if (odd) 0x1d5 else 0x175,
                    .north => if (odd) 0x145 else 0x115,
                    else => if (odd) 0x115 else 0x145,
                };
                try self.namedLiteral(value);
            },
        }
    }

    fn lit(self: *Interpreter) Error!void {
        if (self.hash) {
            self.hash = false;
            return;
        }
        const value = try self.popDouble();
        try (try self.builder()).literal(word18(value));
    }

    fn begin(self: *Interpreter) Error!void {
        const b = try self.builder();
        _ = try b.begin();
        try self.push(b.location());
    }

    fn back(self: *Interpreter, opcode: Opcode) Error!void {
        const destination = try self.pop();
        if (destination < 0 or destination > 0x3ff) return error.NumberOutOfRange;
        try (try self.builder()).back(opcode, @intCast(destination));
    }

    /// leaves a handle for then, with the P the jump runs at, its address
    /// and slot
    fn forward(self: *Interpreter, opcode: Opcode) Error!void {
        const jump = try (try self.builder()).forward(opcode);
        try self.push(@as(i32, jump.p) << 9 | @as(i32, jump.address) << 2 | jump.slot);
    }

    fn then(self: *Interpreter) Error!void {
        const handle: u32 = @bitCast(try self.pop());
        if (handle >> 19 != 0) return error.UnmatchedControl;
        try (try self.builder()).then(.{
            .p = @intCast(handle >> 9),
            .address = @intCast(handle >> 2 & 0x7f),
            .slot = @intCast(handle & 3),
        });
    }

    fn node(self: *Interpreter) Error!void {
        const directive = self.diagnostic.*;
        const number_of_node = try self.pop();
        if (number_of_node < 0 or number_of_node > 999999) return error.InvalidNode;
        try self.checkSaved();
        self.bin = .init(@intCast(@rem(number_of_node, 10000)), @intCast(number_of_node));
        self.bin.?.directive = directive;
    }

    /// Saves the bin as the program for its node, replacing a bin saved
    /// before with the same number
    fn save(self: *Interpreter) Error!void {
        const bin = try self.currentBin();
        try bin.builder.finish(self.diagnostic);
        var main: u7 = 0;
        if (bin.find("main")) |value| if (value < 0x40) {
            main = @intCast(value);
        };
        const program: Program = .{
            .node = bin.node,
            .bin = if (bin.number == bin.node) null else bin.number,
            .ram = bin.builder.mem[0..64].*,
            .len = bin.builder.len,
            .lines = bin.builder.lines[0..64].*,
            .rom = if (bin.builder.rom_len == 0) null else .{
                .words = bin.builder.mem[64..].*,
                .lines = bin.builder.lines[64..].*,
                .len = bin.builder.rom_len,
            },
            .entry = .{ .io = false, .rom = false, .local = main },
            .rom_word = bin.rom_word,
        };

        // keeps the bin's own labels, sharing them with a bin that has the
        // same, such as the ROMs of nodes of a kind, and refers to the ROM's
        const own = bin.labels[bin.rom_labels.len..bin.label_count];
        const labels = for (self.saved[0..self.saved_count]) |saved| {
            if (sameLabels(saved.labels, own)) break saved.labels;
        } else copy: {
            if (self.pool_len + own.len > self.label_pool.len) return error.TooManyLabels;
            const copy = self.label_pool[self.pool_len..][0..own.len];
            @memcpy(copy, own);
            self.pool_len += @intCast(own.len);
            break :copy copy;
        };
        const saved_bin: SavedBin = .{ .number = bin.number, .rom_labels = bin.rom_labels, .labels = labels };

        bin.changed = false;
        for (self.saved[0..self.saved_count], 0..) |*saved, i| {
            if (saved.number == bin.number) {
                self.programs[i] = program;
                saved.* = saved_bin;
                return;
            }
        }
        if (self.count == self.programs.len) return error.TooManyNodes;
        if (self.saved_count == self.saved.len) return error.TooManyNodes;
        self.programs[self.count] = program;
        self.count += 1;
        self.saved[self.saved_count] = saved_bin;
        self.saved_count += 1;
    }

    /// the value of a label in a saved bin, or in the ROM of the bin's node
    fn labelOf(self: *Interpreter, number_of_bin: i32, label_name: []const u8) Error!u16 {
        if (number_of_bin < 0 or number_of_bin > 999999) return error.InvalidNode;
        const saved: SavedBin = for (self.saved[0..self.saved_count]) |saved| {
            if (saved.number == number_of_bin) break saved;
        } else .{ .number = @intCast(number_of_bin), .rom_labels = romLabels(@intCast(@rem(number_of_bin, 10000))), .labels = &.{} };
        for ([_][]const Label{ saved.labels, saved.rom_labels }) |labels| {
            var i = labels.len;
            while (i > 0) {
                i -= 1;
                if (sameLabel(labels[i].name, label_name)) return labels[i].value;
            }
        }
        self.diagnostic.token = label_name;
        return error.UndefinedLabel;
    }

    fn runForth(self: *Interpreter, word: ForthWord) Error!void {
        switch (word) {
            .@"ASM[" => {
                self.assembling = true;
                self.asm_context = true;
                self.hash = false;
            },
            .@"A[" => {
                if (self.inline_word != null) return error.NestedInline;
                self.outer = .{ .assembling = self.assembling, .asm_context = self.asm_context };
                self.inline_word = .{ .returns = true, .short_forward = true, .single_word = true };
                self.assembling = true;
                self.asm_context = true;
                self.hash = false;
            },
            .ASM => self.asm_context = true,
            .FORTH => self.asm_context = false,
            .EXIT => self.assembling = false,
            .DUP => {
                const a = try self.pop();
                try self.push(a);
                try self.push(a);
            },
            .DROP => _ = try self.pop(),
            .SWAP => try self.swap(),
            .OVER => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(a);
                try self.push(b);
                try self.push(a);
            },
            .ROT => {
                const c = try self.pop();
                const b = try self.pop();
                const a = try self.pop();
                try self.push(b);
                try self.push(c);
                try self.push(a);
            },
            .@"2DUP" => {
                const d = try self.popDouble();
                try self.pushDouble(d);
                try self.pushDouble(d);
            },
            .@"2DROP" => _ = try self.popDouble(),
            .@"2SWAP" => {
                const b = try self.popDouble();
                const a = try self.popDouble();
                try self.pushDouble(b);
                try self.pushDouble(a);
            },
            .@"2OVER" => {
                const b = try self.popDouble();
                const a = try self.popDouble();
                try self.pushDouble(a);
                try self.pushDouble(b);
                try self.pushDouble(a);
            },
            .AND, .OR, .XOR, .@"+", .@"-" => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(switch (word) {
                    .AND => a & b,
                    .OR => a | b,
                    .XOR => a ^ b,
                    .@"+" => a +% b,
                    else => a -% b,
                });
            },
            .NEGATE => try self.push(0 -% try self.pop()),
            .@"D+" => {
                const b = try self.popDouble();
                const a = try self.popDouble();
                try self.pushDouble(a +% b);
            },
            .DNEGATE => try self.pushDouble(0 -% try self.popDouble()),
            .@"S>D" => try self.pushDouble(try self.pop()),
            .@"." => {
                const value = try self.pop();
                if (self.out) |out| try self.printNumber(out, value, true);
            },
            .@"U." => {
                const value: u32 = @bitCast(try self.pop());
                if (self.out) |out| try self.printNumber(out, value, true);
            },
            .@"D." => {
                const value = try self.popDouble();
                if (self.out) |out| try self.printNumber(out, value, true);
            },
            .@".S" => if (self.out) |out| {
                for (self.stack[0..self.depth]) |value| try self.printNumber(out, value, true);
            },
            .CR => if (self.out) |out| try out.writeByte('\n'),
            .SPACE => if (self.out) |out| try out.writeByte(' '),
            .NODE => try self.selectTarget(try self.pop()),
            .HOOK => {
                const node_number = try self.pop();
                _ = try self.pop();
                try self.selectTarget(node_number);
            },
            .PATH, .@"-HOOK" => _ = try self.pop(),
            .FOCUS, .VIRGIN => _ = try self.targetNode(),
            .UPD, .@".STK" => try self.showStacks(),
            .@"?RAM" => try self.showMemory(0),
            .@"?ROM" => try self.showMemory(0x80),
            .@"-ASM" => {
                const n = try self.pop();
                try self.disassemble(try self.pop(), n);
            },
            .LIT => {
                const value = word18(try self.popDouble());
                (try self.targetNode()).data_stack.push(value);
            },
            .@"R@" => {
                const address = try self.registerAddress(try self.pop());
                const n = try self.targetNode();
                try self.pushDouble(@as(u18, @bitCast(n.read(address).?)));
            },
            .@"R!" => {
                const address = try self.registerAddress(try self.pop());
                const value = word18(try self.popDouble());
                _ = (try self.targetNode()).write(address, value);
            },
            .RINS => try self.remote(word18(try self.popDouble())),
            .CALL => {
                const address = try self.pop();
                if (address < 0 or address > 0x3ff) return error.NumberOutOfRange;
                try self.remote(Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }, 0, @intCast(address)));
            },
            .BOOT => {
                const number_of_bin = try self.pop();
                const n = try self.pop();
                const address = try self.pop();
                if (!inRam(address, n)) return error.NumberOutOfRange;
                const program = for (self.saved[0..self.saved_count], 0..) |saved, i| {
                    if (saved.number == number_of_bin) break &self.programs[i];
                } else return error.NoSuchBin;
                const start: usize = @intCast(address);
                const end: usize = @intCast(address + n);
                @memcpy((try self.targetNode()).mem[start..end], program.ram[start..end]);
            },
            .@"RB!", .@"@B", .@"!B", .@"RA@", .@"RA!", .@"@A", .@"!A", .@"@+", .@"!+", .@"R+", .@"R+*", .@"R2*", .@"R2/", .RINV, .RAND, .RXOR, .ROR, .RDROP, .RDUP, .ROVER => {
                const opcode: Opcode = switch (word) {
                    .@"RB!" => .@"b!",
                    .@"@B" => .@"@b",
                    .@"!B" => .@"!b",
                    .@"RA@" => .a,
                    .@"RA!" => .@"a!",
                    .@"@A" => .@"@",
                    .@"!A" => .@"!",
                    .@"@+" => .@"@+",
                    .@"!+" => .@"!+",
                    .@"R+" => .@"+",
                    .@"R+*" => .@"+*",
                    .@"R2*" => .@"2*",
                    .@"R2/" => .@"2/",
                    .RINV => .inv,
                    .RAND => .@"and",
                    .RXOR, .ROR => .xor,
                    .RDROP => .drop,
                    .RDUP => .dup,
                    else => .over,
                };
                try self.remote(Instruction.encode(.{ .slot_0 = opcode, .slot_1 = .@";", .slot_2 = .@";", .slot_3 = 0 }));
            },
            .HEX => self.base = 16,
            .DECIMAL => self.base = 10,
            .CONSTANT => try self.define(.constant, try self.pop()),
            .LOAD => {
                const block = try self.pop();
                try self.load(block, block);
            },
            .THRU => {
                const last = try self.pop();
                try self.load(try self.pop(), last);
            },
            .FH => {
                const offset = try self.pop();
                const block = self.frames[self.frame_count - 1].block orelse return error.NoSuchBlock;
                try self.push(@as(i32, @intCast(block)) +% offset);
            },
            .@"+NODE" => try self.bootNode(try self.pop()),
            .@"/RAM" => try self.loadRam(0, 0, 64, try self.pop()),
            .@"/SOME" => {
                const bin = try self.pop();
                const len = try self.pop();
                const destination = try self.pop();
                try self.loadRam(try self.pop(), destination, len, bin);
            },
            .@"/PART" => {
                const bin = try self.pop();
                const len = try self.pop();
                const address = try self.pop();
                try self.loadRam(address, address, len, bin);
            },
            .@"/A" => (try self.bootDescriptor()).a = word18(try self.popDouble()),
            .@"/B" => (try self.bootDescriptor()).b = word18(try self.popDouble()),
            .@"/IO" => (try self.bootDescriptor()).io = word18(try self.popDouble()),
            .@"/P" => {
                const p = try self.pop();
                if (p < 0 or p > 0x3ff) return error.NumberOutOfRange;
                (try self.bootDescriptor()).p = @intCast(p);
            },
            .@"/STACK" => {
                const d = try self.bootDescriptor();
                d.stack_len = try self.popValues(&d.stack);
            },
            .@"/RSTACK" => {
                const d = try self.bootDescriptor();
                d.return_stack_len = try self.popValues(&d.return_stack);
            },
            .@"/RINF" => {
                const d = try self.bootDescriptor();
                d.return_stack = @splat(-1);
                d.return_stack_len = d.return_stack.len;
            },
            .@"!ND" => {
                const node_number = try self.pop();
                try self.bootNode(node_number);
                try self.loadRam(0, 0, 64, node_number);
            },
            .@"+ND" => {
                const node_number = try self.pop();
                try self.bootNode(node_number);
                try self.loadRam(0, 0, 64, node_number);
                const d = try self.bootDescriptor();
                const p = try self.pop();
                if (p < 0 or p > 0x3ff) return error.NumberOutOfRange;
                d.p = @intCast(p);
                d.b = word18(try self.popDouble());
                d.a = word18(try self.popDouble());
            },
            .@"+wire" => {
                // a wire from bin 1802, as in GreenArrays' small tools
                try self.bootNode(try self.pop());
                try self.loadRam(0, 0, 1, 1802);
                const d = try self.bootDescriptor();
                d.b = word18(try self.popDouble());
                d.a = word18(try self.popDouble());
                d.p = 0;
                d.return_stack = @splat(-1);
                d.return_stack_len = d.return_stack.len;
            },
            .ITS => {
                const number_of_bin = try self.pop();
                try self.push(try self.labelOf(number_of_bin, try self.name()));
            },
            .UP => try self.pushDouble(0x145),
            .DOWN => try self.pushDouble(0x115),
            .LEFT => try self.pushDouble(0x175),
            .RIGHT => try self.pushDouble(0x1d5),
            .IO => try self.pushDouble(0x15d),
            .DATA => try self.pushDouble(0x141),
            .LDATA => try self.pushDouble(0x171),
            .NORTH, .SOUTH, .EAST, .WEST => {
                const node_number = (try self.bootDescriptor()).node;
                const odd = if (word == .EAST or word == .WEST) node_number % 2 == 1 else node_number / 100 % 2 == 1;
                try self.pushDouble(switch (word) {
                    .EAST => if (odd) 0x175 else 0x1d5,
                    .WEST => if (odd) 0x1d5 else 0x175,
                    .NORTH => if (odd) 0x145 else 0x115,
                    else => if (odd) 0x115 else 0x145,
                });
            },
            .@"IF{" => if (try self.pop() == 0) self.tokens().skipPast('}'),
            .@"{ELSE}" => self.tokens().skipPast('}'),
            .@"}" => {},
            .@"{" => self.tokens().skipPast('}'),
            .ZAP => _ = try self.pop(),
            .FORGET => {
                const forget_name = try self.name();
                self.name_count = self.findName(forget_name) orelse return error.UnknownWord;
            },
        }
    }

    /// Selects the boot descriptor of a node, which starts at warm with B
    /// addressing IO, as arrayForth 3's FRAME[ sets them
    fn bootNode(self: *Interpreter, number_of_node: i32) Error!void {
        if (number_of_node < 0 or number_of_node > 999999) return error.InvalidNode;
        const node_number: u16 = @intCast(@rem(number_of_node, 10000));
        for (self.descriptors[0..self.descriptor_count], 0..) |d, i| if (d.node == node_number) {
            self.boot_node = i;
            return;
        };
        if (self.descriptor_count == self.descriptors.len) return error.TooManyDescriptors;
        self.descriptors[self.descriptor_count] = .{ .node = node_number, .b = Computer.io_address, .p = 0xa9 };
        self.boot_node = self.descriptor_count;
        self.descriptor_count += 1;
    }

    fn bootDescriptor(self: *Interpreter) Error!*boot.Descriptor {
        return &self.descriptors[self.boot_node orelse return error.NoBootNode];
    }

    /// Adds a load of `len` words from address `source` of a saved bin into
    /// RAM at `destination`. A load of all of RAM replaces any before it.
    fn loadRam(self: *Interpreter, source: i32, destination: i32, len: i32, bin: i32) Error!void {
        const d = try self.bootDescriptor();
        if (!inRam(source, len) or !inRam(destination, len)) return error.NumberOutOfRange;
        for (self.saved[0..self.saved_count]) |saved| {
            if (saved.number == bin) break;
        } else return error.NoSuchBin;
        if (len == 64) d.load_count = 0;
        if (d.load_count == d.loads.len) return error.TooManyLoads;
        d.loads[d.load_count] = .{ .bin = @intCast(bin), .source = @intCast(source), .destination = @intCast(destination), .len = @intCast(len) };
        d.load_count += 1;
    }

    /// Pops a count of up to `values.len` doubles and the doubles, the last
    /// of which goes on top
    fn popValues(self: *Interpreter, values: []Word) Error!u4 {
        const n = try self.pop();
        if (n < 1 or n > values.len) return error.NumberOutOfRange;
        var i: usize = @intCast(n);
        while (i > 0) {
            i -= 1;
            values[i] = word18(try self.popDouble());
        }
        return @intCast(n);
    }

    fn printNumber(self: Interpreter, out: *Io.Writer, value: anytype, space: bool) Error!void {
        try out.printInt(value, self.base, .upper, .{});
        if (space) try out.writeByte(' ');
    }

    fn selectTarget(self: *Interpreter, number_of_node: i32) Error!void {
        const chip = self.chip orelse return error.NoChip;
        if (number_of_node < 0 or number_of_node > 999999) return error.InvalidNode;
        const node_number: u16 = @intCast(@rem(number_of_node, 10000));
        if (chip.layout.index(node_number) == null) return error.InvalidNode;
        self.target = node_number;
    }

    fn targetNode(self: *Interpreter) Error!*Computer {
        const chip = self.chip orelse return error.NoChip;
        return chip.node(self.target orelse return error.NoTarget).?;
    }

    /// an address R@ and R! can use without waiting: memory, or the io and
    /// data registers
    fn registerAddress(self: *Interpreter, value: i32) Error!f18.Address {
        _ = self;
        if (value < 0 or value > 0x1ff) return error.NumberOutOfRange;
        const address: f18.Address = .fromWord(@intCast(value));
        if (address.io and value != Computer.io_address and value != Computer.data_address) return error.PortAccess;
        return address;
    }

    /// Has the target execute an instruction word from its port, and runs
    /// the chip until it is waiting for code again, or saying so if it is
    /// still running
    fn remote(self: *Interpreter, word: Word) Error!void {
        const chip = self.chip orelse return error.NoChip;
        const node_number = self.target orelse return error.NoTarget;
        const i = chip.layout.index(node_number).?;
        chip.execute(i, word) catch return error.NotWaitingForCode;
        const waiting = chip.runUntilWaiting(i, remote_rounds) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => return error.NotWaitingForCode,
        };
        if (!waiting) if (self.out) |out| try out.print("node {d:0>3} is still running\n", .{node_number});
    }

    /// Writes the target's stacks as the IDE shows them: the deepest four of
    /// the eight below S, then the shallower four, S and T, with the return
    /// stack's top and the rest below
    fn showStacks(self: *Interpreter) Error!void {
        const n = try self.targetNode();
        const out = self.out orelse return;
        const data = n.data_stack;
        // the next to be popped into S first
        var below: [8]Word = undefined;
        for (&below, 1..) |*value, depth| value.* = data.stack[data.index -% @as(u3, @intCast(depth % 8))];
        // the deeper half circularly, as the IDE shows it
        for ([_]usize{ 4, 5, 6, 7 }) |depth| try self.printWord(out, below[depth]);
        try out.writeByte('\n');
        for ([_]usize{ 3, 2, 1, 0 }) |depth| try self.printWord(out, below[depth]);
        try self.printWord(out, data.s);
        try self.printWord(out, data.t);
        try out.writeAll("\nR");
        try self.printWord(out, n.return_stack.t);
        for (1..9) |depth| try self.printWord(out, n.return_stack.stack[n.return_stack.index -% @as(u3, @intCast(depth % 8))]);
        try out.writeByte('\n');
    }

    fn printWord(self: Interpreter, out: *Io.Writer, word: Word) Error!void {
        try out.writeByte(' ');
        try out.printInt(@as(u18, @bitCast(word)), self.base, .upper, .{ .width = if (self.base == 16) 5 else 6, .fill = if (self.base == 16) '0' else ' ' });
    }

    /// Writes 64 words of the target's RAM or ROM, 8 to a line
    fn showMemory(self: *Interpreter, first: u9) Error!void {
        const n = try self.targetNode();
        const out = self.out orelse return;
        for (0..64) |i| {
            if (i % 8 == 0) {
                if (i > 0) try out.writeByte('\n');
                try out.print("{x:0>3}", .{first + i});
            }
            try self.printWord(out, n.mem[(first & 0x80) / 2 + i]);
        }
        try out.writeByte('\n');
    }

    /// Writes a line for each of `count` words from `first` of the target's
    /// memory, with its address, value and disassembly
    fn disassemble(self: *Interpreter, first: i32, count: i32) Error!void {
        const n = try self.targetNode();
        const out = self.out orelse return;
        if (first < 0 or first > 0xff or count < 0) return error.NumberOutOfRange;
        const ram_literals = disassembler.literals(n.mem[0..64]);
        const rom_literals = disassembler.literals(n.mem[64..128]);
        for (0..@intCast(count)) |i| {
            const address: u9 = @intCast((@as(usize, @intCast(first)) + i) & 0xff);
            const word = n.mem[@as(usize, address & 0x80) / 2 + (address & 0x3f)];
            try out.print("{x:0>3} {x:0>5}  ", .{ address, @as(u18, @bitCast(word)) });
            const data = if (address & 0x80 != 0) rom_literals else ram_literals;
            if (data & (@as(u64, 1) << @intCast(address & 0x3f)) != 0) {
                try disassembler.writeLiteral(out, word);
            } else try disassembler.write(out, word, address);
            try out.writeByte('\n');
        }
    }

    fn swap(self: *Interpreter) Error!void {
        const b = try self.pop();
        const a = try self.pop();
        try self.push(b);
        try self.push(a);
    }

    fn push(self: *Interpreter, value: i32) Error!void {
        if (self.depth == self.stack.len) return error.StackOverflow;
        self.stack[self.depth] = value;
        self.depth += 1;
    }

    fn pop(self: *Interpreter) Error!i32 {
        if (self.depth == 0) return error.StackUnderflow;
        self.depth -= 1;
        return self.stack[self.depth];
    }

    /// pushes a double as two cells, the high one on top
    fn pushDouble(self: *Interpreter, value: i64) Error!void {
        const bits: u64 = @bitCast(value);
        try self.push(@bitCast(@as(u32, @truncate(bits))));
        try self.push(@bitCast(@as(u32, @truncate(bits >> 32))));
    }

    fn popDouble(self: *Interpreter) Error!i64 {
        const high: u32 = @bitCast(try self.pop());
        const low: u32 = @bitCast(try self.pop());
        return @bitCast(@as(u64, high) << 32 | low);
    }
};

/// whether `len` words from `address` are all in RAM, for values from the
/// stack, which may be anything
fn inRam(address: i32, len: i32) bool {
    return address >= 0 and len >= 0 and address <= 64 and len <= 64 - address;
}

/// the low 18 bits of a value, as stored in F18 memory
fn word18(value: i64) Word {
    return @bitCast(@as(u18, @truncate(@as(u64, @bitCast(value)))));
}

/// The address of a node's default multiport, which await calls: the ports
/// to its neighbours, fewer at the edges and corners of the GA144
fn idle(node: u16) u16 {
    const index = (node / 100 * 18 + node % 100) % 144;
    const row = index / 18;
    const column = index % 18;
    const ports = [_]u16{ 0x195, 0x185, 0x1b5, 0x1a5 };
    return ports[@as(usize, @intFromBool(row % 7 != 0)) + 2 * @as(usize, @intFromBool(column % 17 != 0))];
}

const AsmWord = enum {
    ex,
    @"#",
    @"..",
    @"<sl",
    here,
    org,
    @"+cy",
    @"-cy",
    @",",
    lit,
    alit,
    @":",
    equ,
    its,
    call,
    await,
    avail,
    NODE,
    BIN,
    ERS,
    @"-ROM",
    @"-SYM",
    @">ROM",
    @">BIN",
    @"]ASM",
    EXIT,
    @"]]",
    @"=P",
    NL,
    NDL,
    NC,
    begin,
    @"for",
    next,
    until,
    @"-until",
    again,
    end,
    unext,
    @"if",
    @"-if",
    zif,
    ahead,
    leap,
    then,
    @"while",
    @"-while",
    repeat,
    @"else",
    @"*next",
    east,
    west,
    north,
    south,
};

const ForthWord = enum {
    @"ASM[",
    @"A[",
    ASM,
    FORTH,
    EXIT,
    DUP,
    DROP,
    SWAP,
    OVER,
    ROT,
    @"2DUP",
    @"2DROP",
    @"2SWAP",
    @"2OVER",
    AND,
    OR,
    XOR,
    @"+",
    @"-",
    NEGATE,
    @"D+",
    DNEGATE,
    @"S>D",
    @".",
    HEX,
    DECIMAL,
    CONSTANT,
    FORGET,
    LOAD,
    THRU,
    FH,
    @"IF{",
    @"{ELSE}",
    @"}",
    @"{",
    ZAP,
    @"U.",
    @"D.",
    @".S",
    CR,
    SPACE,
    NODE,
    HOOK,
    PATH,
    @"-HOOK",
    FOCUS,
    VIRGIN,
    UPD,
    @".STK",
    @"?RAM",
    @"?ROM",
    @"-ASM",
    LIT,
    @"R@",
    @"R!",
    RINS,
    CALL,
    BOOT,
    @"RB!",
    @"@B",
    @"!B",
    @"RA@",
    @"RA!",
    @"@A",
    @"!A",
    @"@+",
    @"!+",
    @"R+",
    @"R+*",
    @"R2*",
    @"R2/",
    RINV,
    RAND,
    RXOR,
    ROR,
    RDROP,
    RDUP,
    ROVER,
    @"+NODE",
    @"/RAM",
    @"/SOME",
    @"/PART",
    @"/A",
    @"/B",
    @"/IO",
    @"/P",
    @"/STACK",
    @"/RSTACK",
    @"/RINF",
    @"!ND",
    @"+ND",
    @"+wire",
    ITS,
    UP,
    DOWN,
    LEFT,
    RIGHT,
    IO,
    DATA,
    LDATA,
    NORTH,
    SOUTH,
    EAST,
    WEST,
};

/// port and register addresses, which assemble literals
const named_literals: std.StaticStringMap(u18) = .initComptime(.{
    .{ "io", 0x15d },    .{ "data", 0x141 }, .{ "ldata", 0x171 },
    .{ "right", 0x1d5 }, .{ "down", 0x115 }, .{ "left", 0x175 },
    .{ "up", 0x145 },    .{ "warp", 0x157 }, .{ "center", 0x1a5 },
    .{ "top", 0x1b5 },   .{ "side", 0x185 }, .{ "corner", 0x195 },
});

/// multiport addresses, which assemble calls
const named_calls: std.StaticStringMap(u16) = .initComptime(.{
    .{ "---u", 0x145 }, .{ "--l-", 0x175 }, .{ "--lu", 0x165 },
    .{ "-d--", 0x115 }, .{ "-d-u", 0x105 }, .{ "-dl-", 0x135 },
    .{ "-dlu", 0x125 }, .{ "r---", 0x1d5 }, .{ "r--u", 0x1c5 },
    .{ "r-l-", 0x1f5 }, .{ "r-lu", 0x1e5 }, .{ "rd--", 0x195 },
    .{ "rd-u", 0x185 }, .{ "rdl-", 0x1b5 }, .{ "rdlu", 0x1a5 },
});

/// The labels arrayForth 3 gives a node's ROM. Addresses with bit 9 set
/// enter Extended Arithmetic Mode.
fn romLabels(node: u16) []const Label {
    return switch (node) {
        7 => &.{ .{ .name = "warm", .value = 0xa9 }, .{ .name = "db@", .value = 0xaa }, .{ .name = "db!", .value = 0xab }, .{ .name = "inpt", .value = 0xad } },
        8 => &.{.{ .name = "warm", .value = 0xa9 }},
        9 => &.{ .{ .name = "warm", .value = 0xa9 }, .{ .name = "cmd", .value = 0xaa } },
        105 => &rom_105,
        106 => &rom_106,
        107 => &.{
            .{ .name = "warm", .value = 0xa9 }, .{ .name = "a2rc", .value = 0xaa }, .{ .name = "row!", .value = 0xaf },
            .{ .name = "sd@", .value = 0xbb },  .{ .name = "sd!", .value = 0xc5 },  .{ .name = "poll", .value = 0xcf },
        },
        108 => &.{
            .{ .name = "warm", .value = 0xa9 }, .{ .name = "noop", .value = 0xaa }, .{ .name = "cmd", .value = 0xac },
            .{ .name = "idle", .value = 0xae }, .{ .name = "init", .value = 0xc0 },
        },
        else => switch (ga144.romType(node)) {
            .basic, .special => &rom_basic,
            .analog => &rom_analog,
            .serdes_boot => &rom_serdes,
            .sync_boot => &rom_sync,
            .async_boot => &rom_async,
            .spi_boot => &rom_spi,
            .one_wire => &rom_one_wire,
        },
    };
}

fn labelTable(comptime entries: anytype) [entries.len]Label {
    var result: [entries.len]Label = undefined;
    for (entries, &result) |entry, *label| label.* = .{ .name = entry[0], .value = entry[1] };
    return result;
}

const rom_basic = labelTable(.{
    .{ "relay", 0xa1 }, .{ "done", 0xa8 },     .{ "warm", 0xa9 },    .{ "*.17", 0xb0 },
    .{ "*.", 0xb7 },    .{ "taps", 0xbc },     .{ "interp", 0xc4 },  .{ "triangle", 0xce },
    .{ "clc", 0x2d3 },  .{ "--u/mod", 0x2d5 }, .{ "-u/mod", 0x2d6 }, .{ "poly", 0xaa },
});
const rom_serdes = labelTable(.{
    .{ "relay", 0xa1 },    .{ "done", 0xa8 }, .{ "warm", 0xa9 },     .{ "cold", 0xaa },
    .{ "*.17", 0xb0 },     .{ "*.", 0xb7 },   .{ "taps", 0xbc },     .{ "interp", 0xc4 },
    .{ "triangle", 0xce }, .{ "clc", 0x2d3 }, .{ "--u/mod", 0x2d5 }, .{ "-u/mod", 0x2d6 },
});
const rom_analog = labelTable(.{
    .{ "relay", 0xa1 },    .{ "done", 0xa8 }, .{ "warm", 0xa9 },     .{ "*.17", 0xb0 },
    .{ "*.", 0xb7 },       .{ "-dac", 0xbc }, .{ "dac27", 0xbc },    .{ "interp", 0xc4 },
    .{ "triangle", 0xce }, .{ "clc", 0x2d3 }, .{ "--u/mod", 0x2d5 }, .{ "-u/mod", 0x2d6 },
    .{ "poly", 0xaa },
});
const rom_one_wire = labelTable(.{
    .{ "rcv", 0x9e },    .{ "bit", 0xa1 },      .{ "warm", 0xa9 },    .{ "cold", 0xaa },
    .{ "fwd-b7", 0xb7 }, .{ "triangle", 0xbe }, .{ "*.17", 0xc3 },    .{ "*.", 0xca },
    .{ "clc", 0x2cf },   .{ "--u/mod", 0x2d1 }, .{ "-u/mod", 0x2d2 },
});
const rom_sync = labelTable(.{
    .{ "sget", 0xbe }, .{ "relay", 0xa1 },    .{ "done", 0xa8 },     .{ "warm", 0xa9 },
    .{ "cold", 0xaa }, .{ "ser-exec", 0xb6 }, .{ "ser-copy", 0xb9 }, .{ "6in", 0xc0 },
    .{ "2in", 0xc2 },  .{ "*.17", 0xcc },     .{ "taps", 0xd3 },     .{ "triangle", 0xdb },
});
const rom_async = labelTable(.{
    .{ "18ibits", 0xcb }, .{ "relay", 0xa1 },    .{ "done", 0xa8 },     .{ "warm", 0xa9 },
    .{ "cold", 0xaa },    .{ "ser-exec", 0xae }, .{ "ser-copy", 0xb3 }, .{ "wait", 0xbb },
    .{ "sync", 0xbe },    .{ "start", 0xc5 },    .{ "delay", 0xc8 },    .{ "byte", 0xd0 },
    .{ "4bits", 0xd2 },   .{ "2bits", 0xd3 },    .{ "1bit", 0xd4 },     .{ "lsh", 0xd9 },
    .{ "rsh", 0xdb },
});
const rom_spi = labelTable(.{
    .{ "relay", 0xa1 },   .{ "done", 0xa8 },     .{ "8obits", 0xc2 },   .{ "ibit", 0xc7 },
    .{ "half", 0xca },    .{ "select", 0xcc },   .{ "obit", 0xd0 },     .{ "rbit", 0xd5 },
    .{ "18ibits", 0xd9 }, .{ "ibits", 0xdb },    .{ "u2/", 0xdf },      .{ "warm", 0xa9 },
    .{ "cold", 0xaa },    .{ "spi-boot", 0xb0 }, .{ "spi-exec", 0xb6 }, .{ "spi-copy", 0xbc },
});
const rom_105 = labelTable(.{
    .{ "warm", 0xa9 },  .{ "rp--", 0xaa },  .{ "'else", 0xac }, .{ "bs@", 0xac },
    .{ "rp@", 0xb0 },   .{ "pshbs", 0xb1 }, .{ "'r@", 0xb3 },   .{ "@w", 0xb4 },
    .{ "rfrom", 0xb6 }, .{ "popbs", 0xb9 }, .{ "pshr", 0xbb },  .{ "rp++", 0xbf },
    .{ "ip++", 0xbf },  .{ "tor", 0xc1 },   .{ "rp!", 0xc4 },   .{ "'con", 0xc7 },
    .{ "'var", 0xc8 },  .{ "'exit", 0xc9 }, .{ "bitsy", 0xce }, .{ "xxt", 0xd0 },
    .{ "'ex", 0xd3 },   .{ "'lit", 0xd5 },  .{ "'if", 0xd8 },
});
const rom_106 = labelTable(.{
    .{ "'c@", 0xaa },   .{ "'@", 0xaa },     .{ "x@", 0xaa },     .{ "1+", 0xac },
    .{ "sp++", 0xac },  .{ "char+", 0xac },  .{ "cell+", 0xac },  .{ "popt", 0xae },
    .{ "1-", 0xb0 },    .{ "sp--", 0xb0 },   .{ "char-", 0xb0 },  .{ "cell-", 0xb0 },
    .{ "psht", 0xb2 },  .{ "x!", 0xb4 },     .{ "'c!", 0xb6 },    .{ "'!", 0xb6 },
    .{ "popts", 0xb7 }, .{ "pops", 0xb8 },   .{ "pshs", 0xba },   .{ "page@", 0xbc },
    .{ "pshw", 0xbe },  .{ "page!", 0xc0 },  .{ "sp@", 0xc3 },    .{ "sp!", 0xc6 },
    .{ "'drop", 0xc8 }, .{ "'over", 0xc9 },  .{ "'dup", 0xca },   .{ "'swap", 0xcb },
    .{ "'2/", 0xcd },   .{ "'2*", 0xce },    .{ "um+", 0xcf },    .{ "'nc", 0xd2 },
    .{ "'cy", 0xd3 },   .{ "zless", 0xd8 },  .{ "'or", 0xdb },    .{ "'xor", 0xdc },
    .{ "'and", 0xdd },  .{ "negate", 0xde }, .{ "invert", 0xdf }, .{ "zeq", 0xe0 },
    .{ "'+", 0xe2 },    .{ "swap-", 0xe3 },  .{ "warm", 0xa9 },
});

/// Parses a polyFORTH number in `base`, or in hex after a leading x. A
/// leading - makes it negative, and any of , . + - / : after its first digit
/// make it a double.
fn parseNumber(token: []const u8, base: u8) Error!?Number {
    var i: usize = 0;
    var radix = base;
    if (token.len > 1 and token[0] == 'x') {
        radix = 16;
        i = 1;
    }
    const negative = i < token.len and token[i] == '-';
    if (negative) i += 1;
    var value: u64 = 0;
    var digits: usize = 0;
    var double = false;
    for (token[i..]) |c| {
        switch (c) {
            ',', '.', '+', '-', '/', ':' => {
                if (digits == 0) return null;
                double = true;
                continue;
            },
            else => {},
        }
        const digit = std.fmt.charToDigit(c, radix) catch return null;
        value = std.math.mul(u64, value, radix) catch return error.NumberOutOfRange;
        value = std.math.add(u64, value, digit) catch return error.NumberOutOfRange;
        digits += 1;
    }
    if (digits == 0) return null;
    if (double) {
        const signed: i64 = @bitCast(value);
        return .{ .double = if (negative) 0 -% signed else signed };
    }
    if (value > std.math.maxInt(u32)) return error.NumberOutOfRange;
    const single: i32 = @bitCast(@as(u32, @intCast(value)));
    return .{ .single = if (negative) 0 -% single else single };
}

/// Splits source into words separated by whitespace, skipping ( ), .( )
/// and \ comments
const Tokenizer = struct {
    source: []const u8,
    /// lines are 64 characters long, as in a block, instead of ending with
    /// a newline
    block_lines: bool = false,
    index: usize = 0,
    line: usize = 1,
    /// where the last token, or the malformed one, starts
    start: usize = 0,
    start_line: usize = 1,

    fn next(self: *Tokenizer) Error!?[]const u8 {
        while (true) {
            while (self.index < self.source.len and isSpace(self.source[self.index])) self.advance();
            if (self.index == self.source.len) return null;

            self.start = self.index;
            self.start_line = self.line;
            while (self.index < self.source.len and !isSpace(self.source[self.index])) self.advance();
            const token = self.source[self.start..self.index];
            if (eql(token, "\\")) {
                const line = self.line;
                while (self.index < self.source.len and self.line == line and self.source[self.index] != '\n') self.advance();
            } else if (eql(token, "(") or eql(token, ".(")) {
                while (self.index < self.source.len and self.source[self.index] != ')') self.advance();
                if (self.index == self.source.len) return error.UnterminatedComment;
                self.advance();
            } else return token;
        }
    }

    /// skips the source up to and including the next `c`
    fn skipPast(self: *Tokenizer, c: u8) void {
        while (self.index < self.source.len and self.source[self.index] != c) self.advance();
        if (self.index < self.source.len) self.advance();
    }

    fn advance(self: *Tokenizer) void {
        if (self.block_lines) {
            self.index += 1;
            if (self.index % 64 == 0) self.line += 1;
            return;
        }
        if (self.source[self.index] == '\n') self.line += 1;
        self.index += 1;
    }

    /// Blocks that were never written hold zeros
    fn isSpace(c: u8) bool {
        return std.ascii.isWhitespace(c) or c == 0;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const assembler = @import("assembler.zig");
const Diagnostic = assembler.Diagnostic;
const Program = assembler.Program;
const boot = @import("boot.zig");
const Builder = @import("Builder.zig");
const Chip = @import("Chip.zig");
const disassembler = @import("disassembler.zig");
const f18 = @import("f18.zig");
const Computer = f18.Computer;
const Instruction = f18.Instruction;
const Slot = f18.Slot;
const Word = f18.Word;
const ga144 = @import("ga144.zig");
const Opcode = @import("opcodes.zig").Opcode;

const std = @import("std");
const Io = std.Io;

fn expectAssembles(source: []const u8, expected: []const Word) !void {
    var diagnostic: Diagnostic = .{};
    const program = assemble(source, &diagnostic) catch |err| {
        std.debug.print("{t} at line {d} '{s}'\n", .{ err, diagnostic.line, diagnostic.token });
        return err;
    };
    try std.testing.expectEqualSlices(Word, expected, program.ram[0..program.len]);
}

fn expectError(expected: Error, source: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(expected, assemble(source, &diagnostic));
}

fn opcodes(slot_0: Opcode, slot_1: Opcode, slot_2: Opcode, slot_3: Opcode) Word {
    return Instruction.encode(.{ .slot_0 = slot_0, .slot_1 = slot_1, .slot_2 = slot_2, .slot_3 = @intCast(@backingInt(slot_3) >> 2) });
}

fn jumpWord(slot_0: Opcode, slot_1: Opcode, slot_2: Opcode, slot: Slot, destination: u10) Word {
    return Instruction.encodeJump(.{ .slot_0 = slot_0, .slot_1 = slot_1, .slot_2 = slot_2, .slot_3 = 0 }, slot, destination);
}

test parseNumber {
    try std.testing.expectEqual(Number{ .single = 708 }, (try parseNumber("708", 10)).?);
    try std.testing.expectEqual(Number{ .single = -5 }, (try parseNumber("-5", 10)).?);
    try std.testing.expectEqual(Number{ .double = 17 }, (try parseNumber("17.", 10)).?);
    // x makes hex whatever the base, and punctuation only makes a double
    try std.testing.expectEqual(Number{ .double = 0x3fc00 }, (try parseNumber("x3.FC00", 10)).?);
    try std.testing.expectEqual(Number{ .single = -0x7f00 }, (try parseNumber("x-7F00", 10)).?);
    try std.testing.expectEqual(Number{ .double = 0 }, (try parseNumber("00.", 10)).?);
    try std.testing.expectEqual(Number{ .single = 0x20 }, (try parseNumber("20", 16)).?);
    try std.testing.expectEqual(null, try parseNumber(".", 10));
    try std.testing.expectEqual(null, try parseNumber("x", 10));
    try std.testing.expectEqual(null, try parseNumber("-d--", 10));
    try std.testing.expectEqual(null, try parseNumber("xor", 10));
    try std.testing.expectError(error.NumberOutOfRange, parseNumber("x100000000", 10));
}

test "bins, literals and the fill of unused slots" {
    var diagnostic: Diagnostic = .{};
    const program = try assemble(
        \\ ASM[ # 5 NODE ERS  # 0 org
        \\ : main  5. dup ;
        \\ : two   drop  : three  over ;
        \\ >BIN ]ASM
    , &diagnostic);
    try std.testing.expectEqual(5, program.node);
    try std.testing.expectEqual(null, program.bin);
    try std.testing.expectEqualSlices(Word, &.{
        // a word that ends with a return is filled with returns
        opcodes(.@"@p", .dup, .@";", .@";"),
        5,
        // and one that runs on into the next with nops
        opcodes(.drop, .@".", .@".", .@"."),
        opcodes(.over, .@";", .@";", .@";"),
    }, program.ram[0..program.len]);
    // unused RAM calls warm
    try std.testing.expectEqual(erased, program.ram[program.len]);
}

test "numbers and labels on the stack" {
    // # leaves numbers and labels on the stack, for directives such as org
    try expectAssembles("ASM[ # 0 NODE  # 2 org : x dup ;  # x org drop >BIN", &.{
        erased, erased, opcodes(.drop, .@";", .@";", .@";"),
    });
    // host words work on numbers outside ASM[
    try expectAssembles("3 2 + ASM[ # 0 NODE org  dup >BIN", &.{
        erased, erased, erased, erased, erased, opcodes(.dup, .@";", .@";", .@";"),
    });
    // and , aligns, filling the word before it with nops
    try expectAssembles("ASM[ # 0 NODE  # 2 S>D # 3. D+ lit  # 7 alit  # up , >BIN", &.{
        opcodes(.@"@p", .@"@p", .@".", .@"."), 5, 7, 0x145,
    });
    try expectError(error.SingleLiteral, "ASM[ # 0 NODE 5");
}

test "calls, tail calls and labels" {
    try expectAssembles("ASM[ # 0 NODE  : a dup ;  : b a ;  : c warm ; >BIN", &.{
        opcodes(.dup, .@";", .@";", .@";"),
        jumpWord(.jump, .@";", .@";", 0, 0),
        jumpWord(.jump, .@";", .@";", 0, 0xa9),
    });
    // only the length and first 7 characters of a label count
    try expectAssembles("ASM[ # 0 NODE  : abcdefgh dup  abcdefgX >BIN", &.{
        jumpWord(.dup, .call, .@";", 1, 0),
    });
    // labels may be redefined, and the latest is used
    try expectAssembles("ASM[ # 0 NODE  # xBE equ sget  sget  : sget sget >BIN", &.{
        jumpWord(.call, .@";", .@";", 0, 0xbe),
        jumpWord(.call, .@";", .@";", 0, 1),
    });
    // -ROM forgets the ROM's labels, and labels cannot be used before they
    // are defined
    try expectError(error.UnknownWord, "ASM[ # 0 NODE -ROM  warm");
    try expectError(error.UnknownWord, "ASM[ # 0 NODE  later : later ;");

    var diagnostic: Diagnostic = .{};
    const rom_word = (try assemble("ASM[ # 0 NODE\n dup warm >BIN", &diagnostic)).rom_word.?;
    try std.testing.expectEqual(2, rom_word.line);
    try std.testing.expectEqualStrings("warm", rom_word.token);
}

test "bins call each other with its" {
    var programs: [3]Program = undefined;
    var diagnostic: Diagnostic = .{};
    const assembled = (try assembleNodes(
        \\ ASM[ # 1 NODE  # 4 org : a dup ; >BIN
        \\ # 2 NODE  # 1 its a ;  # 1 # its a alit >BIN
        \\ # 3 NODE  # 1600 BIN  # 1 its relay >BIN ]ASM
    , &programs, &.{}, &diagnostic)).programs;
    try std.testing.expectEqual(3, assembled.len);
    try std.testing.expectEqualSlices(Word, &.{
        jumpWord(.jump, .@";", .@";", 0, 4),
        opcodes(.@"@p", .@";", .@";", .@";"),
        4,
    }, assembled[1].ram[0..assembled[1].len]);
    // a bin of its own number is kept, but not as its node's program
    try std.testing.expectEqual(1600, assembled[2].bin);
    try std.testing.expectEqual(3, assembled[2].node);
    // its finds the ROM labels of bins not assembled here
    try std.testing.expectEqual(jumpWord(.call, .@";", .@";", 0, 0xa1), assembled[2].ram[0]);

    // saving a bin again replaces it
    const saved_twice = (try assembleNodes("ASM[ # 1 NODE dup >BIN  # 1 NODE drop >BIN", &programs, &.{}, &diagnostic)).programs;
    try std.testing.expectEqual(1, saved_twice.len);
    try std.testing.expectEqual(opcodes(.drop, .@";", .@";", .@";"), saved_twice[0].ram[0]);
    try std.testing.expectError(error.UndefinedLabel, assembleNodes("ASM[ # 1 NODE  # 2 its nothing", &programs, &.{}, &diagnostic));
    try std.testing.expectEqualStrings("nothing", diagnostic.token);
}

test "control structures" {
    // a forward jump may go in slot 2, which reaches within the same 8 words
    try expectAssembles("ASM[ # 0 NODE  dup dup if  drop then >BIN", &.{
        jumpWord(.dup, .dup, .@"if", 2, 2),
        opcodes(.drop, .@".", .@".", .@"."),
    });
    try expectError(error.UnreachableThen, "ASM[ # 0 NODE  dup dup if  # 9 org then");
    // while is if SWAP, and repeat is again then
    try expectAssembles("ASM[ # 0 NODE  begin dup while drop repeat >BIN", &.{
        jumpWord(.dup, .@"if", .@";", 1, 2),
        jumpWord(.drop, .jump, .@";", 1, 0),
    });
    try expectAssembles("ASM[ # 0 NODE  3. for dup unext  zif ;  then  ahead  leap  then then ;  >BIN", &.{
        opcodes(.@"@p", .@">r", .@".", .@"."),
        3,
        jumpWord(.dup, .unext, .next, 2, 4),
        opcodes(.@";", .@";", .@";", .@";"),
        jumpWord(.jump, .@";", .@";", 0, 6),
        jumpWord(.call, .@";", .@";", 0, 6),
        opcodes(.@";", .@";", .@";", .@";"),
    });
    try expectAssembles("ASM[ # 0 NODE  5. for dup -if *next ;  then drop >BIN", &.{
        opcodes(.@"@p", .@">r", .@".", .@"."),
        5,
        jumpWord(.dup, .@"-if", .@";", 1, 5),
        jumpWord(.next, .@";", .@";", 0, 2),
        opcodes(.@";", .@";", .@";", .@";"),
        opcodes(.drop, .@";", .@";", .@";"),
    });
    try expectAssembles("ASM[ # 0 NODE  if dup else drop then >BIN", &.{
        jumpWord(.@"if", .@";", .@";", 0, 2),
        jumpWord(.dup, .jump, .@";", 1, 3),
        opcodes(.drop, .@".", .@".", .@"."),
    });
}

test "the location counter" {
    try expectAssembles("ASM[ # 0 NODE  dup ..  here alit  dup dup # 2 <sl drop >BIN", &.{
        opcodes(.dup, .@".", .@".", .@"."),
        opcodes(.@"@p", .dup, .dup, .@"."),
        1,
        opcodes(.drop, .@";", .@";", .@";"),
    });
    // code runs on past the end of RAM as P does, ignoring bit 6
    var diagnostic: Diagnostic = .{};
    const program = try assemble("ASM[ # 0 NODE  # x3F org  dup dup dup dup  : x drop  # x alit >BIN", &diagnostic);
    try std.testing.expectEqual(opcodes(.drop, .@"@p", .@";", .@";"), program.ram[0]);
    try std.testing.expectEqual(0x40, program.ram[1]);
    // labels assembled with P9 set run in Extended Arithmetic Mode
    try expectAssembles("ASM[ # 0 NODE  +cy : x dup ;  -cy  # x alit  x >BIN", &.{
        opcodes(.dup, .@";", .@";", .@";"),
        // a call from slot 1 cannot set P9
        opcodes(.@"@p", .@".", .@".", .@"."),
        0x200,
        jumpWord(.call, .@";", .@";", 0, 0x200),
    });
}

test "inline instruction words" {
    // a word executed from a port, whose slot 2 call reaches RAM by clearing P8
    try expectAssembles("ASM[ # 0 NODE  A[ @p b! ]] ,  A[ ; ]] ,  A[ # x115 =P @p ! # x10 call ]] , >BIN", &.{
        opcodes(.@"@p", .@"b!", .@".", .@"."),
        opcodes(.@";", .@";", .@";", .@";"),
        jumpWord(.@"@p", .@"!", .call, 2, 0),
    });
    // without =P, P is not known for a short jump, but a slot 1 jump only
    // keeps P9
    try expectError(error.InlineTooLong, "ASM[ # 0 NODE  A[ @p ! # x10 call ]]");
    try expectAssembles("ASM[ # 0 NODE  A[ @p # x10 call ]] , >BIN", &.{jumpWord(.@"@p", .call, .@";", 1, 0x10)});
    try expectError(error.InlineTooLong, "ASM[ # 0 NODE  A[ dup 5. ]]");
    try expectError(error.NestedInline, "A[ A[");
    try expectError(error.UnclosedInline, "A[ dup");
    try expectError(error.NotInline, "ASM[ ]]");
}

test "named literals and calls" {
    var programs: [2]Program = undefined;
    var diagnostic: Diagnostic = .{};
    const assembled = (try assembleNodes(
        \\ ASM[ # 0 NODE  # east , # north ,  right  rdlu  # -d-- alit >BIN
        \\ # 101 NODE  # east , # north , >BIN ]ASM
    , &programs, &.{}, &diagnostic)).programs;
    try std.testing.expectEqualSlices(Word, &.{
        0x1d5,                                   0x115,
        // a call from slot 1 cannot reach a multiport
        opcodes(.@"@p", .@".", .@".", .@"."),    0x1d5,
        jumpWord(.call, .@";", .@";", 0, 0x1a5), opcodes(.@"@p", .@";", .@";", .@";"),
        0x115,
    }, assembled[0].ram[0..assembled[0].len]);
    // cardinal directions depend on the node's row and column
    try std.testing.expectEqualSlices(Word, &.{ 0x175, 0x145 }, assembled[1].ram[0..2]);

    // NL, NC and CONSTANT define names, and FORGET forgets back to one
    try expectAssembles("ASM 21 NL lit21  x145 NC up?  FORTH  ASM[ # 0 NODE  lit21 up? >BIN", &.{
        opcodes(.@"@p", .@".", .@".", .@"."),
        21,
        jumpWord(.call, .@";", .@";", 0, 0x145),
    });
    try expectError(error.UnknownWord, "ASM 21 NL lit21 FORTH  FORGET lit21  ASM[ # 0 NODE lit21");
    try expectAssembles("4 CONSTANT four  ASM[ # 0 NODE  four org dup >BIN", &.{
        erased, erased, erased, erased, opcodes(.dup, .@";", .@";", .@";"),
    });
}

test idle {
    try std.testing.expectEqual(0x195, idle(0));
    try std.testing.expectEqual(0x1b5, idle(7));
    try std.testing.expectEqual(0x185, idle(100));
    try std.testing.expectEqual(0x1a5, idle(101));
    try std.testing.expectEqual(0x195, idle(717));
}

test "errors" {
    try expectError(error.StackUnderflow, "ASM[ NODE");
    try expectError(error.NoNode, "ASM[ dup");
    try expectError(error.UnsavedBin, "ASM[ # 0 NODE dup ]ASM");
    try expectError(error.UnsavedBin, "ASM[ # 0 NODE dup  # 1 NODE");
    try expectError(error.UnknownWord, "ASM[ # 0 NODE  push");
    try expectError(error.UnterminatedComment, "( never closed");
    try expectError(error.MissingLabelName, "ASM[ # 0 NODE :");

    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.UnsavedBin, assemble("\n ASM[ # 0 NODE\n dup", &diagnostic));
    try std.testing.expectEqual(2, diagnostic.line);
    try std.testing.expectEqualStrings("NODE", diagnostic.token);
}

test "comments and EXIT" {
    try expectAssembles(
        \\ ( a comment)  ASM[ # 0 NODE  dup  \ to the end of the line
        \\ >BIN ]ASM  EXIT  anything at all
    , &.{opcodes(.dup, .@";", .@";", .@";")});
    // EXIT within ASM[ leaves it, so it takes two to stop
    try expectAssembles("ASM[ # 0 NODE dup >BIN EXIT EXIT garbage", &.{opcodes(.dup, .@";", .@";", .@";")});
}

/// blocks holding the given lines, each padded with spaces to 64 characters
fn testBlocks(comptime blocks: []const []const []const u8) [blocks.len * block_size]u8 {
    var result: [blocks.len * block_size]u8 = @splat(' ');
    for (blocks, 0..) |lines, b| for (lines, 0..) |line, l| {
        @memcpy(result[b * block_size + l * 64 ..][0..line.len], line);
    };
    return result;
}

test "blocks" {
    const disk = comptime testBlocks(&.{
        &.{ "( load block)  1 FH LOAD  ASM[ # 0 NODE  dup  \\ to the line's end", "  drop  # 2 FH # 3 FH THRU" },
        &.{ "2 CONSTANT two", "EXIT dup" },
        // a bin may run on into the next block, which starts with ASM[
        &.{"ASM[ two org over"},
        &.{"ASM[ a >BIN ]ASM"},
    });
    var programs: [2]Program = undefined;
    var diagnostic: Diagnostic = .{};
    const assembled = (try assembleBlocks(&disk, &.{0}, &programs, &.{}, &diagnostic)).programs;
    try std.testing.expectEqual(1, assembled.len);
    try std.testing.expectEqualSlices(Word, &.{
        opcodes(.dup, .drop, .@".", .@"."), erased, opcodes(.over, .a, .@";", .@";"),
    }, assembled[0].ram[0..3]);
    // lines count 16 to a block
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 33 }, assembled[0].lines[0..3]);

    // blocks may be loaded in turn
    try std.testing.expectEqual(1, (try assembleBlocks(&disk, &.{ 1, 0 }, &programs, &.{}, &diagnostic)).programs.len);
    try std.testing.expectError(error.NoSuchBlock, assembleBlocks(&disk, &.{4}, &programs, &.{}, &diagnostic));
    try std.testing.expectEqual(0, diagnostic.line);
}

test "loading from within ASM[" {
    // LOAD interprets the block as host code, and goes back to assembling
    const disk = comptime testBlocks(&.{
        &.{"ASM[ # 0 NODE  # 1 LOAD  dup >BIN ]ASM"},
        &.{"( host code)  ASM[ drop"},
    });
    var programs: [1]Program = undefined;
    var diagnostic: Diagnostic = .{};
    const assembled = (try assembleBlocks(&disk, &.{0}, &programs, &.{}, &diagnostic)).programs;
    try std.testing.expectEqual(opcodes(.drop, .dup, .@";", .@";"), assembled[0].ram[0]);
}

test "conditional assembly" {
    try expectAssembles("ASM[ # 0 NODE  # 1 IF{ dup {ELSE} drop }  # 0 IF{ over {ELSE} a } >BIN", &.{
        opcodes(.dup, .a, .@";", .@";"),
    });
}

test "block errors" {
    const disk = comptime testBlocks(&.{
        &.{"0 LOAD"},
        &.{ "", "", "ASM[ # 0 NODE  nothing" },
        &.{},
    });
    var programs: [1]Program = undefined;
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.LoadTooDeep, assembleBlocks(&disk, &.{0}, &programs, &.{}, &diagnostic));
    try std.testing.expectError(error.UnknownWord, assembleBlocks(&disk, &.{1}, &programs, &.{}, &diagnostic));
    try std.testing.expectEqual(16 + 3, diagnostic.line);
    try std.testing.expectError(error.NoSuchBlock, assembleBlocks(&disk, &.{ 2, 3 }, &programs, &.{}, &diagnostic));
    try std.testing.expectEqual(0, diagnostic.line);
    try expectError(error.NoSuchBlock, "1 LOAD");
    try expectError(error.NoSuchBlock, "1 FH");
}

test blockText {
    const disk = comptime testBlocks(&.{&.{ "first", "second\n" }});
    var text: [16 * 65]u8 = undefined;
    const lines = blockText(&disk, &text);
    try std.testing.expectEqual(16 * 65, lines.len);
    try std.testing.expectEqualStrings("first ", lines[0..6]);
    try std.testing.expectEqualStrings(" \nsecond ", lines[63 .. 65 + 7]);
}

test "boot descriptors" {
    var programs: [3]Program = undefined;
    var descriptors: [3]boot.Descriptor = undefined;
    var diagnostic: Diagnostic = .{};
    const assembled = try assembleNodes(
        \\ ASM[ # 5 NODE  : main dup ; : run drop ; >BIN
        \\ # 6 NODE  : go over ; >BIN
        \\ # 7 NODE # 1600 BIN  a a ; >BIN ]ASM
        \\ 5 +NODE  5 /RAM  1 2 3 1600 /SOME  4 1 1600 /PART
        \\    RIGHT /A  x15. /IO  5 ITS run /P
        \\    1. 2. NORTH 3 /STACK  /RINF
        \\ 6 +NODE  1600 /RAM  EAST LEFT 6 ITS go 6 +ND
        \\ 7 +NODE  5 +NODE  7. /B
    , &programs, &descriptors, &diagnostic);
    try std.testing.expectEqual(3, assembled.descriptors.len);

    const five = assembled.descriptors[0];
    try std.testing.expectEqual(5, five.node);
    try std.testing.expectEqualSlices(boot.Descriptor.Load, &.{
        .{ .bin = 5 },
        .{ .bin = 1600, .source = 1, .destination = 2, .len = 3 },
        .{ .bin = 1600, .source = 4, .destination = 4, .len = 1 },
    }, five.loads[0..five.load_count]);
    try std.testing.expectEqual(0x1d5, five.a);
    // +NODE again goes back to the node's descriptor
    try std.testing.expectEqual(7, five.b);
    try std.testing.expectEqual(0x15, five.io);
    try std.testing.expectEqual(1, five.p);
    // the last value goes on top, and node 005's row is even
    try std.testing.expectEqualSlices(Word, &.{ 1, 2, 0x115 }, five.stack[0..five.stack_len]);
    try std.testing.expectEqualSlices(Word, &@as([9]Word, @splat(-1)), five.return_stack[0..five.return_stack_len]);

    // +ND loads the node's own bin, replacing earlier loads of all of RAM,
    // and sets A, B and P
    const six = assembled.descriptors[1];
    try std.testing.expectEqualSlices(boot.Descriptor.Load, &.{.{ .bin = 6 }}, six.loads[0..six.load_count]);
    // east of an even column is right
    try std.testing.expectEqual(0x1d5, six.a);
    try std.testing.expectEqual(0x175, six.b);
    try std.testing.expectEqual(0, six.p);

    // nodes start at warm with B addressing IO, unless set otherwise
    const seven = assembled.descriptors[2];
    try std.testing.expectEqual(0xa9, seven.p);
    try std.testing.expectEqual(0x15d, seven.b);
    try std.testing.expectEqual(null, seven.a);
}

test "boot descriptor errors" {
    var programs: [1]Program = undefined;
    var descriptors: [1]boot.Descriptor = undefined;
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.NoBootNode, assembleNodes("1 /P", &programs, &descriptors, &diagnostic));
    try std.testing.expectError(error.NoSuchBin, assembleNodes("1 +NODE 1 /RAM", &programs, &descriptors, &diagnostic));
    try std.testing.expectError(error.TooManyDescriptors, assembleNodes("1 +NODE 2 +NODE", &programs, &descriptors, &diagnostic));
    try std.testing.expectError(error.TooManyLoads, assembleNodes("ASM[ # 1 NODE dup >BIN ]ASM 1 +NODE  0 1 1 /PART 0 1 1 /PART 0 1 1 /PART 0 1 1 /PART", &programs, &descriptors, &diagnostic));
    try std.testing.expectError(error.NumberOutOfRange, assembleNodes("ASM[ # 1 NODE dup >BIN ]ASM 1 +NODE  60 5 1 /PART", &programs, &descriptors, &diagnostic));
    try std.testing.expectError(error.NumberOutOfRange, assembleNodes("1 +NODE  11 /STACK", &programs, &descriptors, &diagnostic));
    // values too large to add without overflowing
    try std.testing.expectError(error.NumberOutOfRange, assembleNodes("ASM[ # 1 NODE dup >BIN ]ASM 1 +NODE  2147483647 1 1 /PART", &programs, &descriptors, &diagnostic));
    try std.testing.expectError(error.NumberOutOfRange, assembleNodes("ASM[ # 1 NODE dup >BIN ]ASM 1 +NODE  1 2147483647 1 /PART", &programs, &descriptors, &diagnostic));
}

/// Reads arrayForth 3's disk from rom/, skipping the test if it is missing,
/// as it is GreenArrays' and not part of gasim
fn testDisk(gpa: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, "rom/pFDISK.blk", gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => |e| e,
    };
}

test "the ROM source assembles to the chip's ROM" {
    const gpa = std.testing.allocator;
    var roms: [144]ga144.NodeRom = undefined;
    const chip_roms = try ga144.testRom(&roms);
    const disk = try testDisk(gpa);
    defer gpa.free(disk);

    // what block 2221 does with host code: names the blocks of the pieces
    // the ROMs share, then loads each node's ROM block with its number,
    // and then the blocks of the nodes with SDRAM and eForth ROMs
    var script: std.Io.Writer.Allocating = .init(gpa);
    defer script.deinit();
    const writer = &script.writer;
    for ([_][]const u8{ "POLY", "INTERP", "FILTER", "RELAY", "MPLY", "SHIFT", "TRIANG", ".MULT", "DIVIDE" }, 2232..) |name, block| {
        try writer.print("{d} CONSTANT {s}\n", .{ block, name });
    }
    for (chip_roms) |rom| {
        const block: u32 = switch (ga144.romType(rom.node)) {
            .basic => 2222,
            .serdes_boot => 2223,
            .sync_boot => 2224,
            .async_boot => 2225,
            .spi_boot => 2227,
            .analog => 2229,
            .one_wire => 2230,
            .special => continue,
        };
        try writer.print("{d} {d} LOAD\n", .{ rom.node, block });
    }
    try writer.writeAll("2241 LOAD\n");

    const programs = try gpa.alloc(Program, 160);
    defer gpa.free(programs);
    var diagnostic: Diagnostic = .{};
    const assembled = assembleScript(script.written(), disk, programs, &.{}, &diagnostic) catch |err| {
        std.debug.print("{t} at block {d} line {d} '{s}'\n", .{ err, (diagnostic.line -| 1) / 16, (diagnostic.line -| 1) % 16, diagnostic.token });
        return err;
    };

    var differences: usize = 0;
    for (chip_roms) |rom| {
        const program = for (assembled.programs) |*p| {
            if (p.node == rom.node and p.bin == null) break p;
        } else {
            std.debug.print("node {d:0>3}: no ROM assembled\n", .{rom.node});
            differences += 1;
            continue;
        };
        const words = program.rom orelse {
            std.debug.print("node {d:0>3}: no ROM assembled\n", .{rom.node});
            differences += 1;
            continue;
        };
        for (words.words, rom.words, 0x80..) |ours, theirs, address| if (ours != theirs) {
            if (differences < 20) std.debug.print("node {d:0>3} {x:0>3}: assembled {x:0>5}, chip {x:0>5}\n", .{ rom.node, address, @as(u18, @bitCast(ours)), @as(u18, @bitCast(theirs)) });
            differences += 1;
        };
    }
    try std.testing.expectEqual(0, differences);
}

test "assembling into ROM" {
    var diagnostic: Diagnostic = .{};
    // ERS erases RAM but not ROM, and code runs on past xbf to xc0, which
    // is x080 again
    const program = try assemble("ASM[ # 0 NODE -ROM  # xA9 org : warm dup ;  ERS  # xBF org  drop drop drop drop over  # x10 org a >BIN", &diagnostic);
    const rom = program.rom.?;
    try std.testing.expectEqual(64, rom.len);
    try std.testing.expectEqual(opcodes(.drop, .over, .@".", .@"."), rom.words[0]);
    try std.testing.expectEqual(erased, rom.words[1]);
    try std.testing.expectEqual(opcodes(.dup, .@";", .@";", .@";"), rom.words[0x29]);
    try std.testing.expectEqual(opcodes(.drop, .drop, .drop, .@"."), rom.words[0x3f]);
    try std.testing.expectEqual(opcodes(.a, .@";", .@";", .@";"), program.ram[0x10]);
    // as does code at xff, which runs on to x80
    const end = try assemble("ASM[ # 0 NODE -ROM  # xFF org  drop drop drop drop over >BIN", &diagnostic);
    try std.testing.expectEqual(opcodes(.drop, .over, .@";", .@";"), end.rom.?.words[0]);

    // a program with no ROM code has none
    try std.testing.expectEqual(null, (try assemble("ASM[ # 0 NODE dup >BIN", &diagnostic)).rom);
}

test "a session acts on a chip, as the IDE does" {
    const gpa = std.testing.allocator;
    var chip: Chip = try .init(gpa, .ga144);
    defer chip.deinit(gpa);
    // node 000 waits for code on its left port, which faces off the chip
    try chip.setUp(.{ .node = 0, .p = 0x175 }, &.{});
    _ = try chip.runUntilWaiting(chip.layout.index(0).?, 10);

    var programs: [2]Program = undefined;
    var descriptors: [2]boot.Descriptor = undefined;
    var buffer: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    var session: Session = .init(&programs, &descriptors, &diagnostic, .{ .out = &out, .chip = &chip });

    try std.testing.expectError(error.NoTarget, session.interpret("UPD"));
    // the stack is kept from one line to the next
    try session.interpret("HEX 1 2");
    try session.interpret("+ .");
    try std.testing.expectEqualStrings("3 ", out.buffered());

    // assemble code, load it into the target, and call it
    try session.interpret("ASM[ # 0 NODE  : inc 1. + ; >BIN ]ASM");
    try std.testing.expectError(error.NumberOutOfRange, session.interpret("0 NODE  2147483647 2 0 BOOT"));
    try session.interpret("0 NODE  0 2 0 BOOT  5. LIT  0 CALL  RDUP");
    out.end = 0;
    try session.interpret("UPD");
    try std.testing.expectStringEndsWith(out.buffered(), " 00006 00006\nR 00000 00000 00000 00000 00000 00000 00000 00000 00000\n");
    out.end = 0;
    try session.interpret("0 R@ D.  0 2 -ASM");
    try std.testing.expectEqualStrings("4155 000 04155  @p + ;\n001 00001  literal 1\n", out.buffered());

    // completion knows words, opcodes and labels
    const Words = struct {
        found: [8][]const u8 = undefined,
        len: usize = 0,
        fn add(self: *@This(), word: []const u8) void {
            if (self.len < self.found.len) self.found[self.len] = word;
            self.len += 1;
        }
    };
    var words: Words = .{};
    session.complete("@b", &words);
    try std.testing.expectEqual(1, words.len);
    try std.testing.expectEqualStrings("@b", words.found[0]);
    words = .{};
    // the bin's labels include its ROM's
    session.complete("in", &words);
    try std.testing.expectEqual(3, words.len);
    try std.testing.expectEqualStrings("inv", words.found[0]);
    try std.testing.expectEqualStrings("interp", words.found[1]);
    try std.testing.expectEqualStrings("inc", words.found[2]);

    // an error empties the stack and leaves ASM[
    try std.testing.expectError(error.UnknownWord, session.interpret("1 2 ASM[ nothing"));
    try std.testing.expectEqual(0, session.stack().len);
    try session.interpret("1 2");
    try std.testing.expectEqual(2, session.stack().len);
}
