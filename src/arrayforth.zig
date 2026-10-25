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
};

/// Assembles the bins in `source` into `programs`, returning the programs
/// saved with >BIN.
pub fn assembleNodes(source: []const u8, programs: []Program, diagnostic: *Diagnostic) Error![]Program {
    var interpreter: Interpreter = .{ .tokens = .{ .source = source }, .diagnostic = diagnostic, .programs = programs };
    return interpreter.run();
}

/// Assembles the single bin in `source`
pub fn assemble(source: []const u8, diagnostic: *Diagnostic) Error!Program {
    var programs: [1]Program = undefined;
    const assembled = try assembleNodes(source, &programs, diagnostic);
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
        return bin;
    }

    fn fresh() Builder {
        return .{ .ram = @splat(erased), .returns = true, .short_forward = true, .wrap = true };
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

/// a bin saved with >BIN, whose labels `its` can find
const SavedBin = struct {
    number: u32,
    labels: []const Label,
};

/// a word defined by NL, NDL, NC or CONSTANT
const Name = struct {
    name: []const u8,
    kind: enum { literal, double_literal, call, constant },
    value: i64,
};

const Number = union(enum) { single: i32, double: i64 };

const Interpreter = struct {
    tokens: Tokenizer,
    diagnostic: *Diagnostic,
    programs: []Program,
    count: usize = 0,

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

    fn run(self: *Interpreter) Error![]Program {
        while (try self.next()) |token| {
            if (eql(token, "EXIT") and !self.assembling) break;
            try self.interpret(token);
        }
        if (self.inline_word != null) return error.UnclosedInline;
        try self.checkSaved();
        return self.programs[0..self.count];
    }

    /// fails if the bin has code or labels that were not saved
    fn checkSaved(self: *Interpreter) Error!void {
        const bin = self.bin orelse return;
        if (bin.changed) {
            self.diagnostic.* = bin.directive;
            return error.UnsavedBin;
        }
    }

    fn next(self: *Interpreter) Error!?[]const u8 {
        const token = self.tokens.next() catch |err| {
            self.diagnostic.* = .{ .line = self.tokens.start_line, .token = self.tokens.source[self.tokens.start..][0..1] };
            return err;
        };
        self.diagnostic.* = .{ .line = self.tokens.start_line, .token = token orelse return null };
        return token;
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
        bin.builder.line = self.tokens.start_line;
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
                if (address < 0 or address & ~@as(i32, 0x27f) != 0) return error.NumberOutOfRange;
                const b = try self.builder();
                try b.org(@intCast(address & 0x7f));
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
                const bin = try self.currentBin();
                bin.builder = Bin.fresh();
                bin.label_count = bin.rom_count;
            },
            .@"-ROM" => {
                const bin = try self.currentBin();
                bin.builder = Bin.fresh();
                bin.label_count = 0;
                bin.rom_count = 0;
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
                const value: Word = if (b.len == 0) @bitCast(@as(u18, 0x15555)) else b.ram[0];
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
                try (try self.builder()).unext(@intCast(destination & 0x3f));
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
        try self.push(@as(i32, jump.p) << 8 | @as(i32, jump.address) << 2 | jump.slot);
    }

    fn then(self: *Interpreter) Error!void {
        const handle: u32 = @bitCast(try self.pop());
        if (handle >> 18 != 0) return error.UnmatchedControl;
        try (try self.builder()).then(.{
            .p = @intCast(handle >> 8),
            .address = @intCast(handle >> 2 & 0x3f),
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
            .ram = bin.builder.ram,
            .len = bin.builder.len,
            .lines = bin.builder.lines,
            .entry = .{ .io = false, .rom = false, .local = main },
            .rom_word = bin.rom_word,
        };

        if (self.pool_len + bin.label_count > self.label_pool.len) return error.TooManyLabels;
        const labels = self.label_pool[self.pool_len..][0..bin.label_count];
        @memcpy(labels, bin.labels[0..bin.label_count]);
        self.pool_len += bin.label_count;

        bin.changed = false;
        for (self.saved[0..self.saved_count], 0..) |*saved, i| {
            if (saved.number == bin.number) {
                self.programs[i] = program;
                saved.labels = labels;
                return;
            }
        }
        if (self.count == self.programs.len) return error.TooManyNodes;
        if (self.saved_count == self.saved.len) return error.TooManyNodes;
        self.programs[self.count] = program;
        self.count += 1;
        self.saved[self.saved_count] = .{ .number = bin.number, .labels = labels };
        self.saved_count += 1;
    }

    /// the value of a label in a saved bin, or in the ROM of the bin's node
    fn labelOf(self: *Interpreter, number_of_bin: i32, label_name: []const u8) Error!u16 {
        if (number_of_bin < 0 or number_of_bin > 999999) return error.InvalidNode;
        const labels = for (self.saved[0..self.saved_count]) |saved| {
            if (saved.number == number_of_bin) break saved.labels;
        } else romLabels(@intCast(@rem(number_of_bin, 10000)));
        var i = labels.len;
        while (i > 0) {
            i -= 1;
            if (sameLabel(labels[i].name, label_name)) return labels[i].value;
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
            .@"." => _ = try self.pop(),
            .HEX => self.base = 16,
            .DECIMAL => self.base = 10,
            .CONSTANT => try self.define(.constant, try self.pop()),
            .FORGET => {
                const forget_name = try self.name();
                self.name_count = self.findName(forget_name) orelse return error.UnknownWord;
            },
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
    index: usize = 0,
    line: usize = 1,
    /// where the last token, or the malformed one, starts
    start: usize = 0,
    start_line: usize = 1,

    fn next(self: *Tokenizer) Error!?[]const u8 {
        while (true) {
            while (self.index < self.source.len and std.ascii.isWhitespace(self.source[self.index])) self.advance();
            if (self.index == self.source.len) return null;

            self.start = self.index;
            self.start_line = self.line;
            while (self.index < self.source.len and !std.ascii.isWhitespace(self.source[self.index])) self.advance();
            const token = self.source[self.start..self.index];
            if (eql(token, "\\")) {
                while (self.index < self.source.len and self.source[self.index] != '\n') self.advance();
            } else if (eql(token, "(") or eql(token, ".(")) {
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
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const assembler = @import("assembler.zig");
const Diagnostic = assembler.Diagnostic;
const Program = assembler.Program;
const Builder = @import("Builder.zig");
const f18 = @import("f18.zig");
const Instruction = f18.Instruction;
const Slot = f18.Slot;
const Word = f18.Word;
const ga144 = @import("ga144.zig");
const Opcode = @import("opcodes.zig").Opcode;

const std = @import("std");

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
    const assembled = try assembleNodes(
        \\ ASM[ # 1 NODE  # 4 org : a dup ; >BIN
        \\ # 2 NODE  # 1 its a ;  # 1 # its a alit >BIN
        \\ # 3 NODE  # 1600 BIN  # 1 its relay >BIN ]ASM
    , &programs, &diagnostic);
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
    const saved_twice = try assembleNodes("ASM[ # 1 NODE dup >BIN  # 1 NODE drop >BIN", &programs, &diagnostic);
    try std.testing.expectEqual(1, saved_twice.len);
    try std.testing.expectEqual(opcodes(.drop, .@";", .@";", .@";"), saved_twice[0].ram[0]);
    try std.testing.expectError(error.UndefinedLabel, assembleNodes("ASM[ # 1 NODE  # 2 its nothing", &programs, &diagnostic));
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
    // without =P, P is not known for a short jump
    try expectError(error.InlineTooLong, "ASM[ # 0 NODE  A[ @p ! # x10 call ]]");
    try expectError(error.InlineTooLong, "ASM[ # 0 NODE  A[ dup 5. ]]");
    try expectError(error.NestedInline, "A[ A[");
    try expectError(error.UnclosedInline, "A[ dup");
    try expectError(error.NotInline, "ASM[ ]]");
}

test "named literals and calls" {
    var programs: [2]Program = undefined;
    var diagnostic: Diagnostic = .{};
    const assembled = try assembleNodes(
        \\ ASM[ # 0 NODE  # east , # north ,  right  rdlu  # -d-- alit >BIN
        \\ # 101 NODE  # east , # north , >BIN ]ASM
    , &programs, &diagnostic);
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
