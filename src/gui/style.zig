//! The fonts and colors chosen in gui.json, in gasim under XDG_CONFIG_HOME,
//! as the Home Manager module writes it, from Stylix or by hand:
//!
//!     {
//!       "fonts": {
//!         "sans": { "regular": "/path/to/Sans.ttf", "bold": "...",
//!                   "italic": "...", "bold_italic": "..." },
//!         "mono": { "regular": "/path/to/Mono.ttf", "bold": "..." },
//!         "size": 11
//!       },
//!       "colors": { "base00": "#1d2021", ..., "base0F": "#d65d0e" }
//!     }
//!
//! dvui draws only the TrueType and OpenType files it is given, not fonts
//! by name, so each face is a file; those left out are Vera's, or a bold
//! thickened from the regular. The size is in points, as Stylix and desktops
//! give it. The colors are a base16 scheme, which the Auto theme uses in
//! place of Adwaita's; Light and Dark keep Adwaita's, with the fonts chosen.

/// as gui.json has it
const Config = struct {
    fonts: struct {
        sans: Faces = .{},
        mono: Faces = .{},
        size: ?f32 = null,
    } = .{},
    colors: ?Scheme = null,
};

/// the files of a family's faces
const Faces = struct {
    regular: ?[]const u8 = null,
    bold: ?[]const u8 = null,
    italic: ?[]const u8 = null,
    bold_italic: ?[]const u8 = null,
};

/// a base16 scheme, each color as hex, with or without a #; `dark` when the
/// scheme says, else from base00
const Scheme = struct {
    dark: ?bool = null,
    base00: []const u8,
    base01: []const u8,
    base02: []const u8,
    base03: []const u8,
    base04: []const u8,
    base05: []const u8,
    base06: []const u8,
    base07: []const u8,
    base08: []const u8,
    base09: []const u8,
    base0A: []const u8,
    base0B: []const u8,
    base0C: []const u8,
    base0D: []const u8,
    base0E: []const u8,
    base0F: []const u8,
};

/// a base16 scheme's colors, by the base16 guidelines' roles
pub const Base16 = struct {
    dark: bool,
    /// backgrounds: the default, a lighter one, the selection
    base00: Color,
    base01: Color,
    base02: Color,
    /// comments and borders, then dark foreground
    base03: Color,
    base04: Color,
    /// foregrounds: the default, then lighter
    base05: Color,
    base06: Color,
    base07: Color,
    /// red, orange, yellow, green, cyan, blue, magenta, brown
    base08: Color,
    base09: Color,
    base0A: Color,
    base0B: Color,
    base0C: Color,
    base0D: Color,
    base0E: Color,
    base0F: Color,

    fn parse(s: Scheme) !Base16 {
        var b: Base16 = undefined;
        inline for (@typeInfo(Scheme).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "dark")) continue;
            @field(b, name) = Color.tryFromHex(@field(s, name)) catch return error.BadColor;
        }
        b.dark = s.dark orelse (b.base00.brightness() < 0.5);
        return b;
    }

    /// dvui's theme in these colors, after Adwaita's of the same darkness
    fn theme(b: Base16) dvui.Theme {
        var t = if (b.dark) dvui.Theme.builtin.adwaita_dark else dvui.Theme.builtin.adwaita_light;
        t.name = "gui.json";
        t.focus = b.base0D;
        t.fill = b.base00;
        // dvui lightens or darkens these from the fill, for its darkness
        t.fill_hover = null;
        t.fill_press = null;
        t.text = b.base05;
        t.text_select = b.base02;
        t.border = b.base03;
        t.control = .{ .fill = b.base02 };
        t.window = .{ .fill = b.base01 };
        t.highlight = .{ .fill = b.base0D, .text = b.base00, .border = b.base0D };
        t.err = .{ .fill = b.base08, .text = b.base00, .border = b.base08 };
        return t;
    }
};

const sans = "gasim sans";
const mono = "gasim mono";

/// what gui.json gave, kept for the run
var size: ?f32 = null;
var has_sans = false;
var has_mono = false;
var scheme: ?Base16 = null;

/// Reads gui.json, adding its fonts to the window; a file missing is none
/// chosen, and one wrong is said, keeping what else it gives
pub fn load(win: *dvui.Window, path: []const u8) void {
    const a = win.arena();
    const bytes = Io.Dir.cwd().readFileAlloc(dvui.io, path, a, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return ui.say("{s}: {t}", .{ path, err }),
    };
    const c = std.json.parseFromSliceLeaky(Config, a, bytes, .{ .ignore_unknown_fields = true }) catch |err| return ui.say("{s}: {t}", .{ path, err });
    size = c.fonts.size;
    has_sans = add(win, sans, c.fonts.sans);
    has_mono = add(win, mono, c.fonts.mono);
    scheme = if (c.colors) |s| Base16.parse(s) catch return ui.say("{s}: a color isn't hex, such as #1d2021", .{path}) else null;
}

/// Adds a family's faces, whether it has the regular
fn add(win: *dvui.Window, family: []const u8, faces: Faces) bool {
    const regular = faces.regular orelse return false;
    if (!addFace(win, family, .normal, .normal, regular)) return false;
    if (faces.bold) |p| _ = addFace(win, family, .bold, .normal, p);
    if (faces.italic) |p| _ = addFace(win, family, .normal, .italic, p);
    if (faces.bold_italic) |p| _ = addFace(win, family, .bold, .italic, p);
    return true;
}

/// Adds a face once FreeType opens it, as `Window.addFont` does
fn addFace(win: *dvui.Window, family: []const u8, weight: dvui.Font.Weight, style: dvui.Font.Style, path: []const u8) bool {
    const bytes = Io.Dir.cwd().readFileAlloc(dvui.io, path, win.gpa, .limited(64 * 1024 * 1024)) catch |err| {
        ui.say("{s}: {t}", .{ path, err });
        return false;
    };
    const source: dvui.Font.Source = .{ .family = dvui.Font.array(family), .weight = weight, .style = style, .bytes = bytes, .allocator = win.gpa };
    var entry = dvui.Font.Cache.Entry.init(win.gpa, source, source.font(), false) catch {
        win.gpa.free(bytes);
        ui.say("{s}: not a font dvui can draw", .{path});
        return false;
    };
    entry.deinit(win.gpa, win.backend);
    win.fonts.database.append(win.gpa, source) catch {
        win.gpa.free(bytes);
        return false;
    };
    return true;
}

/// The theme to show, in gui.json's colors when Auto has them, with its fonts
pub fn theme(dark: bool) dvui.Theme {
    var t = if (colors()) |b| b.theme() else if (dark) dvui.Theme.builtin.adwaita_dark else dvui.Theme.builtin.adwaita_light;
    // dvui's size is a capital M's height in pixels: near 0.7 of an em
    const body = if (size) |pt| pt * 96.0 / 72.0 * 0.7 else t.font_body.size;
    if (has_sans) {
        t.font_body = .find(.{ .family = sans, .size = body });
        t.font_heading = .find(.{ .family = sans, .size = body, .weight = .bold });
        t.font_title = .find(.{ .family = sans, .size = body + 2 });
    } else {
        t.font_body = t.font_body.withSize(body);
        t.font_heading = t.font_heading.withSize(body);
        t.font_title = t.font_title.withSize(body + 2);
    }
    t.font_mono = if (has_mono) .find(.{ .family = mono, .size = body }) else t.font_mono.withSize(body);
    return t;
}

/// gui.json's colors, while the theme shown is theirs
pub fn colors() ?Base16 {
    return if (help.theme == .auto) scheme else null;
}

/// Forgets what gui.json gave, for tests
fn reset() void {
    size = null;
    has_sans = false;
    has_mono = false;
    scheme = null;
}

test "gui.json's colors are Auto's theme, and its fonts every theme's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);

    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    defer reset();
    defer help.theme = .auto;

    const win = dvui.currentWindow();
    const json = try std.fmt.allocPrint(win.arena(),
        \\{{"fonts": {{"mono": {{"regular": "{s}"}}, "size": 12}},
        \\ "colors": {{"base00": "282828", "base01": "#3c3836", "base02": "#504945", "base03": "#665c54",
        \\  "base04": "#bdae93", "base05": "#d5c4a1", "base06": "#ebdbb2", "base07": "#fbf1c7",
        \\  "base08": "#fb4934", "base09": "#fe8019", "base0A": "#fabd2f", "base0B": "#b8bb26",
        \\  "base0C": "#8ec07c", "base0D": "#83a598", "base0E": "#d3869b", "base0F": "#d65d0e"}}}}
    , .{try std.fs.path.join(win.arena(), &.{ dir, "mono.ttf" })});
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "gui.json", .data = json });
    // a font of dvui's own, as a file
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "mono.ttf", .data = dvui.Font.Source.fallback.bytes });
    load(win, try std.fs.path.join(win.arena(), &.{ dir, "gui.json" }));

    help.theme = .auto;
    help.apply();
    try testing.settle(ui.frame);
    const t = dvui.themeGet();
    try expect(t.dark);
    try expectEqual(Color.fromHex("#282828"), t.fill);
    try expectEqual(Color.fromHex("#83a598"), t.highlight.fill.?);
    try expectEqualStrings(mono, t.font_mono.familyName());
    try expect(dvui.Font.theme(.mono).findSource() != null);
    try expectEqual(12 * 96.0 / 72.0 * 0.7, t.font_body.size);
    try ui.saveImage(&w, "gui-json.png");

    help.theme = .light;
    help.apply();
    try expect(!dvui.themeGet().dark);
    try expectEqual(dvui.Theme.builtin.adwaita_light.fill, dvui.themeGet().fill);
    try expectEqualStrings(mono, dvui.themeGet().font_mono.familyName());
    try expect(colors() == null);
}

test "a font that isn't one is said, and Vera kept" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);

    var w = try testing.init(.{ .window_size = .{ .w = 1400, .h = 900 } });
    defer w.deinit();
    try ui.startWith(ui.upcase);
    defer ui.stop();
    defer reset();

    const win = dvui.currentWindow();
    // gui.json itself, as the font
    const json_path = try std.fs.path.join(win.arena(), &.{ dir, "gui.json" });
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "gui.json", .data = try std.fmt.allocPrint(win.arena(), "{{\"fonts\": {{\"sans\": {{\"regular\": \"{s}\"}}}}}}", .{json_path}) });
    // FreeType's warning, which is what's tested
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    load(win, json_path);
    std.testing.log_level = level;
    try expect(!has_sans);
    try expect(std.mem.endsWith(u8, ui.message, "not a font dvui can draw"));
    help.apply();
    try expectEqualStrings("Vera Sans", dvui.themeGet().font_body.familyName());
}

const std = @import("std");
const Io = std.Io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const dvui = @import("dvui");
const Color = dvui.Color;
const testing = dvui.testing;
const help = @import("help.zig");
const ui = @import("ui.zig");
