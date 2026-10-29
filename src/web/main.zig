//! The web build: one `Sim`, compiled to wasm32-freestanding and driven from
//! JavaScript (web/engine.js). Bytes cross as a pointer and length into this
//! module's memory. Text and JSON come back in one buffer, at `outPtr` for
//! the length a call returns. No libc, and no imports besides jsLog.
const std = @import("std");
const gasim = @import("gasim");
const Sim = @import("Sim.zig");
const Editor = gasim.Editor;

const gpa = std.heap.wasm_allocator;

/// console.error, for panics
extern "env" fn jsLog(ptr: [*]const u8, len: usize) void;

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        jsLog(msg.ptr, msg.len);
        @trap();
    }
}.f);

var sim: *Sim = undefined;
var statuses: [2 * Sim.layout.count()]u8 = undefined;

// ---------- memory ----------

export fn alloc(n: usize) ?[*]u8 {
    return (gpa.alloc(u8, n) catch return null).ptr;
}

export fn free(p: [*]u8, n: usize) void {
    gpa.free(p[0..n]);
}

export fn outPtr() [*]const u8 {
    return sim.out.written().ptr;
}

export fn outLen() usize {
    return sim.out.written().len;
}

fn bytes(p: [*]const u8, n: usize) []const u8 {
    return if (n == 0) "" else p[0..n];
}

/// the length of what was written to `out`, or 0 out of memory
fn written(result: error{OutOfMemory}![]const u8) usize {
    return (result catch return 0).len;
}

// ---------- the chip ----------

export fn init() bool {
    sim = gpa.create(Sim) catch return false;
    sim.init(gpa) catch return false;
    return true;
}

/// a ROM dump, or arrayForth 3's pFDISK.blk to assemble it from
export fn setRom(p: [*]const u8, n: usize) bool {
    sim.setRom(bytes(p, n)) catch return false;
    return true;
}

/// Assembles a file of a `Sim.Kind` and sets up the chip with it, loading
/// the blocks at `loads`. On false, `out` says why.
export fn load(kind: u8, p: [*]const u8, n: usize, loads: [*]const u32, loads_len: usize) bool {
    const k = std.enums.fromInt(Sim.Kind, kind) orelse return false;
    sim.load(k, bytes(p, n), if (loads_len == 0) &.{} else loads[0..loads_len]) catch return false;
    return true;
}

/// Runs for up to `budget` rounds, returning a `Sim.Stop`
export fn run(budget: usize) u8 {
    return @backingInt(sim.run(budget) catch return 0xff);
}

/// the index of the node stepped, or -1 when every node is waiting
export fn stepNext() i32 {
    const i = sim.stepNext() catch return -1;
    return if (i) |index| index else -1;
}

export fn stepRound() bool {
    return sim.stepRound() catch false;
}

export fn stepNode(i: u16) bool {
    return sim.stepNode(i) catch false;
}

export fn reset() void {
    sim.reset();
}

/// saves the chip before a run, a `Sim.Cause`
export fn remember(cause: u8) void {
    sim.remember(std.enums.fromInt(Sim.Cause, cause) orelse .run);
}

export fn back() bool {
    return sim.back();
}

export fn backTo(n: usize) bool {
    return sim.backTo(n);
}

export fn historyView() usize {
    return written(sim.historyView());
}

/// 1 if the breakpoint is set now, 0 if not, -1 if there are too many
export fn toggleBreakpoint(i: u16, address: u16) i32 {
    return @intFromBool(sim.toggleBreakpoint(i, @truncate(address)) catch return -1);
}

/// 1 if the watch is set now, 0 if not, -1 if there are too many
export fn toggleWatch(i: u16, direction: u8, write: bool) i32 {
    const d = std.enums.fromInt(gasim.Direction, direction) orelse return -1;
    return @intFromBool(sim.toggleWatch(i, d, write) catch return -1);
}

export fn clearBreakpoints() void {
    sim.clearBreakpoints();
}

// ---------- the trace ----------

export fn setTracing(on: bool) bool {
    sim.setTracing(on) catch return false;
    return true;
}

/// What was traced since last called, in `out`. Returns its length, with
/// the top bit set if older lines were dropped.
export fn takeTrace() u32 {
    const dropped = sim.takeTrace();
    return @as(u32, @intCast(sim.out.written().len)) | @as(u32, @intFromBool(dropped)) << 31;
}

/// each node's `Sim.Status`, then the ports it moved words through, as
/// `Sim.statuses` writes them
export fn nodeStatuses() [*]const u8 {
    const count = Sim.layout.count();
    sim.statuses(statuses[0..count], statuses[count..]);
    return &statuses;
}

export fn nodeView(i: u16) usize {
    return written(sim.nodeView(i));
}

export fn chipView() usize {
    return written(sim.chipView());
}

// ---------- the prompt ----------

export fn interpret(p: [*]const u8, n: usize, target: u16) usize {
    return written(sim.interpret(bytes(p, n), target));
}

export fn complete(p: [*]const u8, n: usize) usize {
    return written(sim.complete(bytes(p, n)));
}

// ---------- the console ----------

/// how much of the input there was room for
export fn give(p: [*]const u8, n: usize) usize {
    return sim.give(bytes(p, n));
}

export fn endInput() void {
    sim.console.end();
}

export fn wantsInput() bool {
    return sim.console.wantsInput();
}

export fn consoleOutput() usize {
    return sim.takeConsoleOutput().len;
}

// ---------- the editor ----------

export fn editorOpen(p: [*]const u8, n: usize) bool {
    sim.openEditor(bytes(p, n)) catch return false;
    return true;
}

/// Gives the editor a key: `code` a tag of `Editor.Key.Code`, with `char`
/// for a character. Returns an `Editor.Action`, or -1 for an error, which
/// `out` describes.
export fn editorKey(code: u8, char: u8, ctrl: bool) i32 {
    const Tag = std.meta.Tag(Editor.Key.Code);
    const tag = std.enums.fromInt(Tag, code) orelse return -1;
    const k: Editor.Key = .{
        .code = switch (tag) {
            .char => .{ .char = char },
            inline else => |t| t,
        },
        .ctrl = ctrl,
    };
    return @backingInt(sim.editorKey(k) catch return -1);
}

export fn editorView() usize {
    return written(sim.editorView());
}

export fn editorMoveTo(i: usize) void {
    sim.editor.moveTo(i) catch {};
}

export fn editorGoTo(block: usize) bool {
    sim.editor.goTo(block) catch return false;
    return true;
}

/// the editor's file to save, at `editorContentsPtr`
export fn editorContents() usize {
    return sim.editor.contents().len;
}

export fn editorContentsPtr() [*]const u8 {
    return sim.editor.contents().ptr;
}

export fn editorSaved() void {
    sim.editor.saved();
}

/// notes that the blocks opened were not saved, as when they are kept in
/// the browser between visits
export fn editorUnsaved() void {
    sim.editor.modified = true;
}

/// Compiles the block being edited and starts the chip again with it, as
/// `L` does. `out` says what came of it.
export fn editorCompile() bool {
    sim.compile() catch return false;
    return true;
}

/// each block of the editor's file, as text
export fn editorBlocks() usize {
    return written(sim.blocksView());
}
