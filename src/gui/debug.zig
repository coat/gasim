//! The dock's panels for debugging, after the web version's: the trace, the
//! breakpoints and watches, and the history of steps and runs to go back to.

const pad = "{d:0>3}";

// ---------- the trace ----------

/// lines of the trace kept, as the web version keeps
const trace_capacity = 5000;

var gpa: Allocator = undefined;
pub var tracing = false;
/// show only the selected node's lines
var only_selected = false;
/// the last lines traced, the oldest first, owned
var lines: std.ArrayList([]u8) = .empty;
/// older lines were dropped to keep the last ones
var dropped = false;
var trace_follow: dock.Follow = .{};

/// the watch form's node, as typed, and its entry this frame
var watch_node: std.ArrayList(u8) = .empty;
pub var watch_id: ?dvui.Id = null;
var watch_write: usize = 0;
var watch_port: usize = 0;

pub fn start(allocator: Allocator) void {
    gpa = allocator;
    tracing = false;
    only_selected = false;
    lines = .empty;
    dropped = false;
    trace_follow = .{};
    watch_node = .empty;
    watch_id = null;
    watch_write = 0;
    watch_port = 0;
}

pub fn stop() void {
    clearTrace();
    lines.deinit(gpa);
    watch_node.deinit(gpa);
}

/// Takes what was traced, keeping the last lines
pub fn service() Allocator.Error!void {
    if (!tracing) return;
    if (ui.sim.takeTrace()) dropped = true;
    var it = std.mem.splitScalar(u8, ui.sim.out.written(), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(gpa, try gpa.dupe(u8, line));
    }
    if (lines.items.len > trace_capacity) {
        const drop = lines.items.len - trace_capacity;
        for (lines.items[0..drop]) |line| gpa.free(line);
        std.mem.copyForwards([]u8, lines.items, lines.items[drop..]);
        lines.shrinkRetainingCapacity(trace_capacity);
        dropped = true;
    }
}

pub fn setTracing(on: bool) void {
    ui.sim.setTracing(on) catch return ui.say("There is not the memory to trace", .{});
    tracing = on;
    ui.say("{s}", .{if (on) "Tracing each step that runs code" else "Not tracing"});
}

fn clearTrace() void {
    for (lines.items) |line| gpa.free(line);
    lines.clearRetainingCapacity();
    dropped = false;
}

/// the lines shown: all, or the selected node's
fn shown(arena: Allocator) []const []const u8 {
    if (!only_selected) return lines.items;
    var prefix: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&prefix, pad ++ " ", .{ui.sim.chip.layout.nodeNumber(ui.selected)}) catch unreachable;
    var found: std.ArrayList([]const u8) = .empty;
    for (lines.items) |line| if (std.mem.startsWith(u8, line, &prefix)) found.append(arena, line) catch break;
    return found.items;
}

pub fn traceHead() void {
    var on = tracing;
    if (dvui.checkbox(@src(), &on, "Tracing", .{ .gravity_y = 0.5, .tag = "tracing" })) setTracing(on);
    var label: [16]u8 = undefined;
    const only = std.fmt.bufPrint(&label, "Only " ++ pad, .{ui.sim.chip.layout.nodeNumber(ui.selected)}) catch unreachable;
    _ = dvui.checkbox(@src(), &only_selected, only, .{ .gravity_y = 0.5 });
    if (dock.button(@src(), "Save", lines.items.len > 0)) saveTrace();
    if (dock.button(@src(), "Clear", lines.items.len > 0)) clearTrace();
}

pub fn trace() void {
    const arena = dvui.currentWindow().arena();
    const all = shown(arena);
    if (all.len == 0) {
        const hint = if (!tracing)
            "Turn tracing on to see each step that runs code: the node, the address, the word and its instructions, and T, S and R after it."
        else if (only_selected and lines.items.len > 0)
            "The selected node has run no code since the trace began."
        else
            "Step or run the chip, and each step that runs code is written here.";
        var text = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .padding = .all(6) });
        defer text.deinit();
        text.addText(hint, .{ .color_text = .{ .color = dock.muted() } });
        return;
    }
    if (dropped) dvui.label(@src(), "Only the last {d} lines are kept.", .{trace_capacity}, .{ .color_text = .{ .color = dock.muted() }, .padding = .all(4) });

    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto }, .{ .expand = .both, .style = .content, .background = true, .max_size_content = ui.small });
    defer scroll.deinit();
    dock.follow(scroll.si, &trace_follow);
    // only the lines in view are drawn, as there can be thousands
    const font: dvui.Font = .theme(.mono);
    const char = font.textSize("0");
    var widest: usize = 0;
    for (all) |line| widest = @max(widest, line.len);
    const pad_x = 6;
    var canvas = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = @as(f32, @floatFromInt(widest)) * char.w + 2 * pad_x, .h = @as(f32, @floatFromInt(all.len)) * char.h } });
    defer canvas.deinit();
    const rs = canvas.data().contentRectScale();
    const view = scroll.si.viewport;
    const first: usize = @intFromFloat(@max(0, @floor(view.y / char.h)));
    const last: usize = @min(all.len, @as(usize, @intFromFloat(@max(0, @ceil((view.y + view.h) / char.h)))) + 1);
    const color = dvui.themeGet().color(.content, .text);
    for (all[@min(first, all.len)..last], first..) |line, k| {
        const at: dvui.Point = .{ .x = pad_x, .y = @as(f32, @floatFromInt(k)) * char.h };
        dvui.renderText(.{ .font = font, .text = line, .rs = rs, .p = rs.pointToPhysical(at), .color = color }) catch {};
    }
}

/// Saves the lines shown where the user says, as trace.txt by default
fn saveTrace() void {
    const arena = dvui.currentWindow().arena();
    const path = dvui.dialogNativeFileSave(arena, .{ .title = "Save the trace", .path = "trace.txt" }) catch null orelse return;
    const all = shown(arena);
    var text: std.ArrayList(u8) = .empty;
    for (all) |line| {
        text.appendSlice(arena, line) catch return ui.say("Out of memory", .{});
        text.append(arena, '\n') catch return ui.say("Out of memory", .{});
    }
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = text.items }) catch |err| return ui.say("{s}: {t}", .{ path, err });
    ui.say("Saved {d} lines as {s}", .{ all.len, std.fs.path.basename(path) });
}

// ---------- breakpoints and watches ----------

pub fn breakpointsHead() void {
    const chip = &ui.sim.chip;
    if (dock.button(@src(), "Remove all", chip.breakpoints.len + chip.watches.len > 0)) {
        ui.sim.clearBreakpoints();
        ui.say("Removed every breakpoint and watch", .{});
    }
}

pub fn breakpoints() void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .max_size_content = ui.small });
    defer scroll.deinit();
    var column = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .all(6) });
    defer column.deinit();
    const layout = ui.sim.chip.layout;

    subheading(@src(), "Breakpoints");
    const stops = ui.sim.chip.breakpoints.items();
    if (stops.len == 0) note(@src(), "Set one in the gutter beside a node's RAM and ROM. Running stops as the node reaches it.");
    for (stops, 0..) |b, k| {
        var label: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&label, "node " ++ pad ++ " at {x:0>3}", .{ layout.nodeNumber(b.index), b.address }) catch unreachable;
        if (row(@src(), k, text, b.index)) _ = ui.sim.toggleBreakpoint(b.index, b.address) catch {};
    }

    subheading(@src(), "Watches");
    const watches = ui.sim.chip.watches.items();
    if (watches.len == 0) note(@src(), "Running stops as a node watched reads or writes a word through the port.");
    for (watches, 0..) |w, k| {
        var label: [40]u8 = undefined;
        const text = std.fmt.bufPrint(&label, "node " ++ pad ++ " {s} {t}", .{ layout.nodeNumber(w.index), if (w.write) "writing" else "reading", w.direction }) catch unreachable;
        if (row(@src(), k, text, w.index)) _ = ui.sim.toggleWatch(w.index, w.direction, w.write) catch {};
    }
    watchForm();
}

fn subheading(src: std.builtin.SourceLocation, text: []const u8) void {
    dvui.labelNoFmt(src, text, .{}, .{ .font = .theme(.heading), .padding = .{ .y = 6, .h = 2 } });
}

fn note(src: std.builtin.SourceLocation, text: []const u8) void {
    var t = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .background = false, .padding = .all(0) });
    defer t.deinit();
    t.addText(text, .{ .color_text = .{ .color = dock.muted() } });
}

/// a breakpoint or watch, to select its node by, and whether to remove it
fn row(src: std.builtin.SourceLocation, k: usize, label: []const u8, node: u16) bool {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{ .id_extra = k, .expand = .horizontal });
    defer line.deinit();
    if (dvui.button(@src(), label, .{ .draw_focus = false }, .{ .background = false, .border = .all(0), .color_text = .{ .color = dvui.themeGet().color(.highlight, .fill) }, .gravity_y = 0.5 })) {
        ui.selected = node;
    }
    return dvui.button(@src(), "Remove", .{}, .{ .gravity_y = 0.5 });
}

const port_names = [_][]const u8{ "right", "down", "left", "up" };

/// A watch on a port of a node: the selected one, unless another is typed
fn watchForm() void {
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
    defer line.deinit();
    const layout = ui.sim.chip.layout;
    dvui.labelNoFmt(@src(), "Watch node", .{}, .{ .gravity_y = 0.5 });
    var placeholder: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&placeholder, pad, .{layout.nodeNumber(ui.selected)}) catch unreachable;
    const src = @src();
    watch_id = dvui.parentGet().extendId(src, 0);
    var te = dvui.textEntry(src, .{
        .text = .{ .array_list = .{ .backing = &watch_node, .allocator = gpa, .limit = 3 } },
        .placeholder = &placeholder,
    }, .{ .font = .theme(.mono), .min_size_content = .{ .w = 40 }, .max_size_content = .width(40), .gravity_y = 0.5, .tag = "watch-node" });
    const entered = te.enter_pressed;
    te.deinit();
    _ = dvui.dropdown(@src(), &.{ "reading", "writing" }, .{ .choice = &watch_write }, .{}, .{ .gravity_y = 0.5 });
    _ = dvui.dropdown(@src(), &port_names, .{ .choice = &watch_port }, .{}, .{ .gravity_y = 0.5 });
    if (dvui.button(@src(), "Watch", .{}, .{ .gravity_y = 0.5, .tag = "watch" }) or entered) watch();
}

fn watch() void {
    const layout = ui.sim.chip.layout;
    const typed = std.mem.trim(u8, watch_node.items, " ");
    const i = if (typed.len == 0) ui.selected else index: {
        const number = std.fmt.parseInt(u16, typed, 10) catch return ui.say("There is no node {s}", .{typed});
        break :index layout.index(number) orelse return ui.say("There is no node {s}", .{typed});
    };
    const direction: gasim.Direction = @fromBackingInt(@intCast(watch_port));
    const write = watch_write == 1;
    if (ui.sim.chip.watches.contains(.{ .index = i, .direction = direction, .write = write })) return ui.say("That is watched already", .{});
    _ = ui.sim.toggleWatch(i, direction, write) catch return ui.say("There are too many watches", .{});
    watch_node.clearRetainingCapacity();
}

// ---------- the history ----------

/// what each kind of moment was saved before
fn cause(c: Sim.Cause) []const u8 {
    return switch (c) {
        .step => "a step",
        .round => "a round of steps",
        .node => "a step of one node",
        .run => "a run",
        .line => "a line at the prompt",
        .reset => "starting again",
        .compile => "compiling a block",
    };
}

pub fn historyHead() void {
    dvui.label(@src(), "{d} of {d} kept", .{ ui.sim.historyLen(), Sim.history_capacity }, .{ .color_text = .{ .color = dock.muted() }, .gravity_y = 0.5 });
}

pub fn history() void {
    var buffer: [Sim.history_capacity]Sim.Moment = undefined;
    const moments = ui.sim.moments(&buffer);
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .max_size_content = ui.small });
    defer scroll.deinit();
    var column = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .all(6) });
    defer column.deinit();
    note(@src(), if (moments.len == 0) "Each step and run is kept here, up to 64, to go back to." else "Going back forgets what came after.");
    moment(@src(), 0, "Now", ui.sim.chip.steps, null);
    var n = moments.len;
    while (n > 0) {
        n -= 1;
        var label: [40]u8 = undefined;
        const text = std.fmt.bufPrint(&label, "Before {s}", .{cause(moments[n].cause)}) catch unreachable;
        moment(@src(), n + 1, text, moments[n].steps, n);
    }
}

/// a moment and its steps, with a button to go back to it, unless it is now
fn moment(src: std.builtin.SourceLocation, k: usize, label: []const u8, steps: u64, back: ?usize) void {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{ .id_extra = k, .expand = .horizontal, .padding = .{ .y = 1, .h = 1 } });
    defer line.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{ .min_size_content = .{ .w = 200 }, .gravity_y = 0.5 });
    dvui.label(@src(), "{d} steps", .{steps}, .{ .color_text = .{ .color = dock.muted() }, .min_size_content = .{ .w = 120 }, .gravity_y = 0.5 });
    const n = back orelse return;
    const go = dvui.button(@src(), "Go back", .{ .grayed = ui.running }, .{ .tag = if (n == 0) "go-back-oldest" else null });
    if (go and !ui.running) {
        if (ui.sim.backTo(n)) ui.say("Back to {d} steps", .{ui.sim.chip.steps});
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const dvui = @import("dvui");
const gasim = @import("gasim");
const Sim = @import("Sim");
const dock = @import("dock.zig");
const ui = @import("ui.zig");

// ---------- tests, in a hidden window ----------

const testing = dvui.testing;

fn open(tab: []const u8) !void {
    try testing.moveTo(tab);
    try testing.click(.left);
    try testing.settle(ui.frame);
}

test "the trace keeps each step that runs code" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    try testing.settle(ui.frame);
    try open("tab-trace");
    try open("tracing");
    try expect(tracing);
    for (0..3) |_| _ = try ui.sim.stepRound();
    try testing.settle(ui.frame);
    try expect(lines.items.len > 0);
    try expect(std.mem.startsWith(u8, lines.items[0], "000 ") or std.mem.startsWith(u8, lines.items[0], "001 "));
    try ui.saveImage(&w, "trace.png");
}

test "watches are added from the form, on the selected node or one typed" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    _ = try ui.sim.toggleBreakpoint(0, 4);
    try testing.settle(ui.frame);
    try open("tab-breakpoints");
    try open("watch");
    try expectEqual(1, ui.sim.chip.watches.len);
    try expectEqual(0, ui.sim.chip.watches.items()[0].index);

    try testing.moveTo("watch-node");
    try testing.click(.left);
    try testing.writeText("001");
    try testing.settle(ui.frame);
    try open("watch");
    try expectEqual(2, ui.sim.chip.watches.len);
    try expectEqual(ui.sim.chip.layout.index(1).?, ui.sim.chip.watches.items()[1].index);
    try ui.saveImage(&w, "breakpoints.png");
}

test "the history goes back to before a step" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    for (0..3) |_| _ = try ui.sim.stepRound();
    try testing.settle(ui.frame);
    try open("tab-history");
    try ui.saveImage(&w, "history.png");
    try open("go-back-oldest");
    try expectEqual(0, ui.sim.chip.steps);
    try expectEqual(0, ui.sim.historyLen());
}
