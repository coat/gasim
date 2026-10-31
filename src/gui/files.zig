//! Files, after the web version's toolbar: opening them, the files opened
//! before and the examples, the blocks to load, and the ROM. And the
//! workspace, kept between runs: the file, the selection, breakpoints and
//! watches, the prompt's history, the layout and the theme.

/// where gasim keeps what lasts between runs; none in tests
pub const Dirs = struct {
    /// the ROM, ga144.txt, as the TUI saves it
    data: []const u8,
    /// the GUI's workspace, gui.json
    state: []const u8,
};

/// a file to load again: where it is, and its blocks to load
const File = struct {
    /// a path, or an example's name
    path: []const u8,
    loads: []const u32 = &.{0},
    example: bool = false,
};

/// files opened before kept, as the web version keeps
const recent_capacity = 8;

var gpa: Allocator = undefined;
var dirs: ?Dirs = null;
/// what `file` and `recent` point into, owned
var arena: std.heap.ArenaAllocator = undefined;
pub var file: ?File = null;
/// the latest first
var recent: std.ArrayList(File) = .empty;
/// the blocks to load, as typed
var loads_text: std.ArrayList(u8) = .empty;
pub var loads_id: ?dvui.Id = null;

pub const Rom = enum {
    none,
    /// with --rom
    given,
    /// in the data directory, saved by the TUI or here
    saved,
};
pub var rom: Rom = .none;
var rom_open = false;

pub fn start(allocator: Allocator, d: ?Dirs) void {
    gpa = allocator;
    dirs = d;
    arena = .init(gpa);
    file = null;
    recent = .empty;
    loads_text = .empty;
    loads_id = null;
    rom = .none;
    rom_open = false;
    dropped = null;
}

pub fn stop() void {
    keepWorkspace();
    recent.deinit(gpa);
    loads_text.deinit(gpa);
    arena.deinit();
}

fn read(path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(dvui.io, path, dvui.currentWindow().arena(), .limited(max_file_len));
}

const max_file_len = 16 * 1024 * 1024;

/// whether a key is being typed into the blocks to load
pub fn typing() bool {
    const focused = dvui.focusedWidgetId() orelse return false;
    return focused == loads_id;
}

/// a ROM dump, or arrayForth 3's disk to assemble the ROM from, rather
/// than a program
fn isRom(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    return std.ascii.endsWithIgnoreCase(name, ".txt") or std.ascii.eqlIgnoreCase(name, "pFDISK.blk");
}

/// Opens a file: as the ROM, if it is one, or loads it onto a new chip,
/// keeping it to open again, with the blocks it was loaded with last
pub fn open(path: []const u8) void {
    if (isRom(path)) return giveRom(path);
    const bytes = read(path) catch |err| return ui.say("{s}: {t}", .{ path, err });
    const loads = for (recent.items) |r| {
        if (std.mem.eql(u8, r.path, path)) break r.loads;
    } else &[_]u32{0};
    load(.{ .path = path, .loads = loads }, bytes);
}

/// a file dropped on the window, to open in the next frame
var dropped_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
var dropped: ?[]const u8 = null;

/// Keeps a file dropped on the window to open in the next frame, the first
/// of several dropped at once, as the web version takes
pub fn drop(path: []const u8) void {
    if (dropped != null or path.len > dropped_buffer.len) return;
    @memcpy(dropped_buffer[0..path.len], path);
    dropped = dropped_buffer[0..path.len];
}

/// Opens the file dropped since the last frame, if there is one
pub fn openDropped() void {
    const path = dropped orelse return;
    dropped = null;
    open(path);
}

pub fn openExample(e: examples.Example) void {
    load(.{ .path = e.name, .example = true }, e.bytes);
}

/// Loads the file again, from disk unless it is an example, with the
/// blocks typed
pub fn reload() void {
    const f = file orelse return;
    if (f.example) {
        for (examples.all) |e| if (std.mem.eql(u8, e.name, f.path)) return load(f, e.bytes);
        return;
    }
    const bytes = read(f.path) catch |err| return ui.say("{s}: {t}", .{ f.path, err });
    load(f, bytes);
}

fn load(f: File, bytes: []const u8) void {
    const kept: File = .{
        .path = arena.allocator().dupe(u8, f.path) catch return ui.say("Out of memory", .{}),
        .loads = arena.allocator().dupe(u32, f.loads) catch return ui.say("Out of memory", .{}),
        .example = f.example,
    };
    file = kept;
    setLoadsText(kept.loads);
    if (!kept.example) keepRecent(kept);
    ui.open(kept.path, bytes, kept.loads, if (kept.example) null else kept.path) catch ui.say("Out of memory", .{});
}

fn keepRecent(f: File) void {
    for (recent.items, 0..) |r, k| if (std.mem.eql(u8, r.path, f.path)) {
        _ = recent.orderedRemove(k);
        break;
    };
    while (recent.items.len >= recent_capacity) _ = recent.pop();
    recent.insert(gpa, 0, f) catch {};
}

/// The colorForth file the editor saved to, as the file open, to open again
pub fn savedAs(path: []const u8) void {
    const f: File = .{
        .path = arena.allocator().dupe(u8, path) catch return,
        .loads = if (file) |open_file| open_file.loads else &[_]u32{0},
    };
    file = f;
    keepRecent(f);
}

fn setLoadsText(loads: []const u32) void {
    loads_text.clearRetainingCapacity();
    for (loads, 0..) |n, k| loads_text.print(gpa, "{s}{d}", .{ if (k > 0) " " else "", n }) catch {};
}

/// whether a file has blocks to choose which to load
fn hasBlocks(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".blk") or std.mem.endsWith(u8, path, ".cf");
}

/// Asks where a file is, and opens it
fn pick() void {
    const a = dvui.currentWindow().arena();
    const path = dvui.dialogNativeFileOpen(a, .{
        .title = "Open a file",
        .filters = &.{ "*.ga", "*.af", "*.blk", "*.cf", "*.txt" },
        .filter_description = "gasim files, or a ROM",
    }) catch null orelse return;
    open(path);
}

/// Open…, the files opened before, the examples, the file, and its blocks
pub fn toolbar() void {
    if (dvui.button(@src(), "Open…", .{}, .{ .tag = "open" })) pick();
    {
        var m = dvui.menu(@src(), .horizontal, .{ .gravity_y = 0.5 });
        defer m.deinit();
        if (recent.items.len > 0) if (dvui.menuItemLabel(@src(), "Recent", .{ .submenu = true }, .{ .tag = "recent" })) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            for (recent.items, 0..) |f, k| {
                if (dvui.menuItemLabel(@src(), f.path, .{}, .{ .id_extra = k, .expand = .horizontal }) != null) {
                    m.close();
                    open(f.path);
                    break;
                }
            }
            if (dvui.menuItemLabel(@src(), "Forget these files", .{}, .{ .expand = .horizontal, .color_text = .{ .color = dock.muted() } }) != null) {
                m.close();
                recent.clearRetainingCapacity();
            }
        };
        if (dvui.menuItemLabel(@src(), "Examples", .{ .submenu = true }, .{ .tag = "examples" })) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            for (examples.all, 0..) |e, k| {
                var item = dvui.menuItem(@src(), .{}, .{ .id_extra = k, .expand = .horizontal, .tag = if (k == 0) "example-0" else null });
                defer item.deinit();
                {
                    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                    defer line.deinit();
                    dvui.labelNoFmt(@src(), e.name, .{}, .{ .font = .theme(.mono), .min_size_content = .{ .w = 110 }, .gravity_y = 0.5 });
                    dvui.labelNoFmt(@src(), e.about, .{}, .{ .color_text = .{ .color = dock.muted() }, .padding = .{ .x = 12 }, .gravity_y = 0.5 });
                }
                if (item.activated) {
                    m.close();
                    openExample(e);
                }
            }
        }
    }
    const f = file orelse return;
    dvui.labelNoFmt(@src(), std.fs.path.basename(f.path), .{}, .{ .gravity_y = 0.5, .font = .theme(.mono), .padding = .{ .x = 6, .w = 6 } });
    if (!hasBlocks(f.path)) return;
    dvui.labelNoFmt(@src(), "Blocks", .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = dock.muted() } });
    const src = @src();
    loads_id = dvui.parentGet().extendId(src, 0);
    var te = dvui.textEntry(src, .{ .text = .{ .array_list = .{ .backing = &loads_text, .allocator = gpa, .limit = 64 } } }, .{ .font = .theme(.mono), .min_size_content = .{ .w = 60 }, .max_size_content = .width(90), .gravity_y = 0.5, .tag = "loads" });
    const entered = te.enter_pressed;
    te.deinit();
    if (dvui.button(@src(), "Load", .{}, .{ .gravity_y = 0.5 }) or entered) loadBlocks();
}

/// Loads the file again with the blocks typed, such as 0 or 18 20
fn loadBlocks() void {
    const f = file orelse return;
    var loads: std.ArrayList(u32) = .empty;
    var it = std.mem.tokenizeAny(u8, loads_text.items, " ,\t");
    const a = dvui.currentWindow().arena();
    while (it.next()) |word| {
        const n = std.fmt.parseInt(u32, word, 10) catch return ui.say("Blocks are numbers, such as 0 or 18 20", .{});
        loads.append(a, n) catch return;
    }
    // in the files' arena, as `reload` may fail before `load` copies them
    file = .{ .path = f.path, .loads = arena.allocator().dupe(u32, loads.items) catch return, .example = f.example };
    reload();
}

// ---------- the ROM ----------

/// Reads the ROM from `path`, with --rom, or else the one saved
pub fn findRom(path: ?[]const u8) void {
    if (path) |p| {
        const bytes = read(p) catch |err| return ui.say("{s}: {t}", .{ p, err });
        ui.sim.setRom(bytes) catch return ui.say("{s} is neither a ROM dump nor arrayForth 3's disk", .{p});
        rom = .given;
        return;
    }
    const saved = savedRom() orelse return;
    const bytes = read(saved) catch return;
    ui.sim.setRom(bytes) catch return ui.say("{s} is not a ROM dump", .{saved});
    rom = .saved;
}

/// where the TUI saves the ROM it assembled, and this saves one given
fn savedRom() ?[]const u8 {
    const d = dirs orelse return null;
    return std.fs.path.join(dvui.currentWindow().arena(), &.{ d.data, "ga144.txt" }) catch null;
}

/// Takes a ROM, keeping it for next time, and loads the file again with it
fn giveRom(path: []const u8) void {
    const bytes = read(path) catch |err| return ui.say("{s}: {t}", .{ path, err });
    ui.sim.setRom(bytes) catch return ui.say("{s} is neither a ROM dump nor arrayForth 3's disk", .{std.fs.path.basename(path)});
    rom = if (keepRom()) .saved else .given;
    reload();
    ui.say("ROM read from {s}{s}", .{ std.fs.path.basename(path), if (file != null) ", and the file loaded again" else "" });
}

/// Saves the ROM set, as a dump, where the TUI looks for it too
fn keepRom() bool {
    const path = savedRom() orelse return false;
    const roms = ui.sim.roms orelse return false;
    var text: std.Io.Writer.Allocating = .init(dvui.currentWindow().arena());
    gasim.rom.write(&text.writer, roms) catch return false;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(dvui.io, dir) catch return false;
    Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = text.written() }) catch return false;
    return true;
}

fn forgetRom() void {
    const path = savedRom() orelse return;
    Io.Dir.cwd().deleteFile(dvui.io, path) catch |err| return ui.say("{s}: {t}", .{ path, err });
    rom = .given;
    ui.say("The saved ROM is forgotten, from the next run", .{});
}

pub fn romButton() void {
    if (dvui.button(@src(), if (rom == .none) "No ROM" else "ROM", .{}, .{ .tag = "rom" })) rom_open = true;
}

pub fn romDialog() void {
    if (!rom_open) return;
    var win = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &rom_open }, .{ .max_size_content = .width(520) });
    defer win.deinit();
    win.autoSize();
    win.dragAreaSet(dvui.windowHeader("The ROM", "", &rom_open));
    var body = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .all(10) });
    defer body.deinit();
    paragraph(@src(), switch (rom) {
        .none => "There is no ROM, so code that calls into it, or starts in it, does not load.",
        .given => "The ROM is the one given, with --rom or here.",
        .saved => "The ROM is the one saved, by the TUI when it assembled one, or here.",
    });
    paragraph(@src(), "The ROM is GreenArrays'. Give a dump of it in the format of gasim's --rom, or arrayForth 3's pFDISK.blk to assemble it from.");
    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .y = 8 } });
    defer actions.deinit();
    if (dvui.button(@src(), "Give a ROM…", .{}, .{ .style = .highlight })) {
        const a = dvui.currentWindow().arena();
        if (dvui.dialogNativeFileOpen(a, .{ .title = "Give a ROM", .filters = &.{ "*.txt", "*.blk" } }) catch null) |p| {
            giveRom(p);
            rom_open = false;
        }
    }
    if (rom == .saved and dvui.button(@src(), "Forget the saved ROM", .{}, .{})) forgetRom();
}

fn paragraph(src: std.builtin.SourceLocation, text: []const u8) void {
    var t = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .background = false, .padding = .{ .y = 2, .h = 4 } });
    defer t.deinit();
    t.addText(text, .{});
}

// ---------- the workspace ----------

/// what is kept between runs, in gui.json
const Workspace = struct {
    file: ?File = null,
    recent: []const File = &.{},
    selected: u16 = 0,
    view: ui.View = .chip,
    tiles: ui.Tiles.Mode = .auto,
    breakpoints: []const struct { node: u16, address: u9 } = &.{},
    watches: []const struct { node: u16, port: gasim.Direction, write: bool } = &.{},
    tracing: bool = false,
    tab: dock.Tab = .forth,
    /// lines typed at the prompt, the oldest first
    history: []const []const u8 = &.{},
    theme: help.Theme = .auto,
    panes: ui.Panes = .{},
    show_format: bool = false,
    show_marks: bool = false,
};

fn workspacePath(a: Allocator) ?[]const u8 {
    const d = dirs orelse return null;
    return std.fs.path.join(a, &.{ d.state, "gui.json" }) catch null;
}

/// Takes up where the last run left off, after the ROM is found
pub fn restoreWorkspace() void {
    const a = dvui.currentWindow().arena();
    const path = workspacePath(a) orelse return;
    const bytes = read(path) catch return;
    const w = std.json.parseFromSliceLeaky(Workspace, a, bytes, .{ .ignore_unknown_fields = true }) catch |err| return ui.say("{s}: {t}", .{ path, err });
    // after the file given on the command line, if `main` opened one
    for (w.recent) |r| {
        if (recent.items.len >= recent_capacity) break;
        if (for (recent.items) |kept| {
            if (std.mem.eql(u8, kept.path, r.path)) break true;
        } else false) continue;
        recent.append(gpa, .{
            .path = arena.allocator().dupe(u8, r.path) catch return,
            .loads = arena.allocator().dupe(u32, r.loads) catch return,
        }) catch return;
    }
    help.theme = w.theme;
    ui.panes = w.panes;
    ui.mode = w.tiles;
    dock.tab = w.tab;
    editor.show_format = w.show_format;
    editor.show_marks = w.show_marks;
    for (w.history) |line| dock.remember(line);
    if (w.tracing) debug.setTracing(true);
    // a file given on the command line, which `main` opens before this,
    // wins: the last run's file, and where it was in it, are left
    if (file != null) return;
    if (w.file) |f| {
        if (f.example) {
            for (examples.all) |e| if (std.mem.eql(u8, e.name, f.path)) load(f, e.bytes);
        } else if (read(f.path)) |data| load(f, data) else |_| {}
    }
    const layout = ui.sim.chip.layout;
    for (w.breakpoints) |b| if (layout.index(b.node)) |i| {
        if (!ui.sim.chip.breakpoints.contains(.init(i, b.address))) _ = ui.sim.toggleBreakpoint(i, b.address) catch {};
    };
    for (w.watches) |watch| if (layout.index(watch.node)) |i| {
        if (!ui.sim.chip.watches.contains(.{ .index = i, .direction = watch.port, .write = watch.write })) _ = ui.sim.toggleWatch(i, watch.port, watch.write) catch {};
    };
    if (w.selected < layout.count()) ui.selected = w.selected;
    ui.view = w.view;
}

/// Keeps the workspace for the next run
pub fn keepWorkspace() void {
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const path = workspacePath(a.allocator()) orelse return;
    keep(a.allocator(), path) catch |err| std.log.warn("{s}: {t}, keeping the workspace", .{ path, err });
}

fn keep(a: Allocator, path: []const u8) !void {
    const layout = ui.sim.chip.layout;
    const breakpoints = ui.sim.chip.breakpoints.items();
    const kept_breakpoints = try a.alloc(@typeInfo(@FieldType(Workspace, "breakpoints")).pointer.child, breakpoints.len);
    for (breakpoints, kept_breakpoints) |b, *k| k.* = .{ .node = layout.nodeNumber(b.index), .address = b.address };
    const watches = ui.sim.chip.watches.items();
    const kept_watches = try a.alloc(@typeInfo(@FieldType(Workspace, "watches")).pointer.child, watches.len);
    for (watches, kept_watches) |w, *k| k.* = .{ .node = layout.nodeNumber(w.index), .port = w.direction, .write = w.write };
    const w: Workspace = .{
        .file = file,
        .recent = recent.items,
        .selected = ui.selected,
        .view = ui.view,
        .tiles = ui.mode,
        .breakpoints = kept_breakpoints,
        .watches = kept_watches,
        .tracing = debug.tracing,
        .tab = dock.tab,
        .history = try dock.lines(a),
        .theme = help.theme,
        .panes = ui.panes,
        .show_format = editor.show_format,
        .show_marks = editor.show_marks,
    };
    var out: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try s.write(w);
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(dvui.io, dir);
    try Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = out.written() });
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const dvui = @import("dvui");
const examples = @import("examples");
const gasim = @import("gasim");
const debug = @import("debug.zig");
const dock = @import("dock.zig");
const editor = @import("editor.zig");
const help = @import("help.zig");
const ui = @import("ui.zig");

// ---------- tests, in a hidden window ----------

const testing = dvui.testing;

fn click(tag: []const u8) !void {
    try testing.moveTo(tag);
    try testing.click(.left);
    try testing.settle(ui.frame);
}

test "the examples menu opens an example" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    try testing.settle(ui.frame);
    try click("examples");
    try ui.saveImage(&w, "examples.png");
    try click("example-0");
    try std.testing.expectEqualStrings("hello.ga", file.?.path);
    try std.testing.expect(file.?.example);
    _ = try ui.sim.run(100_000);
    try testing.settle(ui.frame);
    try std.testing.expectEqualStrings("Hello, world!\n", dock.consoleText());
}

test "the blocks to load are numbers" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    openExample(examples.all[2]);
    try testing.settle(ui.frame);
    try std.testing.expectEqual(.editor, ui.view);
    try std.testing.expectEqualStrings("0", loads_text.items);
    loads_text.clearRetainingCapacity();
    try loads_text.appendSlice(gpa, "0 x");
    loadBlocks();
    try std.testing.expectEqualStrings("Blocks are numbers, such as 0 or 18 20", ui.message);
}

test "the workspace lasts between runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);
    const d: Dirs = .{ .data = dir, .state = dir };

    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.start(std.testing.allocator, d);
    openExample(examples.all[0]);
    ui.selected = 5;
    _ = try ui.sim.toggleBreakpoint(5, 3);
    _ = try ui.sim.toggleWatch(1, .right, true);
    dock.remember("1 2 +");
    ui.panes.node = 0.6;
    ui.stop();

    try ui.start(std.testing.allocator, d);
    defer ui.stop();
    restoreWorkspace();
    try testing.settle(ui.frame);
    try std.testing.expectEqualStrings("hello.ga", file.?.path);
    try std.testing.expectEqual(5, ui.selected);
    try std.testing.expect(ui.sim.chip.breakpoints.contains(.init(5, 3)));
    try std.testing.expect(ui.sim.chip.watches.contains(.{ .index = 1, .direction = .right, .write = true }));
    try std.testing.expectEqualStrings("1 2 +", (try dock.lines(std.testing.allocator))[0]);
    try std.testing.expectEqual(0.6, ui.panes.node);
}

test "a file given wins over the last run's, and Recent keeps 8, once each" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);
    const d: Dirs = .{ .data = dir, .state = dir };

    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    var paths: [recent_capacity + 1][]const u8 = undefined;
    for (&paths, 0..) |*p, k| {
        const name = try std.fmt.allocPrint(dvui.currentWindow().arena(), "f{d}.ga", .{k});
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = name, .data = examples.all[0].bytes });
        p.* = try std.fs.path.join(dvui.currentWindow().arena(), &.{ dir, name });
    }

    try ui.start(std.testing.allocator, d);
    for (paths) |p| open(p);
    ui.selected = 5;
    ui.stop();

    // as `main` opens one before taking up the last run
    try ui.start(std.testing.allocator, d);
    defer ui.stop();
    open(paths[3]);
    restoreWorkspace();
    try std.testing.expectEqualStrings(paths[3], file.?.path);
    try std.testing.expectEqual(0, ui.selected);
    try std.testing.expectEqual(recent_capacity, recent.items.len);
    for (recent.items, 0..) |r, k| for (recent.items[k + 1 ..]) |other| {
        try std.testing.expect(!std.mem.eql(u8, r.path, other.path));
    };
}

test "a file dropped on the window opens in the next frame, the first of several" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    var paths: [2][]const u8 = undefined;
    for (&paths, [_][]const u8{ "first.ga", "second.ga" }) |*p, name| {
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = name, .data = examples.all[0].bytes });
        // lasting past the frame, unlike the window's arena
        p.* = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    }
    defer for (paths) |p| std.testing.allocator.free(p);

    try ui.start(std.testing.allocator, null);
    defer ui.stop();
    for (paths) |p| drop(p);
    try testing.settle(ui.frame);
    try std.testing.expectEqualStrings(paths[0], file.?.path);
    try std.testing.expectEqual(null, dropped);
}

test "F1 shows the keys, and e and f go to the editor and the prompt" {
    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    try testing.settle(ui.frame);
    try testing.pressKey(.f1, .none);
    try testing.settle(ui.frame);
    try std.testing.expect(help.open);
    try ui.saveImage(&w, "help.png");
    try testing.pressKey(.escape, .none);
    try testing.settle(ui.frame);
    try std.testing.expect(!help.open);

    try testing.pressKey(.f, .none);
    try testing.settle(ui.frame);
    try std.testing.expect(dock.typing());
    try testing.pressKey(.escape, .none);
    try testing.settle(ui.frame);
    try std.testing.expect(!dock.typing());
    try testing.pressKey(.e, .none);
    try testing.settle(ui.frame);
    try std.testing.expectEqual(.editor, ui.view);
}
