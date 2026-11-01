//! The GUI: the web version's Sim, drawn with dvui in an SDL3 window, as
//! `ui.zig` lays it out.
//!
//!     gasim-gui [--rom <path>] [<file>]

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 1280, .h = 800 },
            .min_size = .{ .w = 320, .h = 240 },
            .title = "gasim",
            .app = "gasim",
            .org = "gasim",
        },
    },
    .initFn = init,
    .deinitFn = deinit,
    .frameFn = ui.frame,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

fn init(win: *dvui.Window) !void {
    const process = dvui.App.main_init.?;
    const arena = process.arena.allocator();
    const environ = process.environ_map;
    const dirs: ?files.Dirs = if (dataDir(arena, environ)) |data| if (stateDir(arena, environ)) |state|
        .{ .data = data, .state = state }
    else
        null else null;
    try ui.start(win.gpa, dirs);
    if (configDir(arena, environ)) |config| style.load(win, try std.fs.path.join(arena, &.{ config, "gui.json" }));

    const args = try process.minimal.args.toSlice(arena);
    var path: ?[]const u8 = null;
    var rom_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--rom") and i + 1 < args.len) {
            i += 1;
            rom_path = args[i];
        } else path = Io.Dir.cwd().realPathFileAlloc(dvui.io, args[i], arena) catch args[i];
    }

    // without --rom, the ROM saved, by the TUI when it last assembled one
    files.findRom(rom_path);
    // a file given wins over the one the last run had
    if (path) |p| files.open(p);
    files.restoreWorkspace();
    help.apply();
    // dvui's SDL backend leaves files dropped on the window unhandled, so
    // SDL hands them over as it queues them
    _ = dvui.backend.c.SDL_AddEventWatch(dropped, null);
}

/// Takes a file dropped on the window, which SDL queues as the main thread
/// pumps events, before the frame that opens it
fn dropped(_: ?*anyopaque, event: [*c]dvui.backend.c.SDL_Event) callconv(.c) bool {
    if (event.*.type == dvui.backend.c.SDL_EVENT_DROP_FILE and event.*.drop.data != null) files.drop(std.mem.span(event.*.drop.data));
    return true;
}

fn deinit(_: *dvui.Window) void {
    dvui.backend.c.SDL_RemoveEventWatch(dropped, null);
    ui.stop();
}

/// where gasim keeps its data, as main.zig finds it: in gasim under
/// XDG_DATA_HOME, or ~/.local/share
fn dataDir(arena: Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    return if (environ.get("XDG_DATA_HOME")) |data|
        std.fs.path.join(arena, &.{ data, "gasim" }) catch null
    else if (builtin.os.tag == .windows)
        std.fs.path.join(arena, &.{ environ.get("LOCALAPPDATA") orelse return null, "gasim" }) catch null
    else
        std.fs.path.join(arena, &.{ environ.get("HOME") orelse return null, ".local", "share", "gasim" }) catch null;
}

/// where gasim keeps its state, as the history of gasim aforth: in gasim under
/// XDG_STATE_HOME, or ~/.local/state
fn stateDir(arena: Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    return if (environ.get("XDG_STATE_HOME")) |state|
        std.fs.path.join(arena, &.{ state, "gasim" }) catch null
    else if (builtin.os.tag == .windows)
        std.fs.path.join(arena, &.{ environ.get("LOCALAPPDATA") orelse return null, "gasim", "state" }) catch null
    else
        std.fs.path.join(arena, &.{ environ.get("HOME") orelse return null, ".local", "state", "gasim" }) catch null;
}

/// where gasim's settings are, the GUI's fonts and colors: in gasim under
/// XDG_CONFIG_HOME, or ~/.config
fn configDir(arena: Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    return if (environ.get("XDG_CONFIG_HOME")) |config|
        std.fs.path.join(arena, &.{ config, "gasim" }) catch null
    else if (builtin.os.tag == .windows)
        std.fs.path.join(arena, &.{ environ.get("APPDATA") orelse return null, "gasim" }) catch null
    else
        std.fs.path.join(arena, &.{ environ.get("HOME") orelse return null, ".config", "gasim" }) catch null;
}

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const dvui = @import("dvui");
const files = @import("files.zig");
const help = @import("help.zig");
const style = @import("style.zig");
const ui = @import("ui.zig");
