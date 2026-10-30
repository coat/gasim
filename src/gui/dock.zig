//! The panels under the map, after the web version's dock: the arrayForth 3
//! prompt, acting on the selected node, the console, its output and input,
//! and the trace, breakpoints and history, which `debug.zig` draws.

pub const Tab = enum { forth, console, trace, breakpoints, history };
pub var tab: Tab = .forth;

/// a line at the prompt and what came of it, owned
const Entry = struct {
    target: u16,
    line: []u8,
    output: []u8,
    ok: bool,
    /// the stack after an ok, or the error, as words, and where
    result: []u8,

    fn deinit(self: Entry, allocator: Allocator) void {
        allocator.free(self.line);
        allocator.free(self.output);
        allocator.free(self.result);
    }
};

/// as many as the web version keeps
const entries_capacity = 500;
const history_capacity = 200;
const console_capacity = 64 * 1024;

var gpa: Allocator = undefined;
var entries: std.ArrayList(Entry) = .empty;
/// lines entered, the oldest first, without repeats in a row
var history: std.ArrayList([]u8) = .empty;
/// how far back in the history the line typed is, 0 for a new one
var back: usize = 0;
var line: std.ArrayList(u8) = .empty;
/// the words Tab found, and where in the line the word they complete starts
const Choices = struct { from: usize, words: Sim.Completions, none: bool };
var choices: ?Choices = null;

/// what the console wrote, its last `console_capacity` bytes
var console: std.ArrayList(u8) = .empty;
var unseen = false;
var input: std.ArrayList(u8) = .empty;
/// input the console had no room for yet
var pending: std.ArrayList(u8) = .empty;
var ended = false;
/// send keys as they are typed, rather than a line at a time
var raw = false;

/// the prompt's and the console's text entries, as of this frame
var forth_id: ?dvui.Id = null;
var console_id: ?dvui.Id = null;

pub fn start(allocator: Allocator) void {
    gpa = allocator;
    tab = .forth;
    entries = .empty;
    history = .empty;
    back = 0;
    line = .empty;
    choices = null;
    console = .empty;
    unseen = false;
    input = .empty;
    pending = .empty;
    ended = false;
    raw = false;
    focusing = null;
    debug.start(gpa);
    pending_recall = null;
    completed = .empty;
    forth_follow = .{};
    console_follow = .{};
}

pub fn stop() void {
    debug.stop();
    clearEntries();
    entries.deinit(gpa);
    for (history.items) |h| gpa.free(h);
    history.deinit(gpa);
    line.deinit(gpa);
    console.deinit(gpa);
    input.deinit(gpa);
    pending.deinit(gpa);
    completed.deinit(gpa);
}

/// Forgets the console's output and input, as the chip starts again
pub fn forgetInput() void {
    console.clearRetainingCapacity();
    unseen = false;
    pending.clearRetainingCapacity();
    ended = false;
}

/// whether a key is being typed into the prompt or the console, rather
/// than for the app
pub fn typing() bool {
    const focused = dvui.focusedWidgetId() orelse return false;
    return focused == forth_id or focused == console_id or focused == debug.watch_id;
}

/// the entry to give focus to next frame, as with f and c
var focusing: ?Tab = null;

/// Shows the prompt or the console, typing into it
pub fn focus(which: Tab) void {
    tab = which;
    if (which == .console) unseen = false;
    focusing = which;
}

/// Keeps a line typed, as at the prompt, such as from the last run
pub fn remember(text: []const u8) void {
    if (history.items.len == history_capacity) gpa.free(history.orderedRemove(0));
    history.append(gpa, gpa.dupe(u8, text) catch return) catch {};
}

/// the lines typed at the prompt, the oldest first
pub fn lines(_: Allocator) Allocator.Error![]const []const u8 {
    return history.items;
}

/// Gives the console what is pending, and takes what it and the trace
/// wrote. Before the chip runs, so input typed is there for it.
pub fn service() Allocator.Error!void {
    try debug.service();
    givePending();
    const out = ui.sim.takeConsoleOutput();
    if (out.len == 0) return;
    try console.appendSlice(gpa, out);
    if (console.items.len > console_capacity) {
        const drop = console.items.len - console_capacity;
        std.mem.copyForwards(u8, console.items, console.items[drop..]);
        console.shrinkRetainingCapacity(console_capacity);
    }
    if (tab != .console) unseen = true;
}

pub fn draw() void {
    var panel = dvui.box(@src(), .{}, .{ .expand = .both });
    defer panel.deinit();
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 } });
        defer head.deinit();
        for (std.enums.values(Tab)) |which| tabButton(which);
        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .gravity_y = 0.5 });
        defer actions.deinit();
        switch (tab) {
            .forth => if (button(@src(), "Clear", entries.items.len > 0)) clearEntries(),
            .console => {
                dvui.label(@src(), "node {d:0>3}, {t} port", .{ Sim.console_node, Sim.console_port }, .{ .color_text = .{ .color = muted() }, .gravity_y = 0.5 });
                if (button(@src(), "Clear", console.items.len > 0)) console.clearRetainingCapacity();
            },
            .trace => debug.traceHead(),
            .breakpoints => debug.breakpointsHead(),
            .history => debug.historyHead(),
        }
    }
    // only the entries drawn this frame can have focus
    forth_id = null;
    console_id = null;
    debug.watch_id = null;
    switch (tab) {
        .forth => forth(),
        .console => consolePanel(),
        .trace => debug.trace(),
        .breakpoints => debug.breakpoints(),
        .history => debug.history(),
    }
}

fn tabButton(which: Tab) void {
    const label, const tag = switch (which) {
        .forth => .{ "Forth", "tab-forth" },
        .console => .{ if (unseen) "Console \u{2022}" else "Console", "tab-console" },
        .trace => .{ "Trace", "tab-trace" },
        .breakpoints => .{ "Breakpoints", "tab-breakpoints" },
        .history => .{ "History", "tab-history" },
    };
    const opts: dvui.Options = .{ .id_extra = @backingInt(which), .style = if (tab == which) .highlight else .control, .tag = tag };
    if (dvui.button(@src(), label, .{}, opts)) {
        tab = which;
        if (which == .console) unseen = false;
    }
}

/// a button that does nothing, and looks it, unless `enabled`
pub fn button(src: std.builtin.SourceLocation, label: []const u8, enabled: bool) bool {
    return dvui.button(src, label, .{ .grayed = !enabled }, .{}) and enabled;
}

pub fn muted() dvui.Color {
    return dvui.themeGet().color(.content, .text).opacity(0.6);
}

// ---------- the prompt ----------

fn forth() void {
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .content, .background = true, .max_size_content = ui.small });
        defer scroll.deinit();
        follow(scroll.si, &forth_follow);
        if (entries.items.len == 0) {
            var hint = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .padding = .all(6) });
            defer hint.deinit();
            hint.addText("Type arrayForth 3 below. The selected node is the target of words such as UPD, R@ and CALL.", .{ .color_text = .{ .color = muted() } });
        }
        for (entries.items, 0..) |e, k| entry(e, k);
    }
    if (choices) |c| choiceRow(c);
    prompt();
}

fn entry(e: Entry, k: usize) void {
    var column = dvui.box(@src(), .{}, .{ .id_extra = k, .expand = .horizontal, .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 } });
    defer column.deinit();
    const mono: dvui.Font = .theme(.mono);
    {
        // the line, to type again
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (dvui.clicked(row.data(), .{})) recall(e.line);
        dvui.label(@src(), "{d:0>3}>", .{e.target}, .{ .font = mono, .color_text = .{ .color = muted() }, .padding = .{ .w = 6 } });
        dvui.labelNoFmt(@src(), e.line, .{}, .{ .font = mono, .padding = .all(0) });
    }
    if (e.output.len > 0) {
        var text = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = mono, .background = false, .padding = .all(0) });
        text.addText(e.output, .{});
        text.deinit();
    }
    const colors: ui.Palette = .get();
    dvui.labelNoFmt(@src(), e.result, .{}, .{
        .font = mono,
        .color_text = .{ .color = if (e.ok) colors.moved else colors.breakpoint },
        .padding = .all(0),
    });
}

/// the words Tab found, to choose from
fn choiceRow(c: Choices) void {
    var row = dvui.flexbox(@src(), .{}, .{ .expand = .horizontal, .padding = .all(4) });
    defer row.deinit();
    if (c.none) {
        dvui.labelNoFmt(@src(), "No word starts with that", .{}, .{ .color_text = .{ .color = muted() } });
        return;
    }
    for (c.words.words(), 0..) |word, k| {
        if (dvui.button(@src(), word, .{}, .{ .id_extra = k, .font = .theme(.mono) })) choose(c.from, word);
    }
}

fn prompt() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(4) });
    defer row.deinit();
    const layout = ui.sim.chip.layout;
    dvui.label(@src(), "{d:0>3}>", .{layout.nodeNumber(ui.selected)}, .{ .font = .theme(.mono), .gravity_y = 0.5 });

    // Tab completes, and up and down go through the history, before the
    // entry sees them
    const src = @src();
    const id = dvui.parentGet().extendId(src, 0);
    forth_id = id;
    var recalled: ?[]const u8 = null;
    if (dvui.focusedWidgetId() == id) for (dvui.events()) |*e| {
        if (e.handled) continue;
        const k = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        if (k.action == .up) continue;
        switch (k.code) {
            .tab => if (k.mod == .none) complete() else continue,
            .up => if (back < history.items.len) {
                back += 1;
                recalled = history.items[history.items.len - back];
            },
            .down => if (back > 0) {
                back -= 1;
                recalled = if (back == 0) "" else history.items[history.items.len - back];
            },
            .escape => if (choices != null) {
                choices = null;
            } else dvui.focusWidget(null, null, null),
            else => continue,
        }
        e.handle(@src(), dvui.currentWindow().data());
    };

    if (focusing == .forth) {
        dvui.focusWidget(id, null, null);
        focusing = null;
    }
    var te = dvui.textEntry(src, .{ .text = .{ .array_list = .{ .backing = &line, .allocator = gpa } } }, .{ .expand = .horizontal, .font = .theme(.mono), .tag = "forth-input" });
    if (recalled) |r| te.textSet(r, false);
    if (pending_recall) |r| {
        te.textSet(r, false);
        pending_recall = null;
        dvui.focusWidget(id, null, null);
    }
    if (te.text_changed and recalled == null) choices = null;
    const entered = te.enter_pressed;
    te.deinit();

    if (dvui.button(@src(), "Complete", .{}, .{})) complete();
    if (dvui.button(@src(), "Enter", .{}, .{ .style = .highlight }) or entered) enter();
}

/// a line clicked in the transcript, for the entry to show next frame
var pending_recall: ?[]const u8 = null;

fn recall(text: []const u8) void {
    pending_recall = text;
    choices = null;
}

fn enter() void {
    const text = gpa.dupe(u8, line.items) catch return ui.say("Out of memory", .{});
    defer gpa.free(text);
    line.clearRetainingCapacity();
    back = 0;
    choices = null;
    interpret(text) catch ui.say("Out of memory", .{});
}

/// Interprets a line with the selected node as the target, keeping the
/// line and what came of it, and selecting the node the line made the
/// target
pub fn interpret(text: []const u8) Allocator.Error!void {
    const layout = ui.sim.chip.layout;
    const target = layout.nodeNumber(ui.selected);
    const answer = try ui.sim.answer(text, target);

    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    const w = &result.writer;
    if (answer.ok) {
        w.writeAll("ok") catch return error.OutOfMemory;
        for (answer.stack) |v| w.print(" {d}", .{v}) catch return error.OutOfMemory;
    } else {
        words(w, answer.@"error".?) catch return error.OutOfMemory;
        if (answer.token) |token| w.print(" at {s}", .{token}) catch return error.OutOfMemory;
    }
    const e: Entry = .{
        .target = target,
        .line = try gpa.dupe(u8, text),
        .output = try gpa.dupe(u8, answer.output),
        .ok = answer.ok,
        .result = try result.toOwnedSlice(),
    };
    if (entries.items.len == entries_capacity) entries.orderedRemove(0).deinit(gpa);
    try entries.append(gpa, e);

    if (std.mem.trim(u8, text, " \t").len > 0 and (history.items.len == 0 or !std.mem.eql(u8, history.items[history.items.len - 1], text))) {
        if (history.items.len == history_capacity) gpa.free(history.orderedRemove(0));
        try history.append(gpa, try gpa.dupe(u8, text));
    }
    if (answer.target) |t| if (t != target) if (layout.index(t)) |i| {
        ui.selected = i;
    };
}

/// an error's name as words, such as `undefined label` for UndefinedLabel
fn words(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    for (name, 0..) |c, k| {
        if (std.ascii.isUpper(c)) {
            if (k > 0 and std.ascii.isLower(name[k - 1])) try w.writeByte(' ');
            try w.writeByte(std.ascii.toLower(c));
        } else try w.writeByte(c);
    }
}

/// Completes the last word of the line: with the only word that could, or
/// as much as they all share, showing them to choose from
fn complete() void {
    const text = line.items;
    var from = text.len;
    while (from > 0 and !std.ascii.isWhitespace(text[from - 1])) from -= 1;
    const partial = text[from..];
    if (partial.len == 0) return;
    const found = ui.sim.completions(partial);
    const all = found.words();
    if (all.len == 0) {
        choices = .{ .from = from, .words = found, .none = true };
        return;
    }
    if (all.len == 1) return choose(from, all[0]);
    var common = all[0];
    for (all) |word| {
        while (!std.mem.startsWith(u8, word, common)) common = common[0 .. common.len - 1];
    }
    if (common.len > partial.len) setLine(from, common, false);
    choices = .{ .from = from, .words = found, .none = false };
}

fn choose(from: usize, word: []const u8) void {
    setLine(from, word, true);
    choices = null;
}

/// Replaces the line from `from` with `word`, and a space after it
fn setLine(from: usize, word: []const u8, space: bool) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    text.appendSlice(gpa, line.items[0..from]) catch return;
    text.appendSlice(gpa, word) catch return;
    if (space) text.append(gpa, ' ') catch return;
    completed.clearRetainingCapacity();
    completed.appendSlice(gpa, text.items) catch return;
    pending_recall = completed.items;
}

/// the line as completed, for the entry to show next frame
var completed: std.ArrayList(u8) = .empty;

fn clearEntries() void {
    for (entries.items) |e| e.deinit(gpa);
    entries.clearRetainingCapacity();
}

// ---------- the console ----------

fn consolePanel() void {
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .content, .background = true, .max_size_content = ui.small });
        defer scroll.deinit();
        follow(scroll.si, &console_follow);
        var text = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.mono), .background = false });
        defer text.deinit();
        if (console.items.len == 0) text.addText("Nothing yet", .{ .color_text = .{ .color = muted() } }) else text.addText(console.items, .{});
    }
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(4) });
    defer row.deinit();

    const src = @src();
    const id = dvui.parentGet().extendId(src, 0);
    console_id = id;
    if (focusing == .console) {
        dvui.focusWidget(id, null, null);
        focusing = null;
    }
    // keys as they are typed: enter as a newline, before the entry takes
    // it, and esc stops typing
    if (dvui.focusedWidgetId() == id) for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .key => |k| if (k.action != .up and k.code == .escape) {
                e.handle(@src(), dvui.currentWindow().data());
                dvui.focusWidget(null, null, null);
            } else if (raw and k.action != .up and k.code == .enter) {
                e.handle(@src(), dvui.currentWindow().data());
                sendInput("\n");
            },
            else => {},
        }
    };
    var te = dvui.textEntry(src, .{
        .text = .{ .array_list = .{ .backing = &input, .allocator = gpa } },
        .placeholder = if (ended) "The input has ended" else if (raw) "Keys go to the node as they are typed" else "A line of input",
    }, .{ .expand = .horizontal, .font = .theme(.mono), .tag = "console-input" });
    const entered = te.enter_pressed;
    // what was typed goes straight to the node
    if (raw and input.items.len > 0) {
        sendInput(input.items);
        te.textSet("", false);
    }
    te.deinit();

    _ = dvui.checkbox(@src(), &raw, "Keys", .{ .gravity_y = 0.5 });
    if ((button(@src(), "Send", !raw and !ended) or (entered and !raw)) and !ended) {
        input.append(gpa, '\n') catch return;
        sendInput(input.items);
        input.clearRetainingCapacity();
    }
    if (button(@src(), "End input", !ended)) endInput();
}

/// what the console wrote, as kept
pub fn consoleText() []const u8 {
    return console.items;
}

/// Gives the console input, keeping what does not fit for when it does
pub fn sendInput(text: []const u8) void {
    if (ended) return ui.say("The console's input has ended", .{});
    pending.appendSlice(gpa, text) catch return ui.say("Out of memory", .{});
    givePending();
    if (pending.items.len > 0) ui.say("{d} bytes wait for the node to read", .{pending.items.len});
}

fn givePending() void {
    if (pending.items.len == 0) return;
    const given = ui.sim.give(pending.items);
    std.mem.copyForwards(u8, pending.items, pending.items[given..]);
    pending.shrinkRetainingCapacity(pending.items.len - given);
}

/// Ends the console's input, once what is pending has been given
fn endInput() void {
    givePending();
    if (pending.items.len > 0) return ui.say("Input can end once the node has read what is pending", .{});
    ui.sim.console.end();
    ended = true;
    ui.say("The console's input has ended", .{});
}

// ---------- following new lines ----------

/// whether a transcript is scrolled to its end, and how tall it was
pub const Follow = struct { at_end: bool = true, height: f32 = 0 };
var forth_follow: Follow = .{};
var console_follow: Follow = .{};

/// Keeps a transcript at its end as lines come, unless scrolled back
pub fn follow(si: *dvui.ScrollInfo, f: *Follow) void {
    const grew = si.virtual_size.h != f.height;
    if (!grew) f.at_end = si.offsetFromMax(.vertical) < 2;
    f.height = si.virtual_size.h;
    if (f.at_end) si.scrollToOffset(.vertical, si.scrollMax(.vertical));
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const dvui = @import("dvui");
const Sim = @import("Sim");
const debug = @import("debug.zig");
const ui = @import("ui.zig");

// ---------- tests, in a hidden window ----------

const testing = dvui.testing;

fn typeInto(tag: []const u8, text: []const u8) !void {
    try testing.moveTo(tag);
    try testing.click(.left);
    try testing.settle(ui.frame);
    try testing.writeText(text);
    try testing.settle(ui.frame);
}

test "the prompt interprets lines on the selected node" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    try testing.settle(ui.frame);

    // a space typed is for the prompt, not to run the chip
    try typeInto("forth-input", "1 2 +");
    try std.testing.expect(!ui.running);
    try testing.pressKey(.enter, .none);
    try testing.settle(ui.frame);
    try std.testing.expectEqualStrings("ok 3", entries.items[entries.items.len - 1].result);
    try std.testing.expectEqualStrings("", line.items);

    try typeInto("forth-input", "nonsense");
    try testing.pressKey(.enter, .none);
    try testing.settle(ui.frame);
    try std.testing.expect(!entries.items[entries.items.len - 1].ok);
    try ui.saveImage(&w, "forth.png");

    // up goes back through the lines entered
    try testing.pressKey(.up, .none);
    try testing.settle(ui.frame);
    try testing.pressKey(.up, .none);
    try testing.settle(ui.frame);
    try std.testing.expectEqualStrings("1 2 +", line.items);
}

test "Tab completes a word at the prompt" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    try testing.settle(ui.frame);
    try typeInto("forth-input", "1 dro");
    try testing.pressKey(.tab, .none);
    try testing.settle(ui.frame);
    try std.testing.expect(std.mem.startsWith(u8, line.items, "1 dro"));
    try std.testing.expect(line.items.len > "1 dro".len or choices != null);
}

test "the console gives a line to the node, and shows what it writes" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    try testing.settle(ui.frame);
    try testing.moveTo("tab-console");
    try testing.click(.left);
    try testing.settle(ui.frame);
    try typeInto("console-input", "hi there");
    try testing.pressKey(.enter, .none);
    try testing.settle(ui.frame);
    _ = try ui.sim.run(100_000);
    try testing.settle(ui.frame);
    try std.testing.expectEqualStrings("HI THERE\n", console.items);
    try ui.saveImage(&w, "console.png");
}
