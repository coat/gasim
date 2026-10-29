//! What the web version runs: a GA144 with a console on node 000's up port,
//! an arrayForth 3 session acting on it, the colorForth editor, and the
//! chip's history to go back through. `main.zig` exports it to JavaScript;
//! here it is plain Zig, so it is tested natively.
//!
//! It keeps pointers to its own fields, so it must not move once `init`.

const Sim = @This();

gpa: Allocator,
chip: Chip,
console: Console = undefined,
/// what the console wrote since JavaScript last took it
console_out: Writer.Allocating,
roms: ?[]ga144.NodeRom = null,
programs: []Program,
descriptors: []boot.Descriptor,
diagnostic: Diagnostic = .{},
session: Session = undefined,
/// what the session wrote for the last line or file
forth_out: Writer.Allocating,
/// the sources and lines the session's labels refer to, for as long as it
/// lasts
sources: std.heap.ArenaAllocator,
/// the chip as it was set up, which `reset` goes back to
start: Chip.Snapshot,
/// the chip before each step or run, the oldest first, with one more saved
/// before it is kept, as the TUI keeps them
history: [history_capacity + 1]?Chip.Snapshot = @splat(null),
/// what each snapshot in `history` was saved before
causes: [history_capacity + 1]Cause = @splat(.run),
history_start: usize = 0,
history_len: usize = 0,
pending: bool = false,
editor: Editor = undefined,
/// the editor's file, with room to grow
editor_blocks: []u8 = &.{},
/// the editor's file was a compressed arrayForth 2 image
editor_compressed: bool = false,
/// the trace, while tracing
trace: ?*Tail = null,
/// text and JSON for JavaScript to read
out: Writer.Allocating,

pub const layout: Chip.Layout = .ga144;
pub const console_node = 0;
pub const console_port: Direction = .up;
pub const history_capacity = 64;
/// how much of the trace is kept between `takeTrace`s
pub const trace_capacity = 256 * 1024;
/// blocks the editor's file can grow to, as the TUI's
pub const editor_capacity = 256;

/// what a file holds, by its extension
pub const Kind = enum(u8) {
    /// gasim's assembler
    ga,
    /// arrayForth 3 text
    af,
    /// arrayForth 3's polyFORTH blocks
    blk,
    /// colorForth blocks, or an arrayForth 2 image
    cf,
};

/// why `run` stopped
pub const Stop = enum(u8) {
    /// it ran for as long as it was given
    budget,
    /// every node is waiting, and nothing can come for them
    settled,
    /// a node waits on the console for input that has not been given
    input,
    /// a breakpoint or watch was hit, as `out` describes
    hit,
};

/// what the chip was saved before, in the history
pub const Cause = enum(u8) {
    step,
    round,
    node,
    run,
    /// a line at the prompt
    line,
    reset,
    compile,
};

pub fn init(self: *Sim, gpa: Allocator) Allocator.Error!void {
    self.* = .{
        .gpa = gpa,
        .chip = try .init(gpa, layout),
        .console_out = .init(gpa),
        .programs = &.{},
        .descriptors = &.{},
        .forth_out = .init(gpa),
        .sources = .init(gpa),
        .start = undefined,
        .out = .init(gpa),
    };
    errdefer self.chip.deinit(gpa);
    self.programs = try gpa.alloc(Program, layout.count());
    errdefer gpa.free(self.programs);
    self.descriptors = try gpa.alloc(boot.Descriptor, layout.count());
    errdefer gpa.free(self.descriptors);
    self.start = try .init(gpa, layout);
    errdefer self.start.deinit(gpa);
    self.editor_blocks = try gpa.alloc(u8, editor_capacity * colorforth.block_size);
    @memset(self.editor_blocks, 0);
    self.editor.open(self.editor_blocks, 1);
    self.attach();
    self.newSession(null);
    self.chip.save(&self.start);
}

pub fn deinit(self: *Sim) void {
    const gpa = self.gpa;
    self.chip.deinit(gpa);
    self.start.deinit(gpa);
    for (&self.history) |*snapshot| if (snapshot.*) |*s| s.deinit(gpa);
    if (self.roms) |roms| gpa.free(roms);
    gpa.free(self.programs);
    gpa.free(self.descriptors);
    gpa.free(self.editor_blocks);
    self.sources.deinit();
    self.setTracing(false) catch unreachable;
    self.console_out.deinit();
    self.forth_out.deinit();
    self.out.deinit();
}

fn attach(self: *Sim) void {
    self.console = .{ .output = &self.console_out.writer };
    self.chip.attachConsole(&self.console, console_node, console_port) catch unreachable;
    self.chip.trace = if (self.trace) |t| &t.writer else null;
}

fn newSession(self: *Sim, blocks: ?[]const u8) void {
    self.diagnostic = .{};
    self.session = .init(self.programs, self.descriptors, &self.diagnostic, .{
        .out = &self.forth_out.writer,
        .chip = &self.chip,
        .blocks = blocks,
    });
}

/// Sets the ROM from a dump in `--rom`'s format, or assembles it from
/// arrayForth 3's disk, `pFDISK.blk`. A chip already set up keeps its own
/// ROM until the next `load`.
pub fn setRom(self: *Sim, bytes: []const u8) error{ InvalidRom, OutOfMemory }!void {
    const roms = try self.gpa.alloc(ga144.NodeRom, layout.count());
    errdefer self.gpa.free(roms);
    const parsed = ga144.parseRom(bytes, roms) catch parsed: {
        var diagnostic: Diagnostic = .{};
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        break :parsed rom.assemble(arena.allocator(), bytes, roms[0..144], &diagnostic) catch return error.InvalidRom;
    };
    if (parsed.len == 0) return error.InvalidRom;
    if (self.roms) |old| self.gpa.free(old);
    self.roms = roms[0..parsed.len];
}

/// Starts a new chip, ROM loaded, and a new session, then assembles `file`
/// and sets up the nodes it has code for. Blocks of `.blk` and `.cf` files
/// are loaded as `--load` loads them; a `.cf` file is also opened in the
/// editor. On an error, `out` says what and where.
pub fn load(self: *Sim, kind: Kind, file: []const u8, loads: []const u32) error{ LoadFailed, OutOfMemory }!void {
    self.out.clearRetainingCapacity();
    // the breakpoints and watches stay, as the chip starts again
    var chip: Chip = try .init(self.gpa, layout);
    chip.breakpoints = self.chip.breakpoints;
    chip.watches = self.chip.watches;
    self.chip.deinit(self.gpa);
    self.chip = chip;
    self.attach();
    if (self.roms) |roms| self.chip.loadRom(roms) catch unreachable;
    // a file that fails to load leaves the chip empty to go back to, rather
    // than as the last file set it up
    self.chip.save(&self.start);
    _ = self.sources.reset(.retain_capacity);
    self.forth_out.clearRetainingCapacity();
    self.console_out.clearRetainingCapacity();
    self.forgetHistory();

    const source = try self.sources.allocator().dupe(u8, file);
    if (kind == .cf) try self.openEditor(source);
    self.newSession(if (kind == .blk) source else null);
    const assembled = self.assemble(kind, source, loads) catch |err| return self.failAt(kind, err);
    try self.setUp(kind, assembled);
}

fn assemble(self: *Sim, kind: Kind, source: []const u8, loads: []const u32) !arrayforth.Assembled {
    switch (kind) {
        .ga => {
            const programs = try assembler.assembleNodes(source, self.programs, &self.diagnostic);
            return .{ .programs = programs, .descriptors = &.{} };
        },
        .af => try self.session.interpret(source),
        .blk => for (loads) |block| {
            if (block >= arrayforth.blockCount(source)) {
                self.diagnostic = .{};
                return error.NoSuchBlock;
            }
            var line: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{d} LOAD", .{block}) catch unreachable;
            try self.session.interpret(try self.sources.allocator().dupe(u8, text));
        },
        .cf => {
            const blocks = self.editor.contents();
            for (loads) |block| try self.session.loadColorForth(blocks, block);
            return self.session.assembled();
        },
    }
    try self.session.finish();
    return self.session.assembled();
}

/// sets up the nodes as the boot descriptors say, or each program in its
/// own node, and saves the chip to start from
fn setUp(self: *Sim, kind: Kind, assembled: arrayforth.Assembled) error{ LoadFailed, OutOfMemory }!void {
    const programs = assembled.programs;
    const descriptors = if (assembled.descriptors.len > 0) assembled.descriptors else own: {
        var count: usize = 0;
        for (programs) |program| if (program.bin == null) {
            self.descriptors[count] = .ofProgram(program);
            count += 1;
        };
        break :own self.descriptors[0..count];
    };
    if (self.roms == null) for (descriptors) |descriptor| {
        for (descriptor.loads[0..descriptor.load_count]) |part| {
            const program = boot.findBin(programs, part.bin) orelse continue;
            if (program.rom_word) |word| {
                self.diagnostic = word;
                return self.failAt(kind, error.MissingRom);
            }
        }
        if (descriptor.p & 0x180 == 0x080) return self.fail("node {d:0>3} starts in ROM at {x:0>3}, which is not loaded", .{ descriptor.node, descriptor.p });
    };
    for (descriptors) |descriptor| self.chip.setUp(descriptor, programs) catch |err| switch (err) {
        error.NoSuchNode => return self.fail("node {d:0>3} is not on the chip", .{descriptor.node}),
        error.NoSuchBin => return self.fail("node {d:0>3} loads a bin that was not saved", .{descriptor.node}),
    };
    self.chip.save(&self.start);
    if (assembled.first_difference) |first| {
        const place = colorforth.place(first.line);
        self.out.writer.print("block {d} word {d}: arrayForth 2 noted {x:0>3} here, where gasim is at {x:0>3}, and {d} more gray numbers differ", .{
            place.block, place.token, first.noted, first.found, assembled.feedback_differs - 1,
        }) catch return error.OutOfMemory;
    }
}

fn fail(self: *Sim, comptime format: []const u8, args: anytype) error{ LoadFailed, OutOfMemory } {
    self.out.clearRetainingCapacity();
    self.out.writer.print(format, args) catch return error.OutOfMemory;
    return error.LoadFailed;
}

/// says where in the file an error was, as the CLI does
fn failAt(self: *Sim, kind: Kind, err: anyerror) error{ LoadFailed, OutOfMemory } {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const line = self.diagnostic.line;
    const token = self.diagnostic.token;
    if (err == error.MissingRom) return self.fail("{f}: '{s}' is in ROM, which is not loaded", .{ where(kind, line), token });
    if (err == error.NoSuchBlock and line == 0) return self.fail("the file has fewer blocks than are loaded", .{});
    return self.fail("{f}: {t} at '{s}'", .{ where(kind, line), err, token });
}

fn where(kind: Kind, line: usize) Where {
    return .{ .kind = kind, .line = line };
}

const Where = struct {
    kind: Kind,
    line: usize,

    pub fn format(self: Where, writer: *Writer) Writer.Error!void {
        switch (self.kind) {
            .ga, .af => try writer.print("line {d}", .{self.line}),
            .blk => try writer.print("block {d} line {d}", .{ (self.line -| 1) / 16, (self.line -| 1) % 16 }),
            .cf => {
                const place = colorforth.place(self.line);
                try writer.print("block {d} word {d}", .{ place.block, place.token });
            },
        }
    }
};

// ---------- running ----------

/// Runs for at most `budget` rounds, each giving the console what it has
/// and stepping each runnable node once
pub fn run(self: *Sim, budget: usize) error{OutOfMemory}!Stop {
    self.chip.hit = null;
    for (0..budget) |_| {
        const advanced = self.chip.advance() catch return error.OutOfMemory;
        if (self.chip.hit != null) return self.stopped();
        if (!advanced) return if (self.console.wantsInput()) .input else .settled;
    }
    return .budget;
}

/// describes the breakpoint or watch hit into `out`, and clears it
fn stopped(self: *Sim) error{OutOfMemory}!Stop {
    const hit = self.chip.hit.?;
    self.chip.hit = null;
    self.out.clearRetainingCapacity();
    self.out.writer.print("{f}", .{hit.describe(layout)}) catch return error.OutOfMemory;
    return .hit;
}

/// Steps the next node to run, returning its index, or null when every node
/// is waiting
pub fn stepNext(self: *Sim) error{OutOfMemory}!?u16 {
    self.remember(.step);
    return self.chip.stepNext() catch error.OutOfMemory;
}

/// Steps each runnable node once. Returns false when every node is waiting.
pub fn stepRound(self: *Sim) error{OutOfMemory}!bool {
    self.remember(.round);
    return self.chip.advance() catch error.OutOfMemory;
}

/// Steps one node, even one that is waiting, which then tries again.
/// Returns false if it is still waiting.
pub fn stepNode(self: *Sim, i: u16) error{OutOfMemory}!bool {
    self.remember(.node);
    _ = self.chip.service() catch return error.OutOfMemory;
    self.chip.stepNode(i);
    return !self.chip.nodes[i].suspended;
}

/// Goes back to the chip as it was set up, with the console's input not
/// yet read forgotten, and not ended
pub fn reset(self: *Sim) void {
    self.remember(.reset);
    self.chip.restore(&self.start);
    self.console.taken_start = 0;
    self.console.taken_end = 0;
    self.console.ended = false;
}

/// Saves the chip, before stepping or running it, to go back to if it
/// changes
pub fn remember(self: *Sim, cause: Cause) void {
    self.keepPending();
    const index = self.historyIndex(self.history_len);
    const snapshot = &self.history[index];
    if (snapshot.* == null) snapshot.* = Chip.Snapshot.init(self.gpa, layout) catch return;
    self.chip.save(&snapshot.*.?);
    self.causes[index] = cause;
    self.pending = true;
}

/// keeps the snapshot saved last, unless nothing has changed since
fn keepPending(self: *Sim) void {
    if (!self.pending) return;
    self.pending = false;
    if (self.chip.matches(&self.history[self.historyIndex(self.history_len)].?)) return;
    if (self.history_len == history_capacity) {
        self.history_start = self.historyIndex(1);
    } else self.history_len += 1;
}

/// Goes back to before the last step or run. Returns false with nothing to
/// go back to.
pub fn back(self: *Sim) bool {
    self.keepPending();
    if (self.history_len == 0) return false;
    self.history_len -= 1;
    self.chip.restore(&self.history[self.historyIndex(self.history_len)].?);
    return true;
}

/// how many steps and runs there are to go back through
pub fn historyLen(self: *Sim) usize {
    self.keepPending();
    return self.history_len;
}

/// Goes back to before the `n`th step or run kept, the oldest 0, forgetting
/// those after it. Returns false if there is no such step.
pub fn backTo(self: *Sim, n: usize) bool {
    if (n >= self.historyLen()) return false;
    while (self.history_len > n) _ = self.back();
    return true;
}

const Moment = struct {
    /// the steps taken by then
    steps: u64,
    cause: Cause,
};

/// Writes the steps and runs to go back through into `out` as JSON, the
/// oldest first
pub fn historyView(self: *Sim) error{OutOfMemory}![]const u8 {
    var moments: [history_capacity]Moment = undefined;
    const len = self.historyLen();
    for (moments[0..len], 0..) |*moment, k| {
        const index = self.historyIndex(k);
        moment.* = .{ .steps = self.history[index].?.steps, .cause = self.causes[index] };
    }
    self.out.clearRetainingCapacity();
    try self.writeJson(moments[0..len]);
    return self.out.written();
}

fn historyIndex(self: Sim, i: usize) usize {
    return (self.history_start + i) % self.history.len;
}

fn forgetHistory(self: *Sim) void {
    self.history_start = 0;
    self.history_len = 0;
    self.pending = false;
}

/// Adds a breakpoint, or removes it. Returns whether it is there now.
pub fn toggleBreakpoint(self: *Sim, i: u16, address: u9) error{Full}!bool {
    return self.chip.breakpoints.toggle(.init(i, address));
}

/// Adds a watch on a port of a node, or removes it. Returns whether it is
/// there now.
pub fn toggleWatch(self: *Sim, i: u16, direction: Direction, write: bool) error{Full}!bool {
    return self.chip.watches.toggle(.{ .index = i, .direction = direction, .write = write });
}

/// Removes every breakpoint and watch
pub fn clearBreakpoints(self: *Sim) void {
    self.chip.breakpoints = .{};
    self.chip.watches = .{};
}

// ---------- the trace ----------

/// Starts writing a line for each step that executes code, as `--trace`
/// does, or stops
pub fn setTracing(self: *Sim, on: bool) error{OutOfMemory}!void {
    if (on and self.trace == null) {
        const t = try self.gpa.create(Tail);
        errdefer self.gpa.destroy(t);
        t.* = .{ .writer = .{ .vtable = &.{ .drain = Tail.drain }, .buffer = try self.gpa.alloc(u8, trace_capacity) } };
        self.trace = t;
    } else if (!on) if (self.trace) |t| {
        self.gpa.free(t.writer.buffer);
        self.gpa.destroy(t);
        self.trace = null;
    };
    self.chip.trace = if (self.trace) |t| &t.writer else null;
}

/// Writes what was traced since this was last called into `out`, and
/// returns whether older lines were dropped to make room
pub fn takeTrace(self: *Sim) bool {
    self.out.clearRetainingCapacity();
    const t = self.trace orelse return false;
    self.out.writer.writeAll(t.writer.buffered()) catch {};
    t.writer.end = 0;
    defer t.dropped = false;
    return t.dropped;
}

/// A writer that keeps the last of what is written to it, dropping the
/// older half of its lines whenever its buffer is full
const Tail = struct {
    writer: Writer,
    dropped: bool = false,

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Tail = @alignCast(@fieldParentPtr("writer", w));
        self.dropped = true;
        const kept = w.buffer[w.end / 2 .. w.end];
        const lines = if (std.mem.indexOfScalar(u8, kept, '\n')) |nl| kept[nl + 1 ..] else kept[kept.len..];
        @memmove(w.buffer[0..lines.len], lines);
        w.end = lines.len;
        // what cannot fit even so is dropped too
        if (data[0].len <= w.buffer.len - w.end) return 0;
        var len: usize = 0;
        for (data[0 .. data.len - 1]) |d| len += d.len;
        return len + data[data.len - 1].len * splat;
    }
};

// ---------- views ----------

/// what a node is doing, for the map: running, or waiting on a port
pub const Status = enum(u8) {
    running,
    code,
    reading,
    writing,

    fn of(status: gasim.Computer.Status) Status {
        return switch (status) {
            .running => .running,
            .code => .code,
            .reading => .reading,
            .writing => .writing,
        };
    }
};

/// Writes each node's status into `statuses`, and the ports each moved
/// words through in its last step into `transfers`: the low four bits
/// written, the high four read, by `Direction`
pub fn statuses(self: Sim, out_statuses: []u8, out_transfers: []u8) void {
    for (self.chip.nodes, out_statuses, out_transfers) |n, *s, *t| {
        s.* = @backingInt(Status.of(n.status()));
        t.* = @as(u8, @truncate(n.transfers.written.bits.mask)) | @as(u8, @truncate(n.transfers.read.bits.mask)) << 4;
    }
}

const Line = struct {
    address: u9,
    value: u18,
    code: []const u8,
    literal: bool,
    breakpoint: bool,
};

const NodeView = struct {
    number: u16,
    status: Status,
    /// what it waits on, such as `right`
    waiting_on: ?[]const u8,
    p: u10,
    slot: u3,
    carry: u1,
    extended: bool,
    /// the instruction word, unless it is fetching the next
    i: ?u18,
    i_code: ?[]const u8,
    /// where the next word comes from, while fetching it
    fetch_from: ?[]const u8,
    a: u18,
    b: u9,
    io: u18,
    time: f32,
    /// T, S and the rest from the top
    data_stack: [10]u18,
    /// R and the rest from the top
    return_stack: [9]u18,
    /// the address of the word being run, if in RAM or ROM
    here: ?u9,
    memory: [128]Line,
};

/// Writes node `i` into `out` as JSON
pub fn nodeView(self: *Sim, i: u16) error{OutOfMemory}![]const u8 {
    self.out.clearRetainingCapacity();
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const n = &self.chip.nodes[i];
    const status = n.status();
    const word = n.current();

    var view: NodeView = .{
        .number = layout.nodeNumber(i),
        .status = .of(status),
        .waiting_on = switch (status) {
            .running => null,
            inline else => |address| disassembler.ioName(address),
        },
        .p = @bitCast(n.p),
        .slot = n.slot,
        .carry = n.carry,
        .extended = n.p.extended_arithmetic,
        .i = if (n.state == .fetch) null else @bitCast(n.i),
        .i_code = if (n.state == .fetch) null else try code(a, n.i, @bitCast(word)),
        .fetch_from = if (n.state != .fetch) null else if (word.io) disassembler.ioName(@bitCast(word)) else "P",
        .a = @bitCast(n.a),
        .b = n.b,
        .io = @bitCast(n.io),
        .time = n.execution_time,
        .data_stack = undefined,
        .return_stack = undefined,
        .here = if (word.io) null else @bitCast(word),
        .memory = undefined,
    };
    var data = n.data_stack;
    view.data_stack[0] = @bitCast(data.t);
    view.data_stack[1] = @bitCast(data.s);
    for (view.data_stack[2..]) |*v| {
        data.index -%= 1;
        v.* = @bitCast(data.stack[data.index]);
    }
    var ret = n.return_stack;
    view.return_stack[0] = @bitCast(ret.t);
    for (view.return_stack[1..]) |*v| {
        ret.index -%= 1;
        v.* = @bitCast(ret.stack[ret.index]);
    }
    const ram_literals = disassembler.literals(n.mem[0..64]);
    const rom_literals = disassembler.literals(n.mem[64..128]);
    for (&view.memory, n.mem, 0..) |*line, value, m| {
        const in_rom = m >= 64;
        const address: u9 = @intCast(if (in_rom) 0x80 + m - 64 else m);
        const literal = (if (in_rom) rom_literals else ram_literals) & (@as(u64, 1) << @intCast(m % 64)) != 0;
        line.* = .{
            .address = address,
            .value = @bitCast(value),
            .code = if (literal) try literalCode(a, value) else try code(a, value, address),
            .literal = literal,
            .breakpoint = self.chip.breakpoints.contains(.init(i, address)),
        };
    }
    try self.writeJson(view);
    return self.out.written();
}

fn code(a: Allocator, word: Word, address: u9) error{OutOfMemory}![]const u8 {
    var w: Writer.Allocating = .init(a);
    disassembler.write(&w.writer, word, address) catch return error.OutOfMemory;
    return w.written();
}

fn literalCode(a: Allocator, word: Word) error{OutOfMemory}![]const u8 {
    var w: Writer.Allocating = .init(a);
    disassembler.writeLiteral(&w.writer, word) catch return error.OutOfMemory;
    return w.written();
}

const BreakpointView = struct { node: u16, address: u9 };
const WatchView = struct { node: u16, port: Direction, write: bool };

const ChipView = struct {
    rows: u8,
    columns: u8,
    steps: u64,
    rom: bool,
    console_node: u16,
    console_port: Direction,
    breakpoints: []const BreakpointView,
    watches: []const WatchView,
    history: usize,
    target: ?u16,
};

/// Writes what the chip is as a whole into `out` as JSON
pub fn chipView(self: *Sim) error{OutOfMemory}![]const u8 {
    self.out.clearRetainingCapacity();
    var breakpoints: [Chip.max_breakpoints]BreakpointView = undefined;
    for (self.chip.breakpoints.items(), 0..) |b, k| breakpoints[k] = .{ .node = layout.nodeNumber(b.index), .address = b.address };
    var watches: [Chip.max_watches]WatchView = undefined;
    for (self.chip.watches.items(), 0..) |w, k| watches[k] = .{ .node = layout.nodeNumber(w.index), .port = w.direction, .write = w.write };
    try self.writeJson(ChipView{
        .rows = layout.rows,
        .columns = layout.columns,
        .steps = self.chip.steps,
        .rom = self.roms != null,
        .console_node = console_node,
        .console_port = console_port,
        .breakpoints = breakpoints[0..self.chip.breakpoints.len],
        .watches = watches[0..self.chip.watches.len],
        .history = self.historyLen(),
        .target = self.session.target(),
    });
    return self.out.written();
}

fn writeJson(self: *Sim, value: anytype) error{OutOfMemory}!void {
    var s: std.json.Stringify = .{ .writer = &self.out.writer };
    s.write(value) catch return error.OutOfMemory;
}

// ---------- the prompt ----------

const Answer = struct {
    ok: bool,
    /// what the line wrote, such as with `.`
    output: []const u8,
    @"error": ?[]const u8 = null,
    /// the word the error was found at
    token: ?[]const u8 = null,
    stack: []const i32,
    target: ?u16,
};

/// Interprets a line at the arrayForth 3 prompt with node `target` as the
/// IDE's, and writes what came of it into `out` as JSON
pub fn interpret(self: *Sim, line: []const u8, target: u16) error{OutOfMemory}![]const u8 {
    self.remember(.line);
    self.forth_out.clearRetainingCapacity();
    self.session.setTarget(target);
    const kept = try self.sources.allocator().dupe(u8, line);
    var name: ?[]const u8 = null;
    self.session.interpret(kept) catch |err| {
        name = @errorName(err);
    };
    self.out.clearRetainingCapacity();
    try self.writeJson(Answer{
        .ok = name == null,
        .output = self.forth_out.written(),
        .@"error" = name,
        .token = if (name != null) self.diagnostic.token else null,
        .stack = self.session.stack(),
        .target = self.session.target(),
    });
    return self.out.written();
}

/// Writes the words that could complete `prefix` into `out` as a JSON
/// array, up to as many as `Completions` keeps
pub fn complete(self: *Sim, prefix: []const u8) error{OutOfMemory}![]const u8 {
    var words: Completions = .{};
    self.session.complete(prefix, &words);
    self.out.clearRetainingCapacity();
    try self.writeJson(words.found[0..words.len]);
    return self.out.written();
}

const Completions = struct {
    found: [64][]const u8 = undefined,
    len: usize = 0,

    pub fn add(self: *Completions, word: []const u8) void {
        // a word can be both an opcode and a label, or several labels
        for (self.found[0..self.len]) |other| if (std.mem.eql(u8, other, word)) return;
        if (self.len == self.found.len) return;
        self.found[self.len] = word;
        self.len += 1;
    }
};

// ---------- the console ----------

/// Gives the console input, returning how much there was room for
pub fn give(self: *Sim, bytes: []const u8) usize {
    return self.console.give(bytes);
}

/// what the console wrote since this was last called
pub fn takeConsoleOutput(self: *Sim) []const u8 {
    self.out.clearRetainingCapacity();
    self.out.writer.writeAll(self.console_out.written()) catch {};
    self.console_out.clearRetainingCapacity();
    return self.out.written();
}

// ---------- the editor ----------

/// Opens colorForth blocks, or an arrayForth 2 image, in the editor
pub fn openEditor(self: *Sim, file: []const u8) error{ LoadFailed, OutOfMemory }!void {
    const compressed = colorforth.compressedBlocks(file);
    const count = compressed orelse colorforth.blockCount(file);
    if (count > editor_capacity) return self.fail("the file has more than {d} blocks", .{editor_capacity});
    @memset(self.editor_blocks, 0);
    if (compressed != null) {
        colorforth.decompress(file, self.editor_blocks[0 .. count * colorforth.block_size]) catch |err|
            return self.fail("the image cannot be decompressed: {t}", .{err});
    } else @memcpy(self.editor_blocks[0..file.len], file);
    self.editor.open(self.editor_blocks, @max(count, 1));
    self.editor_compressed = compressed != null;
}

/// Gives the editor a key, returning what the front end must do, or the
/// error, whose message is in `out`
pub fn editorKey(self: *Sim, k: Editor.Key) Editor.Error!Editor.Action {
    return self.editor.key(k) catch |err| {
        self.out.clearRetainingCapacity();
        self.out.writer.writeAll(Editor.describe(err)) catch {};
        return err;
    };
}

/// Compiles the block being edited, and the blocks it loads, and starts the
/// chip again as it was set up, with the code compiled so far, the block's
/// replacing what it compiled before, as `L` does in the TUI. `out` says
/// what came of it; an error in the block moves the cursor to its word.
pub fn compile(self: *Sim) error{ CompileFailed, OutOfMemory }!void {
    const editor = &self.editor;
    self.out.clearRetainingCapacity();
    self.session.loadColorForth(editor.contents(), @intCast(editor.block)) catch |err| {
        const place = colorforth.place(self.diagnostic.line);
        if (place.block == editor.block and place.token <= editor.len) editor.cursor = place.token - 1;
        self.out.writer.print("{t} at {s} in block {d}", .{ err, self.diagnostic.token, place.block }) catch return error.OutOfMemory;
        return error.CompileFailed;
    };
    self.remember(.compile);
    self.chip.restore(&self.start);
    const assembled = self.session.assembled();
    var nodes: usize = 0;
    for (assembled.programs) |program| if (program.bin == null) {
        self.chip.setUp(.ofProgram(program), assembled.programs) catch continue;
        nodes += 1;
    };
    const w = &self.out.writer;
    if (assembled.first_difference) |first| {
        w.print("compiled, and started the chip again with {d} nodes' code, but {d} gray numbers differ, the first {x:0>3} where gasim is at {x:0>3}", .{
            nodes, assembled.feedback_differs, first.noted, first.found,
        }) catch return error.OutOfMemory;
    } else w.print("compiled, and started the chip again with {d} nodes' code", .{nodes}) catch return error.OutOfMemory;
}

const BlockView = struct {
    block: usize,
    /// not colorForth source, such as an arrayForth 2 kernel's
    read_only: bool,
    empty: bool,
    /// the block as text, as `gasim blocks` lists it
    text: []const u8,
};

/// Writes each block of the editor's file into `out` as JSON, up to the
/// last that holds anything, or the file's own count
pub fn blocksView(self: *Sim) error{OutOfMemory}![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const editor = &self.editor;
    const bytes = editor.contents();
    const count = bytes.len / colorforth.block_size;
    const views = try a.alloc(BlockView, count);
    var tokens: [colorforth.cells_per_block]colorforth.Token = undefined;
    for (views, 0..) |*view, b| {
        const block = bytes[b * colorforth.block_size ..][0..colorforth.block_size];
        view.* = .{ .block = b, .read_only = true, .empty = false, .text = "" };
        const decoded = colorforth.decode(block, &tokens) catch continue;
        var encoded: [colorforth.block_size]u8 = undefined;
        colorforth.encode(decoded, &encoded) catch continue;
        if (!std.mem.eql(u8, block, &encoded)) continue;
        var text: Writer.Allocating = .init(a);
        colorforth.writeText(decoded, &text.writer) catch return error.OutOfMemory;
        view.* = .{ .block = b, .read_only = false, .empty = decoded.len == 0, .text = text.written() };
    }
    self.out.clearRetainingCapacity();
    try self.writeJson(views);
    return self.out.written();
}

const TokenView = struct {
    text: []const u8,
    color: colorforth.Color,
    /// a variable's value
    value: ?i32,
    /// the line it is on, from 0, as colorForth shows a block
    line: usize,
};

const EditorView = struct {
    block: usize,
    blocks: usize,
    capacity: usize,
    mode: Editor.Mode,
    cursor: usize,
    cells: usize,
    prefix: ?usize,
    read_only: bool,
    unsaved: bool,
    compressed: bool,
    tokens: []const TokenView,
};

/// Writes the block being edited into `out` as JSON
pub fn editorView(self: *Sim) error{OutOfMemory}![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const editor = &self.editor;
    const tokens = try a.alloc(TokenView, editor.len);
    var lines: colorforth.Lines = .{};
    for (editor.tokens[0..editor.len], tokens, 0..) |*token, *view, i| {
        const typing = editor.mode == .insert and i == editor.cursor;
        view.* = .{
            .text = if (typing) token.text() else try std.fmt.allocPrint(a, "{f}", .{token.*}),
            .color = token.tag.color(),
            .value = if (token.tag == .variable) token.value else null,
            .line = lines.of(token.*),
        };
    }
    self.out.clearRetainingCapacity();
    try self.writeJson(EditorView{
        .block = editor.block,
        .blocks = editor.count,
        .capacity = editor.capacity(),
        .mode = editor.mode,
        .cursor = editor.cursor,
        .cells = editor.cells(),
        .prefix = editor.prefix,
        .read_only = editor.read_only,
        .unsaved = editor.unsaved(),
        .compressed = self.editor_compressed,
        .tokens = tokens,
    });
    return self.out.written();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const gasim = @import("gasim");
const arrayforth = gasim.arrayforth;
const assembler = gasim.assembler;
const boot = gasim.boot;
const Chip = gasim.Chip;
const colorforth = gasim.colorforth;
const Console = gasim.Console;
const Direction = gasim.Direction;
const disassembler = gasim.disassembler;
const Editor = gasim.Editor;
const ga144 = gasim.ga144;
const rom = gasim.rom;
const Word = gasim.Word;
const Diagnostic = arrayforth.Diagnostic;
const Program = arrayforth.Program;
const Session = arrayforth.Session;

fn testSim() !*Sim {
    const sim = try std.testing.allocator.create(Sim);
    errdefer std.testing.allocator.destroy(sim);
    try sim.init(std.testing.allocator);
    return sim;
}

fn freeSim(sim: *Sim) void {
    sim.deinit();
    std.testing.allocator.destroy(sim);
}

const hello =
    \\: main
    \\    up b!
    \\    'message a!
    \\    @+ for @+ !b unext
    \\    left b! @b
    \\
    \\: message 4 , "Hello"
;

test "running a program to the end of its output" {
    const sim = try testSim();
    defer freeSim(sim);
    try sim.load(.ga, hello, &.{});
    try std.testing.expectEqual(.budget, try sim.run(1));
    try std.testing.expectEqual(.settled, try sim.run(10_000));
    try std.testing.expectEqualStrings("Hello", sim.takeConsoleOutput());
    try std.testing.expectEqualStrings("", sim.takeConsoleOutput());

    // and again from the start
    sim.reset();
    try std.testing.expectEqual(.settled, try sim.run(10_000));
    try std.testing.expectEqualStrings("Hello", sim.takeConsoleOutput());
}

test "input given to the console" {
    const sim = try testSim();
    defer freeSim(sim);
    try sim.load(.ga, ": main up b! begin @b !b again", &.{});
    try std.testing.expectEqual(.input, try sim.run(10_000));
    try std.testing.expectEqual(2, sim.give("hi"));
    try std.testing.expectEqual(.input, try sim.run(10_000));
    try std.testing.expectEqualStrings("hi", sim.takeConsoleOutput());

    // at the end of input the node waits on, with nothing to come
    sim.console.end();
    try std.testing.expectEqual(.input, try sim.run(10_000));
    try std.testing.expectEqual(0, sim.give("x"));

    // until it starts again, forgetting input not read
    sim.reset();
    try std.testing.expectEqual(1, sim.give("y"));
    sim.reset();
    try std.testing.expectEqual(.input, try sim.run(10_000));
    try std.testing.expectEqualStrings("", sim.takeConsoleOutput());
}

test "errors say where they are" {
    const sim = try testSim();
    defer freeSim(sim);
    try std.testing.expectError(error.LoadFailed, sim.load(.ga, ": main\n  frob", &.{}));
    try std.testing.expectEqualStrings("line 2: UndefinedLabel at 'frob'", sim.out.written());
    try std.testing.expectError(error.LoadFailed, sim.load(.blk, "", &.{3}));
    try std.testing.expectEqualStrings("the file has fewer blocks than are loaded", sim.out.written());
}

test "a file that fails to load leaves nothing of the last to reset to" {
    const sim = try testSim();
    defer freeSim(sim);
    try sim.load(.ga, hello, &.{});
    try std.testing.expectError(error.LoadFailed, sim.load(.ga, ": main\n  frob", &.{}));
    sim.reset();
    try std.testing.expectEqual(.settled, try sim.run(10_000));
    try std.testing.expectEqualStrings("", sim.takeConsoleOutput());
}

test "stepping, breakpoints, and going back" {
    const sim = try testSim();
    defer freeSim(sim);
    try sim.load(.ga, hello, &.{});
    try std.testing.expect(!sim.back());

    try std.testing.expectEqual(0, try sim.stepNext());
    try std.testing.expect(try sim.stepRound());
    _ = try sim.stepNode(0);
    try std.testing.expectEqual(3, sim.historyLen());
    const steps = sim.chip.steps;
    try std.testing.expect(sim.back());
    try std.testing.expect(sim.chip.steps < steps);

    // a breakpoint at the loop, reached by running
    sim.reset();
    try std.testing.expect(try sim.toggleBreakpoint(0, 4));
    try std.testing.expectEqual(.hit, try sim.run(10_000));
    try std.testing.expectEqualStrings("node 000 reached 004", sim.out.written());
    try std.testing.expect(!try sim.toggleBreakpoint(0, 4));

    // and a watch on the console's port
    try std.testing.expect(try sim.toggleWatch(0, .up, true));
    try std.testing.expectEqual(.hit, try sim.run(10_000));
    try std.testing.expectEqualStrings("node 000 wrote 00048 to up", sim.out.written());
}

test "views as JSON" {
    const sim = try testSim();
    defer freeSim(sim);
    try sim.load(.ga, hello, &.{});
    _ = try sim.run(10_000);

    var statuses_: [layout.count()]u8 = undefined;
    var transfers: [layout.count()]u8 = undefined;
    sim.statuses(&statuses_, &transfers);
    try std.testing.expectEqual(@backingInt(Status.reading), statuses_[0]);
    try std.testing.expectEqual(@backingInt(Status.code), statuses_[1]);

    const node = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, try sim.nodeView(0), .{});
    defer node.deinit();
    try std.testing.expectEqualStrings("reading", node.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("left", node.value.object.get("waiting_on").?.string);
    try std.testing.expectEqual(128, node.value.object.get("memory").?.array.items.len);

    const chip = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, try sim.chipView(), .{});
    defer chip.deinit();
    try std.testing.expectEqual(18, chip.value.object.get("columns").?.integer);
    try std.testing.expectEqual(false, chip.value.object.get("rom").?.bool);
}

test "the prompt" {
    const sim = try testSim();
    defer freeSim(sim);
    const answer = try std.json.parseFromSlice(Answer, std.testing.allocator, try sim.interpret("1 2 + 5", 0), .{});
    defer answer.deinit();
    try std.testing.expect(answer.value.ok);
    try std.testing.expectEqualSlices(i32, &.{ 3, 5 }, answer.value.stack);

    const failed = try std.json.parseFromSlice(Answer, std.testing.allocator, try sim.interpret("frob", 0), .{});
    defer failed.deinit();
    try std.testing.expect(!failed.value.ok);
    try std.testing.expectEqualStrings("frob", failed.value.token.?);

    const words = try std.json.parseFromSlice([]const []const u8, std.testing.allocator, try sim.complete("unex"), .{});
    defer words.deinit();
    try std.testing.expectEqualStrings("unext", words.value[0]);
}

test "editing colorForth, and loading what was typed" {
    const sim = try testSim();
    defer freeSim(sim);
    const ctrl = struct {
        fn key(c: u8) Editor.Key {
            return .{ .code = .{ .char = c }, .ctrl = true };
        }
    };
    _ = try sim.editorKey(.char('i'));
    _ = try sim.editorKey(ctrl.key('y'));
    for ("0 node 0 org") |c| _ = try sim.editorKey(.char(c));
    _ = try sim.editorKey(.{ .code = .enter });
    for ("main up b! 72 !b left b! @b") |c| _ = try sim.editorKey(.char(c));
    _ = try sim.editorKey(.{ .code = .escape });

    const view = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, try sim.editorView(), .{});
    defer view.deinit();
    const tokens = view.value.object.get("tokens").?.array.items;
    try std.testing.expectEqualStrings("node", tokens[1].object.get("text").?.string);
    try std.testing.expectEqualStrings("yellow", tokens[1].object.get("color").?.string);
    try std.testing.expectEqualStrings("red", tokens[5].object.get("color").?.string);
    try std.testing.expectEqual(1, tokens[5].object.get("line").?.integer);
    try std.testing.expect(view.value.object.get("unsaved").?.bool);

    const file = try std.testing.allocator.dupe(u8, sim.editor.contents());
    defer std.testing.allocator.free(file);
    try sim.load(.cf, file, &.{0});
    try std.testing.expectEqual(.settled, try sim.run(10_000));
    try std.testing.expectEqualStrings("H", sim.takeConsoleOutput());
}

test "a file that is no ROM is refused" {
    const sim = try testSim();
    defer freeSim(sim);
    try std.testing.expectError(error.InvalidRom, sim.setRom("not a rom\n"));
    try std.testing.expectEqual(null, sim.roms);
}

test "compiling the block being edited starts the chip again with its code" {
    const sim = try testSim();
    defer freeSim(sim);
    try sim.load(.ga, hello, &.{});
    _ = try sim.run(10_000);
    try std.testing.expectEqualStrings("Hello", sim.takeConsoleOutput());

    const ctrl_y: Editor.Key = .{ .code = .{ .char = 'y' }, .ctrl = true };
    _ = try sim.editorKey(.char('i'));
    _ = try sim.editorKey(ctrl_y);
    for ("1 node 0 org") |c| _ = try sim.editorKey(.char(c));
    _ = try sim.editorKey(.{ .code = .enter });
    for ("main up b! 72 !b left b! @b") |c| _ = try sim.editorKey(.char(c));
    _ = try sim.editorKey(.{ .code = .escape });
    try sim.compile();
    try std.testing.expectEqualStrings("compiled, and started the chip again with 1 nodes' code", sim.out.written());

    // node 000 is as it started, and node 001 has the block's code
    try std.testing.expect(sim.chip.nodes[1].mem[0] != 0);
    try std.testing.expectEqual(.settled, try sim.run(10_000));
    try std.testing.expectEqualStrings("Hello", sim.takeConsoleOutput());

    // an error moves the cursor to the word
    _ = try sim.editorKey(.char('a'));
    for (" frob") |c| _ = try sim.editorKey(.char(c));
    _ = try sim.editorKey(.{ .code = .escape });
    try std.testing.expectError(error.CompileFailed, sim.compile());
    try std.testing.expectEqualStrings("frob", sim.editor.current().?.text());
}

test "blocks as text" {
    const sim = try testSim();
    defer freeSim(sim);
    _ = try sim.editorKey(.char('i'));
    for ("one two") |c| _ = try sim.editorKey(.char(c));
    _ = try sim.editorKey(.{ .code = .escape });
    _ = try sim.editorKey(.char(']'));

    const views = try std.json.parseFromSlice([]const BlockView, std.testing.allocator, try sim.blocksView(), .{});
    defer views.deinit();
    try std.testing.expectEqual(1, views.value.len);
    try std.testing.expectEqualStrings(":one ]two\n", views.value[0].text);
    try std.testing.expect(!views.value[0].read_only);
}

test "tracing" {
    const sim = try testSim();
    defer freeSim(sim);
    try sim.setTracing(true);
    try sim.load(.ga, hello, &.{});
    _ = try sim.stepNext();
    try std.testing.expect(!sim.takeTrace());
    try std.testing.expectStringStartsWith(sim.out.written(), "000 000 ");
    _ = sim.takeTrace();
    try std.testing.expectEqualStrings("", sim.out.written());

    try sim.setTracing(false);
    _ = try sim.stepNext();
    try std.testing.expect(!sim.takeTrace());
    try std.testing.expectEqualStrings("", sim.out.written());
}

test "a trace bigger than its buffer keeps whole lines" {
    var buffer: [64]u8 = undefined;
    var tail: Tail = .{ .writer = .{ .vtable = &.{ .drain = Tail.drain }, .buffer = &buffer } };
    for (0..20) |k| try tail.writer.print("line {d:0>3}\n", .{k});
    try std.testing.expect(tail.dropped);
    const kept = tail.writer.buffered();
    try std.testing.expectStringStartsWith(kept, "line ");
    try std.testing.expectStringEndsWith(kept, "line 019\n");
}

test "the history, and going back to a step in it" {
    const sim = try testSim();
    defer freeSim(sim);
    try sim.load(.ga, hello, &.{});
    _ = try sim.stepNext();
    _ = try sim.stepRound();
    _ = try sim.stepNode(0);
    const moments = try std.json.parseFromSlice([]const Moment, std.testing.allocator, try sim.historyView(), .{});
    defer moments.deinit();
    try std.testing.expectEqual(3, moments.value.len);
    try std.testing.expectEqual(.step, moments.value[0].cause);
    try std.testing.expectEqual(0, moments.value[0].steps);
    try std.testing.expectEqual(.node, moments.value[2].cause);

    try std.testing.expect(sim.backTo(1));
    try std.testing.expectEqual(1, sim.historyLen());
    try std.testing.expectEqual(moments.value[1].steps, sim.chip.steps);
    try std.testing.expect(!sim.backTo(1));
}

test "breakpoints stay as a file is loaded again" {
    const sim = try testSim();
    defer freeSim(sim);
    try sim.load(.ga, hello, &.{});
    _ = try sim.toggleBreakpoint(0, 4);
    try sim.load(.ga, hello, &.{});
    try std.testing.expectEqual(.hit, try sim.run(10_000));
    sim.clearBreakpoints();
    try std.testing.expectEqual(.settled, try sim.run(10_000));
}
