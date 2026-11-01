//! The colorForth editor, after the web version's: the blocks of the file
//! to search and go to, the block being edited as colored words, and a bar
//! of colors and what the editor is doing. `Editor.zig` is the model; keys
//! go to it as the TUI's do.

/// show blue words, which lay out the block
pub var show_format = false;
/// mark where colors change, as `gasim blocks` does
pub var show_marks = false;

var gpa: Allocator = undefined;
/// the file the blocks came from or were last saved to, owned
var path: ?[]u8 = null;
/// the blocks list's search, as typed
var query: std.ArrayList(u8) = .empty;
/// the blocks as text, worked out again when they may have changed
var listing: std.heap.ArenaAllocator = undefined;
var views: []const Sim.BlockView = &.{};
var stale = true;
/// New was pressed with the blocks not saved, and pressing it again starts
/// a new file anyway
var confirm_new = false;
/// the block, to give keys to, and the search, as of this frame
pub var block_id: ?dvui.Id = null;
pub var search_id: ?dvui.Id = null;
/// focus the block next frame, as when the editor is opened
var focus_block = true;

pub fn start(allocator: Allocator) void {
    gpa = allocator;
    show_format = false;
    show_marks = false;
    path = null;
    query = .empty;
    listing = .init(gpa);
    views = &.{};
    stale = true;
    confirm_new = false;
    block_id = null;
    search_id = null;
    focus_block = true;
}

pub fn stop() void {
    if (path) |p| gpa.free(p);
    query.deinit(gpa);
    listing.deinit();
}

/// Notes the file the editor opened, to save back to, unless null
pub fn opened(file_path: ?[]const u8) void {
    if (path) |p| gpa.free(p);
    path = if (file_path) |p| gpa.dupe(u8, p) catch null else null;
    stale = true;
    focus_block = true;
}

/// whether a key is being typed into the editor, rather than for the app
pub fn typing() bool {
    const focused = dvui.focusedWidgetId() orelse return false;
    return focused == block_id or focused == search_id;
}

pub fn draw() void {
    const arena = dvui.currentWindow().arena();
    const view = ui.sim.editing(arena) catch return;
    if (stale) {
        _ = listing.reset(.retain_capacity);
        views = ui.sim.editorBlocks(listing.allocator()) catch &.{};
        stale = false;
    }
    var panes = dvui.paned(@src(), .{ .direction = .horizontal, .collapsed_size = 0, .split_ratio = &ui.panes.blocks }, .{ .expand = .both });
    defer panes.deinit();
    if (panes.showFirst()) blocksList(view);
    if (panes.showSecond()) {
        var panel = dvui.box(@src(), .{}, .{ .expand = .both });
        defer panel.deinit();
        head(view);
        block(view);
        colorBar(view);
    }
}

// ---------- the blocks ----------

fn blocksList(view: Sim.EditorView) void {
    var panel = dvui.box(@src(), .{}, .{ .expand = .both });
    defer panel.deinit();
    dvui.labelNoFmt(@src(), "Blocks", .{}, .{ .font = .theme(.heading), .padding = .{ .x = 8, .y = 4, .w = 8, .h = 2 } });
    const src = @src();
    search_id = dvui.parentGet().extendId(src, 0);
    var te = dvui.textEntry(src, .{ .text = .{ .array_list = .{ .backing = &query, .allocator = gpa, .limit = 64 } }, .placeholder = "Search" }, .{ .expand = .horizontal, .tag = "block-search" });
    te.deinit();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .max_size_content = ui.small });
    defer scroll.deinit();
    const wanted = std.mem.trim(u8, query.items, " ");
    var any = false;
    for (views) |b| {
        if (wanted.len > 0 and !matches(b, wanted)) continue;
        any = true;
        const first = if (b.read_only) "not source" else if (b.empty) "empty" else first: {
            const end = std.mem.indexOfScalar(u8, b.text, '\n') orelse b.text.len;
            break :first b.text[0..end];
        };
        const current = b.block == view.block;
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = b.block,
            .expand = .horizontal,
            .background = current,
            .style = .highlight,
            .padding = .{ .x = 6, .y = 1, .w = 6, .h = 1 },
            .tag = if (b.block == 0) "block-0" else null,
        });
        defer line.deinit();
        if (dvui.clicked(line.data(), .{})) goTo(b.block);
        const faint: ?dvui.ColorOrGradient = if (b.empty or b.read_only) .{ .color = dock.muted() } else null;
        dvui.label(@src(), "{d}", .{b.block}, .{ .font = .theme(.mono), .min_size_content = .{ .w = 36 }, .color_text = faint });
        dvui.labelNoFmt(@src(), first, .{}, .{ .font = .theme(.mono), .color_text = faint });
    }
    if (!any) dvui.labelNoFmt(@src(), "No block has that", .{}, .{ .color_text = .{ .color = dock.muted() }, .padding = .all(6) });
}

/// a block whose text has `wanted`, ignoring case, or whose number it is
fn matches(b: Sim.BlockView, wanted: []const u8) bool {
    if (std.fmt.parseInt(usize, wanted, 10)) |n| {
        if (n == b.block) return true;
    } else |_| {}
    if (wanted.len > b.text.len) return false;
    for (0..b.text.len - wanted.len + 1) |at| {
        if (std.ascii.eqlIgnoreCase(b.text[at..][0..wanted.len], wanted)) return true;
    }
    return false;
}

/// Gives the block the keys, next frame
pub fn focusBlock() void {
    focus_block = true;
}

fn goTo(n: usize) void {
    ui.sim.editor.goTo(n) catch return ui.say("There is no such block", .{});
    focus_block = true;
    stale = true;
}

// ---------- the block ----------

fn head(view: Sim.EditorView) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 } });
    defer bar.deinit();
    dvui.label(@src(), "Block {d}", .{view.block}, .{ .font = .theme(.heading), .gravity_y = 0.5, .padding = .{ .x = 4, .w = 8 } });
    const name = if (path) |p| std.fs.path.basename(p) else "a new file";
    dvui.label(@src(), "{s}{s}", .{ name, if (view.unsaved) " (not saved)" else "" }, .{ .color_text = .{ .color = dock.muted() }, .gravity_y = 0.5 });
    if (view.read_only) dvui.labelNoFmt(@src(), "not source", .{}, .{
        .gravity_y = 0.5,
        .background = true,
        .border = .all(1),
        .corners = .round(100),
        .padding = .{ .x = 6, .w = 6 },
        .margin = .{ .x = 6 },
    });

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .gravity_y = 0.5 });
    defer actions.deinit();
    if (dock.button(@src(), "Before", view.block > 0)) goTo(view.block - 1);
    if (dock.button(@src(), "After", view.block + 1 < view.capacity)) goTo(view.block + 1);
    _ = dvui.checkbox(@src(), &show_format, "Blue", .{ .gravity_y = 0.5 });
    _ = dvui.checkbox(@src(), &show_marks, "Marks", .{ .gravity_y = 0.5 });
    if (dvui.button(@src(), "New", .{}, .{})) newFile(view);
    if (dvui.button(@src(), "Compile", .{}, .{ .tag = "compile" })) compile();
    if (dvui.button(@src(), "Save as…", .{}, .{})) save(true);
    if (dvui.button(@src(), "Save", .{}, .{ .style = .highlight })) save(false);
}

/// How a word is drawn: the colorForth colors, darker to read on white, as
/// the web version's
const Palette = struct {
    background: dvui.Color,
    cursor: dvui.Color,
    red: dvui.Color,
    yellow: dvui.Color,
    green: dvui.Color,
    cyan: dvui.Color,
    white: dvui.Color,
    magenta: dvui.Color,
    gray: dvui.Color,
    blue: dvui.Color,

    const light: Palette = blk: {
        @setEvalBranchQuota(10_000);
        break :blk .{
            .background = .fromHex("#ffffff"),
            .cursor = .fromHex("#e7ebf0"),
            .red = .fromHex("#c4122f"),
            .yellow = .fromHex("#8a6200"),
            .green = .fromHex("#1a7f37"),
            .cyan = .fromHex("#0b7285"),
            .white = .fromHex("#3b3f45"),
            .magenta = .fromHex("#a3268f"),
            .gray = .fromHex("#8a8f98"),
            .blue = .fromHex("#2f5bd3"),
        };
    };
    const dark: Palette = blk: {
        @setEvalBranchQuota(10_000);
        break :blk .{
            .background = .fromHex("#050505"),
            .cursor = .fromHex("#303540"),
            .red = .fromHex("#ff5f5f"),
            .yellow = .fromHex("#ffd75f"),
            .green = .fromHex("#5fd75f"),
            .cyan = .fromHex("#5fd7ff"),
            .white = .fromHex("#e8e8e8"),
            .magenta = .fromHex("#ff7fd4"),
            .gray = .fromHex("#8f8f8f"),
            .blue = .fromHex("#7f9cff"),
        };
    };

    fn get() Palette {
        if (style.colors()) |b| return .{
            .background = b.base00,
            .cursor = b.base02,
            .red = b.base08,
            .yellow = b.base0A,
            .green = b.base0B,
            .cyan = b.base0C,
            .white = b.base05,
            .magenta = b.base0E,
            .gray = b.base04,
            .blue = b.base0D,
        };
        return if (dvui.themeGet().dark) dark else light;
    }

    fn of(self: Palette, color: Color) dvui.Color {
        return switch (color) {
            .red => self.red,
            .yellow => self.yellow,
            .green => self.green,
            .cyan => self.cyan,
            .white => self.white,
            .magenta => self.magenta,
            .gray => self.gray,
            .blue => self.blue,
            .none => self.gray,
        };
    }
};

/// the marks `gasim blocks` writes before a word whose color changes
fn mark(color: Color) []const u8 {
    return switch (color) {
        .red => ":",
        .yellow => "[",
        .green => "]",
        .cyan => "\\",
        .white => "(",
        .magenta => "@",
        .gray => "^",
        .blue => "~",
        .none => "",
    };
}

/// where a word is drawn, in the block's own coordinates
const Placed = struct { i: usize, x: f32, y: f32, w: f32, mark: []const u8 };

/// The block's words in lines, as colorForth shows a block, keys going to
/// the editor while it has focus, and a click moving the cursor to a word
fn block(view: Sim.EditorView) void {
    const arena = dvui.currentWindow().arena();
    const font: dvui.Font = blk: {
        const mono: dvui.Font = .theme(.mono);
        break :blk mono.withSize(mono.size * 1.15);
    };
    const char = font.textSize("0");
    const pad = char.w;

    // where each word goes, before the box, which needs the size
    var placed: std.ArrayList(Placed) = .empty;
    var previous: ?Color = null;
    var x: f32 = pad;
    var line: usize = 0;
    var widest: f32 = 0;
    var lines: usize = 1;
    for (view.tokens, 0..) |t, i| {
        defer previous = t.color;
        if (t.line != line) {
            line = t.line;
            x = pad;
            lines = t.line + 1;
        }
        const here = i == view.cursor;
        if (t.color == .blue and !show_format and !here) continue;
        const m = if (show_marks and (previous != t.color or t.color == .red or t.color == .magenta)) mark(t.color) else "";
        var w = font.textSize(m).w + font.textSize(t.text).w;
        if (t.value) |v| w += font.textSize(std.fmt.allocPrint(arena, " {d}", .{v}) catch "").w;
        // a word being typed has room for the caret
        if (here and view.mode == .insert) w = @max(w + char.w, char.w);
        placed.append(arena, .{ .i = i, .x = x, .y = pad / 2 + @as(f32, @floatFromInt(t.line)) * char.h, .w = w, .mark = m }) catch return;
        x += w + char.w;
        widest = @max(widest, x);
    }

    const palette: Palette = .get();
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto }, .{ .expand = .both, .max_size_content = ui.small, .background = true, .color_fill = .{ .color = palette.background } });
    defer scroll.deinit();
    var box = dvui.box(@src(), .{}, .{
        .expand = .both,
        .min_size_content = .{ .w = widest + pad, .h = @as(f32, @floatFromInt(lines)) * char.h + pad },
        .tag = "block",
    });
    defer box.deinit();
    const id = box.data().id;
    block_id = id;
    if (focus_block) {
        dvui.focusWidget(id, null, null);
        focus_block = false;
    }
    const rs = box.data().contentRectScale();
    const focused = dvui.focusedWidgetId() == id;
    if (focused) dvui.wantTextInput(box.data().borderRectScale().r.toNatural());

    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, box.data())) continue;
        switch (e.evt) {
            .mouse => |m| if (m.action == .press and m.button.pointer()) {
                e.handle(@src(), box.data());
                dvui.focusWidget(id, null, e.num);
                const p = rs.pointFromPhysical(m.p);
                for (placed.items) |w| if (p.x >= w.x and p.x < w.x + w.w + char.w and p.y >= w.y and p.y < w.y + char.h) {
                    ui.sim.editor.moveTo(w.i) catch {};
                    break;
                };
            },
            .key => |k| if (k.action != .up) if (keyOf(k)) |editor_key| {
                e.handle(@src(), box.data());
                key(editor_key);
            },
            .text => |t| switch (t.action) {
                .value => |v| {
                    e.handle(@src(), box.data());
                    for (v.txt) |c| if (c >= ' ' and c < 0x7f) key(.char(c));
                },
                .selection => {},
            },
            else => {},
        }
    }
    // what the keys did, drawn this frame
    const after = ui.sim.editing(arena) catch return;
    if (after.tokens.len != view.tokens.len or after.cursor != view.cursor or after.mode != view.mode) dvui.refresh(null, @src(), id);

    const border = dvui.themeGet().color(if (focused) .highlight else .content, if (focused) .fill else .border);
    rs.r.stroke(.all(0), .{ .thickness = rs.s, .color = .{ .color = border } });
    for (placed.items) |w| {
        const t = view.tokens[w.i];
        const here = w.i == view.cursor;
        const typing_here = here and view.mode == .insert;
        if (here and !typing_here) rs.rectToPhysical(.{ .x = w.x - 2, .y = w.y, .w = w.w + 4, .h = char.h }).fill(.all(3 * rs.s), .{ .color = .{ .color = palette.cursor } });
        const color = palette.of(t.color);
        var at = w.x;
        if (w.mark.len > 0) {
            text(rs, font, at, w.y, w.mark, palette.gray);
            at += font.textSize(w.mark).w;
        }
        text(rs, font, at, w.y, t.text, color);
        at += font.textSize(t.text).w;
        if (t.value) |v| {
            const value = std.fmt.allocPrint(arena, " {d}", .{v}) catch "";
            text(rs, font, at, w.y, value, palette.green);
            at += font.textSize(value).w;
        }
        // the caret, after what is typed
        if (typing_here and focused) rs.rectToPhysical(.{ .x = at + 1, .y = w.y + 2, .w = 2, .h = char.h - 4 }).fill(.all(0), .{ .color = .{ .color = color } });
    }
    if (view.tokens.len == 0 and !focused) text(rs, font, pad, pad / 2, "Click here, then i to type", dock.muted());
}

fn text(rs: dvui.RectScale, font: dvui.Font, x: f32, y: f32, s: []const u8, color: dvui.Color) void {
    dvui.renderText(.{ .font = font, .text = s, .rs = rs, .p = rs.pointToPhysical(.{ .x = x, .y = y }), .color = color }) catch {};
}

/// The editor's key for a key event, or null for keys that are not the
/// editor's, or come as text. Alt with a color's letter does what ctrl
/// does, as the web version's.
fn keyOf(k: dvui.Event.Key) ?Editor.Key {
    const ctrl = k.mod.control() or k.mod.alt();
    if (ctrl) {
        const letter: u8 = switch (k.code) {
            .r => 'r',
            .y => 'y',
            .g => 'g',
            .w => 'w',
            .t => 't',
            .v => 'v',
            .b => 'b',
            .s => 's',
            else => return null,
        };
        return .{ .code = .{ .char = letter }, .ctrl = true };
    }
    return .{ .code = switch (k.code) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .escape => .escape,
        .enter => .enter,
        .backspace => .backspace,
        else => return null,
    } };
}

/// Gives the editor a key, and does what it asks
pub fn key(k: Editor.Key) void {
    confirm_new = false;
    stale = true;
    const action = ui.sim.editorKey(k) catch return ui.say("{s}", .{ui.sim.out.written()});
    switch (action) {
        .none => {},
        .save => save(false),
        .compile => compile(),
        .toggle_format => show_format = !show_format,
        .quit => ui.view = .chip,
    }
}

/// the colors, the letter that sets each with ctrl, and what they do
const colors = [_]struct { Color, u8, []const u8 }{
    .{ .red, 'r', "defines a word" },
    .{ .yellow, 'y', "runs as it compiles" },
    .{ .green, 'g', "compiles" },
    .{ .white, 'w', "is a comment" },
    .{ .cyan, 't', "compiles a macro" },
    .{ .magenta, 'v', "is a variable" },
    .{ .blue, 'b', "lays out the block" },
};

fn colorBar(view: Sim.EditorView) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 } });
    defer bar.deinit();
    const palette: Palette = .get();
    for (colors, 0..) |c, n| {
        const color, const letter, _ = c;
        const pressed = dvui.button(@src(), @tagName(color), .{ .grayed = view.read_only }, .{
            .id_extra = n,
            .color_text = .{ .color = palette.of(color) },
            .font = .theme(.mono),
            .tag = if (color == .red) "swatch-red" else null,
        });
        if (pressed and !view.read_only) {
            key(.{ .code = .{ .char = letter }, .ctrl = true });
            focus_block = true;
        }
    }
    dvui.labelNoFmt(@src(), if (view.mode == .insert) "typing" else "moving", .{}, .{ .gravity_y = 0.5, .padding = .{ .x = 10, .w = 6 } });
    dvui.label(@src(), "{d}/255 cells", .{view.cells}, .{ .gravity_y = 0.5, .color_text = .{ .color = dock.muted() } });
    if (view.prefix) |p| dvui.label(@src(), "{d}", .{p}, .{ .gravity_y = 0.5, .padding = .{ .x = 6 } });
    const hints = if (view.mode == .insert)
        "space: next word · enter: new line · esc: done"
    else
        "i a o: type · x y p: cut copy put · u U: undo redo · [ ]: blocks · L: compile · ctrl+s: save";
    dvui.labelNoFmt(@src(), hints, .{}, .{ .gravity_y = 0.5, .gravity_x = 1, .color_text = .{ .color = dock.muted() } });
}

// ---------- the file ----------

/// Compiles the block and the blocks it loads, and starts the chip again
/// with them, as `L` does
fn compile() void {
    ui.running = false;
    ui.sim.compile() catch |err| switch (err) {
        error.CompileFailed => {},
        error.OutOfMemory => return ui.say("Out of memory", .{}),
    };
    ui.say("{s}", .{ui.sim.out.written()});
}

/// Saves the blocks to the file they came from or were saved to last, or
/// where the user says, and with `as`, always where the user says
fn save(as: bool) void {
    confirm_new = false;
    const arena = dvui.currentWindow().arena();
    const where: []const u8 = (if (as) null else path) orelse
        (dvui.dialogNativeFileSave(arena, .{ .title = "Save the blocks", .path = path orelse "blocks.cf" }) catch null) orelse return;
    const view = ui.sim.editing(arena) catch return ui.say("Out of memory", .{});
    const bytes = ui.sim.editor.contents();
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = where, .data = bytes }) catch |err| return ui.say("{s}: {t}", .{ where, err });
    ui.sim.editor.saved();
    if (path == null or !std.mem.eql(u8, path.?, where)) {
        opened(where);
        files.savedAs(where);
    }
    const count = bytes.len / gasim.colorforth.block_size;
    ui.say("Saved {d} blocks{s} to {s}", .{ count, if (view.compressed) ", uncompressed," else "", std.fs.path.basename(where) });
}

/// Starts a new file of blocks, once unsaved changes are let go of by
/// pressing New again
fn newFile(view: Sim.EditorView) void {
    if (view.unsaved and !confirm_new) {
        confirm_new = true;
        return ui.say("The blocks are not saved: press New again to start a new file anyway", .{});
    }
    confirm_new = false;
    ui.sim.openEditor("") catch return ui.say("{s}", .{ui.sim.out.written()});
    if (path) |p| gpa.free(p);
    path = null;
    stale = true;
    focus_block = true;
    ui.say("A new file of blocks", .{});
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const dvui = @import("dvui");
const gasim = @import("gasim");
const Color = gasim.colorforth.Color;
const Editor = gasim.Editor;
const Sim = @import("Sim");
const dock = @import("dock.zig");
const files = @import("files.zig");
const style = @import("style.zig");
const ui = @import("ui.zig");

// ---------- tests, in a hidden window ----------

const testing = dvui.testing;

fn click(tag: []const u8) !void {
    try testing.moveTo(tag);
    try testing.click(.left);
    try testing.settle(ui.frame);
}

test "keys go to the editor, and the color bar recolors words" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    try testing.settle(ui.frame);
    try click("view-editor");
    try expectEqual(.editor, ui.view);

    // a space is the editor's, not to run the chip
    try testing.writeText("i");
    try testing.settle(ui.frame);
    try testing.writeText("dup drop");
    try testing.settle(ui.frame);
    try testing.pressKey(.escape, .none);
    try testing.settle(ui.frame);
    try expect(!ui.running);
    const arena = dvui.currentWindow().arena();
    var view = try ui.sim.editing(arena);
    try expectEqual(2, view.tokens.len);
    try expectEqualStrings("dup", view.tokens[0].text);
    try expectEqual(.normal, view.mode);

    try testing.pressKey(.home, .none);
    try testing.pressKey(.r, .lcontrol);
    try testing.settle(ui.frame);
    view = try ui.sim.editing(arena);
    try expectEqual(.red, view.tokens[0].color);
    try click("swatch-red");
    try ui.saveImage(&w, "editor.png");

    // a .cf file opens in the editor
    const blocks = try std.testing.allocator.dupe(u8, ui.sim.editor.contents());
    defer std.testing.allocator.free(blocks);
    ui.view = .chip;
    try ui.open("blocks.cf", blocks, &.{0}, null);
    try expectEqual(.editor, ui.view);
    try testing.settle(ui.frame);
    view = try ui.sim.editing(dvui.currentWindow().arena());
    try expectEqualStrings("dup", view.tokens[0].text);
}

test "the blocks list searches the blocks" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    ui.view = .editor;
    try testing.settle(ui.frame);
    try expect(matches(.{ .block = 3, .read_only = false, .empty = false, .text = "dup Drop" }, "drop"));
    try expect(matches(.{ .block = 3, .read_only = false, .empty = true, .text = "" }, "3"));
    try expect(!matches(.{ .block = 3, .read_only = false, .empty = false, .text = "dup" }, "swap"));
    try click("block-0");
    try expectEqual(0, ui.sim.editor.block);
}
