//! The keys, shown for the view, and the theme, after the web version's
//! help dialog and theme toggle

pub var open = false;

const chip_keys = [_][2][]const u8{
    .{ "space", "Run or pause" },
    .{ "s", "Step the next node to run" },
    .{ "shift+s", "Take a step for each node that can run, the furthest behind first" },
    .{ "n", "Step the selected node" },
    .{ "z", "Go back before the last step or run" },
    .{ "arrows or h j k l", "Select a node" },
    .{ "e", "The colorForth editor, and q in it to come back" },
    .{ "f", "Type at the arrayForth prompt" },
    .{ "c", "Type into the console" },
    .{ "esc", "Stop typing" },
    .{ "tab", "Complete a word at the prompt" },
    .{ "up and down", "Lines typed before, at the prompt" },
    .{ "? or F1", "Show these keys" },
};

const editor_keys = [_][2][]const u8{
    .{ "h l, or left right", "The word before or after" },
    .{ "j k, or down up", "The next or last red word" },
    .{ "0 $, or home end", "The first or last word" },
    .{ "[ ], or page up down", "The block before or after" },
    .{ "a number, then g", "Go to that block" },
    .{ "i a", "Type a word before or after this one" },
    .{ "o O", "Type a red word on a line after or before" },
    .{ "space, enter, esc", "The next word, a new line, done typing" },
    .{ "x X", "Cut this word, or the one before" },
    .{ "y p P", "Copy, and put after or before" },
    .{ "u U", "Undo and redo" },
    .{ "R Y G W C M B", "Color this word" },
    .{ "ctrl or alt + r y g w t v b", "Color the word, as it is typed too" },
    .{ "L", "Compile the block and start the chip again" },
    .{ "ctrl+s, or s", "Save" },
    .{ "f", "Show or hide blue words" },
    .{ "q", "Back to the chip" },
    .{ "F1", "Show these keys" },
};

pub fn dialog() void {
    if (!open) return;
    var win = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{ .max_size_content = .width(640), .tag = "help-window" });
    defer win.deinit();
    win.autoSize();
    const editing = ui.view == .editor;
    win.dragAreaSet(dvui.windowHeader(if (editing) "The editor's keys" else "Keys", "", &open));
    var body = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .all(10) });
    defer body.deinit();
    const rows: []const [2][]const u8 = if (editing) &editor_keys else &chip_keys;
    for (rows, 0..) |r, k| {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = k, .expand = .horizontal });
        defer line.deinit();
        dvui.labelNoFmt(@src(), r[0], .{}, .{ .font = .theme(.mono), .min_size_content = .{ .w = 190 } });
        dvui.labelNoFmt(@src(), r[1], .{}, .{});
    }
    if (!editing) dvui.labelNoFmt(@src(), "Drop a file on the window to open it. Open… and dropping take a .txt file, or pFDISK.blk, as the ROM.", .{}, .{ .color_text = .{ .color = dock.muted() }, .padding = .{ .y = 8 } });
    for (dvui.events()) |*e| switch (e.evt) {
        .key => |k| if (!e.handled and k.action == .down and k.code == .escape) {
            e.handle(@src(), win.data());
            open = false;
        },
        else => {},
    };
}

// ---------- the theme ----------

pub const Theme = enum { auto, light, dark };
pub var theme: Theme = .auto;

/// Sets the theme chosen, or with auto, gui.json's colors or the system's
pub fn apply() void {
    const dark = switch (theme) {
        .auto => (dvui.currentWindow().backend.preferredColorScheme() orelse .light) == .dark,
        .light => false,
        .dark => true,
    };
    dvui.themeSet(style.theme(dark));
}

pub fn themeButton() void {
    const t: ui.Tool = switch (theme) {
        .auto => .{ .label = "Auto", .icon = icons.computer_desktop, .tip = "Theme: auto" },
        .light => .{ .label = "Light", .icon = icons.sun, .tip = "Theme: light" },
        .dark => .{ .label = "Dark", .icon = icons.moon, .tip = "Theme: dark" },
    };
    if (ui.tool(@src(), t, .{ .tag = "theme" })) {
        theme = switch (theme) {
            .auto => .light,
            .light => .dark,
            .dark => .auto,
        };
        apply();
    }
}

const dvui = @import("dvui");
const dock = @import("dock.zig");
const icons = @import("icons");
const style = @import("style.zig");
const ui = @import("ui.zig");
