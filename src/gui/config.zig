//! Reads the GUI's settings from gui.json, in gasim under XDG_CONFIG_HOME.
//! You can write the file yourself, or the Home Manager module writes it.
//! It holds the fonts and colors, which style.zig uses, and whether to show
//! the Examples menu.
//!
//!     {
//!       "fonts": { ... },
//!       "colors": { ... },
//!       "examples": { "menu": false }
//!     }
//!
//! Every setting is optional. The GUI never writes this file, because the
//! one from Home Manager is a read-only link into the Nix store.

/// The settings in gui.json.
const Config = struct {
    fonts: style.Fonts = .{},
    colors: ?style.Scheme = null,
    examples: struct {
        /// Whether to show the Examples menu, if there are examples.
        menu: bool = true,
    } = .{},
};

/// Reads gui.json and applies its settings. If the file is missing, the GUI
/// keeps its defaults. If the file has an error, the GUI shows it.
pub fn load(win: *dvui.Window, path: []const u8) void {
    const a = win.arena();
    const bytes = Io.Dir.cwd().readFileAlloc(dvui.io, path, a, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return ui.say("{s}: {t}", .{ path, err }),
    };
    const c = std.json.parseFromSliceLeaky(Config, a, bytes, .{ .ignore_unknown_fields = true }) catch |err| return ui.say("{s}: {t}", .{ path, err });
    files.examples_menu = c.examples.menu;
    style.set(win, path, c.fonts, c.colors);
}

test "gui.json can leave out the Examples menu" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);

    var w = try dvui.testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    defer files.examples_menu = true;

    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "gui.json", .data = "{\"examples\": {\"menu\": false}}" });
    load(dvui.currentWindow(), try std.fs.path.join(dvui.currentWindow().arena(), &.{ dir, "gui.json" }));
    try dvui.testing.settle(ui.frame);
    try std.testing.expect(files.exampleList().len > 0);
    try std.testing.expectEqual(null, dvui.tagGet("examples"));
}

const std = @import("std");
const Io = std.Io;

const dvui = @import("dvui");
const files = @import("files.zig");
const style = @import("style.zig");
const ui = @import("ui.zig");
