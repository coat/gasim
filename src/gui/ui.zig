//! What the GUI shows, after the web version: a toolbar to run, step, go
//! back and reset, the chip map, the prompt and console under it, the
//! selected node beside them, and a status line; or in place of the map
//! and the dock, the colorForth editor.
//! The map shows nodes as tiles coloured by what they are doing, and with
//! room, as the TUI's do, their registers, with arrows between them showing
//! which way words go. `main.zig` opens it in a window; tests draw it in a
//! hidden one.

/// It keeps pointers to its own fields, so it lives here rather than moving
pub var sim: Sim = undefined;
var gpa: Allocator = undefined;
pub var running = false;
/// rounds to run each frame, kept to about a frame's time, as the web
/// version keeps it
var rounds: usize = 10_000;
pub var selected: u16 = 0;
/// the chip, or the colorForth editor, beside the selected node
pub const View = enum { chip, editor };
pub var view: View = .chip;
/// how the map drew nodes last
pub var tiles: Tiles = .compact;
/// what happened last, for the status line
pub var message: []const u8 = "";
var message_buffer: [256]u8 = undefined;

/// What a scroll area says it needs at least, rather than all its
/// content, so the panels fit the window and leave the status line room
pub const small: dvui.Options.MaxSize = .all(120);

/// how long a frame's rounds should take, leaving the rest for drawing
const frame_budget_ns = 8 * std.time.ns_per_ms;

/// The panes' sizes, kept between runs
pub const Panes = struct {
    /// of the map, or the editor, beside the node
    node: f32 = 0.74,
    /// of the map above the dock
    dock: f32 = 0.75,
    /// of the blocks list beside the block, in the editor
    blocks: f32 = 0.25,
};
pub var panes: Panes = .{};

/// Starts with an empty chip, keeping the workspace in `dirs`, unless null
pub fn start(allocator: Allocator, dirs: ?files.Dirs) Allocator.Error!void {
    gpa = allocator;
    files.start(gpa, dirs);
    help.open = false;
    panes = .{};
    dock.start(gpa);
    editor.start(gpa);
    view = .chip;
    running = false;
    selected = 0;
    fit = .{};
    labels_add = null;
    mode = .auto;
    listing_here = null;
    listing_node = null;
    message = "";
    try sim.init(gpa);
}

pub fn stop() void {
    // first, while what it keeps is there
    files.stop();
    dock.stop();
    editor.stop();
    sim.deinit();
}

/// Sets up the chip with `file`, named `path`, as its extension says,
/// loading `loads` of `.blk` and `.cf` files. The editor saves colorForth
/// back to `saved_to`, or asks where.
pub fn open(path: []const u8, file: []const u8, loads: []const u32, saved_to: ?[]const u8) Allocator.Error!void {
    const kind: Sim.Kind = if (std.mem.endsWith(u8, path, ".af"))
        .af
    else if (std.mem.endsWith(u8, path, ".blk"))
        .blk
    else if (std.mem.endsWith(u8, path, ".cf"))
        .cf
    else
        .ga;
    running = false;
    dock.forgetInput();
    const loaded = sim.load(kind, file, loads);
    // colorForth opens in the editor, as in the TUI, even when it does not
    // compile, to put right
    if (kind == .cf) {
        editor.opened(saved_to);
        view = .editor;
    }
    loaded catch |err| switch (err) {
        error.LoadFailed => return say("{s}", .{sim.out.written()}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    say("Opened {s}", .{std.fs.path.basename(path)});
}

pub fn say(comptime fmt: []const u8, args: anytype) void {
    message = std.fmt.bufPrint(&message_buffer, fmt, args) catch &message_buffer;
}

pub fn frame() !dvui.App.Result {
    files.openDropped();
    try dock.service();
    if (running) try runFrame();

    {
        // the window lays its children over each other, so one box stacks
        // them: the toolbar, the panels taking what is left, the status line
        var page = dvui.box(@src(), .{}, .{ .expand = .both });
        defer page.deinit();
        toolbar();
        {
            // the map and the dock beside the node, as the web version
            // lays them out
            var columns = dvui.paned(@src(), .{ .direction = .horizontal, .collapsed_size = 0, .split_ratio = &panes.node }, .{ .expand = .both });
            defer columns.deinit();
            if (columns.showFirst()) switch (view) {
                .chip => chipView(),
                .editor => editor.draw(),
            };
            if (columns.showSecond()) nodePanel();
            if (view == .chip) {
                editor.block_id = null;
                editor.search_id = null;
            }
        }
        statusLine();
    }
    files.romDialog();
    help.dialog();
    keys();
    return .ok;
}

/// the map, and the dock under it
fn chipView() void {
    var rows = dvui.paned(@src(), .{ .direction = .vertical, .collapsed_size = 0, .split_ratio = &panes.dock }, .{ .expand = .both });
    defer rows.deinit();
    if (rows.showFirst()) map();
    if (rows.showSecond()) dock.draw();
}

fn runFrame() !void {
    const began = Io.Clock.awake.now(dvui.io);
    const stopped = try sim.run(rounds);
    const took: u64 = @intCast(@max(1, began.durationTo(Io.Clock.awake.now(dvui.io)).toNanoseconds()));
    switch (stopped) {
        .budget => {
            rounds = std.math.clamp(rounds * frame_budget_ns / took, 1000, 2_000_000);
            // straight on to the next frame, rather than waiting for input
            dvui.refresh(null, @src(), null);
        },
        .settled => pause("Every node is waiting", .{}),
        .input => pause("Waiting for console input", .{}),
        .hit => pause("{s}", .{sim.out.written()}),
    }
}

fn pause(comptime fmt: []const u8, args: anytype) void {
    running = false;
    say(fmt, args);
}

// ---------- what the toolbar and keys do, as the web version's ----------

fn toggleRun() void {
    if (running) return pause("Paused", .{});
    sim.remember(.run);
    running = true;
    say("Running", .{});
}

fn stepNext() void {
    const i = sim.stepNext() catch return say("Out of memory", .{});
    if (i) |n| say("Stepped node {d:0>3}", .{sim.chip.layout.nodeNumber(n)}) else say("Every node is waiting", .{});
}

fn stepRound() void {
    const advanced = sim.stepRound() catch return say("Out of memory", .{});
    say("{s}", .{if (advanced) "Stepped each node that could run" else "Every node is waiting"});
}

fn stepNode() void {
    const ran = sim.stepNode(selected) catch return say("Out of memory", .{});
    say("Node {d:0>3} {s}", .{ sim.chip.layout.nodeNumber(selected), if (ran) "stepped" else "is still waiting" });
}

fn back() void {
    if (sim.back()) say("Back to {d} steps", .{sim.chip.steps}) else say("Nothing to go back to", .{});
}

fn reset() void {
    running = false;
    sim.reset();
    dock.forgetInput();
    say("Reset", .{});
}

/// Moves the selection `dx` columns east and `dy` rows north
fn move(dx: i32, dy: i32) void {
    const layout = sim.chip.layout;
    const x: i32 = @intCast(selected % layout.columns);
    const y: i32 = @intCast(selected / layout.columns);
    const nx = std.math.clamp(x + dx, 0, @as(i32, layout.columns) - 1);
    const ny = std.math.clamp(y + dy, 0, @as(i32, layout.rows) - 1);
    selected = @intCast(ny * layout.columns + nx);
}

/// The web version's keys, for what no widget took: space runs or pauses,
/// s steps, shift+s steps a round, n steps the selected node, z goes back,
/// and the arrows move the selection
fn keys() void {
    if (help.open) return;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        const k = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        if (k.action == .up) continue;
        // the keys, anywhere
        if (k.code == .f1 and k.action == .down) {
            help.open = true;
            e.handle(@src(), dvui.currentWindow().data());
            // the dialog was drawn before this, so another frame shows it
            dvui.refresh(null, @src(), null);
            continue;
        }
        // the chip's keys are for the chip's view, as the web version's
        if (view != .chip or dock.typing() or files.typing()) continue;
        const repeatable = switch (k.code) {
            .up, .down, .left, .right => true,
            else => false,
        };
        if (k.action == .repeat and !repeatable) continue;
        const shift = k.mod.shiftOnly();
        if (k.mod != .none and !shift) continue;
        switch (k.code) {
            .slash => if (shift) {
                help.open = true;
            } else continue,
            .e => if (shift) continue else {
                view = .editor;
                editor.focusBlock();
            },
            .f => if (shift) continue else dock.focus(.forth),
            .c => if (shift) continue else dock.focus(.console),
            .h => move(-1, 0),
            .j => move(0, -1),
            .k => move(0, 1),
            .l => move(1, 0),
            .space => toggleRun(),
            .s => if (running) continue else if (shift) stepRound() else stepNext(),
            .n => if (running) continue else stepNode(),
            .z => if (running) continue else back(),
            .up => move(0, 1),
            .down => move(0, -1),
            .left => move(-1, 0),
            .right => move(1, 0),
            else => continue,
        }
        e.handle(@src(), dvui.currentWindow().data());
        dvui.refresh(null, @src(), null);
    }
}

fn toolbar() void {
    fitToolbar();
    var bar = dvui.box(@src(), .{ .dir = if (fit.rows) .vertical else .horizontal }, .{ .expand = .horizontal, .style = .window, .background = true, .padding = .all(4) });
    defer bar.deinit();
    bar_ids[0] = bar.data().id;

    {
        var rest = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer rest.deinit();
        bar_ids[1] = rest.data().id;
        for (std.enums.values(View)) |v| {
            const t: Tool = if (v == .chip)
                .{ .label = "Chip", .icon = icons.cpu_chip, .tip = "The chip (q in the editor)" }
            else
                .{ .label = "Editor", .icon = icons.code_bracket, .tip = "The colorForth editor (e)" };
            if (tool(@src(), t, .{ .id_extra = @backingInt(v), .style = if (view == v) .highlight else .control, .tag = if (v == .chip) "view-chip" else "view-editor" })) view = v;
        }
        files.toolbar();
        files.romButton();
        if (tool(@src(), .{ .label = "Help", .icon = icons.question_mark_circle, .tip = "Keys (?)" }, .{ .tag = "help" })) help.open = true;
        help.themeButton();
    }

    // running and stepping at the right, as the web version's, the steps
    // before them growing leftward, so the buttons stay put; centred only
    // on one row, as a vertical box lays a child centred over the others
    var run = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .gravity_y = if (fit.rows) 0 else 0.5, .padding = .{ .x = 12 } });
    defer run.deinit();
    bar_ids[2] = run.data().id;
    dvui.label(@src(), "{d} steps", .{sim.chip.steps}, .{ .gravity_y = 0.5, .padding = .{ .x = 4, .w = 8 } });
    const stopped = !running;
    // as wide running as not, so the buttons after it stay put
    const font = dvui.themeGet().font_body;
    const run_w = if (fit.labels) font.textHeight() + 4 + font.textSize("Pause").w else 0;
    if (tool(@src(), .{ .label = if (running) "Pause" else "Run", .icon = if (running) icons.pause else icons.play, .tip = "Run or pause (space)" }, .{ .style = .highlight, .min_size_content = .{ .w = run_w } })) toggleRun();
    if (tool(@src(), .{ .label = "Step", .icon = icons.step, .tip = "Step the next node to run (s)", .enabled = stopped }, .{})) stepNext();
    if (tool(@src(), .{ .label = "Round", .icon = icons.round, .tip = "Step each node that can run once (shift+s)", .enabled = stopped }, .{})) stepRound();
    if (tool(@src(), .{ .label = "Node", .icon = icons.step_node, .tip = "Step the selected node (n)", .enabled = stopped }, .{})) stepNode();
    if (tool(@src(), .{ .label = "Back", .icon = icons.step_back, .tip = "Go back before the last step or run (z)", .enabled = stopped and sim.historyLen() > 0 }, .{})) back();
    if (tool(@src(), .{ .label = "Reset", .icon = icons.arrow_path, .tip = "Start the chip again as it was loaded" }, .{})) reset();
}

/// A toolbar button, and what it says as the pointer rests on it
pub const Tool = struct {
    label: []const u8,
    /// with an icon, the label shows only where the window is wide enough
    icon: ?[]const u8 = null,
    tip: []const u8,
    enabled: bool = true,
};

/// How the toolbar fits the window: with its labels beside its icons, or
/// not, and on one row, or two, running and stepping on the second, as the
/// web version's wraps
const Fit = struct { labels: bool = true, rows: bool = false };
var fit: Fit = .{};
/// the toolbar, the rest of it, and running and stepping, to measure
var bar_ids: [3]dvui.Id = undefined;
/// how wide the toolbar's two parts were with their labels when they were
/// last left out, and from the frame after, how much the labels add to each
var labelled: [2]f32 = .{ 0, 0 };
var labels_add: ?[2]f32 = null;

pub fn toolbarLabels() bool {
    return fit.labels;
}

fn oneRow(parts: [2]f32) f32 {
    return parts[0] + parts[1];
}

fn twoRows(parts: [2]f32) f32 {
    return @max(parts[0], parts[1]);
}

/// Fits the toolbar to the window, as it measured last frame: one row with
/// its labels where it has room, otherwise one without them, otherwise two
/// rows, with them where they have room. Without the labels, it knows what
/// they add from when it last had them, so one that grew and shrank again
/// gets them back.
fn fitToolbar() void {
    const bar = dvui.minSizeGet(bar_ids[0]) orelse return;
    const now: [2]f32 = .{ (dvui.minSizeGet(bar_ids[1]) orelse return).w, (dvui.minSizeGet(bar_ids[2]) orelse return).w };
    const room = dvui.windowRect().w - (bar.w - if (fit.rows) twoRows(now) else oneRow(now));
    var with = now;
    var without: ?[2]f32 = null;
    if (fit.labels) {
        if (labels_add) |add| without = .{ now[0] - add[0], now[1] - add[1] };
    } else {
        const add = labels_add orelse .{ labelled[0] - now[0], labelled[1] - now[1] };
        labels_add = add;
        with = .{ now[0] + add[0], now[1] + add[1] };
        without = now;
    }
    const was = fit;
    fit = if (oneRow(with) <= room)
        .{}
    else if (without == null)
        // to measure it without them
        .{ .labels = false }
    else if (oneRow(without.?) <= room)
        .{ .labels = false }
    else if (twoRows(with) <= room)
        .{ .rows = true }
    else
        .{ .labels = false, .rows = true };
    if (was.labels and !fit.labels) {
        labelled = with;
        labels_add = null;
    }
    if (!std.meta.eql(was, fit)) dvui.refresh(null, @src(), null);
}

/// a toolbar button that does nothing, and looks it, unless `t.enabled`
pub fn tool(src: std.builtin.SourceLocation, t: Tool, opts: dvui.Options) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .grayed = !t.enabled }, opts.override(.{ .label = .{ .text = t.label } }));
    bw.processEvents();
    bw.drawBackground();
    const inside = opts.strip().override(bw.style()).override(.{ .gravity_y = 0.5, .role = .none });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        defer row.deinit();
        if (t.icon) |tvg| dvui.icon(@src(), t.label, tvg, .{}, inside);
        if (t.icon == null or toolbarLabels())
            dvui.labelNoFmt(@src(), t.label, .{}, inside.override(.{ .padding = .{ .x = if (t.icon == null) 0 else 4 } }));
    }
    const click = bw.clicked();
    bw.drawFocus();
    dvui.tooltip(@src(), .{ .active_rect = bw.data().borderRectScale().r }, "{s}", .{t.tip}, .{});
    bw.deinit();
    return click and t.enabled;
}

fn statusLine() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .style = .window, .background = true, .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 } });
    defer bar.deinit();
    dvui.labelNoFmt(@src(), message, .{}, .{});
    const n = &sim.chip.nodes[selected];
    dvui.label(@src(), "node {d:0>3}, {s}", .{ sim.chip.layout.nodeNumber(selected), statusText(n.status()) }, .{ .gravity_x = 1 });
}

fn statusText(status: gasim.Computer.Status) []const u8 {
    return switch (status) {
        .running => "running",
        .code => "waiting for code",
        .reading => "waiting to read",
        .writing => "waiting to write",
    };
}

fn heading(src: std.builtin.SourceLocation, text: []const u8) void {
    dvui.labelNoFmt(src, text, .{}, .{ .font = .theme(.heading), .padding = .{ .x = 8, .y = 4, .w = 8, .h = 2 } });
}

// ---------- the map ----------

/// The colours that mean something, as the web version's tokens
pub const Palette = struct {
    running: dvui.Color,
    reading: dvui.Color,
    writing: dvui.Color,
    moved: dvui.Color,
    breakpoint: dvui.Color,
    tile_text: dvui.Color,
    /// the word being run, in the listing
    here: dvui.Color,
    literal: dvui.Color,

    const light: Palette = blk: {
        @setEvalBranchQuota(10_000);
        break :blk .{
            .running = .fromHex("#d3f0d9"),
            .reading = .fromHex("#d6e6fa"),
            .writing = .fromHex("#e8dcf7"),
            .moved = .fromHex("#2f9e55"),
            .breakpoint = .fromHex("#d6334a"),
            .tile_text = .fromHex("#1c2128"),
            .here = .fromHex("#fff3c4"),
            .literal = .fromHex("#8a5a00"),
        };
    };
    const dark: Palette = blk: {
        @setEvalBranchQuota(10_000);
        break :blk .{
            .running = .fromHex("#1f4a2c"),
            .reading = .fromHex("#1d3a5e"),
            .writing = .fromHex("#3d2c5c"),
            .moved = .fromHex("#5fd585"),
            .breakpoint = .fromHex("#ff6b7f"),
            .tile_text = .fromHex("#e6e9ee"),
            .here = .fromHex("#4a4120"),
            .literal = .fromHex("#e3b65c"),
        };
    };

    pub fn get() Palette {
        return if (dvui.themeGet().dark) dark else light;
    }

    /// a tile's background for a node's status; none for waiting for code
    fn status(self: Palette, s: gasim.Computer.Status) ?dvui.Color {
        return switch (s) {
            .running => self.running,
            .code => null,
            .reading => self.reading,
            .writing => self.writing,
        };
    }
};

/// How the map draws nodes, in characters of the mono font: as numbers, or
/// as tiles of their registers with gaps between them for arrows
pub const Tiles = struct {
    width: f32,
    height: f32,
    /// characters and lines between tiles
    gap_x: f32,
    gap_y: f32,

    /// the least a number takes, its tile growing to fill the map as the
    /// web version's do
    pub const compact: Tiles = .{ .width = 4, .height = 1.75, .gap_x = 0.75, .gap_y = 0.5 };
    /// big enough for a node's registers on a few lines, with arrows in the
    /// middle of the gaps
    pub const comfortable: Tiles = .{ .width = 11, .height = 4, .gap_x = 2, .gap_y = 1 };
    pub const smallest: Tiles = .{ .width = 8, .height = 2.5, .gap_x = 2, .gap_y = 1 };
    pub const largest: Tiles = .{ .width = 16, .height = 6, .gap_x = 2, .gap_y = 1 };

    /// which tiles the map chooses
    pub const Mode = enum {
        /// tiles of registers if every node fits in them, otherwise numbers
        auto,
        numbers,
        /// tiles of registers, scrolling if every node does not fit
        registers,
    };

    /// Tiles for a view `columns` characters wide and `lines` high: as large
    /// as fit with every node in view, up to the largest, and with too
    /// little room, for `choice`, compact ones filling the view, or
    /// comfortable ones to scroll through
    pub fn fit(choice: Mode, columns: f32, lines: f32, layout: Chip.Layout) Tiles {
        const per_column = columns / @as(f32, @floatFromInt(layout.columns));
        const per_row = lines / @as(f32, @floatFromInt(layout.rows));
        const s = smallest;
        const least: Tiles = if (choice == .registers) comfortable else smallest;
        if (choice != .numbers and per_column >= least.width + s.gap_x and per_row >= least.height + s.gap_y) {
            return .{ .width = @min(@floor(per_column - s.gap_x), largest.width), .height = @min(@floor(per_row - s.gap_y), largest.height), .gap_x = s.gap_x, .gap_y = s.gap_y };
        }
        if (choice == .registers) return comfortable;
        const k = compact;
        return .{ .width = @max(per_column - k.gap_x, k.width), .height = @max(per_row - k.gap_y, k.height), .gap_x = k.gap_x, .gap_y = k.gap_y };
    }

    pub fn registers(self: Tiles) bool {
        return self.gap_x >= smallest.gap_x;
    }
};

pub var mode: Tiles.Mode = .auto;

fn map() void {
    var panel = dvui.box(@src(), .{}, .{ .expand = .both });
    defer panel.deinit();
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer head.deinit();
        heading(@src(), "Chip");
        modes();
        legend();
    }
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto }, .{ .expand = .both, .style = .content, .background = true, .max_size_content = small });
    defer scroll.deinit();
    drawMap(scroll.si.viewport.w, scroll.si.viewport.h);
}

fn modes() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
    defer row.deinit();
    for (std.enums.values(Tiles.Mode), 0..) |m, n| {
        if (dvui.radio(@src(), mode == m, @tagName(m), .{ .id_extra = n })) mode = m;
    }
}

fn legend() void {
    const palette: Palette = .get();
    const items = [_]struct { []const u8, ?dvui.Color }{
        .{ "running", palette.running },
        .{ "reading", palette.reading },
        .{ "writing", palette.writing },
        .{ "waiting for code", null },
        .{ "moved", palette.moved },
    };
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .gravity_y = 0.5, .padding = .{ .w = 8 } });
    defer row.deinit();
    const theme = dvui.themeGet();
    for (items, 0..) |item, n| {
        const name, const color = item;
        const swatch = dvui.box(@src(), .{}, .{
            .id_extra = n,
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .x = 10, .w = 4 },
            .background = true,
            .color_fill = .{ .color = color orelse theme.color(.content, .fill) },
            .border = .all(1),
            .color_border = .{ .color = theme.color(.content, .border) },
            .corners = .all(3),
        });
        swatch.deinit();
        dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = n, .gravity_y = 0.5 });
    }
}

/// Draws every node, north at the top, in a view `width` by `height`,
/// scrolling when the tiles are larger
fn drawMap(width: f32, height: f32) void {
    const layout = sim.chip.layout;
    const font = tileFont();
    const char = font.textSize("0");
    const pad = char.w / 2;
    const t: Tiles = .fit(mode, (width - 2 * pad) / char.w, (height - 2 * pad) / char.h, layout);
    tiles = t;
    // a tile's size, and the distance to the next, in natural units
    const tile: dvui.Size = .{ .w = t.width * char.w, .h = t.height * char.h };
    const step: dvui.Size = .{ .w = (t.width + t.gap_x) * char.w, .h = (t.height + t.gap_y) * char.h };
    const columns: f32 = @floatFromInt(layout.columns);
    const rows: f32 = @floatFromInt(layout.rows);

    var canvas = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = columns * step.w - t.gap_x * char.w + 2 * pad, .h = rows * step.h - t.gap_y * char.h + 2 * pad },
    });
    defer canvas.deinit();
    const rs = canvas.data().contentRectScale();
    const origin: dvui.Point = .{ .x = pad, .y = pad };

    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, canvas.data())) continue;
        switch (e.evt) {
            .mouse => |m| if (m.action == .press and m.button.pointer()) {
                const p = rs.pointFromPhysical(m.p).diff(origin);
                if (p.x < 0 or p.y < 0) continue;
                const c: u16 = @intFromFloat(p.x / step.w);
                const r: u16 = @intFromFloat(p.y / step.h);
                // a click in a gap selects nothing
                if (c >= layout.columns or r >= layout.rows or @mod(p.x, step.w) > tile.w or @mod(p.y, step.h) > tile.h) continue;
                e.handle(@src(), canvas.data());
                selected = (layout.rows - 1 - r) * layout.columns + c;
                dvui.refresh(null, @src(), canvas.data().id);
            },
            else => {},
        }
    }

    const palette: Palette = .get();
    const muted = dvui.themeGet().color(.content, .text);
    for (0..layout.rows) |r| {
        // north at the top
        const y = layout.rows - 1 - r;
        for (0..layout.columns) |c| {
            const i: u16 = @intCast(y * layout.columns + c);
            const at: dvui.Point = .{ .x = origin.x + @as(f32, @floatFromInt(c)) * step.w, .y = origin.y + @as(f32, @floatFromInt(r)) * step.h };
            drawTile(rs, font, .{ .x = at.x, .y = at.y, .w = tile.w, .h = tile.h }, i, t.registers());
            if (!t.registers()) continue;
            // between this tile and those east and north of it
            if (c + 1 < layout.columns) if (sim.chip.flow(i, .east)) |f| {
                drawArrow(rs, .{ .x = at.x + tile.w + t.gap_x * char.w / 2, .y = at.y + tile.h / 2 }, if (f.outward) .east else .west, char.w * 1.2, flowColor(f.kind, palette, muted));
            };
            if (r > 0) if (sim.chip.flow(i, .north)) |f| {
                drawArrow(rs, .{ .x = at.x + tile.w / 2, .y = at.y - t.gap_y * char.h / 2 }, if (f.outward) .north else .south, char.h * 0.7, flowColor(f.kind, palette, muted));
            };
        }
    }
}

/// a little smaller than the mono font, so more fits on the map
fn tileFont() dvui.Font {
    const mono: dvui.Font = .theme(.mono);
    return mono.withSize(mono.size * 0.85);
}

/// green for a word that went across in the last step, or that has been
/// handed over to be taken, the text's colour for a node waiting to read or
/// write, and faint for one waiting for code
fn flowColor(kind: Chip.Flow.Kind, palette: Palette, text: dvui.Color) dvui.Color {
    return switch (kind) {
        .moved => palette.moved,
        .waiting => text.opacity(0.75),
        .code => text.opacity(0.3),
    };
}

/// Draws a node's tile, coloured by what it is doing, with its number, and
/// with room, what it waits on and its registers on as many lines as fit.
/// Small tiles light the edges words went through in the last step, as the
/// web version's do; large ones have arrows between them for that.
fn drawTile(rs: dvui.RectScale, font: dvui.Font, box: dvui.Rect, i: u16, registers: bool) void {
    const theme = dvui.themeGet();
    const palette: Palette = .get();
    const layout = sim.chip.layout;
    const n = &sim.chip.nodes[i];
    const status = n.status();
    const x = i % layout.columns;
    const y = i / layout.columns;
    const physical = rs.rectToPhysical(box);
    const corner: dvui.CornerRect.Physical = .all(4 * rs.s);
    const fill = palette.status(status) orelse theme.color(.content, .fill);
    physical.fill(corner, .{ .color = .{ .color = fill } });
    if (i == selected) {
        physical.outsetAll(1.5 * rs.s).stroke(.all(5.5 * rs.s), .{ .thickness = 2 * rs.s, .color = .{ .color = theme.color(.content, .text) } });
    } else physical.stroke(corner, .{ .thickness = rs.s, .color = .{ .color = theme.color(.content, .border) } });

    for (sim.chip.breakpoints.items()) |b| if (b.index == i) {
        const dot = 6 * rs.s;
        rs.rectToPhysical(.{ .x = box.x + 3, .y = box.y + 3, .w = 6, .h = 6 }).fill(.round(dot), .{ .color = .{ .color = palette.breakpoint } });
        break;
    };
    // the console's port, facing off the chip
    if (i == Sim.console_node) edge(rs, box, Chip.facing(x, y, Sim.console_port), theme.color(.highlight, .fill));

    const arena = dvui.currentWindow().arena();
    const char = font.textSize("0");
    const text = palette.tile_text;
    const number = std.fmt.allocPrint(arena, "{d:0>3}", .{layout.nodeNumber(i)}) catch return;
    if (!registers) {
        const size = font.textSize(number);
        drawText(rs, font, .{ .x = box.x + (box.w - size.w) / 2, .y = box.y + (box.h - size.h) / 2 }, number, text);
        for (std.enums.values(gasim.Direction)) |d| if (n.transfers.written.contains(d) or n.transfers.read.contains(d))
            edge(rs, box, Chip.facing(x, y, d), palette.moved);
        return;
    }

    var at = box.x + char.w / 2;
    const top = box.y + char.h / 4;
    drawText(rs, font, .{ .x = at, .y = top }, number, text);
    at += 4 * char.w;
    const doing, const address = switch (status) {
        .running => .{ "run", null },
        .code => |a| .{ "code", a },
        .reading => |a| .{ "rd", a },
        .writing => |a| .{ "wr", a },
    };
    const faint = text.opacity(0.65);
    drawText(rs, font, .{ .x = at, .y = top }, doing, faint);
    at += @as(f32, @floatFromInt(doing.len + 1)) * char.w;
    // the ports it waits on, as arrows, or the I/O register
    if (address) |a| if (gasim.port.select(a)) |ports| {
        var it = ports.iterator();
        while (it.next()) |direction| {
            if (at + char.w > box.x + box.w) break;
            drawArrow(rs, .{ .x = at + char.w / 2, .y = top + char.h / 2 }, Chip.facing(x, y, direction), char.w * 0.8, faint);
            at += char.w;
        }
    } else drawText(rs, font, .{ .x = at, .y = top }, gasim.disassembler.ioName(a), faint);

    // as many as fit on each line, in order, labels faint
    const items = [_]struct { []const u8, []const u8 }{
        .{ "P", std.fmt.allocPrint(arena, "{x}", .{@as(u10, @bitCast(n.p))}) catch return },
        .{ "s", std.fmt.allocPrint(arena, "{d}", .{n.slot}) catch return },
        .{ "T", std.fmt.allocPrint(arena, "{x}", .{@as(u18, @bitCast(n.data_stack.t))}) catch return },
        .{ "S", std.fmt.allocPrint(arena, "{x}", .{@as(u18, @bitCast(n.data_stack.s))}) catch return },
        .{ "A", std.fmt.allocPrint(arena, "{x}", .{@as(u18, @bitCast(n.a))}) catch return },
        .{ "B", std.fmt.allocPrint(arena, "{x}", .{n.b}) catch return },
        .{ "io", std.fmt.allocPrint(arena, "{x}", .{@as(u18, @bitCast(n.io))}) catch return },
    };
    const width = box.w - char.w;
    var line = top + char.h;
    var item: usize = 0;
    while (line + char.h <= box.y + box.h + 0.5 and item < items.len) : (line += char.h) {
        var used: f32 = 0;
        while (item < items.len) : (item += 1) {
            const name, const value = items[item];
            const len = @as(f32, @floatFromInt(name.len + value.len)) * char.w;
            const space = if (used > 0) char.w else 0;
            // an item too wide for a line is cut short
            if (used > 0 and used + space + len > width) break;
            used += space;
            drawText(rs, font, .{ .x = box.x + char.w / 2 + used, .y = line }, name, faint);
            drawText(rs, font, .{ .x = box.x + char.w / 2 + used + @as(f32, @floatFromInt(name.len)) * char.w, .y = line }, value, text);
            used += len;
        }
    }
}

/// a bar along the middle half of a tile's side, just outside it
fn edge(rs: dvui.RectScale, box: dvui.Rect, side: Chip.Cardinal, color: dvui.Color) void {
    const thick = 3;
    const bar: dvui.Rect = switch (side) {
        .north => .{ .x = box.x + box.w / 4, .y = box.y - thick - 1, .w = box.w / 2, .h = thick },
        .south => .{ .x = box.x + box.w / 4, .y = box.y + box.h + 1, .w = box.w / 2, .h = thick },
        .east => .{ .x = box.x + box.w + 1, .y = box.y + box.h / 4, .w = thick, .h = box.h / 2 },
        .west => .{ .x = box.x - thick - 1, .y = box.y + box.h / 4, .w = thick, .h = box.h / 2 },
    };
    rs.rectToPhysical(bar).fill(.all(2 * rs.s), .{ .color = .{ .color = color } });
}

fn drawText(rs: dvui.RectScale, font: dvui.Font, at: dvui.Point, text: []const u8, color: dvui.Color) void {
    dvui.renderText(.{ .font = font, .text = text, .rs = rs, .p = rs.pointToPhysical(at), .color = color }) catch {};
}

/// Draws a triangle `size` across centred on `center`, pointing toward
/// `cardinal`, with north up
fn drawArrow(rs: dvui.RectScale, center: dvui.Point, cardinal: Chip.Cardinal, size: f32, color: dvui.Color) void {
    const h = size / 2;
    const tip: dvui.Point, const left: dvui.Point, const right: dvui.Point = switch (cardinal) {
        .north => .{ .{ .x = 0, .y = -h }, .{ .x = -h, .y = h }, .{ .x = h, .y = h } },
        .south => .{ .{ .x = 0, .y = h }, .{ .x = h, .y = -h }, .{ .x = -h, .y = -h } },
        .east => .{ .{ .x = h, .y = 0 }, .{ .x = -h, .y = h }, .{ .x = -h, .y = -h } },
        .west => .{ .{ .x = -h, .y = 0 }, .{ .x = h, .y = -h }, .{ .x = h, .y = h } },
    };
    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();
    for ([_]dvui.Point{ tip, left, right }) |p| path.addPoint(rs.pointToPhysical(center.plus(p)));
    path.build().fillConvex(.{ .color = .{ .color = color }, .fade = 1.0 });
}

// ---------- the node ----------

/// the word the listing last scrolled to, and in which node, so it scrolls
/// again only when that moves or another node is selected
var listing_here: ?u9 = null;
var listing_node: ?u16 = null;

/// The selected node, as the web version shows it: what it is doing, its
/// registers and stacks, and its RAM and ROM disassembled, with a gutter
/// to set breakpoints in
fn nodePanel() void {
    var panel = dvui.box(@src(), .{}, .{ .expand = .both, .tag = "node" });
    defer panel.deinit();
    const n = sim.node(dvui.currentWindow().arena(), selected) catch return;
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer head.deinit();
        dvui.label(@src(), "Node {d:0>3}", .{n.number}, .{ .font = .theme(.heading), .padding = .{ .x = 8, .y = 4, .w = 8, .h = 2 }, .gravity_y = 0.5 });
        doingPill(n);
    }
    var body = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .{ .x = 8, .w = 4 } });
    defer body.deinit();
    registerFields(n);
    stacks(n);
    listing(n);
}

/// what the node is doing, on its status's colour
fn doingPill(n: Sim.NodeView) void {
    const palette: Palette = .get();
    const theme = dvui.themeGet();
    const fill: ?dvui.Color = switch (n.status) {
        .running => palette.running,
        .reading => palette.reading,
        .writing => palette.writing,
        .code => null,
    };
    const opts: dvui.Options = .{
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = fill orelse theme.color(.content, .fill) },
        .border = .all(1),
        .color_border = .{ .color = theme.color(.content, .border) },
        .corners = .round(100),
        .padding = .{ .x = 8, .y = 1, .w = 8, .h = 1 },
    };
    switch (n.status) {
        .running => dvui.labelNoFmt(@src(), "Running", .{}, opts),
        .code => dvui.label(@src(), "Waiting for code from {s}", .{n.waiting_on.?}, opts),
        .reading => dvui.label(@src(), "Waiting to read {s}", .{n.waiting_on.?}, opts),
        .writing => dvui.label(@src(), "Waiting to write {s}", .{n.waiting_on.?}, opts),
    }
}

fn mutedText() dvui.Color {
    return dvui.themeGet().color(.content, .text).opacity(0.6);
}

/// the registers two to a line, and the instruction word on its own
fn registerFields(n: Sim.NodeView) void {
    const arena = dvui.currentWindow().arena();
    const fields = [_]struct { []const u8, []const u8 }{
        .{ "P", std.fmt.allocPrint(arena, "{x:0>3}", .{n.p}) catch return },
        .{ "slot", std.fmt.allocPrint(arena, "{d}", .{n.slot}) catch return },
        .{ "carry", std.fmt.allocPrint(arena, "{d}{s}", .{ n.carry, if (n.extended) " (extended)" else "" }) catch return },
        .{ "A", std.fmt.allocPrint(arena, "{x:0>5}", .{n.a}) catch return },
        .{ "B", std.fmt.allocPrint(arena, "{x:0>3}", .{n.b}) catch return },
        .{ "io", std.fmt.allocPrint(arena, "{x:0>5}", .{n.io}) catch return },
        .{ "time", std.fmt.allocPrint(arena, "{d:.1} ns", .{n.time}) catch return },
    };
    var k: usize = 0;
    while (k < fields.len) : (k += 2) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = k });
        defer row.deinit();
        for (fields[k..@min(k + 2, fields.len)], k..) |f, id| field(f[0], f[1], id);
    }
    const i = if (n.i) |i|
        std.fmt.allocPrint(arena, "{x:0>5} {s}", .{ i, n.i_code.? }) catch return
    else
        std.fmt.allocPrint(arena, "next word from {s}", .{n.fetch_from.?}) catch return;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    field("I", i, fields.len);
}

fn field(name: []const u8, value: []const u8, id: usize) void {
    // as wide as each other, so the second of a line line up
    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .w = 140 }, .id_extra = id });
    defer cell.deinit();
    dvui.labelNoFmt(@src(), name, .{}, .{ .color_text = .{ .color = mutedText() }, .min_size_content = .{ .w = 44 }, .padding = .all(1) });
    dvui.labelNoFmt(@src(), value, .{}, .{ .font = .theme(.mono), .padding = .all(1) });
}

fn stacks(n: Sim.NodeView) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8, .h = 8 } });
    defer row.deinit();
    stack("Data stack", &n.data_stack, &.{ "T", "S" }, 0);
    stack("Return stack", &n.return_stack, &.{"R"}, 1);
}

/// a stack from the top, with its registers named
fn stack(name: []const u8, values: []const u18, named: []const []const u8, id: usize) void {
    var column = dvui.box(@src(), .{}, .{ .expand = .horizontal, .id_extra = id });
    defer column.deinit();
    dvui.labelNoFmt(@src(), name, .{}, .{ .color_text = .{ .color = mutedText() }, .padding = .{ .y = 0, .h = 2 } });
    for (values, 0..) |v, k| {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = k });
        defer line.deinit();
        dvui.labelNoFmt(@src(), if (k < named.len) named[k] else "", .{}, .{ .font = .theme(.mono), .color_text = .{ .color = mutedText() }, .min_size_content = .{ .w = 14 }, .padding = .all(0) });
        dvui.label(@src(), "{x:0>5}", .{v}, .{ .font = .theme(.mono), .color_text = if (k < named.len) null else .{ .color = mutedText() }, .padding = .all(0) });
    }
}

/// RAM and ROM disassembled, scrolling to keep the word being run in view
/// as it moves, unless running, and to it, or the top, for a node newly
/// selected
fn listing(n: Sim.NodeView) void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .content, .background = true, .max_size_content = small });
    defer scroll.deinit();
    const palette: Palette = .get();
    const theme = dvui.themeGet();
    const newly = listing_node != selected;
    const moved = n.here != listing_here;
    if (newly and n.here == null) scroll.si.viewport.y = 0;
    listing_node = selected;
    listing_here = n.here;

    const mono: dvui.Font = .theme(.mono);
    const line_height = mono.lineHeight();
    for (n.memory, 0..) |line, k| {
        if (k == 0 or k == 64) dvui.labelNoFmt(@src(), if (k == 0) "RAM" else "ROM", .{}, .{ .id_extra = k, .color_text = .{ .color = mutedText() }, .padding = .{ .x = 4, .y = 6, .h = 2 } });
        // RAM and ROM repeat at x040 and x0c0
        const here = if (n.here) |h| h & 0x1bf == line.address else false;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = k,
            .expand = .horizontal,
            .background = here,
            .color_fill = .{ .color = palette.here },
        });
        defer row.deinit();
        if (here and (newly or (moved and !running))) dvui.scrollTo(.{ .screen_rect = row.data().borderRectScale().r });

        {
            var gutter = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 22, .h = line_height }, .tag = if (k == 0) "gutter-000" else null });
            defer gutter.deinit();
            var hovered = false;
            if (dvui.clicked(gutter.data(), .{ .hovered = &hovered })) {
                _ = sim.toggleBreakpoint(selected, line.address) catch say("Too many breakpoints", .{});
            }
            const rs = gutter.data().contentRectScale();
            const dot: dvui.Rect.Physical = .{ .x = rs.r.x + rs.r.w / 2 - 5 * rs.s, .y = rs.r.y + rs.r.h / 2 - 5 * rs.s, .w = 10 * rs.s, .h = 10 * rs.s };
            if (line.breakpoint or hovered) dot.fill(.round(5 * rs.s), .{ .color = .{ .color = if (line.breakpoint) palette.breakpoint else theme.color(.content, .border) } });
        }
        const zero = line.value == 0;
        const pad: dvui.Rect = .{ .x = 4, .w = 8 };
        dvui.label(@src(), "{x:0>3}", .{line.address}, .{ .font = mono, .color_text = .{ .color = theme.color(.highlight, .fill) }, .padding = pad });
        dvui.label(@src(), "{x:0>5}", .{line.value}, .{ .font = mono, .color_text = .{ .color = mutedText() }, .padding = pad });
        dvui.labelNoFmt(@src(), line.code, .{}, .{ .font = mono, .padding = pad, .color_text = if (zero) .{ .color = mutedText() } else if (line.literal) .{ .color = palette.literal } else null });
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const dvui = @import("dvui");
const gasim = @import("gasim");
const Chip = gasim.Chip;
const Sim = @import("Sim");
const dock = @import("dock.zig");
const editor = @import("editor.zig");
const files = @import("files.zig");
const help = @import("help.zig");
const icons = @import("icons");

// ---------- tests, in a hidden window ----------

pub const upcase =
    \\node 000
    \\: main
    \\    right a!  up b!
    \\    begin @b ! @ !b again
    \\
    \\node 001
    \\: main
    \\    right b!
    \\    begin @b upcase !b again
    \\
    \\: upcase ( c - C )
    \\    dup -97 + -if drop ; then
    \\    -26 + -if drop -32 + ; then
    \\    drop ;
;

/// Saves the window as `name` in -Dgui-images, if it was given, to look at
pub fn saveImage(t: *dvui.testing, name: []const u8) !void {
    const dir = build_options.gui_images orelse return;
    try Io.Dir.cwd().createDirPath(dvui.io, dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, name });
    defer std.testing.allocator.free(path);
    var file = try Io.Dir.cwd().createFile(dvui.io, path, .{});
    defer file.close(dvui.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(dvui.io, &buffer);
    try dvui.testing.capturePng(frame, null, &writer.interface);
    try writer.interface.flush();
    _ = t;
}

pub fn startWith(source: []const u8) !void {
    try start(std.testing.allocator, null);
    try open("upcase.ga", source, &.{0}, null);
}

test "the map shows registers and arrows when it has room" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1800, .h = 1100 } });
    defer t.deinit();
    try startWith(upcase);
    defer stop();
    for (0..4) |_| _ = try sim.stepRound();
    try dvui.testing.settle(frame);
    try saveImage(&t, "map-large.png");
    try std.testing.expect(tiles.registers());
}

test "the map scrolls through tiles of registers when asked for them" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();
    try startWith(upcase);
    defer stop();
    mode = .registers;
    try dvui.testing.settle(frame);
    try saveImage(&t, "map-scrolling.png");
    try std.testing.expectEqual(Tiles.comfortable, tiles);
}

test "the map shows numbers when it is small" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 520, .h = 480 } });
    defer t.deinit();
    try startWith(upcase);
    defer stop();
    for (0..4) |_| _ = try sim.stepRound();
    try dvui.testing.settle(frame);
    try saveImage(&t, "map-small.png");
    try std.testing.expect(!tiles.registers());
}

test "the toolbar leaves out its labels, then takes two rows, where it does not fit" {
    for ([_]f32{ 1800, 900, 520, 1800 }) |w| {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = w, .h = 700 } });
        defer t.deinit();
        try startWith(upcase);
        defer stop();
        try dvui.testing.settle(frame);
        try std.testing.expectEqual(Fit{ .labels = w > 900, .rows = w < 900 }, fit);
        try saveImage(&t, try std.fmt.bufPrint(&image_name, "toolbar-{d}.png", .{w}));
    }
}

var image_name: [32]u8 = undefined;

test "the toolbar's labels come back once it shrinks to fit them" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1800, .h = 700 } });
    defer t.deinit();
    try startWith(upcase);
    defer stop();
    try dvui.testing.settle(frame);
    // as if they were left out while a long file name and its blocks took
    // the room, and it measured then how much they add
    fit = .{ .labels = false };
    labels_add = .{ 1500, 0 };
    try dvui.testing.settle(frame);
    try std.testing.expect(!fit.labels);
    // the file name and blocks gone, the toolbar is narrower, and what the
    // labels add, without them, fits
    labels_add = .{ 150, 150 };
    try dvui.testing.settle(frame);
    try std.testing.expectEqual(Fit{}, fit);
}

test "the keys step and go back" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    try startWith(upcase);
    defer stop();
    try dvui.testing.settle(frame);
    try dvui.testing.pressKey(.s, .lshift);
    try dvui.testing.settle(frame);
    try std.testing.expectEqual(1, sim.historyLen());
    try dvui.testing.pressKey(.z, .none);
    try dvui.testing.settle(frame);
    try std.testing.expectEqual(0, sim.chip.steps);
    try dvui.testing.pressKey(.right, .none);
    try dvui.testing.settle(frame);
    try std.testing.expectEqual(1, selected);
}

test "the node panel sets breakpoints in its gutter" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer t.deinit();
    try startWith(upcase);
    defer stop();
    for (0..4) |_| _ = try sim.stepRound();
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("node");
    try dvui.testing.moveTo("gutter-000");
    try dvui.testing.click(.left);
    try dvui.testing.settle(frame);
    try std.testing.expect(sim.chip.breakpoints.contains(.init(0, 0)));
    try saveImage(&t, "node.png");
}

test {
    _ = dock;
    _ = editor;
    _ = files;
    _ = help;
    _ = @import("debug.zig");
}

const build_options = @import("build_options");
