//! A terminal user interface for watching and controlling a chip: a map of
//! its nodes, the registers, stacks and memory of the selected node, the
//! console, and arrayForth 3 typed at the chip with the words of its IDE.
//! Panels can be hidden, zoomed to fill the screen, resized and scrolled.
//! A screen of its own edits colorForth blocks, with vim-like keys, and
//! opens and saves files of them from a command line as vim's.
//! Help lists the keys over either screen.

/// bytes of console output kept for display
pub const console_capacity = 16 * 1024;

pub const Options = struct {
    source_path: []const u8,
    /// attached to the chip, with its output writing into a fixed buffer of
    /// `console_capacity` bytes
    console: *Console,
    console_node: u16,
    console_port: Direction,
    /// arrayForth 3 typed into the aaforth panel, if it is shown
    forth: ?Forth = null,
    /// colorForth blocks to edit, of the file opened or a new one
    colorforth: ?ColorForth = null,
};

pub const ColorForth = struct {
    editor: *Editor,
    /// where the blocks are saved, or null for a new file, which saving
    /// names
    path: ?[]const u8,
    /// the file was a compressed arrayForth 2 image, which is saved
    /// uncompressed
    compressed: bool,
};

pub const Forth = struct {
    /// interprets the lines typed, with the selected node as the target of
    /// the IDE's words
    session: *Session,
    /// where the session writes, a fixed buffer of `forth_capacity` bytes
    output: *Io.Writer,
    diagnostic: *const Diagnostic,
    /// keeps the lines typed, which the session's labels refer to
    arena: Allocator,
};

/// bytes of the aaforth panel's output kept for display
pub const forth_capacity = 16 * 1024;

/// lines typed into the aaforth panel that up and down recall
const recall_capacity = 32;

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
};

/// time spent stepping the chip between frames while it runs
const frame_budget: Io.Duration = .fromMilliseconds(15);
/// rounds between checks of the clock while stepping. A node outputs at
/// most a byte a round, so the console has room for this many.
const rounds_per_check = 256;

/// how many times the user can go back, before steps and runs
const history_capacity = 64;

/// width of a node in the map
const cell_width = 4;
/// rows of the node panel above its memory listing
const node_header_rows = 14;
/// rows of the memory listing: a heading and 64 words each for RAM and ROM
const memory_rows = 2 * 65;

const Panel = enum { map, console, forth, node, debug };

/// the chip's panels, or the colorForth editor
const Screen = enum { chip, editor };

/// the border between the left panels and the node panel, or the one above
/// a panel in the left column, by its place in `Tui.stacked`
const Border = union(enum) { columns, rows: usize };

/// a panel in the left column, where it was last drawn
const Stacked = struct { panel: Panel, top: u16, height: u16 };

/// what the debug panel shows: the trace, the breakpoints and watches, or
/// the steps and runs to go back to
const Debug = enum { trace, breakpoints, history };

/// what the chip was saved before, in the history
const Cause = enum {
    step,
    round,
    node,
    run,
    /// a line typed into the aaforth panel
    line,
    compile,

    fn text(self: Cause) []const u8 {
        return switch (self) {
            .step => "a step",
            .round => "a round of steps",
            .node => "a step of one node",
            .run => "a run",
            .line => "a line at the prompt",
            .compile => "compiling a block",
        };
    }
};

/// which tiles the map chooses: tiles of registers where they fit, and
/// numbers otherwise; numbers; or tiles of registers, scrolling where
/// every node does not fit
const MapMode = enum { auto, numbers, registers };

/// bytes of the trace kept
const trace_capacity = 256 * 1024;

const colors = struct {
    const label: vaxis.Style = .{ .fg = .{ .index = 4 } };
    const address: vaxis.Style = .{ .fg = .{ .index = 4 } };
    const raw: vaxis.Style = .{ .fg = .{ .index = 8 } };
    const literal: vaxis.Style = .{ .fg = .{ .index = 3 } };
    const heading: vaxis.Style = .{ .bold = true };
    const focused: vaxis.Style = .{ .fg = .{ .index = 4 } };
    const dim: vaxis.Style = .{ .dim = true };
    const breakpoint: vaxis.Style = .{ .fg = .{ .index = 1 }, .bold = true };
};

/// a key and what it does, for the status bar
const Hint = struct { []const u8, []const u8 };

/// keys listed in the help, under a heading
const help: []const struct { []const u8, []const Hint } = &.{
    .{ "everywhere", &.{
        .{ "F1, ?", "show or hide this help, with ? where it is not typed" },
        .{ "alt+1-5", "the map, console, node, aforth or debug panel, showing it" },
        .{ "ctrl+1-5", "the same, in terminals that report it" },
        .{ "alt+6", "the colorForth editor" },
        .{ "alt+h j k l", "the panel to the left, below, above or right" },
        .{ "ctrl+c", "quit" },
    } },
    .{ "panels, except while typing", &.{
        .{ "space", "run or pause" },
        .{ "s", "step the next node to run, and select it" },
        .{ "S", "a round of steps, the furthest behind first" },
        .{ "n", "step the selected node" },
        .{ "z", "go back to before the last step or run, up to 64 times" },
        .{ "tab, shift+tab", "the next or previous panel" },
        .{ "1 2 3 4 5", "show or hide the map, console, node, aforth and debug panels" },
        .{ "f, esc", "fill the screen with the panel, and go back" },
        .{ "< >", "narrow or widen the panels on the left" },
        .{ "- +", "shorten or lengthen the panel, or the map" },
        .{ "q", "quit" },
    } },
    .{ "map", &.{
        .{ "arrows, h j k l", "select a node, with north up" },
        .{ "t", "tiles: registers if they fit, only numbers, or registers" },
    } },
    .{ "node", &.{
        .{ "up down, j k", "move through memory" },
        .{ "pgup pgdn", "page through memory" },
        .{ "g, home", "follow the word the node is executing" },
        .{ "b", "set or clear a breakpoint on the word under the cursor" },
        .{ "w, then r d l u", "watch reads from a port, or stop watching them" },
        .{ "w, then R D L U", "watch writes to a port, or stop watching them" },
    } },
    .{ "console and aforth", &.{
        .{ "i a, enter", "type" },
        .{ "alt+2, alt+4", "go to the console or aforth, typing" },
        .{ "click the prompt", "type" },
        .{ "up down, j k", "scroll" },
        .{ "pgup pgdn", "page" },
        .{ "g G, home end", "the first or last of the output" },
    } },
    .{ "typing in the console", &.{
        .{ "enter", "send the line" },
        .{ "ctrl+d", "send what is typed without a newline, or end the input" },
        .{ "pgup pgdn", "scroll" },
        .{ "esc", "done" },
    } },
    .{ "typing in aforth", &.{
        .{ "enter", "interpret the line, with the selected node as the target" },
        .{ "tab", "complete a word" },
        .{ "up down", "recall lines typed" },
        .{ "pgup pgdn", "scroll" },
        .{ "esc", "done" },
    } },
    .{ "debug", &.{
        .{ "h l, left right", "trace, breakpoints and watches, or history" },
        .{ "t", "trace or stop, keeping what was traced" },
        .{ "o", "trace only the selected node, or every node" },
        .{ "c", "clear the trace" },
        .{ "w", "save the trace to trace.txt" },
        .{ "pgup pgdn", "scroll the trace" },
        .{ "up down, j k", "choose a breakpoint, watch or step" },
        .{ "enter", "show the breakpoint or watch, or go back to the step" },
        .{ "x X", "remove the breakpoint or watch, or all of them" },
    } },
    .{ "colorForth editor", &.{
        .{ "h l, b w", "the word before or after" },
        .{ "j k", "the next or previous red name" },
        .{ "0 $", "the first or last word" },
        .{ "[ ], 256g", "the block before or after, or block 256" },
        .{ "i a", "type a word before or after the cursor" },
        .{ "o O", "type a new red name on a line below or above" },
        .{ "x X", "delete the word, or the one before it" },
        .{ "y", "copy the word" },
        .{ "p P", "put the last deleted or copied after or before" },
        .{ "u U", "undo, redo" },
        .{ "R Y G W C M B", "red, yellow, green, white, cyan, magenta or blue" },
        .{ "f", "show or hide blue words, which lay out the block" },
        .{ "L", "compile the block and start the chip again with its code" },
        .{ "s, ctrl+s", "save, naming a new file first" },
        .{ ":", "type a command: save, open or quit" },
        .{ "q", "quit" },
    } },
    .{ "the editor's commands", &.{
        .{ ":w, :w file", "save, or save as the file, with :w! over another" },
        .{ ":e file, :e! file", "open a file of blocks, with ! though not saved" },
        .{ ":new, :new!", "start a new file of blocks, with ! though not saved" },
        .{ ":q, :q!, :wq", "quit, though not saved, or after saving" },
        .{ "tab", "complete the name of a .cf file or a directory" },
        .{ "esc", "done" },
    } },
    .{ "typing in the editor", &.{
        .{ "space", "the next word" },
        .{ "enter", "a new red name on the next line" },
        .{ "backspace", "delete a character" },
        .{ "ctrl+r y g w t v b", "red, yellow, green, white, cyan, magenta or blue" },
        .{ "esc", "done" },
    } },
    .{ "mouse", &.{
        .{ "click", "focus a panel, select a node, or move to a word in memory" },
        .{ "click memory's edge", "set or clear a breakpoint" },
        .{ "wheel", "scroll memory, the console, the aaforth panel or this help" },
        .{ "drag a border", "resize panels, or tap it and then where it goes" },
    } },
    .{ "this help", &.{
        .{ "up down, j k", "scroll" },
        .{ "pgup pgdn", "page" },
        .{ "g G, home end", "the top or bottom" },
        .{ "esc, q, ?, F1", "close" },
    } },
};

/// rows of the help: a heading and its keys, with a blank row between
/// headings
const help_rows = rows: {
    var rows: u16 = help.len - 1;
    for (help) |section| rows += 1 + section[1].len;
    break :rows rows;
};

/// columns of the help taken by keys
const help_key_width = 22;

/// the row of the help a heading is on
fn helpRow(heading: []const u8) u16 {
    var row: u16 = 0;
    for (help) |section| {
        if (std.mem.eql(u8, section[0], heading)) break;
        row += 2 + @as(u16, @intCast(section[1].len));
    }
    return row;
}

const Tui = struct {
    io: Io,
    /// for snapshots of the chip, as they are needed
    gpa: Allocator,
    chip: *Chip,
    options: Options,
    /// whether the user wants the chip to run
    running: bool = false,
    /// nothing happened when the chip last advanced, so there is nothing
    /// to do until the user does something
    settled: bool = false,
    /// index of the selected node
    selected: u16,
    screen: Screen = .chip,
    focus: Panel = .map,
    /// whether keys are typed into the console or the aaforth panel, rather
    /// than left to the panels, as in the editor
    inserting: bool = false,
    /// when each panel last had the focus, counting changes of focus, for
    /// moving back to the one left with alt and h j k l
    focused_at: std.EnumArray(Panel, u64) = .initFill(0),
    focus_changes: u64 = 0,
    shown: std.EnumSet(Panel) = .full,
    zoomed: ?Panel = null,
    /// sizes chosen by the user, rather than fitting the chip
    left_width: ?u16 = null,
    /// heights of the map and the panels under it, the last of those shown
    /// taking what is left
    heights: std.EnumArray(Panel, ?u16) = .initFill(null),
    /// a border being moved, by dragging it, or by tapping it and then
    /// where it should go, for touch screens that do not report drags
    dragging: ?Border = null,
    /// whether the border being moved has been dragged
    dragged: bool = false,

    input: [256]u8 = undefined,
    input_len: u8 = 0,
    /// rows of console output scrolled back from the end
    console_scroll: usize = 0,
    /// the line being typed into the aaforth panel, and rows of its output
    /// scrolled back from the end
    forth_input: [256]u8 = undefined,
    forth_input_len: u8 = 0,
    forth_scroll: usize = 0,
    /// lines typed into the aaforth panel, the latest last, and how far back
    /// up has recalled
    recalled: [recall_capacity][]const u8 = undefined,
    recalled_len: usize = 0,
    recalling: usize = 0,
    /// the first row of the memory listing in view, or null to follow
    /// execution
    memory_scroll: ?u16 = null,
    /// the row of the memory listing where breakpoints are set, or null for
    /// the current word
    memory_cursor: ?u16 = null,
    /// the first column and row of the map in view, counting rows from the
    /// north edge
    map_scroll: struct { x: u16 = 0, y: u16 = 0 } = .{},
    /// how the map was last drawn, for the mouse
    tiles: Tiles = .compact,
    map_mode: MapMode = .auto,
    /// arrows for the directions of nodes out of the map's view
    map_more: []const u8 = "",
    /// a message for the status bar, until the next key
    message: ?[]const u8 = null,
    message_buffer: [64]u8 = undefined,
    /// the first row of the help in view, while it is shown
    help_scroll: ?u16 = null,
    /// rows of the help last drawn in view
    help_page: u16 = 1,
    /// the next key chooses a port of the selected node to watch
    choosing_watch: bool = false,
    /// quitting was asked for with unsaved blocks, and asking again quits
    quit_asked: bool = false,
    quit_confirmed: bool = false,
    /// the first row of the editor's block in view
    editor_scroll: u16 = 0,
    /// a command typed in the editor after `:`, while there is one
    command: [256]u8 = undefined,
    command_len: ?u16 = null,
    /// the editor's file, once a command names it
    path_buffer: [Io.Dir.max_path_bytes]u8 = undefined,
    /// whether the editor shows blue words, which lay out the block
    show_format: bool = true,
    /// the chip as it started, which compiling colorForth starts it from
    /// again
    start: ?Chip.Snapshot = null,
    /// the chip before each step or run, to go back to, allocated the first
    /// time each is needed. The `history_len` kept start from the oldest at
    /// `history_start`, and the oldest is dropped to make room. The one after
    /// them is saved before each step or run, and kept once the chip changes.
    history: []?Chip.Snapshot = &.{},
    history_start: usize = 0,
    history_len: usize = 0,
    /// whether the snapshot after those kept was saved before the last step
    /// or run
    pending: bool = false,
    /// what each snapshot in `history` was saved before
    causes: [history_capacity + 1]Cause = undefined,

    debug: Debug = .trace,
    /// the row of the breakpoints or the history chosen, and the first in
    /// view
    debug_cursor: usize = 0,
    debug_first: usize = 0,
    /// the last lines traced, kept once tracing stops, until cleared; the
    /// chip writes to it while tracing
    trace: ?Tail = null,
    /// rows of the trace scrolled back from the end
    trace_scroll: usize = 0,
    /// show only the selected node's lines of the trace
    trace_only_selected: bool = false,

    /// where panels were last drawn, for the mouse
    windows: std.EnumArray(Panel, ?vaxis.Window) = .initFill(null),
    memory_window: ?vaxis.Window = null,
    /// the column of the border between the left panels and the node panel,
    /// and the panels in the left column, top to bottom
    column_border: ?u16 = null,
    stacked: [4]Stacked = undefined,
    stacked_len: usize = 0,

    /// text drawn in a frame, which must last until the frame is rendered
    frame_buffer: [64 * 1024]u8 = undefined,
    frame: std.heap.FixedBufferAllocator = undefined,

    fn init(io: Io, gpa: Allocator, chip: *Chip, options: Options) Tui {
        var tui: Tui = .{ .io = io, .gpa = gpa, .chip = chip, .options = options, .selected = chip.layout.index(options.console_node) orelse 0 };
        if (options.forth == null) tui.shown.remove(.forth);
        // until asked for
        tui.shown.remove(.debug);
        // a file of colorForth was opened to edit it
        if (options.colorforth) |cf| {
            tui.screen = .editor;
            if (cf.compressed) tui.message = "decompressed, and saved uncompressed";
        }
        return tui;
    }

    fn deinit(self: *Tui) void {
        if (self.start) |*s| s.deinit(self.gpa);
        for (self.history) |*snapshot| if (snapshot.*) |*s| s.deinit(self.gpa);
        if (self.trace) |t| {
            self.chip.trace = null;
            self.gpa.free(t.writer.buffer);
        }
    }

    /// formats text that lasts until the next frame
    fn print(self: *Tui, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.frame.allocator(), format, args) catch "…";
    }

    /// formats a message for the status bar
    fn printLasting(self: *Tui, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(&self.message_buffer, format, args) catch "…";
    }

    /// keeps room in the console's output for another `rounds_per_check`
    fn trimOutput(self: *Tui) void {
        const output = self.options.console.output;
        if (output.end <= output.buffer.len - rounds_per_check) return;
        // keep the most recent half
        const keep = output.buffer.len / 2;
        @memmove(output.buffer[0..keep], output.buffer[output.end - keep .. output.end]);
        output.end = keep;
    }

    fn advance(self: *Tui) !bool {
        self.trimOutput();
        return self.chip.advance();
    }

    /// Runs the chip until it settles or the frame's time is up
    fn run(self: *Tui) !void {
        const deadline = Io.Timestamp.now(self.io, .awake).addDuration(frame_budget);
        while (true) {
            for (0..rounds_per_check) |_| {
                if (!try self.advance()) {
                    self.settled = true;
                    return;
                }
                if (self.chip.hit != null) return self.stop();
            }
            if (Io.Timestamp.now(self.io, .awake).compare(.gte, deadline)) return;
        }
    }

    /// pauses at the breakpoint a node reached, or the watched transfer it
    /// made, showing the node
    fn stop(self: *Tui) void {
        const hit = self.chip.hit orelse return;
        self.chip.hit = null;
        self.running = false;
        self.select(hit.index());
        self.memory_scroll = null;
        self.message = self.printLasting("{f}", .{hit.describe(self.chip.layout)});
    }

    /// Handles an event, returning false to quit
    fn handle(self: *Tui, event: Event) !bool {
        // anything the user does may give the chip something to do
        self.settled = false;
        switch (event) {
            .key_press => |k| {
                self.message = null;
                self.quit_confirmed = self.quit_asked;
                self.quit_asked = false;
                // a key ends moving a border by tapping
                self.dragging = null;
                if (k.matches('c', .{ .ctrl = true })) return self.keepOnQuit();
                if (self.help_scroll != null) return self.helpKey(k);
                if (k.matches(vaxis.Key.f1, .{})) return self.openHelp();
                // a digit with alt, or with ctrl where the terminal reports it,
                // focuses a panel, even from the panels that take text
                for ([_]Panel{ .map, .console, .node, .forth, .debug }, "12345") |panel, digit| {
                    if (k.matches(digit, .{ .alt = true }) or k.matches(digit, .{ .ctrl = true })) {
                        self.screen = .chip;
                        self.focusPanel(panel);
                        return true;
                    }
                }
                // and alt with h j k l the panel that way
                if (self.screen == .chip) for ("hjkl", [_][2]i2{ .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 } }) |letter, way| {
                    if (k.matches(letter, .{ .alt = true })) {
                        if (self.neighbor(way[0], way[1])) |panel| self.focusPanel(panel);
                        return true;
                    }
                };
                if (k.matches('6', .{ .alt = true }) or k.matches('6', .{ .ctrl = true })) {
                    if (self.options.colorforth != null) self.screen = .editor;
                    return true;
                }
                if (self.screen == .editor) return self.editorKey(k);
                if (self.inserting and self.focus == .console and try self.consoleKey(k)) return true;
                if (self.inserting and self.focus == .forth and try self.forthKey(k)) return true;
                return self.key(k);
            },
            .mouse => |m| self.mouse(m),
            .winsize => {},
        }
        return true;
    }

    /// Handles keys for the panels and the chip, returning false to quit
    fn key(self: *Tui, k: vaxis.Key) !bool {
        if (self.choosing_watch) {
            self.choosing_watch = false;
            self.chooseWatch(k);
            return true;
        }
        if (k.matches('q', .{})) return self.keepOnQuit();
        if (k.matches('?', .{})) return self.openHelp();
        // matching text would take tab for shift+tab too
        if (k.codepoint == vaxis.Key.tab) self.cycleFocus(if (k.mods.shift) -1 else 1);
        if (k.matches(vaxis.Key.escape, .{})) self.zoomed = null;
        if (k.matches('f', .{})) self.zoomed = if (self.zoomed == null) self.focus else null;
        for ([_]Panel{ .map, .console, .node, .forth, .debug }, "12345") |panel, digit| {
            if (k.matches(digit, .{}) and (panel != .forth or self.options.forth != null)) self.toggle(panel);
        }

        // resizing
        if (k.matches('<', .{})) self.left_width = (self.left_width orelse self.defaultLeftWidth()) -| 2;
        if (k.matches('>', .{})) self.left_width = (self.left_width orelse self.defaultLeftWidth()) + 2;
        if (k.matches('-', .{})) self.resize(-1);
        if (k.matchesAny(&.{ '+', '=' }, .{})) self.resize(1);

        // running and stepping
        if (k.matches(' ', .{})) {
            if (!self.running) self.remember(.run);
            self.running = !self.running;
            // a breakpoint reached while stepping is left behind
            self.chip.hit = null;
        }
        const stepping = k.matches('s', .{}) or k.matches('S', .{}) or k.matches('n', .{});
        if (stepping and self.running) self.message = "pause with space to step";
        if (k.matches('z', .{})) {
            if (self.running) self.message = "pause with space to go back" else self.back();
        }
        if (!self.running) {
            const layout = self.chip.layout;
            if (k.matches('s', .{})) {
                self.remember(.step);
                // the next node to run, which the view follows
                self.trimOutput();
                if (try self.chip.stepNext()) |i| {
                    self.select(i);
                    self.message = self.printLasting("stepped node {d:0>3}", .{layout.nodeNumber(i)});
                } else self.message = "every node is waiting";
            }
            if (k.matches('S', .{})) {
                self.remember(.round);
                self.message = if (try self.advance()) "took a round of steps, the furthest behind first" else "every node is waiting";
            }
            if (k.matches('n', .{})) {
                self.remember(.node);
                self.trimOutput();
                _ = try self.chip.service();
                self.chip.stepNode(self.selected);
                self.memory_scroll = null;
                const waiting = self.chip.nodes[self.selected].suspended;
                self.message = self.printLasting("node {d:0>3} {s}", .{ layout.nodeNumber(self.selected), if (waiting) "is still waiting" else "stepped" });
            }
        }

        if (self.chip.hit != null) self.stop();

        switch (self.focus) {
            .map => self.mapKey(k),
            .node => {
                if (k.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) self.moveCursor(-1);
                if (k.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) self.moveCursor(1);
                if (k.matches(vaxis.Key.page_up, .{})) self.moveCursor(-@as(i32, self.memoryPage()));
                if (k.matches(vaxis.Key.page_down, .{})) self.moveCursor(self.memoryPage());
                if (k.matchesAny(&.{ vaxis.Key.home, 'g' }, .{})) {
                    self.memory_scroll = null;
                    self.memory_cursor = null;
                }
                if (k.matches('b', .{})) {
                    if (self.cursorRow()) |row| {
                        self.toggleBreakpoint(row);
                    } else self.message = "move to a word in memory first";
                }
                if (k.matches('w', .{})) {
                    self.choosing_watch = true;
                    self.message = "watch reads from r d l u, or writes to R D L U";
                }
            },
            .debug => self.debugKey(k),
            .console => self.textKey(k, &self.console_scroll),
            .forth => self.textKey(k, &self.forth_scroll),
        }
        return true;
    }

    /// Handles keys for the console or the aaforth panel when not typing into
    /// it, which scroll its output, or start typing
    fn textKey(self: *Tui, k: vaxis.Key, scroll: *usize) void {
        const panel = self.focus;
        if (k.matchesAny(&.{ 'i', 'a', vaxis.Key.enter }, .{})) self.inserting = true;
        if (k.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) scroll.* += 1;
        if (k.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) scroll.* -|= 1;
        if (k.matches(vaxis.Key.page_up, .{})) scroll.* += self.textPage(panel);
        if (k.matches(vaxis.Key.page_down, .{})) scroll.* -|= self.textPage(panel);
        // drawing stops at the first page
        if (k.matchesAny(&.{ vaxis.Key.home, 'g' }, .{})) scroll.* = std.math.maxInt(usize);
        if (k.matchesAny(&.{ vaxis.Key.end, 'G' }, .{})) scroll.* = 0;
    }

    /// Shows the help, at the editor's keys in the editor
    fn openHelp(self: *Tui) bool {
        self.help_scroll = if (self.screen == .editor) helpRow("colorForth editor") else 0;
        return true;
    }

    /// Handles keys while the help is shown, which scroll and close it
    fn helpKey(self: *Tui, k: vaxis.Key) bool {
        const page: i32 = self.help_page;
        if (k.matchesAny(&.{ vaxis.Key.escape, vaxis.Key.f1, 'q', '?' }, .{})) self.help_scroll = null;
        if (k.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) self.scrollHelp(-1);
        if (k.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) self.scrollHelp(1);
        if (k.matches(vaxis.Key.page_up, .{})) self.scrollHelp(-page);
        if (k.matches(vaxis.Key.page_down, .{})) self.scrollHelp(page);
        if (k.matchesAny(&.{ vaxis.Key.home, 'g' }, .{})) self.help_scroll = 0;
        if (k.matchesAny(&.{ vaxis.Key.end, 'G' }, .{})) self.scrollHelp(help_rows);
        return true;
    }

    fn scrollHelp(self: *Tui, rows: i32) void {
        const first = self.help_scroll orelse return;
        self.help_scroll = @intCast(std.math.clamp(@as(i32, first) + rows, 0, @max(help_rows - @as(i32, self.help_page), 0)));
    }

    fn mapKey(self: *Tui, k: vaxis.Key) void {
        const layout = self.chip.layout;
        const x = self.selected % layout.columns;
        const y = self.selected / layout.columns;
        if (k.matchesAny(&.{ vaxis.Key.left, 'h' }, .{}) and x > 0) self.select(self.selected - 1);
        if (k.matchesAny(&.{ vaxis.Key.right, 'l' }, .{}) and x + 1 < layout.columns) self.select(self.selected + 1);
        // north is up
        if (k.matchesAny(&.{ vaxis.Key.up, 'k' }, .{}) and y + 1 < layout.rows) self.select(self.selected + layout.columns);
        if (k.matchesAny(&.{ vaxis.Key.down, 'j' }, .{}) and y > 0) self.select(self.selected - layout.columns);
        if (k.matches('t', .{})) {
            self.map_mode = switch (self.map_mode) {
                .auto => .numbers,
                .numbers => .registers,
                .registers => .auto,
            };
            self.message = switch (self.map_mode) {
                .auto => "tiles of registers where they fit, and numbers otherwise",
                .numbers => "numbers",
                .registers => "tiles of registers, scrolling where they do not fit",
            };
        }
    }

    /// Keys for the debug panel: h and l choose what it shows, and the rest
    /// act on that
    fn debugKey(self: *Tui, k: vaxis.Key) void {
        const views = std.enums.values(Debug);
        const at: usize = @backingInt(self.debug);
        if (k.matchesAny(&.{ vaxis.Key.left, 'h' }, .{})) self.showDebug(views[(at + views.len - 1) % views.len]);
        if (k.matchesAny(&.{ vaxis.Key.right, 'l' }, .{})) self.showDebug(views[(at + 1) % views.len]);
        switch (self.debug) {
            .trace => {
                if (k.matches('t', .{})) self.setTracing(self.chip.trace == null);
                if (k.matches('o', .{})) self.trace_only_selected = !self.trace_only_selected;
                if (k.matches('c', .{})) if (self.trace) |*t| {
                    t.clear();
                    self.trace_scroll = 0;
                };
                if (k.matches('w', .{})) self.saveTrace();
                if (k.matches(vaxis.Key.page_up, .{})) self.trace_scroll += self.textPage(.debug);
                if (k.matches(vaxis.Key.page_down, .{})) self.trace_scroll -|= self.textPage(.debug);
            },
            .breakpoints, .history => {
                if (k.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) self.debug_cursor -|= 1;
                if (k.matchesAny(&.{ vaxis.Key.down, 'j' }, .{}) and self.debug_cursor + 1 < self.debugRows()) self.debug_cursor += 1;
                if (k.matches(vaxis.Key.enter, .{})) self.chooseDebug();
                if (self.debug == .breakpoints) {
                    if (k.matchesAny(&.{ 'x', vaxis.Key.delete }, .{})) self.removeStop();
                    if (k.matches('X', .{})) {
                        self.chip.breakpoints = .{};
                        self.chip.watches = .{};
                        self.message = "removed every breakpoint and watch";
                    }
                }
            },
        }
    }

    fn showDebug(self: *Tui, view: Debug) void {
        self.debug = view;
        self.debug_cursor = 0;
        self.debug_first = 0;
    }

    /// the rows of the breakpoints and watches, or of the history: now, and
    /// before each step or run kept, the latest first
    fn debugRows(self: *Tui) usize {
        self.keepPaused();
        return switch (self.debug) {
            .trace => 0,
            .breakpoints => self.chip.breakpoints.len + self.chip.watches.len,
            .history => self.history_len + 1,
        };
    }

    /// Selects the node of the breakpoint or watch chosen, showing where the
    /// breakpoint is, or goes back to the moment chosen
    fn chooseDebug(self: *Tui) void {
        const cursor = self.debug_cursor;
        if (cursor >= self.debugRows()) return;
        switch (self.debug) {
            .trace => {},
            .breakpoints => {
                const stops = self.chip.breakpoints.items();
                if (cursor < stops.len) {
                    const b = stops[cursor];
                    self.select(b.index);
                    // one on an I/O register, as --break can set, is not in
                    // the listing
                    if (memoryRow(.fromWord(b.address))) |row| {
                        self.memory_cursor = row;
                        self.memory_scroll = row -| self.memoryPage() / 2;
                    }
                } else self.select(self.chip.watches.items()[cursor - stops.len].index);
            },
            .history => {
                if (cursor == 0) return;
                if (self.running) {
                    self.message = "pause with space to go back";
                    return;
                }
                self.backTo(self.history_len - cursor);
                self.debug_cursor = 0;
            },
        }
    }

    /// removes the breakpoint or watch chosen
    fn removeStop(self: *Tui) void {
        const stops = self.chip.breakpoints.items();
        const cursor = self.debug_cursor;
        if (cursor < stops.len) {
            _ = self.chip.breakpoints.toggle(stops[cursor]) catch {};
        } else if (cursor - stops.len < self.chip.watches.len) {
            _ = self.chip.watches.toggle(self.chip.watches.items()[cursor - stops.len]) catch {};
        } else return;
        self.debug_cursor = @min(self.debug_cursor, self.debugRows() -| 1);
    }

    /// Starts writing a line for each step that runs code, as `--trace`
    /// does, or stops, keeping what was traced
    fn setTracing(self: *Tui, on: bool) void {
        if (on and self.trace == null) {
            const buffer = self.gpa.alloc(u8, trace_capacity) catch {
                self.message = "there is no memory left to trace with";
                return;
            };
            self.trace = .init(buffer);
        }
        self.chip.trace = if (on) &self.trace.?.writer else null;
        self.message = if (on) "tracing each step that runs code, which is slower" else "not tracing";
    }

    /// the start of the selected node's lines of the trace, if only those
    /// show
    fn traceOnly(self: *Tui) ?[]const u8 {
        return if (self.trace_only_selected) self.print("{d:0>3} ", .{self.chip.layout.nodeNumber(self.selected)}) else null;
    }

    /// writes the lines of the trace shown to trace.txt
    fn saveTrace(self: *Tui) void {
        const t = self.trace orelse {
            self.message = "t starts tracing";
            return;
        };
        const only = self.traceOnly();
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, t.writer.buffered(), '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (only) |prefix| if (!std.mem.startsWith(u8, line, prefix)) continue;
            text.appendSlice(self.gpa, line) catch break;
            text.append(self.gpa, '\n') catch break;
            lines += 1;
        }
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = "trace.txt", .data = text.items }) catch |err| {
            self.message = self.printLasting("cannot save trace.txt: {t}", .{err});
            return;
        };
        self.message = self.printLasting("saved {d} lines as trace.txt", .{lines});
    }

    /// Whether to keep going rather than quit, which with blocks not saved
    /// takes asking twice
    fn keepOnQuit(self: *Tui) bool {
        const cf = self.options.colorforth orelse return false;
        if (self.quit_confirmed or !cf.editor.unsaved()) return false;
        self.quit_asked = true;
        self.message = "blocks are not saved: s in the editor saves them, and q again quits";
        return true;
    }

    /// Handles keys in the colorForth editor, returning false to quit
    fn editorKey(self: *Tui, k: vaxis.Key) !bool {
        const editor = self.options.colorforth.?.editor;
        // a key with a name, or the text typed, a character at a time
        var chars: []const u8 = &.{};
        var named: ?Editor.Key = null;
        if (k.mods.alt or k.mods.super or k.mods.hyper or k.mods.meta) return true;
        if (self.command_len != null) return self.commandKey(k);
        if (k.mods.ctrl) {
            if (k.codepoint < 0x80) named = .{ .code = .{ .char = @intCast(k.codepoint) }, .ctrl = true };
        } else if (editorKeyCode(k)) |code| {
            named = .{ .code = code };
        } else if (k.text) |text| {
            // text pasted in normal mode is not keys of the map
            if (editor.mode == .insert or text.len == 1) chars = text;
        }

        if (editor.mode == .normal and named == null and std.mem.eql(u8, chars, "?")) return self.openHelp();
        if (editor.mode == .normal and named == null and std.mem.eql(u8, chars, ":")) {
            editor.prefix = null;
            self.startCommand("");
            return true;
        }
        if (named) |one| return self.editorAction(editor, one);
        for (chars) |c| if (!self.editorAction(editor, .char(c))) return false;
        return true;
    }

    /// the editor's name for a key, unless it is a character
    fn editorKeyCode(k: vaxis.Key) ?Editor.Key.Code {
        if (k.mods.shift) return null;
        return switch (k.codepoint) {
            vaxis.Key.left => .left,
            vaxis.Key.right => .right,
            vaxis.Key.up => .up,
            vaxis.Key.down => .down,
            vaxis.Key.home => .home,
            vaxis.Key.end => .end,
            vaxis.Key.page_up => .page_up,
            vaxis.Key.page_down => .page_down,
            vaxis.Key.escape => .escape,
            vaxis.Key.enter => .enter,
            vaxis.Key.backspace => .backspace,
            else => null,
        };
    }

    /// Gives the editor a key and does what it asks, returning false to quit
    fn editorAction(self: *Tui, editor: *Editor, k: Editor.Key) bool {
        const action = editor.key(k) catch |err| {
            self.message = Editor.describe(err);
            return true;
        };
        switch (action) {
            .none => {},
            .save => if (self.options.colorforth.?.path) |path| {
                _ = self.save(path);
            } else {
                self.startCommand("w ");
                self.message = "name the new file";
            },
            .compile => self.compile(),
            .toggle_format => self.show_format = !self.show_format,
            .quit => return self.keepOnQuit(),
        }
        return true;
    }

    /// Compiles the block being edited, and the blocks it loads, and starts
    /// the chip again as it started, with the code compiled so far, the
    /// block's replacing what it compiled before. An error in the block
    /// moves the cursor to the word.
    fn compile(self: *Tui) void {
        const editor = self.options.colorforth.?.editor;
        const forth = self.options.forth orelse return;
        const start = self.start orelse return;
        forth.session.loadColorForth(editor.contents(), @intCast(editor.block)) catch |err| {
            const place = gasim.colorforth.place(forth.diagnostic.line);
            if (place.block == editor.block and place.token <= editor.len) editor.cursor = place.token - 1;
            self.message = self.printLasting("{t} at {s} in block {d}", .{ err, forth.diagnostic.token, place.block });
            return;
        };
        self.remember(.compile);
        self.chip.restore(&start);
        const assembled = forth.session.assembled();
        var nodes: usize = 0;
        for (assembled.programs) |program| if (program.bin == null) {
            self.chip.setUp(.ofProgram(program), assembled.programs) catch continue;
            nodes += 1;
        };
        self.settled = false;
        self.message = if (assembled.first_difference) |first| self.printLasting("started again with {d} nodes' code, but {d} gray numbers differ, the first {x:0>3} where gasim is at {x:0>3}", .{ nodes, assembled.feedback_differs, first.noted, first.found }) else self.printLasting("compiled, and started the chip again with {d} nodes' code", .{nodes});
    }

    /// Writes the editor's blocks to a file, which becomes theirs, returning
    /// whether they were saved
    fn save(self: *Tui, path: []const u8) bool {
        const cf = &self.options.colorforth.?;
        const contents = cf.editor.contents();
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = contents }) catch |err| {
            self.message = self.printLasting("cannot save {s}: {t}", .{ std.fs.path.basename(path), err });
            return false;
        };
        cf.editor.saved();
        if (cf.path == null or !std.mem.eql(u8, cf.path.?, path)) self.name(path);
        cf.compressed = false;
        self.message = self.printLasting("saved {d} blocks", .{contents.len / gasim.colorforth.block_size});
        return true;
    }

    /// makes `path` the editor's file
    fn name(self: *Tui, path: []const u8) void {
        @memmove(self.path_buffer[0..path.len], path);
        self.options.colorforth.?.path = self.path_buffer[0..path.len];
    }

    /// Opens a file of colorForth blocks, or an arrayForth 2 image, in the
    /// editor, in place of its blocks. A file that does not exist is new, and
    /// saving creates it.
    fn open(self: *Tui, path: []const u8) void {
        const colorforth = gasim.colorforth;
        const cf = &self.options.colorforth.?;
        const editor = cf.editor;
        if (path.len > self.path_buffer.len) {
            self.message = "the file's name is too long";
            return;
        }
        // a compressed image takes less than the blocks it holds, and a
        // file that fills them reaches a limit of their size
        var found = true;
        const read = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(editor.blocks.len + 1)) catch |err| switch (err) {
            error.FileNotFound => read: {
                found = false;
                break :read &.{};
            },
            error.StreamTooLong => {
                self.message = self.printLasting("{s} has more than {d} blocks", .{ std.fs.path.basename(path), editor.capacity() });
                return;
            },
            else => {
                self.message = self.printLasting("cannot open {s}: {t}", .{ std.fs.path.basename(path), err });
                return;
            },
        };
        defer self.gpa.free(read);
        const compressed = colorforth.compressedBlocks(read);
        const count = compressed orelse colorforth.blockCount(read);
        if (count > editor.capacity()) {
            self.message = self.printLasting("{s} has more than {d} blocks", .{ std.fs.path.basename(path), editor.capacity() });
            return;
        }
        // decompressed apart, to leave the blocks as they are if it fails
        const bytes = self.gpa.alloc(u8, count * colorforth.block_size) catch {
            self.message = "out of memory";
            return;
        };
        defer self.gpa.free(bytes);
        if (compressed != null) {
            colorforth.decompress(read, bytes) catch |err| {
                self.message = self.printLasting("cannot decompress {s}: {t}", .{ std.fs.path.basename(path), err });
                return;
            };
        } else {
            @memcpy(bytes[0..read.len], read);
            @memset(bytes[read.len..], 0);
        }
        @memset(editor.blocks, 0);
        @memcpy(editor.blocks[0..bytes.len], bytes);
        editor.open(editor.blocks, count);
        self.name(path);
        cf.compressed = compressed != null;
        self.forgetCompiled();
        self.editor_scroll = 0;
        self.message = if (compressed != null)
            "decompressed, and saved uncompressed"
        else if (!found)
            self.printLasting("{s} is new", .{std.fs.path.basename(path)})
        else
            self.printLasting("opened {d} blocks", .{count});
    }

    /// Starts a new file of blocks, which saving names
    fn newFile(self: *Tui) void {
        const cf = &self.options.colorforth.?;
        @memset(cf.editor.blocks, 0);
        cf.editor.open(cf.editor.blocks, 0);
        cf.path = null;
        cf.compressed = false;
        self.forgetCompiled();
        self.editor_scroll = 0;
        self.message = "a new file of blocks";
    }

    /// forgets the code compiled from the blocks of the file before, so
    /// compiling another file's starts the chip with its code alone
    fn forgetCompiled(self: *Tui) void {
        if (self.options.forth) |forth| forth.session.forgetColorForth();
    }

    /// starts typing a command in the editor, with `text` typed
    fn startCommand(self: *Tui, text: []const u8) void {
        @memcpy(self.command[0..text.len], text);
        self.command_len = @intCast(text.len);
    }

    /// Handles keys typed into the editor's command line, returning false to
    /// quit
    fn commandKey(self: *Tui, k: vaxis.Key) bool {
        const len = &self.command_len.?;
        if (k.matches(vaxis.Key.escape, .{})) {
            self.command_len = null;
        } else if (k.matches(vaxis.Key.backspace, .{})) {
            // as in vim, deleting the last character stops
            if (len.* == 0) self.command_len = null else len.* -= 1;
        } else if (k.matches(vaxis.Key.enter, .{})) {
            const command = self.command[0..len.*];
            self.command_len = null;
            return self.runCommand(command);
        } else if (k.codepoint == vaxis.Key.tab) {
            if (!k.mods.shift) self.completePath();
        } else if (k.text) |text| {
            for (text) |byte| if (len.* < self.command.len and byte >= ' ' and byte < 0x7f) {
                self.command[len.*] = byte;
                len.* += 1;
            };
        }
        return true;
    }

    /// Runs a command typed in the editor, as vim's: `w` saves, as a file if
    /// one is named, `e` opens a file, `new` starts a new one, and `q` quits,
    /// with `!` letting unsaved blocks go or saving over another file, and
    /// `wq` saves and quits, as `x` does when there is anything to save
    fn runCommand(self: *Tui, line: []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " ");
        const end = for (trimmed, 0..) |c, i| {
            if (!std.ascii.isAlphabetic(c)) break i;
        } else trimmed.len;
        const command = trimmed[0..end];
        const forced = end < trimmed.len and trimmed[end] == '!';
        const argument = std.mem.trim(u8, trimmed[end + @intFromBool(forced) ..], " ");
        const cf = self.options.colorforth.?;
        const is = struct {
            fn is(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.is;

        if (command.len == 0) return true;
        if (is(command, "w") or is(command, "write") or is(command, "wq") or is(command, "x")) {
            const quitting = !is(command, "w") and !is(command, "write");
            if (is(command, "x") and argument.len == 0 and !cf.editor.unsaved()) return false;
            const path = if (argument.len > 0) argument else cf.path orelse {
                // and quits once it is named
                self.startCommand(if (quitting) "wq " else "w ");
                self.message = "name the new file";
                return true;
            };
            const another = cf.path == null or !std.mem.eql(u8, cf.path.?, path);
            if (another and !forced) if (Io.Dir.cwd().access(self.io, path, .{})) |_| {
                self.message = self.printLasting("{s} exists: :{s}! saves over it", .{ std.fs.path.basename(path), command });
                return true;
            } else |_| {};
            if (!self.save(path)) return true;
            return !quitting;
        }
        if (is(command, "q") or is(command, "quit")) {
            // as in vim, rather than asking twice
            if (forced or !cf.editor.unsaved()) return false;
            self.message = "blocks are not saved: :w saves them, and :q! quits";
            return true;
        }
        if (is(command, "e") or is(command, "edit") or is(command, "new") or is(command, "enew")) {
            const opening = is(command, "e") or is(command, "edit");
            if (opening and argument.len == 0) {
                self.message = "name the file to open, as :e blocks.cf";
                return true;
            }
            if (!forced and cf.editor.unsaved()) {
                self.message = self.printLasting("blocks are not saved: :w saves them, and :{s}! lets them go", .{command});
                return true;
            }
            if (opening) self.open(argument) else self.newFile();
            return true;
        }
        self.message = self.printLasting("no command {s}: :w, :e, :new or :q", .{command});
        return true;
    }

    /// Completes the name of the file being typed in a command, as far as the
    /// .cf files and directories it could be agree, or lists them when that
    /// adds nothing
    fn completePath(self: *Tui) void {
        const line = self.command[0..self.command_len.?];
        const start = if (std.mem.findScalarLast(u8, line, ' ')) |space| space + 1 else {
            self.message = "complete a file's name after :e or :w";
            return;
        };
        const typed = line[start..];
        const slash = if (std.mem.findScalarLast(u8, typed, '/')) |i| i + 1 else 0;
        const partial = typed[slash..];
        const dir_path = if (slash == 0) "." else typed[0..slash];
        var dir = Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch {
            self.message = "no such directory";
            return;
        };
        defer dir.close(self.io);

        // the names it could be, with a slash after a directory, as many as
        // fit in a message
        var listed_buffer: [256]u8 = undefined;
        var listed: Io.Writer = .fixed(&listed_buffer);
        var common: [256]u8 = undefined;
        var common_len: usize = 0;
        var found: usize = 0;
        var entries = dir.iterate();
        while (entries.next(self.io) catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, partial)) continue;
            // hidden files only when asked for
            if (partial.len == 0 and entry.name[0] == '.') continue;
            // a link, or an entry the file system does not say the kind of,
            // is what it leads to
            const kind = switch (entry.kind) {
                .sym_link, .unknown => if (dir.statFile(self.io, entry.name, .{})) |stat| stat.kind else |_| entry.kind,
                else => entry.kind,
            };
            const directory = kind == .directory;
            if (!directory and !std.mem.endsWith(u8, entry.name, ".cf")) continue;
            if (entry.name.len + 1 > common.len) continue;
            if (found == 0) {
                @memcpy(common[0..entry.name.len], entry.name);
                common_len = entry.name.len;
                if (directory) {
                    common[common_len] = '/';
                    common_len += 1;
                }
            } else common_len = std.mem.indexOfDiff(u8, common[0..common_len], entry.name) orelse common_len;
            found += 1;
            listed.print("{s}{s} ", .{ entry.name, if (directory) "/" else "" }) catch {};
        }
        if (found == 0) {
            self.message = "no .cf file or directory starts with that";
            return;
        }
        if (common_len > partial.len and start + slash + common_len <= self.command.len) {
            @memcpy(self.command[start + slash ..][0..common_len], common[0..common_len]);
            self.command_len = @intCast(start + slash + common_len);
            return;
        }
        const names = std.mem.trimEnd(u8, listed.buffered(), " ");
        const ellipsis = "…";
        if (names.len <= self.message_buffer.len) {
            @memcpy(self.message_buffer[0..names.len], names);
            self.message = self.message_buffer[0..names.len];
        } else {
            const cut = self.message_buffer.len - ellipsis.len;
            @memcpy(self.message_buffer[0..cut], names[0..cut]);
            @memcpy(self.message_buffer[cut..], ellipsis);
            self.message = &self.message_buffer;
        }
    }

    /// Handles keys typed into the console, returning false for keys it
    /// leaves to the panels. Escape stops typing, and tab does nothing, as input
    /// is printable characters.
    fn consoleKey(self: *Tui, k: vaxis.Key) !bool {
        if (k.codepoint == vaxis.Key.tab) {
            return true;
        } else if (k.matches(vaxis.Key.escape, .{})) {
            self.inserting = false;
        } else if (k.matches(vaxis.Key.page_up, .{})) {
            self.console_scroll += self.consolePage();
        } else if (k.matches(vaxis.Key.page_down, .{})) {
            self.console_scroll -|= self.consolePage();
        } else if (k.matches(vaxis.Key.backspace, .{})) {
            self.input_len -|= 1;
        } else if (k.matches(vaxis.Key.enter, .{})) {
            if (self.input_len < self.input.len) {
                self.input[self.input_len] = '\n';
                self.input_len += 1;
            }
            try self.send();
        } else if (k.matches('d', .{ .ctrl = true })) {
            // as in a terminal, text typed so far is sent without a newline,
            // and otherwise the input ends
            if (self.input_len > 0) {
                try self.send();
            } else {
                self.options.console.input.?.queue.close(self.io);
                self.message = "the console's input has ended";
            }
        } else if (k.text) |text| {
            for (text) |byte| if (self.input_len < self.input.len - 1 and byte >= ' ' and byte < 0x7f) {
                self.input[self.input_len] = byte;
                self.input_len += 1;
            };
        } else return false;
        return true;
    }

    /// Handles keys typed into the aaforth panel, returning false for keys it
    /// leaves to the panels. Escape stops typing, and tab completes words.
    fn forthKey(self: *Tui, k: vaxis.Key) !bool {
        if (k.codepoint == vaxis.Key.tab) {
            if (!k.mods.shift) self.complete();
        } else if (k.matches(vaxis.Key.escape, .{})) {
            self.inserting = false;
        } else if (k.matches(vaxis.Key.page_up, .{})) {
            self.forth_scroll += self.textPage(.forth);
        } else if (k.matches(vaxis.Key.page_down, .{})) {
            self.forth_scroll -|= self.textPage(.forth);
        } else if (k.matches(vaxis.Key.up, .{})) {
            if (self.recalling < self.recalled_len) self.recall(self.recalling + 1);
        } else if (k.matches(vaxis.Key.down, .{})) {
            if (self.recalling > 0) self.recall(self.recalling - 1);
        } else if (k.matches(vaxis.Key.backspace, .{})) {
            self.forth_input_len -|= 1;
        } else if (k.matches(vaxis.Key.enter, .{})) {
            try self.interpret();
        } else if (k.text) |text| {
            for (text) |byte| if (self.forth_input_len < self.forth_input.len and byte >= ' ' and byte < 0x7f) {
                self.forth_input[self.forth_input_len] = byte;
                self.forth_input_len += 1;
            };
        } else return false;
        return true;
    }

    /// Completes the word being typed into the aaforth panel, as far as the
    /// words it could be agree, or lists them when that adds nothing
    fn complete(self: *Tui) void {
        const forth = self.options.forth.?;
        const input = self.forth_input[0..self.forth_input_len];
        const start = if (std.mem.findScalarLast(u8, input, ' ')) |space| space + 1 else 0;
        var words: Completions = .{ .partial = input[start..] };
        forth.session.complete(words.partial, &words);
        if (words.len == 0) {
            self.message = "no word starts with that";
            return;
        }
        const found = words.found[0..@min(words.len, words.found.len)];
        // as much as every word starts with, and a space after a whole word
        var common = found[0];
        for (found[1..]) |word| common = common[0 .. std.mem.indexOfDiff(u8, common, word) orelse common.len];
        const end = start + common.len + @intFromBool(found.len == 1);
        if (end > self.forth_input.len) return;
        if (common.len > words.partial.len or found.len == 1) {
            @memcpy(self.forth_input[start..][0..common.len], common);
            if (found.len == 1) self.forth_input[end - 1] = ' ';
            self.forth_input_len = @intCast(end);
            return;
        }
        const output = forth.output;
        self.forth_scroll = 0;
        for (found) |word| output.print(" {s}", .{word}) catch {};
        if (words.len > found.len) output.print(" and {d} more", .{words.len - found.len}) catch {};
        output.writeByte('\n') catch {};
    }

    /// puts the line typed `lines_back` lines ago into the aaforth panel's
    /// input, or an empty line for none
    fn recall(self: *Tui, lines_back: usize) void {
        self.recalling = lines_back;
        const line: []const u8 = if (lines_back == 0) "" else self.recalled[(self.recalled_len - lines_back) % recall_capacity];
        const len = @min(line.len, self.forth_input.len);
        @memcpy(self.forth_input[0..len], line[0..len]);
        self.forth_input_len = @intCast(len);
    }

    /// Interprets the line typed into the aaforth panel, with the selected node
    /// as the target, and selects the target it leaves. The chip is
    /// remembered first, to go back to as after a step.
    fn interpret(self: *Tui) !void {
        const forth = self.options.forth.?;
        const line = try forth.arena.dupe(u8, self.forth_input[0..self.forth_input_len]);
        self.forth_input_len = 0;
        self.forth_scroll = 0;
        self.recalling = 0;
        if (line.len > 0) {
            self.recalled[self.recalled_len % recall_capacity] = line;
            self.recalled_len += 1;
        }

        // keep room for what the line writes
        const output = forth.output;
        if (output.end > output.buffer.len / 2) {
            const keep = output.buffer.len / 4;
            @memmove(output.buffer[0..keep], output.buffer[output.end - keep .. output.end]);
            output.end = keep;
        }
        const layout = self.chip.layout;
        if (!self.running) self.remember(.line);
        forth.session.setTarget(layout.nodeNumber(self.selected));
        output.print("{d:0>3}> {s}\n", .{ layout.nodeNumber(self.selected), line }) catch {};
        aforth.interpret(forth.session, line, forth.diagnostic, output) catch {
            self.message = "the aaforth panel's output is full";
        };
        if (forth.session.target()) |node| if (layout.index(node)) |i| self.select(i);
        self.memory_scroll = null;
    }

    /// sends the text typed into the console as input
    fn send(self: *Tui) !void {
        const text = self.input[0..self.input_len];
        self.input_len = 0;
        self.console_scroll = 0;
        // the queue is full when the node is not reading its input
        const sent = self.options.console.input.?.queue.put(self.io, text, 0) catch |err| switch (err) {
            error.Closed => {
                self.message = "the console's input has ended";
                return;
            },
            else => |e| return e,
        };
        if (sent < text.len) self.message = "the console's input is full";
    }

    fn mouse(self: *Tui, m: vaxis.Mouse) void {
        // the help takes the wheel, and nothing else
        if (self.help_scroll != null) {
            if (m.type != .press) return;
            if (m.button == .wheel_up) self.scrollHelp(-3);
            if (m.button == .wheel_down) self.scrollHelp(3);
            return;
        }
        if (m.type == .drag) if (self.dragging) |border| {
            self.moveBorder(border, m);
            self.dragged = true;
            return;
        };
        // a tap leaves the border to move with the next tap
        if (m.type == .release and self.dragged) {
            self.dragging = null;
            self.message = null;
        }
        if (m.type == .press and m.button == .left) if (self.dragging) |border| {
            if (self.onBorder(m) == null) {
                self.moveBorder(border, m);
                self.dragging = null;
                self.message = null;
                return;
            }
        };

        const wheel: i32 = switch (m.button) {
            .wheel_up => -3,
            .wheel_down => 3,
            else => 0,
        };
        if (wheel != 0 and m.type == .press) {
            if (self.memory_window) |w| if (w.hasMouse(m) != null) return self.scrollMemory(wheel);
            if (self.windows.get(.console)) |w| if (w.hasMouse(m) != null) {
                self.console_scroll = if (wheel < 0) self.console_scroll + 3 else self.console_scroll -| 3;
            };
            if (self.windows.get(.forth)) |w| if (w.hasMouse(m) != null) {
                self.forth_scroll = if (wheel < 0) self.forth_scroll + 3 else self.forth_scroll -| 3;
            };
            if (self.windows.get(.debug)) |w| if (w.hasMouse(m) != null and self.debug == .trace) {
                self.trace_scroll = if (wheel < 0) self.trace_scroll + 3 else self.trace_scroll -| 3;
            };
            return;
        }
        if (m.type != .press or m.button != .left) return;

        if (self.onBorder(m)) |border| {
            self.dragging = border;
            self.dragged = false;
            self.message = "drag the border, or tap where it should go";
            return;
        }

        for ([_]Panel{ .map, .console, .forth, .debug, .node }) |panel| {
            const w = self.windows.get(panel) orelse continue;
            if (w.hasMouse(m) == null) continue;
            self.focusOn(panel);
            // the prompt's row types into it
            if ((panel == .console or panel == .forth) and m.row == w.y_off + w.height -| 1) self.inserting = true;
            // a row of the breakpoints or the history chooses it
            if (panel == .debug and self.debug != .trace) {
                const row = self.debug_first + @as(usize, @intCast(m.row - w.y_off));
                if (row < self.debugRows()) self.debug_cursor = row;
            }
            if (panel == .node) if (self.memory_window) |listing| if (listing.hasMouse(m) != null) {
                const row = self.memoryFirstRow() + @as(u16, @intCast(m.row - listing.y_off));
                if (rowAddress(row) == null) return;
                // the left edge sets and clears breakpoints
                if (m.col - listing.x_off < 2) return self.toggleBreakpoint(row);
                self.memory_scroll = self.memoryFirstRow();
                self.memory_cursor = row;
            };
            if (panel == .map) {
                const t = self.tiles;
                const x: u16 = @intCast(m.col - w.x_off);
                const y: u16 = @intCast(m.row - w.y_off);
                const columns, const rows = t.inView(w);
                // nothing in the gaps between tiles, or past the last tile in view
                if (x % (t.width + t.gap_x) >= t.width or y % (t.height + t.gap_y) >= t.height) return;
                if (x / (t.width + t.gap_x) >= columns or y / (t.height + t.gap_y) >= rows) return;
                const column = x / (t.width + t.gap_x) + self.map_scroll.x;
                const row = y / (t.height + t.gap_y) + self.map_scroll.y;
                const layout = self.chip.layout;
                if (column < layout.columns and row < layout.rows) self.select((layout.rows - 1 - row) * layout.columns + column);
            }
        }
    }

    /// the border between panels under the mouse
    fn onBorder(self: Tui, m: vaxis.Mouse) ?Border {
        if (self.column_border) |column| if (m.col == column or m.col + 1 == column) return .columns;
        if (self.column_border != null and m.col >= self.column_border.?) return null;
        for (self.stacked[0..self.stacked_len], 0..) |stacked, n| {
            if (n > 0 and (m.row == stacked.top or m.row + 1 == stacked.top)) return .{ .rows = n };
        }
        return null;
    }

    fn moveBorder(self: *Tui, border: Border, m: vaxis.Mouse) void {
        switch (border) {
            .columns => self.left_width = @intCast(@max(m.col, 0)),
            .rows => |n| self.moveRow(n, @intCast(@max(m.row, 0))),
        }
    }

    /// Moves the border above the nth panel in the left column to a row,
    /// keeping the bottom of that panel where it is
    fn moveRow(self: *Tui, n: usize, row: u16) void {
        // from a layout since drawn too small for one
        if (n == 0 or n >= self.stacked_len) return;
        // so the panels sharing what is left keep their heights too
        for (self.stacked[0 .. self.stacked_len - 1]) |stacked| {
            if (self.heights.get(stacked.panel) == null) self.heights.set(stacked.panel, stacked.height);
        }
        const above = self.stacked[n - 1];
        const below = self.stacked[n];
        const top = @max(row, above.top);
        self.heights.set(above.panel, top - above.top);
        // the last takes what is left
        if (n + 1 < self.stacked_len) self.heights.set(below.panel, (below.top + below.height) -| top);
    }

    /// Lengthens or shortens the focused panel in the left column, or the
    /// map from the node panel, by moving its bottom border, or its top one
    /// for the last
    fn resize(self: *Tui, rows: i32) void {
        if (self.stacked_len < 2) return;
        var focused: ?usize = if (self.stacked[0].panel == .map) 0 else null;
        for (self.stacked[0..self.stacked_len], 0..) |stacked, i| {
            if (stacked.panel == self.focus) focused = i;
        }
        const n = focused orelse return;
        if (n + 1 < self.stacked_len) {
            self.moveRow(n + 1, @intCast(@max(@as(i32, self.stacked[n + 1].top) + rows, 0)));
        } else {
            self.moveRow(n, @intCast(@max(@as(i32, self.stacked[n].top) - rows, 0)));
        }
    }

    fn select(self: *Tui, i: u16) void {
        if (i != self.selected) {
            self.memory_scroll = null;
            self.memory_cursor = null;
        }
        self.selected = i;
    }

    /// the row of the memory listing under the cursor, which is nowhere while
    /// following a node running code from a port
    fn cursorRow(self: Tui) ?u16 {
        return self.memory_cursor orelse memoryRow(self.chip.nodes[self.selected].current());
    }

    /// moves the cursor over the words of the memory listing, keeping it in view
    fn moveCursor(self: *Tui, rows: i32) void {
        // from above the first word, when the node runs code from a port
        var row: i32 = std.math.clamp(@as(i32, self.cursorRow() orelse 0) + rows, 1, memory_rows - 1);
        // past the heading of ROM
        if (rowAddress(@intCast(row)) == null) row += if (rows < 0) -1 else 1;
        self.memory_cursor = @intCast(row);
        const page = self.memoryPage();
        const first = self.memoryFirstRow();
        if (row < first) self.memory_scroll = @intCast(row);
        if (row >= first + page) self.memory_scroll = @intCast(row + 1 - page);
        // so the RAM heading shows at the top
        if (row == 1 and first <= 1) self.memory_scroll = 0;
    }

    /// saves the chip before the user steps or runs it, to go back to if it
    /// changes
    fn remember(self: *Tui, cause: Cause) void {
        // one is saved before it is kept
        if (self.history.len < 2) return;
        self.keepPending();
        const index = self.historyIndex(self.history_len);
        self.causes[index] = cause;
        const snapshot = &self.history[index];
        if (snapshot.* == null) snapshot.* = Chip.Snapshot.init(self.gpa, self.chip.layout) catch {
            self.message = "there is no memory left to go back with";
            return;
        };
        self.chip.save(&snapshot.*.?);
        self.pending = true;
    }

    /// keeps the snapshot saved before the last step or run, unless nothing
    /// has changed since
    fn keepPending(self: *Tui) void {
        if (!self.pending) return;
        self.pending = false;
        if (self.chip.matches(&self.history[self.historyIndex(self.history_len)].?)) return;
        if (self.history_len == self.history.len - 1) {
            self.history_start = self.historyIndex(1);
        } else self.history_len += 1;
    }

    /// keeps the snapshot saved before the last step or run, for the
    /// history to show, unless running: the chip may not have changed yet,
    /// and keeping it then would drop it
    fn keepPaused(self: *Tui) void {
        if (!self.running) self.keepPending();
    }

    /// goes back to before the last step or run
    fn back(self: *Tui) void {
        self.keepPending();
        if (self.history_len == 0) {
            self.message = "nothing to go back to";
            return;
        }
        self.backTo(self.history_len - 1);
    }

    /// goes back to before the `n`th step or run kept, the oldest 0,
    /// forgetting those after it
    fn backTo(self: *Tui, n: usize) void {
        self.keepPending();
        if (n >= self.history_len) return;
        self.history_len = n;
        self.chip.restore(&self.history[self.historyIndex(n)].?);
        self.memory_scroll = null;
        self.message = self.printLasting("back to {d} steps", .{self.chip.steps});
    }

    /// the index in `history` of the snapshot `i` from the oldest
    fn historyIndex(self: Tui, i: usize) usize {
        return (self.history_start + i) % self.history.len;
    }

    /// sets or clears a watch on the port of the selected node a key names
    fn chooseWatch(self: *Tui, k: vaxis.Key) void {
        const text = k.text orelse return;
        if (text.len != 1) return;
        const direction: Direction = switch (std.ascii.toLower(text[0])) {
            'r' => .right,
            'd' => .down,
            'l' => .left,
            'u' => .up,
            else => return,
        };
        _ = self.chip.watches.toggle(.{ .index = self.selected, .direction = direction, .write = std.ascii.isUpper(text[0]) }) catch {
            self.message = "there are too many watches";
        };
    }

    fn toggleBreakpoint(self: *Tui, row: u16) void {
        const address = rowAddress(row) orelse return;
        _ = self.chip.breakpoints.toggle(.init(self.selected, address)) catch {
            self.message = "there are too many breakpoints";
            return;
        };
    }

    /// Moves the focus to a panel, showing it if it is hidden, and filling
    /// the screen with it if another panel fills it
    fn focusPanel(self: *Tui, panel: Panel) void {
        if (panel == .forth and self.options.forth == null) return;
        self.shown.insert(panel);
        if (self.zoomed != null) self.zoomed = panel;
        self.focusOn(panel);
        self.inserting = panel == .console or panel == .forth;
    }

    /// Moves the focus to a panel, not typing into it
    fn focusOn(self: *Tui, panel: Panel) void {
        self.focus_changes += 1;
        self.focused_at.set(self.focus, self.focus_changes);
        self.focus = panel;
        self.inserting = false;
    }

    fn toggle(self: *Tui, panel: Panel) void {
        // keep one panel in view
        if (self.shown.contains(panel) and self.shown.count() == 1) return;
        self.shown.toggle(panel);
        if (self.zoomed == panel) self.zoomed = null;
        // the chip's panels first
        if (!self.shown.contains(self.focus)) {
            for ([_]Panel{ .node, .map, .console, .forth, .debug }) |other| if (self.shown.contains(other)) {
                self.focusOn(other);
                break;
            };
        }
    }

    /// The panel in view beside the focused one, to the left, below, above
    /// or to the right: the nearest, then the one focused last, and then the
    /// one beside the middle of the focused one
    fn neighbor(self: *Tui, dx: i2, dy: i2) ?Panel {
        const from = self.windows.get(self.focus) orelse return null;
        const Candidate = struct { panel: Panel, gap: i32, focused_at: u64, middle: bool };
        var best: ?Candidate = null;
        for (std.enums.values(Panel)) |panel| {
            if (panel == self.focus) continue;
            const w = self.windows.get(panel) orelse continue;
            // squeezed to no rows
            if (w.width == 0 or w.height == 0) continue;
            // the axis moved along, and the one across it
            const along: [2][2]i32 = if (dx != 0)
                .{ .{ from.x_off, from.width }, .{ w.x_off, w.width } }
            else
                .{ .{ from.y_off, from.height }, .{ w.y_off, w.height } };
            const across: [2][2]i32 = if (dx != 0)
                .{ .{ from.y_off, from.height }, .{ w.y_off, w.height } }
            else
                .{ .{ from.x_off, from.width }, .{ w.x_off, w.width } };
            const gap = if (dx + dy < 0)
                along[0][0] - (along[1][0] + along[1][1])
            else
                along[1][0] - (along[0][0] + along[0][1]);
            if (gap < 0) continue;
            if (across[1][0] >= across[0][0] + across[0][1] or across[0][0] >= across[1][0] + across[1][1]) continue;
            const middle = across[0][0] + @divFloor(across[0][1], 2);
            const candidate: Candidate = .{
                .panel = panel,
                .gap = gap,
                .focused_at = self.focused_at.get(panel),
                .middle = middle >= across[1][0] and middle < across[1][0] + across[1][1],
            };
            const better = if (best) |b|
                if (candidate.gap != b.gap)
                    candidate.gap < b.gap
                else if (candidate.focused_at != b.focused_at)
                    candidate.focused_at > b.focused_at
                else
                    candidate.middle and !b.middle
            else
                true;
            if (better) best = candidate;
        }
        return if (best) |b| b.panel else null;
    }

    /// moves the focus to the next panel in view
    fn cycleFocus(self: *Tui, direction: i2) void {
        const panels = [_]Panel{ .map, .console, .forth, .debug, .node };
        var i = std.mem.indexOfScalar(Panel, &panels, self.focus).?;
        for (0..panels.len) |_| {
            i = @intCast(@mod(@as(isize, @intCast(i)) + direction, panels.len));
            if (self.visible().contains(panels[i])) break;
        }
        self.focusOn(panels[i]);
    }

    fn visible(self: Tui) std.EnumSet(Panel) {
        return if (self.zoomed) |panel| .initOne(panel) else self.shown;
    }

    fn scrollMemory(self: *Tui, rows: i32) void {
        const page = self.memoryPage();
        const first: i32 = self.memoryFirstRow();
        self.memory_scroll = @intCast(std.math.clamp(first + rows, 0, @max(memory_rows - @as(i32, page), 0)));
    }

    /// the first row of the memory listing in view
    fn memoryFirstRow(self: Tui) u16 {
        const page = self.memoryPage();
        return @min(self.memory_scroll orelse self.followedMemoryRow(page), memory_rows -| page);
    }

    fn memoryPage(self: Tui) u16 {
        return if (self.memory_window) |w| @max(w.height, 1) else 16;
    }

    fn consolePage(self: Tui) u16 {
        return self.textPage(.console);
    }

    /// rows of output a page of the console or aforth panel shows
    fn textPage(self: Tui, panel: Panel) u16 {
        return if (self.windows.get(panel)) |w| @max(w.height -| 1, 1) else 8;
    }

    /// the first row of the memory listing that centers the current word
    fn followedMemoryRow(self: Tui, page: u16) u16 {
        const row = memoryRow(self.chip.nodes[self.selected].current()) orelse 0;
        return @min(row -| page / 2, memory_rows -| page);
    }

    fn defaultLeftWidth(self: Tui) u16 {
        return @as(u16, self.chip.layout.columns) * cell_width + 3;
    }

    fn defaultMapHeight(self: Tui) u16 {
        return @as(u16, self.chip.layout.rows) + 2;
    }

    fn draw(self: *Tui, win: vaxis.Window) void {
        self.frame = .init(&self.frame_buffer);
        self.map_more = "";
        win.clear();
        // until the console shows it
        win.hideCursor();
        self.windows = .initFill(null);
        self.memory_window = null;
        self.column_border = null;
        self.stacked_len = 0;
        if (win.width < 30 or win.height < 8) {
            _ = win.printSegment(.{ .text = "The terminal is too small" }, .{});
            return;
        }
        // over either screen
        defer if (self.help_scroll != null) self.drawHelp(win);
        if (self.screen == .editor) return self.drawEditor(win);

        const layout = self.chip.layout;
        const body_height = win.height - 1;
        const shown = self.visible();
        // the map, and the panels under it sharing the rest of the column
        var column: [4]Panel = undefined;
        var count: usize = 0;
        for ([_]Panel{ .map, .console, .forth, .debug }) |panel| if (shown.contains(panel)) {
            column[count] = panel;
            count += 1;
        };
        const below_count: u16 = @intCast(count - @intFromBool(shown.contains(.map)));

        // the map and console on the left, and the node on the right
        var left_width: u16 = win.width;
        if (shown.contains(.node)) {
            left_width = if (count > 0) std.math.clamp(self.left_width orelse @min(self.defaultLeftWidth(), win.width -| 36), 12, win.width - 12) else 0;
            if (count > 0) {
                self.column_border = left_width;
                // so resizing back takes effect at once
                if (self.left_width != null) self.left_width = left_width;
            }
        }

        var y: u16 = 0;
        var share = if (below_count > 0) body_height / below_count else 0;
        for (column[0..count], 0..) |panel, n| {
            const remaining = body_height - y;
            const height = if (n + 1 == count) remaining else height: {
                const chosen = self.heights.get(panel);
                // the rest share what is left, as evenly as it divides
                if (chosen == null and panel != .map) break :height @min(share, remaining);
                // leaving the panels below rows of their own
                const height = @min(@max(chosen orelse @min(self.defaultMapHeight(), body_height -| 5), 3), remaining -| 3);
                if (chosen != null) self.heights.set(panel, height);
                break :height height;
            };
            if (panel == .map and below_count > 0) share = (body_height - height) / below_count;
            self.stacked[n] = .{ .panel = panel, .top = y, .height = height };
            const title = switch (panel) {
                .map => self.print("1 chip {d}x{d}{s}", .{ layout.rows, layout.columns, switch (self.map_mode) {
                    .auto => "",
                    .numbers => " numbers",
                    .registers => " registers",
                } }),
                .console => self.print("2 console {d:0>3}:{t}", .{ self.options.console_node, self.options.console_port }),
                .forth => "4 aforth",
                else => self.debugTitle(),
            };
            const inside = self.drawPanel(win, panel, 0, y, left_width, height, title);
            switch (panel) {
                .map => {
                    self.drawMap(inside);
                    // which way the nodes out of view are, after the title
                    if (self.map_more.len > 0) {
                        const heading = win.child(.{ .x_off = 3 + @as(u16, @intCast(title.len)), .width = left_width -| (4 + @as(u16, @intCast(title.len))), .height = 1 });
                        _ = heading.printSegment(.{ .text = self.map_more, .style = .{ .bold = true } }, .{ .wrap = .none });
                    }
                },
                .console => self.drawConsole(inside),
                .forth => self.drawForth(inside),
                else => self.drawDebug(inside),
            }
            y += height;
        }
        self.stacked_len = count;
        if (shown.contains(.node)) {
            self.drawNode(self.drawPanel(win, .node, left_width, 0, win.width - left_width, body_height, self.print("3 node {d:0>3}", .{layout.nodeNumber(self.selected)})));
        }
        self.drawStatus(win.child(.{ .y_off = body_height, .height = 1 }));
    }

    /// Draws the help in a box over the screen, with arrows after its title
    /// when there is more of it above or below
    fn drawHelp(self: *Tui, win: vaxis.Window) void {
        const width = @min(win.width -| 4, help_key_width + 60);
        const height = @min(win.height -| 1, help_rows + 2);
        const x = (win.width - width) / 2;
        const y = (win.height - 1 -| height) / 2;
        const box = win.child(.{ .x_off = x, .y_off = y, .width = width, .height = height });
        box.clear();
        // with a column of space inside the border
        const inside = box.child(.{ .border = .{ .where = .all, .style = .{ .fg = .{ .index = 6 } } } }).child(.{ .x_off = 1 });
        self.help_page = @max(inside.height, 1);
        // so the last page is full, as after resizing
        const first = @min(self.help_scroll.?, help_rows -| self.help_page);
        self.help_scroll = first;
        const more = self.print("{s}{s}", .{ if (first > 0) "↑" else "", if (first + self.help_page < help_rows) "↓" else "" });
        _ = box.child(.{ .x_off = 2, .width = width -| 3, .height = 1 }).print(&.{
            .{ .text = "help", .style = .{ .bold = true } },
            .{ .text = " " },
            .{ .text = more, .style = .{ .bold = true } },
        }, .{ .wrap = .none });

        var row: u16 = 0;
        for (help) |section| {
            if (row >= first and row - first < inside.height) {
                _ = inside.printSegment(.{ .text = section[0], .style = colors.heading }, .{ .row_offset = row - first, .wrap = .none });
            }
            row += 1;
            for (section[1]) |hint| {
                if (row >= first and row - first < inside.height) {
                    _ = inside.printSegment(.{ .text = hint[0], .style = colors.label }, .{ .row_offset = row - first, .wrap = .none });
                    _ = inside.printSegment(.{ .text = hint[1] }, .{ .row_offset = row - first, .col_offset = help_key_width, .wrap = .none });
                }
                row += 1;
            }
            row += 1;
        }
    }

    /// Draws a bordered panel with a title, returning the window inside it
    fn drawPanel(self: *Tui, win: vaxis.Window, which: Panel, x: u16, y: u16, width: u16, height: u16, title: []const u8) vaxis.Window {
        const style: vaxis.Style = if (self.focus == which) colors.focused else colors.dim;
        const inside = win.child(.{ .x_off = x, .y_off = y, .width = width, .height = height, .border = .{ .where = .all, .style = style } });
        // within the top border
        const heading = win.child(.{ .x_off = x + 2, .y_off = y, .width = width -| 3, .height = 1 });
        _ = heading.printSegment(.{ .text = title, .style = .{ .bold = true } }, .{ .wrap = .none });
        self.windows.set(which, inside);
        return inside;
    }

    /// Draws the nodes in view, following the selected one: as tiles of
    /// their state and registers, with arrows between tiles showing what the
    /// ports between them are doing, or with too little room as numbers
    fn drawMap(self: *Tui, win: vaxis.Window) void {
        const layout = self.chip.layout;
        const t: Tiles = .fit(win, layout, self.map_mode);
        self.tiles = t;
        const columns, const rows = t.inView(win);

        // keep the selected node in view
        const x = self.selected % layout.columns;
        const row = layout.rows - 1 - self.selected / layout.columns;
        if (x < self.map_scroll.x) self.map_scroll.x = x;
        if (x >= self.map_scroll.x + columns) self.map_scroll.x = x + 1 - columns;
        if (row < self.map_scroll.y) self.map_scroll.y = row;
        if (row >= self.map_scroll.y + rows) self.map_scroll.y = row + 1 - rows;
        const scroll = self.map_scroll;
        self.map_more = self.print("{s}{s}{s}{s}", .{
            if (scroll.y > 0) "↑" else "",
            if (scroll.y + rows < layout.rows) "↓" else "",
            if (scroll.x > 0) "←" else "",
            if (scroll.x + columns < layout.columns) "→" else "",
        });

        for (scroll.y..@min(layout.rows, scroll.y + rows)) |r| {
            // north at the top
            const y = layout.rows - 1 - r;
            for (scroll.x..@min(layout.columns, scroll.x + columns)) |c| {
                const i: u16 = @intCast(y * layout.columns + c);
                const column: u16 = @intCast((c - scroll.x) * (t.width + t.gap_x));
                const top: u16 = @intCast((r - scroll.y) * (t.height + t.gap_y));
                if (t.height == 1) {
                    var style = statusStyle(self.chip.nodes[i].status());
                    if (i == self.selected) style.reverse = true;
                    _ = win.printSegment(.{ .text = self.print("{d:0>3}", .{layout.nodeNumber(i)}), .style = style }, .{ .row_offset = top, .col_offset = column });
                    continue;
                }
                self.drawTile(win.child(.{ .x_off = column, .y_off = top, .width = t.width, .height = t.height }), i);
                // between this tile and those east and north of it, if in view
                if (c + 1 < @min(layout.columns, scroll.x + columns)) if (self.portArrow(i, .east)) |segment| {
                    _ = win.printSegment(segment, .{ .row_offset = top + t.height / 2, .col_offset = column + t.width + t.gap_x / 2, .wrap = .none });
                };
                if (r > scroll.y) if (self.portArrow(i, .north)) |segment| {
                    _ = win.printSegment(segment, .{ .row_offset = top - 1, .col_offset = column + t.width / 2, .wrap = .none });
                };
            }
        }
    }

    /// Draws a node's number and what it is doing, coloured by it, then its
    /// registers on as many lines as fit
    fn drawTile(self: *Tui, win: vaxis.Window, i: u16) void {
        const n = &self.chip.nodes[i];
        const status = n.status();
        var style = statusStyle(status);
        if (i == self.selected) {
            style.reverse = true;
            win.child(.{ .height = 1 }).fill(.{ .style = style });
        }
        const header = self.print("{d:0>3} {s}", .{ self.chip.layout.nodeNumber(i), self.statusText(i, status) });
        _ = win.printSegment(.{ .text = header, .style = style }, .{ .wrap = .none });

        // labels in their own colour, as in the node panel
        const items = [_]struct { []const u8, []const u8 }{
            .{ "P", self.print("{x}", .{@as(u10, @bitCast(n.p))}) },
            .{ "s", self.print("{d}", .{n.slot}) },
            .{ "T", self.print("{x}", .{@as(u18, @bitCast(n.data_stack.t))}) },
            .{ "S", self.print("{x}", .{@as(u18, @bitCast(n.data_stack.s))}) },
            .{ "A", self.print("{x}", .{@as(u18, @bitCast(n.a))}) },
            .{ "B", self.print("{x}", .{n.b}) },
            .{ "io", self.print("{x}", .{@as(u18, @bitCast(n.io))}) },
        };
        // as many as fit on each line, in order
        var line: u16 = 1;
        var at: usize = 0;
        while (line < win.height and at < items.len) : (line += 1) {
            var segments: [3 * items.len]vaxis.Segment = undefined;
            var count: usize = 0;
            var len: usize = 0;
            while (at < items.len) : (at += 1) {
                const item = items[at];
                const space = @intFromBool(count > 0);
                // an item too wide for a line is cut short
                if (count > 0 and len + space + item[0].len + item[1].len > win.width) break;
                if (space == 1) {
                    segments[count] = .{ .text = " " };
                    count += 1;
                }
                segments[count] = .{ .text = item[0], .style = colors.label };
                segments[count + 1] = .{ .text = item[1] };
                count += 2;
                len += space + item[0].len + item[1].len;
            }
            _ = win.print(segments[0..count], .{ .row_offset = line, .wrap = .none });
        }
    }

    /// what a node is doing, briefly: running, or waiting for code, to read
    /// or to write, with arrows for the ports it waits on
    fn statusText(self: *Tui, i: u16, status: Computer.Status) []const u8 {
        const kind, const address = switch (status) {
            .running => return "run",
            .code => |a| .{ "code", a },
            .reading => |a| .{ "rd", a },
            .writing => |a| .{ "wr", a },
        };
        const ports = gasim.port.select(address) orelse return self.print("{s} {s}", .{ kind, disassembler.ioName(address) });
        const layout = self.chip.layout;
        var arrows: [4][]const u8 = undefined;
        var count: usize = 0;
        var it = ports.iterator();
        while (it.next()) |direction| {
            arrows[count] = arrow(Chip.facing(i % layout.columns, i / layout.columns, direction));
            count += 1;
        }
        return self.print("{s} {s}", .{ kind, std.mem.join(self.frame.allocator(), "", arrows[0..count]) catch "" });
    }

    /// An arrow for the port between a node and its neighbour in a direction,
    /// pointing the way the word goes: green for a word that went across in
    /// the last step, or that has been handed over to be taken, yellow for a
    /// node waiting to read or write, and dim for one waiting for code
    fn portArrow(self: *Tui, i: u16, cardinal: Chip.Cardinal) ?vaxis.Segment {
        const f = self.chip.flow(i, cardinal) orelse return null;
        return .{
            .text = arrow(if (f.outward) cardinal else cardinal.opposite()),
            .style = switch (f.kind) {
                .moved => .{ .fg = .{ .index = 2 }, .bold = true },
                .waiting => .{ .fg = .{ .index = 3 } },
                .code => .{ .dim = true },
            },
        };
    }

    fn drawConsole(self: *Tui, win: vaxis.Window) void {
        const prompt = if (self.console_scroll > 0)
            self.print("  {d} lines back, pgdn to return", .{self.console_scroll})
        else
            self.print("> {s}", .{self.input[0..self.input_len]});
        self.drawText(win, .console, self.options.console.output.buffered(), &self.console_scroll, prompt, null);
    }

    fn drawForth(self: *Tui, win: vaxis.Window) void {
        const prompt = if (self.forth_scroll > 0)
            self.print("  {d} lines back, pgdn to return", .{self.forth_scroll})
        else
            self.print("{d:0>3}> {s}", .{ self.chip.layout.nodeNumber(self.selected), self.forth_input[0..self.forth_input_len] });
        self.drawText(win, .forth, self.options.forth.?.output.buffered(), &self.forth_scroll, prompt, null);
    }

    fn debugTitle(self: *Tui) []const u8 {
        return switch (self.debug) {
            .trace => if (self.chip.trace == null) "5 trace" else "5 trace, tracing",
            .breakpoints => self.print("5 breakpoints {d}, watches {d}", .{ self.chip.breakpoints.len, self.chip.watches.len }),
            .history => self.print("5 history {d} of {d}", .{ self.history_len, self.history.len -| 1 }),
        };
    }

    /// Draws the trace, or the breakpoints and watches, or the moments to go
    /// back to
    fn drawDebug(self: *Tui, win: vaxis.Window) void {
        const layout = self.chip.layout;
        switch (self.debug) {
            .trace => {
                const text = if (self.trace) |t| t.writer.buffered() else "";
                const only = self.traceOnly();
                const footer = if (self.trace_scroll > 0)
                    self.print("  {d} lines back, pgdn to return", .{self.trace_scroll})
                else if (self.chip.trace == null)
                    "t traces each step that runs code, as --trace does"
                else if (self.trace.?.dropped)
                    "tracing, keeping the last lines"
                else
                    "tracing";
                const shown = if (only) |prefix| self.print("{s}, only node {s}", .{ footer, prefix[0..3] }) else footer;
                self.drawText(win, .debug, text, &self.trace_scroll, shown, only);
            },
            .breakpoints => {
                const stops = self.chip.breakpoints.items();
                const watched = self.chip.watches.items();
                const rows = self.frame.allocator().alloc([]const u8, stops.len + watched.len) catch return;
                for (stops, rows[0..stops.len]) |b, *row| row.* = self.print("{d:0>3} stops at {x:0>3}", .{ layout.nodeNumber(b.index), b.address });
                for (watched, rows[stops.len..]) |w, *row| row.* = self.print("{d:0>3} stops {s} {t}", .{ layout.nodeNumber(w.index), if (w.write) "writing" else "reading", w.direction });
                self.drawList(win, rows, "none: b sets a breakpoint in the node panel, and w watches a port");
            },
            .history => {
                self.keepPaused();
                const rows = self.frame.allocator().alloc([]const u8, self.history_len + 1) catch return;
                rows[0] = self.print("{s:<27}  {d} steps", .{ "now", self.chip.steps });
                for (rows[1..], 1..) |*row, k| {
                    const index = self.historyIndex(self.history_len - k);
                    row.* = self.print("before {s:<20}  {d} steps", .{ self.causes[index].text(), self.history[index].?.steps });
                }
                self.drawList(win, rows, "");
            },
        }
    }

    /// Draws rows to choose from, keeping the one chosen in view, or a note
    /// when there are none
    fn drawList(self: *Tui, win: vaxis.Window, rows: []const []const u8, empty: []const u8) void {
        if (win.height == 0) return;
        if (rows.len == 0) {
            _ = win.printSegment(.{ .text = empty, .style = colors.dim }, .{ .wrap = .word });
            return;
        }
        self.debug_cursor = @min(self.debug_cursor, rows.len - 1);
        // with rows removed, no room left after the last
        self.debug_first = @min(self.debug_first, rows.len -| win.height);
        if (self.debug_cursor < self.debug_first) self.debug_first = self.debug_cursor;
        if (self.debug_cursor >= self.debug_first + win.height) self.debug_first = self.debug_cursor + 1 - win.height;
        for (rows[self.debug_first..@min(rows.len, self.debug_first + win.height)], self.debug_first..) |row, k| {
            const chosen = k == self.debug_cursor and self.focus == .debug;
            _ = win.printSegment(.{ .text = row, .style = .{ .reverse = chosen } }, .{ .row_offset = @intCast(k - self.debug_first), .wrap = .none });
        }
    }

    /// Draws the end of some output, `scroll` rows back from it, above a
    /// prompt with the cursor at its end when the panel takes text, has the
    /// focus and is not scrolled back. With `only`, just the lines starting
    /// with it.
    fn drawText(self: *Tui, win: vaxis.Window, panel: Panel, output: []const u8, scroll: *usize, prompt: []const u8, only: ?[]const u8) void {
        // too short for even the prompt
        if (win.height == 0) return;
        const rows = win.height - 1;
        const width = @max(win.width, 1);
        // the rows that fit above the input line, with long lines wrapped,
        // scrolled back from the end and collected from the last
        const collected = self.frame.allocator().alloc([]const u8, rows) catch return;
        var count: u16 = 0;
        var skipped: usize = 0;
        var end = output.len;
        // output ending in a newline has no row after it
        if (end > 0 and output[end - 1] == '\n') end -= 1;
        if (output.len > 0) lines: while (true) {
            const start = if (std.mem.lastIndexOfScalar(u8, output[0..end], '\n')) |newline| newline + 1 else 0;
            const line = std.mem.trimEnd(u8, output[start..end], "\r");
            const shown = if (only) |prefix| std.mem.startsWith(u8, line, prefix) else true;
            var line_rows = if (shown) @max(std.math.divCeil(usize, line.len, width) catch unreachable, 1) else 0;
            while (line_rows > 0) : (line_rows -= 1) {
                if (skipped < scroll.*) {
                    skipped += 1;
                    continue;
                }
                if (count == rows) break :lines;
                count += 1;
                collected[rows - count] = line[(line_rows - 1) * width .. @min(line.len, line_rows * width)];
            }
            if (start == 0) break;
            end = start - 1;
        };
        // scrolled back past the start, so show the first page instead
        if (count < rows and skipped > 0) {
            scroll.* = skipped -| (rows - count);
            return self.drawText(win, panel, output, scroll, prompt, only);
        }
        scroll.* = skipped;

        for (collected[rows - count ..], 0..) |row, r| {
            // sanitized for display
            const text = self.frame.allocator().dupe(u8, row) catch continue;
            for (text) |*byte| byte.* = switch (byte.*) {
                '\t' => ' ',
                ' '...0x7e => byte.*,
                else => '.',
            };
            _ = win.printSegment(.{ .text = text }, .{ .row_offset = @intCast(r), .wrap = .none });
        }

        const style: vaxis.Style = if (self.focus == panel) .{} else colors.dim;
        _ = win.printSegment(.{ .text = prompt, .style = style }, .{ .row_offset = win.height - 1, .wrap = .none });
        if (self.focus == panel and self.inserting and scroll.* == 0) win.showCursor(@intCast(@min(prompt.len, win.width - 1)), win.height - 1);
    }

    /// prints labelled values on a row, with the labels in their own color
    fn fields(self: *Tui, win: vaxis.Window, row: u16, items: []const struct { []const u8, []const u8 }) void {
        var segments: [16]vaxis.Segment = undefined;
        var n: usize = 0;
        for (items) |item| {
            if (n + 2 > segments.len) break;
            segments[n] = .{ .text = item[0], .style = colors.label };
            segments[n + 1] = .{ .text = self.print(" {s}  ", .{item[1]}) };
            n += 2;
        }
        _ = win.print(segments[0..n], .{ .row_offset = row, .wrap = .none });
    }

    /// a word in five hex digits
    fn hex(self: *Tui, word: Word) []const u8 {
        return self.print("{x:0>5}", .{@as(u18, @bitCast(word))});
    }

    fn drawNode(self: *Tui, win: vaxis.Window) void {
        const n = &self.chip.nodes[self.selected];
        const node_status = n.status();
        _ = win.printSegment(.{ .text = switch (node_status) {
            .running => "running",
            .code => |address| self.print("waiting for code from {s}", .{disassembler.ioName(address)}),
            .reading => |address| self.print("waiting to read {s}", .{disassembler.ioName(address)}),
            .writing => |address| self.print("waiting to write {s}", .{disassembler.ioName(address)}),
        }, .style = statusStyle(node_status) }, .{ .wrap = .none });

        const word = n.current();
        self.fields(win, 2, &.{
            .{ "P", self.print("{x:0>3}", .{@as(u10, @bitCast(n.p))}) },
            .{ "slot", self.print("{d}", .{n.slot}) },
            .{ "carry", self.print("{d}", .{n.carry}) },
            .{ "", if (n.p.extended_arithmetic) "extended arithmetic" else "" },
        });
        if (n.state == .fetch) {
            self.fields(win, 3, &.{.{ "I", self.print("next word from {s}", .{if (word.io) disassembler.ioName(@bitCast(word)) else "P"}) }});
        } else self.fields(win, 3, &.{.{ "I", self.print("{s}  {s}", .{ self.hex(n.i), self.disassemble(n.i, @bitCast(word)) }) }});
        self.fields(win, 4, &.{ .{ "A", self.hex(n.a) }, .{ "B", self.print("{x:0>3}", .{n.b}) }, .{ "io", self.hex(n.io) } });
        self.fields(win, 5, &.{.{ "time", self.print("{d:.1} ns", .{@as(f64, @floatFromInt(n.time)) / 1000}) }});

        self.fields(win, 7, &.{ .{ "T", self.hex(n.data_stack.t) }, .{ "S", self.hex(n.data_stack.s) } });
        _ = win.printSegment(.{ .text = self.stack(&n.data_stack.stack, n.data_stack.index), .style = colors.dim }, .{ .row_offset = 8, .col_offset = 2, .wrap = .none });
        self.fields(win, 9, &.{.{ "R", self.hex(n.return_stack.t) }});
        _ = win.printSegment(.{ .text = self.stack(&n.return_stack.stack, n.return_stack.index), .style = colors.dim }, .{ .row_offset = 10, .col_offset = 2, .wrap = .none });
        self.fields(win, 11, &.{.{ "watch", self.watches() }});

        if (win.height <= node_header_rows) return;
        const listing = win.child(.{ .y_off = node_header_rows - 1 });
        self.memory_window = listing;
        self.drawMemory(listing, n);
    }

    /// RAM and ROM, following the current word unless scrolled
    fn drawMemory(self: *Tui, win: vaxis.Window, n: *const Computer) void {
        const page = @max(win.height, 1);
        const first = self.memoryFirstRow();
        const here = memoryRow(n.current());
        const ram_literals = disassembler.literals(n.mem[0..64]);
        const rom_literals = disassembler.literals(n.mem[64..128]);

        for (first..@min(memory_rows, first + page)) |r| {
            const row: u16 = @intCast(r - first);
            // a heading, then 64 words, for RAM and then for ROM
            const in_rom = r >= 65;
            const index = r % 65;
            if (index == 0) {
                _ = win.printSegment(.{ .text = if (in_rom) "ROM" else "RAM", .style = colors.heading }, .{ .row_offset = row, .wrap = .none });
                continue;
            }
            const i = index - 1;
            const address: u9 = @intCast(if (in_rom) 0x80 + i else i);
            const word = n.mem[if (in_rom) 64 + i else i];
            const value: u18 = @bitCast(word);
            const is_here = if (here) |h| h == r else false;
            const is_literal = (if (in_rom) rom_literals else ram_literals) & (@as(u64, 1) << @intCast(i)) != 0;

            var code: vaxis.Segment = .{ .text = self.disassemble(word, address), .style = if (word == 0) colors.dim else .{} };
            if (is_literal) code = .{ .text = self.literal(word), .style = colors.literal };
            const is_breakpoint = self.chip.breakpoints.contains(.init(self.selected, address));
            var address_style = colors.address;
            if (self.focus == .node and r == (self.cursorRow() orelse memory_rows)) address_style.reverse = true;
            var segments = [_]vaxis.Segment{
                .{ .text = if (is_breakpoint) "●" else " ", .style = colors.breakpoint },
                .{ .text = if (is_here) ">" else " ", .style = .{ .fg = .{ .index = 2 }, .bold = true } },
                .{ .text = self.print("{x:0>3}", .{address}), .style = address_style },
                .{ .text = " " },
                .{ .text = self.print("{x:0>5}  ", .{value}), .style = colors.raw },
                code,
            };
            if (is_here) for (segments[1..]) |*segment| {
                segment.style.bold = true;
            };
            _ = win.print(&segments, .{ .row_offset = row, .wrap = .none });
        }
    }

    /// Draws the block being edited, with its tokens in their colors and
    /// laid out as colorForth shows them
    fn drawEditor(self: *Tui, win: vaxis.Window) void {
        const cf = self.options.colorforth.?;
        const editor = cf.editor;
        const body_height = win.height - 1;
        const inside = win.child(.{ .height = body_height, .border = .{ .where = .all, .style = colors.focused } });
        const file = if (cf.path) |path| std.fs.path.basename(path) else "new file";
        const title = self.print("6 colorforth  block {d}{s}  {s}", .{ editor.block, if (editor.unsaved()) " +" else "", file });
        _ = win.child(.{ .x_off = 2, .width = win.width -| 3, .height = 1 }).printSegment(.{ .text = title, .style = .{ .bold = true } }, .{ .wrap = .none });

        if (editor.read_only) {
            _ = inside.printSegment(.{ .text = "This block is not colorForth source, such as the kernel of an arrayForth 2 image, so it cannot be edited.", .style = colors.dim }, .{});
        } else if (editor.len == 0) {
            _ = inside.printSegment(.{ .text = "An empty block: i to type into it", .style = colors.dim }, .{});
        } else {
            // keep the cursor in view
            const row = self.layoutBlock(inside, false);
            if (row < self.editor_scroll) self.editor_scroll = row;
            if (row >= self.editor_scroll + inside.height) self.editor_scroll = row + 1 - inside.height;
            _ = self.layoutBlock(inside, true);
        }
        self.drawEditorStatus(win.child(.{ .y_off = body_height, .height = 1 }));
    }

    /// Lays out the block's tokens in `win`, from the row scrolled to,
    /// drawing them if `drawing`, and returns the row of the cursor
    fn layoutBlock(self: *Tui, win: vaxis.Window, drawing: bool) u16 {
        const editor = self.options.colorforth.?.editor;
        var x: u16 = 0;
        var y: u16 = 0;
        var cursor_row: u16 = 0;
        for (editor.tokens[0..editor.len], 0..) |*token, i| {
            if (i > 0 and editor.startsLine(i) and x > 0) {
                x = 0;
                y += 1;
            }
            const typing = editor.mode == .insert and i == editor.cursor;
            const text = if (typing) token.text() else self.print("{f}", .{token.*});
            const value = if (token.tag == .variable) self.print(" {d}", .{token.value}) else "";
            const hidden = token.tag == .format and !self.show_format and !typing;
            const width: u16 = @intCast(@min(text.len + value.len, win.width));
            if (!hidden and x > 0 and x + width > win.width) {
                x = 0;
                y += 1;
            }
            if (i == editor.cursor) cursor_row = y;
            if (drawing and !hidden and y >= self.editor_scroll and y - self.editor_scroll < win.height) {
                const row = y - self.editor_scroll;
                var style = tokenStyle(token.tag.color());
                if (i == editor.cursor) {
                    if (typing) style.ul_style = .single else style.reverse = true;
                }
                _ = win.print(&.{
                    .{ .text = text, .style = style },
                    .{ .text = value, .style = tokenStyle(.green) },
                }, .{ .row_offset = row, .col_offset = x, .wrap = .none });
                if (typing) win.showCursor(@min(x + text.len, win.width - 1), row);
            }
            if (!hidden) x += width + 1;
            if (token.tag == .format and !typing) {
                if (std.mem.eql(u8, token.text(), "cr")) {
                    x = 0;
                    y += 1;
                } else if (std.mem.eql(u8, token.text(), "br")) {
                    x = 0;
                    y += 2;
                }
            }
        }
        return cursor_row;
    }

    fn drawEditorStatus(self: *Tui, win: vaxis.Window) void {
        const editor = self.options.colorforth.?.editor;
        if (self.command_len) |len| {
            const typed = self.command[0..len];
            // the end of a long command, to keep the cursor in view
            const shown = typed[typed.len -| (win.width -| 2)..];
            _ = win.print(&.{
                .{ .text = ":" },
                .{ .text = shown },
            }, .{ .wrap = .none });
            if (self.message) |message| _ = win.printSegment(.{ .text = message, .style = colors.literal }, .{ .col_offset = @intCast(@min(shown.len + 3, win.width)), .wrap = .none });
            win.showCursor(@intCast(@min(shown.len + 1, win.width -| 1)), 0);
            return;
        }
        const hints: []const Hint = if (editor.mode == .insert)
            &.{ .{ "space", "next word" }, .{ "enter", "new line" }, .{ "ctrl+r y g w t v b", "color" }, .{ "esc", "done" } }
        else
            &.{ .{ "i a o", "type" }, .{ "x y p", "cut copy put" }, .{ "u U", "undo redo" }, .{ "R Y G W C M B", "color" }, .{ "[ ] Ng", "block" }, .{ "L", "compile" }, .{ "s", "save" }, .{ ":", "w e new" }, .{ "f", "blue words" }, .{ "alt+1", "chip" }, .{ "?", "help" }, .{ "q", "quit" } };
        var segments: [4 + 2 * 12]vaxis.Segment = undefined;
        var len: usize = 0;
        segments[len] = if (editor.mode == .insert)
            .{ .text = " insert ", .style = .{ .fg = .{ .index = 2 }, .reverse = true, .bold = true } }
        else
            .{ .text = " normal ", .style = .{ .reverse = true, .bold = true } };
        len += 1;
        segments[len] = .{ .text = self.print(" {d}/{d} cells ", .{ editor.cells(), gasim.colorforth.cells_per_block }), .style = colors.dim };
        len += 1;
        if (editor.prefix) |count| {
            segments[len] = .{ .text = self.print(" {d} ", .{count}), .style = colors.label };
            len += 1;
        }
        if (self.message) |message| {
            segments[len] = .{ .text = self.print(" {s} ", .{message}), .style = colors.literal };
            len += 1;
        }
        for (hints) |hint| {
            segments[len] = .{ .text = self.print(" {s}", .{hint[0]}), .style = colors.label };
            segments[len + 1] = .{ .text = self.print(" {s} ", .{hint[1]}) };
            len += 2;
        }
        _ = win.print(segments[0..len], .{ .wrap = .none });
    }

    fn drawStatus(self: *Tui, win: vaxis.Window) void {
        // reversed, so the text takes the theme's background colour
        const state: vaxis.Segment = if (!self.running)
            .{ .text = " paused ", .style = .{ .reverse = true, .bold = true } }
        else if (self.settled)
            .{ .text = " waiting ", .style = .{ .fg = .{ .index = 3 }, .reverse = true, .bold = true } }
        else
            .{ .text = " running ", .style = .{ .fg = .{ .index = 2 }, .reverse = true, .bold = true } };
        const hints: []const Hint = switch (self.focus) {
            .map => &.{ .{ "space", "run" }, .{ "s", "step" }, .{ "S", "round" }, .{ "n", "step node" }, .{ "z", "back" }, .{ "arrows", "select" }, .{ "t", "tiles" }, .{ if (self.options.forth == null) "1-3 5" else "1-5", "panels" }, .{ "f", "zoom" }, .{ "tab", "next" }, .{ "?", "help" }, .{ "q", "quit" } },
            .console => if (self.inserting)
                &.{ .{ "enter", "send" }, .{ "ctrl+d", "end input" }, .{ "pgup/pgdn", "scroll" }, .{ "esc", "done" }, .{ "alt+1-6", "panels" }, .{ "F1", "help" } }
            else
                &.{ .{ "i", "type" }, .{ "j/k", "scroll" }, .{ "g/G", "first last" }, .{ "space", "run" }, .{ "s", "step" }, .{ if (self.options.forth == null) "1-3 5" else "1-5", "panels" }, .{ "f", "zoom" }, .{ "tab", "next" }, .{ "?", "help" }, .{ "q", "quit" } },
            .forth => if (self.inserting)
                &.{ .{ "enter", "interpret" }, .{ "tab", "complete" }, .{ "up/down", "recall" }, .{ "pgup/pgdn", "scroll" }, .{ "esc", "done" }, .{ "alt+1-6", "panels" }, .{ "F1", "help" } }
            else
                &.{ .{ "i", "type" }, .{ "j/k", "scroll" }, .{ "g/G", "first last" }, .{ "space", "run" }, .{ "s", "step" }, .{ "1-5", "panels" }, .{ "f", "zoom" }, .{ "tab", "next" }, .{ "?", "help" }, .{ "q", "quit" } },
            .node => &.{ .{ "space", "run" }, .{ "s", "step" }, .{ "n", "step node" }, .{ "z", "back" }, .{ "b", "breakpoint" }, .{ "w", "watch" }, .{ "up/down", "move" }, .{ "g", "follow" }, .{ "f", "zoom" }, .{ "tab", "next" }, .{ "?", "help" } },
            .debug => switch (self.debug) {
                .trace => &.{ .{ "h/l", "views" }, .{ "t", "trace or stop" }, .{ "o", "only this node" }, .{ "c", "clear" }, .{ "w", "save trace.txt" }, .{ "pgup/pgdn", "scroll" }, .{ "space", "run" }, .{ "tab", "next" }, .{ "?", "help" } },
                .breakpoints => &.{ .{ "h/l", "views" }, .{ "up/down", "choose" }, .{ "enter", "show" }, .{ "x", "remove" }, .{ "X", "remove all" }, .{ "space", "run" }, .{ "tab", "next" }, .{ "?", "help" } },
                .history => &.{ .{ "h/l", "views" }, .{ "up/down", "choose" }, .{ "enter", "go back" }, .{ "space", "run" }, .{ "tab", "next" }, .{ "?", "help" } },
            },
        };
        var segments: [4 + 2 * 13]vaxis.Segment = undefined;
        var len: usize = 0;
        segments[len] = state;
        len += 1;
        if (self.inserting) {
            segments[len] = .{ .text = " typing ", .style = .{ .fg = .{ .index = 4 }, .reverse = true, .bold = true } };
            len += 1;
        }
        segments[len] = .{ .text = self.print(" {d} steps ", .{self.chip.steps}), .style = colors.dim };
        len += 1;
        if (self.message) |message| {
            segments[len] = .{ .text = self.print(" {s} ", .{message}), .style = colors.literal };
            len += 1;
        }
        for (hints) |hint| {
            segments[len] = .{ .text = self.print(" {s}", .{hint[0]}), .style = colors.label };
            segments[len + 1] = .{ .text = self.print(" {s} ", .{hint[1]}) };
            len += 2;
        }
        if (self.options.colorforth != null and self.focus == .map) {
            segments[len] = .{ .text = " alt+6", .style = colors.label };
            segments[len + 1] = .{ .text = " colorforth " };
            len += 2;
        }
        _ = win.print(segments[0..len], .{ .wrap = .none });
    }

    /// the ports of the selected node that are watched, such as `reads
    /// right, writes up`
    fn watches(self: *Tui) []const u8 {
        var text: []const u8 = "";
        for (self.chip.watches.items()) |w| if (w.index == self.selected) {
            const separator = if (text.len == 0) "" else ", ";
            text = self.print("{s}{s}{s} {t}", .{ text, separator, if (w.write) "writes" else "reads", w.direction });
        };
        return if (text.len == 0) "none, w to add" else text;
    }

    fn disassemble(self: *Tui, word: Word, address: u9) []const u8 {
        const buffer = self.frame.allocator().alloc(u8, 48) catch return "";
        var writer: Io.Writer = .fixed(buffer);
        disassembler.write(&writer, word, address) catch {};
        return writer.buffered();
    }

    fn literal(self: *Tui, word: Word) []const u8 {
        const buffer = self.frame.allocator().alloc(u8, 32) catch return "";
        var writer: Io.Writer = .fixed(buffer);
        disassembler.writeLiteral(&writer, word) catch {};
        return writer.buffered();
    }

    /// the 8 entries of a circular stack below its top, most recent first
    fn stack(self: *Tui, entries: *const [8]Word, index: u3) []const u8 {
        var text: []const u8 = "";
        for (1..9) |i| {
            const entry = entries[index -% @as(u3, @intCast(i % 8))];
            text = self.print("{s}{x:0>5} ", .{ text, @as(u18, @bitCast(entry)) });
        }
        return text;
    }
};

/// the address of a row of the memory listing, unless it is a heading
fn rowAddress(row: u16) ?u9 {
    if (row == 0 or row == 65 or row >= memory_rows) return null;
    return @intCast(if (row > 65) 0x80 + row - 66 else row - 1);
}

/// the row of an address in the memory listing, if it is in memory
fn memoryRow(address: Address) ?u16 {
    if (address.io) return null;
    const i = address.local % 64;
    return if (address.rom) 65 + 1 + i else 1 + i;
}

/// how a token in a color is drawn, with white in the terminal's own color
fn tokenStyle(color: Color) vaxis.Style {
    return switch (color) {
        .red => .{ .fg = .{ .index = 1 }, .bold = true },
        .yellow => .{ .fg = .{ .index = 3 } },
        .green => .{ .fg = .{ .index = 2 } },
        .cyan => .{ .fg = .{ .index = 6 } },
        .white => .{},
        .magenta => .{ .fg = .{ .index = 5 } },
        .gray => .{ .fg = .{ .index = 8 } },
        .blue => .{ .fg = .{ .index = 4 } },
        .none => .{ .dim = true },
    };
}

fn statusStyle(s: Computer.Status) vaxis.Style {
    return switch (s) {
        .running => .{ .fg = .{ .index = 2 }, .bold = true },
        .code => .{ .dim = true },
        .reading, .writing => .{ .fg = .{ .index = 3 } },
    };
}

/// Shows the chip until the user quits
pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map, chip: *Chip, options: Options) !void {
    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, environ, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    // Cells are all the mouse needs. Pixel coordinates do not reach programs
    // in some terminal multiplexers, such as herdr with a client that cannot
    // report them.
    vx.caps.sgr_pixels = false;
    try vx.setMouseMode(tty.writer(), true);

    // and one more, saved before each step or run
    var history: [history_capacity + 1]?Chip.Snapshot = @splat(null);
    var tui: Tui = .init(io, gpa, chip, options);
    defer tui.deinit();
    tui.history = &history;
    tui.start = try .init(gpa, chip.layout);
    chip.save(&tui.start.?);
    while (true) {
        // wait for the user unless the chip has something to do
        const busy = tui.running and !tui.settled;
        var next: ?Event = if (busy) try loop.tryEvent() else try loop.nextEvent();
        while (next) |event| : (next = try loop.tryEvent()) {
            if (event == .winsize) try vx.resize(gpa, tty.writer(), event.winsize);
            if (!try tui.handle(event)) return;
        }
        if (tui.running and !tui.settled) try tui.run();

        tui.draw(vx.window());
        try vx.render(tty.writer());
    }
}

/// words that could complete what was typed into the aaforth panel, up to as
/// many as are listed
const Completions = struct {
    partial: []const u8,
    found: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn add(self: *Completions, word: []const u8) void {
        // a word can be both an opcode and a label, or several labels
        for (self.found[0..@min(self.len, self.found.len)]) |other| if (std.mem.eql(u8, other, word)) return;
        if (self.len < self.found.len) self.found[self.len] = word;
        self.len += 1;
    }
};

/// How the map draws nodes: as their numbers, or with more room, as tiles of
/// their registers, with gaps between them for arrows
const Tiles = struct {
    width: u16,
    height: u16,
    /// columns and rows between tiles
    gap_x: u16,
    gap_y: u16,

    const compact: Tiles = .{ .width = cell_width - 1, .height = 1, .gap_x = 1, .gap_y = 0 };
    /// big enough for a node's registers on a few lines, with arrows in the
    /// middle of the gaps
    const comfortable: Tiles = .{ .width = 12, .height = 4, .gap_x = 3, .gap_y = 1 };
    const smallest: Tiles = .{ .width = 8, .height = 2, .gap_x = 3, .gap_y = 1 };
    const largest: Tiles = .{ .width = 16, .height = 6, .gap_x = 3, .gap_y = 1 };

    /// Tiles every node fits in `win` with, if they are at least
    /// comfortable, and as large as fit up to the largest. Otherwise
    /// comfortable tiles to scroll through, if at least two by two fit, or
    /// every node in the smallest tiles or larger, and with too little room
    /// for those, compact ones. For `numbers`, compact ones, and for
    /// `registers`, comfortable ones to scroll through however little room.
    fn fit(win: vaxis.Window, layout: Chip.Layout, mode: MapMode) Tiles {
        if (mode == .numbers) return compact;
        const width = win.width / layout.columns;
        const height = win.height / layout.rows;
        const c = comfortable;
        if (width >= c.width + c.gap_x and height >= c.height + c.gap_y) {
            return .{ .width = @min(width - c.gap_x, largest.width), .height = @min(height - c.gap_y, largest.height), .gap_x = c.gap_x, .gap_y = c.gap_y };
        }
        if (mode == .registers or (win.width >= 2 * c.width + c.gap_x and win.height >= 2 * c.height + c.gap_y)) return c;
        const s = smallest;
        if (width >= s.width + s.gap_x and height >= s.height + s.gap_y) {
            return .{ .width = @min(width - s.gap_x, largest.width), .height = @min(height - s.gap_y, largest.height), .gap_x = s.gap_x, .gap_y = s.gap_y };
        }
        return compact;
    }

    /// how many columns and rows of tiles `win` shows, at least one of each
    fn inView(self: Tiles, win: vaxis.Window) struct { u16, u16 } {
        return .{
            @max((win.width + self.gap_x) / (self.width + self.gap_x), 1),
            @max((win.height + self.gap_y) / (self.height + self.gap_y), 1),
        };
    }
};

fn arrow(cardinal: Chip.Cardinal) []const u8 {
    return switch (cardinal) {
        .north => "▴",
        .east => "▸",
        .south => "▾",
        .west => "◂",
    };
}

/// a TUI showing a GA144 sized chip loaded with `source`, for tests
const TestTui = struct {
    chip: Chip,
    input_buffer: [16]u8 = undefined,
    input: Io.Queue(u8) = undefined,
    output_buffer: [console_capacity]u8 = undefined,
    output: Io.Writer = undefined,
    console: Console = undefined,
    screen: vaxis.Screen = undefined,
    /// keeping two
    history: [3]?Chip.Snapshot = @splat(null),
    tui: Tui = undefined,

    fn init(self: *TestTui, source: []const u8) !void {
        return self.initLayout(source, .ga144);
    }

    fn initLayout(self: *TestTui, source: []const u8, spec: gasim.Spec) !void {
        const gpa = std.testing.allocator;
        self.chip = try .init(gpa, spec);
        errdefer self.chip.deinit(gpa);
        var programs: [4]gasim.assembler.Program = undefined;
        var diagnostic: gasim.assembler.Diagnostic = .{};
        for (try gasim.assembler.assembleNodesFor(&spec, source, &programs, &diagnostic)) |program| try self.chip.load(program);

        self.input = .init(&self.input_buffer);
        self.output = .fixed(&self.output_buffer);
        self.console = .{ .input = .{ .io = std.testing.io, .queue = &self.input }, .output = &self.output };
        try self.chip.attachConsole(&self.console, 0, .up);
        self.screen = try .init(gpa, .{ .rows = 30, .cols = 120, .x_pixel = 0, .y_pixel = 0 });
        self.tui = .init(std.testing.io, gpa, &self.chip, .{ .source_path = "test.ga", .console = &self.console, .console_node = 0, .console_port = .up });
        self.tui.history = &self.history;
    }

    fn deinit(self: *TestTui) void {
        self.tui.deinit();
        self.screen.deinit(std.testing.allocator);
        self.chip.deinit(std.testing.allocator);
    }

    fn draw(self: *TestTui) void {
        self.tui.draw(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &self.screen });
    }

    fn press(self: *TestTui, codepoint: u21) !void {
        var buffer: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &buffer);
        const text: ?[]const u8 = if (codepoint < 0x80) buffer[0..len] else null;
        try expect(try self.tui.handle(.{ .key_press = .{ .codepoint = codepoint, .text = text } }));
        self.draw();
    }

    fn pressWith(self: *TestTui, codepoint: u21, mods: vaxis.Key.Modifiers) !void {
        try expect(try self.tui.handle(.{ .key_press = .{ .codepoint = codepoint, .mods = mods } }));
        self.draw();
    }

    fn click(self: *TestTui, col: u16, row: u16, kind: vaxis.Mouse.Type) !void {
        try expect(try self.tui.handle(.{ .mouse = .{ .col = @intCast(col), .row = @intCast(row), .button = .left, .mods = .{}, .type = kind } }));
        self.draw();
    }

    /// whether the screen shows `text` on a row
    fn shows(self: *TestTui, row: u16, text: []const u8) !bool {
        var line: [120]u8 = undefined;
        for (0..120) |col| {
            const cell = self.screen.readCell(@intCast(col), row) orelse break;
            line[col] = if (cell.char.grapheme.len == 1) cell.char.grapheme[0] else '#';
        }
        return std.mem.indexOf(u8, &line, text) != null;
    }
};

test "draws the chip, console and selected node" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("up b! 72 !b left b! @b");
    defer t.deinit();
    t.draw();

    try expect(try t.shows(0, "1 chip 8x18"));
    try expect(try t.shows(0, "3 node 000"));
    try expect(try t.shows(1, "700 701"));
    try expect(try t.shows(8, "000 001"));
    try expect(try t.shows(10, "2 console 000:up"));
    try expect(try t.shows(14, "RAM"));
    try expect(try t.shows(15, ">000"));

    // stepping follows the node that runs, and the console shows its output
    try t.press('s');
    try t.press('s');
    try expect(try t.shows(0, "3 node 001"));
    for (0..4) |_| try t.press('n');
    try t.press(vaxis.Key.left);
    try expect(try t.shows(0, "3 node 000"));
    // node 000 writes to the console, which takes it in the next round
    try t.press('S');
    try t.press('S');
    try expect(try t.shows(11, "H"));

    // hiding and zooming panels
    try t.press('1');
    try expect(try t.shows(0, "2 console"));
    try t.press('1');
    // tab moves on from the map to the console, which keeps tab while
    // typing, and alt with a digit moves to a panel from anywhere
    t.tui.focus = .map;
    try t.press(vaxis.Key.tab);
    try expectEqual(.console, t.tui.focus);
    try t.press('i');
    try t.press(vaxis.Key.tab);
    try expectEqual(.console, t.tui.focus);
    try t.pressWith('3', .{ .alt = true });
    try expectEqual(.node, t.tui.focus);
    try t.press('f');
    try expect(!try t.shows(0, "1 chip"));
    try expect(try t.shows(0, "3 node 000"));
    try t.press(vaxis.Key.page_down);
    try expect(t.tui.memory_scroll != null);
    try t.press('g');
    try expectEqual(null, t.tui.memory_scroll);
    try t.press(vaxis.Key.escape);
    try expect(try t.shows(0, "1 chip"));

    // borders move by dragging, or by tapping them and then where they go
    const border = t.tui.column_border.?;
    try t.click(border, 5, .press);
    try t.click(border - 10, 5, .drag);
    try t.click(border - 10, 5, .release);
    try expectEqual(border - 10, t.tui.column_border.?);
    try expectEqual(null, t.tui.message);
    try t.click(border - 10, 5, .press);
    try t.click(border - 10, 5, .release);
    try t.click(border - 4, 5, .press);
    try t.click(border - 4, 5, .release);
    try expectEqual(border - 4, t.tui.column_border.?);
    // clicking a node selects it
    try t.click(1, 8, .press);
    try expectEqual(.map, t.tui.focus);
    try expect(try t.shows(0, "3 node 000"));

    // typing into the console, after the map
    try t.press(vaxis.Key.tab);
    try expectEqual(.console, t.tui.focus);
    try t.press('i');
    try t.press('h');
    try t.press('i');
    try expect(try t.shows(27, "> hi"));
    try t.press(vaxis.Key.enter);
    var sent: [3]u8 = undefined;
    try expectEqual(3, try t.input.get(std.testing.io, &sent, 0));
    try expectEqualStrings("hi\n", &sent);
}

test "help lists the keys, and scrolls" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    t.draw();

    try t.press('?');
    // more below, after the title in the middle of the screen
    const more = (120 - (help_key_width + 60)) / 2 + 2 + "help ".len;
    try expect(try t.shows(0, "help #"));
    try expectEqualStrings("↓", t.screen.readCell(more, 0).?.char.grapheme);
    try expect(try t.shows(1, "everywhere"));
    try expect(try t.shows(2, "F1, ?"));
    // keys scroll it rather than reaching the chip
    try t.press('s');
    try expectEqual(0, t.tui.chip.steps);
    try t.press('j');
    try expect(try t.shows(1, "F1, ?"));
    try t.press('G');
    try expect(try t.shows(27, "esc, q, ?, F1"));
    try expectEqualStrings("↑", t.screen.readCell(more, 0).?.char.grapheme);
    try expectEqualStrings("─", t.screen.readCell(more + 1, 0).?.char.grapheme);
    try expect(try t.tui.handle(.{ .mouse = .{ .col = 50, .row = 10, .button = .wheel_up, .mods = .{}, .type = .press } }));
    try expectEqual(help_rows - t.tui.help_page - 3, t.tui.help_scroll.?);
    try t.press('g');
    try expectEqual(0, t.tui.help_scroll.?);
    try t.press(vaxis.Key.escape);
    try expectEqual(null, t.tui.help_scroll);
    try expect(try t.shows(0, "1 chip"));

    // ? is typed into the console, and F1 shows the help from it
    try t.pressWith('2', .{ .alt = true });
    try t.press('?');
    try expectEqualStrings("?", t.tui.input[0..t.tui.input_len]);
    try t.press(vaxis.Key.f1);
    try expect(try t.shows(1, "everywhere"));
    try t.press(vaxis.Key.f1);
    try expectEqual(null, t.tui.help_scroll);
}

test "types into the console only after i, and ends moving a border with a key" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    t.draw();

    // alt+2 types into the console, with the cursor shown, and escape
    // stops typing, staying in the console
    try t.pressWith('2', .{ .alt = true });
    try expect(t.tui.inserting);
    try expect(t.screen.cursor_vis);
    try t.press('f');
    try expectEqualStrings("f", t.tui.input[0..t.tui.input_len]);
    try t.press(vaxis.Key.escape);
    try expect(!t.tui.inserting);
    try expect(!t.screen.cursor_vis);
    try expectEqual(.console, t.tui.focus);

    // and then keys are the panels': zooming, stepping, and leaving
    try t.press('f');
    try expectEqual(.console, t.tui.zoomed);
    try expectEqualStrings("f", t.tui.input[0..t.tui.input_len]);
    try t.press('s');
    try expectEqual(1, t.tui.chip.steps);
    try t.press(vaxis.Key.escape);
    try expectEqual(null, t.tui.zoomed);
    try expectEqual(.console, t.tui.focus);
    try t.press(vaxis.Key.tab);
    try expect(t.tui.focus != .console);

    // tab to the console does not type into it, and i or enter does
    t.tui.focus = .map;
    try t.press(vaxis.Key.tab);
    try expectEqual(.console, t.tui.focus);
    try expect(!t.tui.inserting);
    try t.press(vaxis.Key.enter);
    try expect(t.tui.inserting);
    try t.press(vaxis.Key.escape);

    // the console can be hidden from itself
    try t.press('2');
    try expect(!t.tui.shown.contains(.console));
    try expect(t.tui.focus != .console);
    try t.press('2');

    // clicking the prompt types into the console, and its output does not
    const console = t.tui.windows.get(.console).?;
    const x: u16 = @intCast(console.x_off);
    const y: u16 = @intCast(console.y_off);
    try t.click(x, y, .press);
    try expectEqual(.console, t.tui.focus);
    try expect(!t.tui.inserting);
    try t.click(x, y + console.height - 1, .press);
    try expect(t.tui.inserting);
    try t.pressWith('1', .{ .alt = true });
    try expect(!t.tui.inserting);

    // a key after tapping a border leaves it where it is
    const border = t.tui.column_border.?;
    try t.click(border, 5, .press);
    try t.click(border, 5, .release);
    try t.press('j');
    try t.click(1, 8, .press);
    try expectEqual(border, t.tui.column_border.?);
}

test "wraps the console, ends its input, and keeps sizes on screen" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();

    // a long line wraps, and a carriage return before a newline is dropped
    const long: [150]u8 = @splat('a');
    try t.output.writeAll(&long);
    try t.output.writeAll("\r\nend\n");
    t.draw();
    try expect(try t.shows(13, "#aaaa "));
    try expect(try t.shows(14, "#end "));
    // scrolling back past the start stops at the first page
    t.tui.console_scroll = 100;
    t.draw();
    try expectEqual(0, t.tui.console_scroll);

    // ctrl+d sends text typed so far, and then ends the input
    try t.pressWith('2', .{ .alt = true });
    try t.press('h');
    const ctrl_d: Event = .{ .key_press = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } };
    try expect(try t.tui.handle(ctrl_d));
    try expect(try t.tui.handle(ctrl_d));
    var sent: [2]u8 = undefined;
    try expectEqual(1, try t.input.get(std.testing.io, &sent, 0));
    try expectEqual('h', sent[0]);
    try expectError(error.Closed, t.input.get(std.testing.io, &sent, 0));
    try t.press('x');
    try t.press(vaxis.Key.enter);
    try expectEqualStrings("the console's input has ended", t.tui.message.?);

    // stepping waits for a pause
    t.tui.focus = .map;
    t.tui.running = true;
    try t.press('s');
    try expectEqualStrings("pause with space to step", t.tui.message.?);
    t.tui.running = false;

    // growing a panel past the screen, and back
    for (0..100) |_| try t.press('>');
    try t.press('<');
    try expectEqual(120 - 12 - 2, t.tui.column_border.?);

    // titles stay within their panels
    t.tui.left_width = 12;
    t.draw();
    try expect(try t.shows(t.tui.stacked[1].top, "2 console"));
    try expect(!try t.shows(t.tui.stacked[1].top, "000:up"));
}

test "stops at breakpoints set in the memory listing" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("begin dup drop again");
    defer t.deinit();
    t.tui.focus = .node;
    t.draw();

    // on the current word, and then the next one
    try t.press('b');
    try expect(t.tui.chip.breakpoints.contains(.init(0, 0)));
    try expect(try t.shows(15, "#>000"));
    try t.press(vaxis.Key.down);
    try t.press('b');
    try expect(t.tui.chip.breakpoints.contains(.init(0, 1)));
    // and cleared by clicking the left edge
    const left: u16 = @intCast(t.tui.memory_window.?.x_off);
    try t.click(left, 16, .press);
    try expect(!t.tui.chip.breakpoints.contains(.init(0, 1)));
    // clicking a word moves the cursor to it
    try t.click(left + 4, 17, .press);
    try expectEqual(3, t.tui.memory_cursor);

    // running stops when the node loops back
    t.tui.running = true;
    try t.tui.run();
    try expect(!t.tui.running);
    try expectEqualStrings("node 000 reached 000", t.tui.message.?);
}

test "breakpoints need a word in memory" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("dup");
    defer t.deinit();
    t.tui.focus = .node;
    // node 001 is waiting for code from its ports
    t.tui.select(1);
    try t.press('b');
    try expectEqualStrings("move to a word in memory first", t.tui.message.?);
    try expectEqual(0, t.tui.chip.breakpoints.len);

    // moving down starts at its first word
    try t.press('j');
    try t.press('b');
    try expect(t.tui.chip.breakpoints.contains(.init(1, 0)));
}

test "stops at watched transfers" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("up b! 72 !b left b! @b");
    defer t.deinit();
    t.tui.focus = .node;
    t.draw();
    try expect(try t.shows(12, "watch none"));

    // writes to up, and reads from left
    try t.press('w');
    try t.press('U');
    try t.press('w');
    try t.press('l');
    try expect(try t.shows(12, "watch writes up, reads left"));
    // another key leaves the watches as they were
    try t.press('w');
    try t.press('x');
    try expectEqual(2, t.tui.chip.watches.len);

    // the console reads the write in the round after
    t.tui.running = true;
    try t.tui.run();
    try expectEqualStrings("node 000 wrote 00048 to up", t.tui.message.?);
}

test memoryRow {
    try expectEqual(1, memoryRow(Address.fromWord(0)));
    try expectEqual(64, memoryRow(Address.fromWord(0x3f)));
    // RAM repeats at x040
    try expectEqual(1, memoryRow(Address.fromWord(0x40)));
    try expectEqual(66, memoryRow(Address.fromWord(0x80)));
    try expectEqual(76, memoryRow(Address.fromWord(0xca)));
    try expectEqual(null, memoryRow(Address.fromWord(0x1d5)));
}

test "goes back before steps" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("begin 1 + again");
    defer t.deinit();
    try t.press('z');
    try expectEqualStrings("nothing to go back to", t.tui.message.?);

    for (0..3) |_| try t.press('n');
    try expectEqual(3, t.tui.chip.steps);
    try t.press('z');
    try expectEqual(2, t.tui.chip.steps);
    try expectEqualStrings("back to 2 steps", t.tui.message.?);
    // the test history only keeps the last two
    try t.press('z');
    try expectEqual(1, t.tui.chip.steps);
    try t.press('z');
    try expectEqual(1, t.tui.chip.steps);
    try expectEqualStrings("nothing to go back to", t.tui.message.?);

    // and before running
    try t.press(' ');
    try t.tui.run();
    try t.press('z');
    try expectEqualStrings("pause with space to go back", t.tui.message.?);
    try t.press(' ');
    try t.press('z');
    try expectEqual(1, t.tui.chip.steps);
}

test "steps that change nothing are not gone back to" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("left b! @b");
    defer t.deinit();
    while (try t.tui.chip.advance()) {}

    // every node is waiting
    try t.press('S');
    try t.press('s');
    try t.press('z');
    try expectEqualStrings("nothing to go back to", t.tui.message.?);
    // each saved over the one before, so only one was allocated
    try expect(t.tui.history[0] != null and t.tui.history[1] == null);
}

const gasim = @import("gasim");
const Address = gasim.Address;
const Chip = gasim.Chip;
const Computer = gasim.Computer;
const Console = gasim.Console;
const Color = gasim.colorforth.Color;
const Diagnostic = gasim.assembler.Diagnostic;
const Direction = gasim.Direction;
const Editor = gasim.Editor;
const Tail = gasim.Tail;
const Instruction = gasim.Instruction;
const Word = gasim.Word;
const disassembler = gasim.disassembler;
const Session = gasim.arrayforth.Session;
const aforth = @import("aforth.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const vaxis = @import("vaxis");

test "the aaforth panel interprets arrayForth 3 at the selected node" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("up b! @b");
    defer t.deinit();
    var programs: [2]gasim.assembler.Program = undefined;
    var descriptors: [2]gasim.boot.Descriptor = undefined;
    var buffer: [forth_capacity]u8 = undefined;
    var output: Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    var session: Session = .init(&programs, &descriptors, &diagnostic, .{ .out = &output, .chip = &t.chip });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    t.tui.options.forth = .{ .session = &session, .output = &output, .diagnostic = &diagnostic, .arena = arena.allocator() };
    t.tui.shown.insert(.forth);
    try t.pressWith('4', .{ .alt = true });
    try expect(try t.shows(19, "4 aforth"));

    // NODE selects the node, and LIT pushes onto its stack
    for ("707 NODE x15. LIT") |c| try t.press(c);
    try expect(try t.shows(27, "000> 707 NODE x15. LIT"));
    try t.press(vaxis.Key.enter);
    const i = t.chip.layout.index(707).?;
    try expectEqual(i, t.tui.selected);
    try expectEqual(0x15, t.chip.nodes[i].data_stack.t);
    try expect(try t.shows(0, "3 node 707"));
    try expect(try t.shows(20, "000> 707 NODE x15. LIT"));
    try expect(try t.shows(21, " ok"));

    // the selected node is the target, and errors are shown
    for ("nothing") |c| try t.press(c);
    try t.press(vaxis.Key.enter);
    try expect(try t.shows(23, "error: UnknownWord at 'nothing'"));

    // up recalls lines typed before
    try t.press(vaxis.Key.up);
    try t.press(vaxis.Key.up);
    try expect(try t.shows(27, "707> 707 NODE x15. LIT"));

    // and down goes back to the line being typed
    try t.press(vaxis.Key.down);
    try t.press(vaxis.Key.down);
    try expect(!try t.shows(27, "707> 707"));

    // tab completes a word, as far as the words it could be agree, and
    // lists them when that adds nothing
    for ("RDU") |c| try t.press(c);
    try t.press(vaxis.Key.tab);
    try expect(try t.shows(27, "707> RDUP "));
    for ("R2") |c| try t.press(c);
    try t.press(vaxis.Key.tab);
    try expect(try t.shows(27, "707> RDUP R2"));
    try expect(try t.shows(24, " R2* R2/"));
    for (0..6) |_| try t.press(vaxis.Key.backspace);
    try expect(try t.shows(27, "707> "));

    // and the chip can go back to before a line, as before a step
    try t.press(vaxis.Key.escape);
    try t.press('z');
    try expectEqual(0, t.chip.nodes[i].data_stack.t);
}

test "alt or ctrl and a digit focus a panel, showing it" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    t.draw();
    try t.press('1');
    try expect(!t.tui.shown.contains(.map));
    t.tui.focus = .console;
    try t.pressWith('1', .{ .ctrl = true });
    try expectEqual(.map, t.tui.focus);
    try expect(t.tui.shown.contains(.map));
    // a panel filling the screen gives way to the one chosen
    t.tui.zoomed = .map;
    try t.pressWith('3', .{ .alt = true });
    try expectEqual(.node, t.tui.zoomed);
    // there is no aforth panel without a session
    try t.pressWith('4', .{ .alt = true });
    try expectEqual(.node, t.tui.focus);
}

test "alt and h j k l focus the panel that way" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    t.draw();

    // the map and the console on the left, and the node on the right
    t.tui.focus = .map;
    try t.pressWith('l', .{ .alt = true });
    try expectEqual(.node, t.tui.focus);
    // back to the panel left, rather than the console beside the middle
    try t.pressWith('h', .{ .alt = true });
    try expectEqual(.map, t.tui.focus);
    // nothing further up or left
    try t.pressWith('k', .{ .alt = true });
    try t.pressWith('h', .{ .alt = true });
    try expectEqual(.map, t.tui.focus);

    // typing into the console, as alt and a digit do, and still moving on
    try t.pressWith('j', .{ .alt = true });
    try expectEqual(.console, t.tui.focus);
    try expect(t.tui.inserting);
    try t.pressWith('l', .{ .alt = true });
    try expectEqual(.node, t.tui.focus);
    try expect(!t.tui.inserting);
    try t.pressWith('h', .{ .alt = true });
    try expectEqual(.console, t.tui.focus);

    // from the node, without a panel left before, the one beside its middle
    t.tui.focused_at = .initFill(0);
    t.tui.focus = .node;
    try t.pressWith('h', .{ .alt = true });
    try expectEqual(.console, t.tui.focus);

    // a panel filling the screen has none beside it
    try t.press(vaxis.Key.escape);
    try t.press('f');
    try t.pressWith('l', .{ .alt = true });
    try expectEqual(.console, t.tui.focus);
}

test "resizes the panels under the map" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    t.draw();
    // the map, the console and the debug panel
    try t.press('5');
    try expectEqual(3, t.tui.stacked_len);
    const map = t.tui.stacked[0];
    const console = t.tui.stacked[1];
    const debug = t.tui.stacked[2];

    // dragging the border between the console and the debug panel leaves
    // the map as it is
    try t.click(1, debug.top, .press);
    try t.click(1, debug.top - 2, .drag);
    try t.click(1, debug.top - 2, .release);
    try expectEqual(map.height, t.tui.stacked[0].height);
    try expectEqual(console.height - 2, t.tui.stacked[1].height);
    try expectEqual(debug.top - 2, t.tui.stacked[2].top);
    try expectEqual(debug.height + 2, t.tui.stacked[2].height);

    // and so does dragging the map's, keeping the debug panel's top
    try t.click(1, console.top, .press);
    try t.click(1, console.top + 1, .drag);
    try t.click(1, console.top + 1, .release);
    try expectEqual(map.height + 1, t.tui.stacked[0].height);
    try expectEqual(debug.top - 2, t.tui.stacked[2].top);

    // + lengthens the focused panel, moving its bottom border, or its top
    // one for the last, and - shortens it
    t.tui.focus = .console;
    try t.press('+');
    try expectEqual(debug.top - 1, t.tui.stacked[2].top);
    t.tui.focus = .debug;
    try t.press('+');
    try expectEqual(debug.top - 2, t.tui.stacked[2].top);
    try t.press('-');
    try expectEqual(debug.top - 1, t.tui.stacked[2].top);

    // a panel keeps rows of its own however far a border is dragged
    try t.click(1, t.tui.stacked[2].top, .press);
    try t.click(1, 29, .drag);
    try t.click(1, 29, .release);
    try expectEqual(3, t.tui.stacked[2].height);
    try t.click(1, t.tui.stacked[2].top, .press);
    try t.click(1, 0, .drag);
    try t.click(1, 0, .release);
    try expectEqual(t.tui.stacked[1].top + 3, t.tui.stacked[2].top);
}

test "the four panels on the left share it, and keep their places as one border moves" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    var programs: [1]gasim.assembler.Program = undefined;
    var descriptors: [1]gasim.boot.Descriptor = undefined;
    var buffer: [64]u8 = undefined;
    var output: Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    var session: Session = .init(&programs, &descriptors, &diagnostic, .{ .out = &output });
    t.tui.options.forth = .{ .session = &session, .output = &output, .diagnostic = &diagnostic, .arena = std.testing.allocator };
    t.tui.shown.insert(.forth);
    t.tui.shown.insert(.debug);

    // on a short screen, as evenly as before, with a row for each
    t.tui.draw(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 17, .screen = &t.screen });
    try expectEqual(4, t.tui.stacked_len);
    for (t.tui.stacked[1..4]) |stacked| try expect(stacked.height >= 2);

    // moving the map's border leaves the one between aforth and debug
    t.draw();
    const debug = t.tui.stacked[3].top;
    const console = t.tui.stacked[1].top;
    try t.click(1, console, .press);
    try t.click(1, console - 3, .drag);
    try t.click(1, console - 3, .release);
    try expectEqual(console - 3, t.tui.stacked[1].top);
    try expectEqual(debug, t.tui.stacked[3].top);
    try t.click(1, console - 3, .press);
    try t.click(1, console + 2, .drag);
    try t.click(1, console + 2, .release);
    try expectEqual(debug, t.tui.stacked[3].top);

    // alt and k from debug passes over panels with no rows inside
    t.tui.heights = .initFill(null);
    t.tui.draw(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 12, .screen = &t.screen });
    try expectEqual(0, t.tui.windows.get(.forth).?.height);
    t.tui.focus = .debug;
    try expect(try t.tui.handle(.{ .key_press = .{ .codepoint = 'k', .mods = .{ .alt = true } } }));
    try expect(t.tui.windows.get(t.tui.focus).?.height > 0);

    // - and + from the node panel do nothing with the map hidden
    t.tui.shown.remove(.map);
    t.draw();
    const top = t.tui.stacked[1].top;
    t.tui.focus = .node;
    try t.press('+');
    try expectEqual(top, t.tui.stacked[1].top);
}

test "a short screen leaves text panels no rows" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    var programs: [1]gasim.assembler.Program = undefined;
    var descriptors: [1]gasim.boot.Descriptor = undefined;
    var buffer: [64]u8 = undefined;
    var output: Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    var session: Session = .init(&programs, &descriptors, &diagnostic, .{ .out = &output });
    t.tui.options.forth = .{ .session = &session, .output = &output, .diagnostic = &diagnostic, .arena = std.testing.allocator };
    t.tui.shown.insert(.forth);
    // the console gets one row of the four below the map, inside its border
    for (8..14) |height| t.tui.draw(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = @intCast(height), .screen = &t.screen });
}

test "tiles are no larger than the largest" {
    const layout: Chip.Layout = .{ .rows = 2, .columns = 3 };
    // too short for comfortable tiles, but wide
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 300, .height = 8, .screen = undefined };
    const tiles: Tiles = .fit(win, layout, .auto);
    try expectEqual(Tiles.largest.width, tiles.width);
    try expectEqual(3, tiles.height);
}

test "the map shows nodes as tiles when it has room" {
    var t: TestTui = .{ .chip = undefined };
    try t.initLayout("", .{ .rows = 2, .columns = 3 });
    defer t.deinit();
    t.tui.focus = .map;
    try t.press('f');
    for (0..3) |_| try t.press('S');
    const tiles = t.tui.tiles;
    try expectEqual(16, tiles.width);
    try expectEqual(6, tiles.height);

    // node 000 is at the bottom left, inside the panel's border, with what
    // it is doing and its registers
    const row: u16 = 1 + tiles.height + tiles.gap_y;
    try expect(try t.shows(row, "000 code"));
    try expect(try t.shows(row + 1, "T0 S0"));
    // with labels in their own colour, and values not
    try expectEqual(colors.label.fg, t.screen.readCell(1, row + 1).?.style.fg);
    try expectEqual(vaxis.Color.default, t.screen.readCell(2, row + 1).?.style.fg);
    // and every node in view, so nothing out of it to show in the title
    try expectEqualStrings("─", t.screen.readCell(3 + "1 chip 2x3".len, 0).?.char.grapheme);

    // nodes waiting for code from each other, as after reset, have no
    // arrows between them
    try expectEqualStrings(" ", t.screen.readCell(1 + tiles.width + tiles.gap_x / 2, row + tiles.height / 2).?.char.grapheme);
    try expectEqualStrings(" ", t.screen.readCell(1 + tiles.width / 2, row - 1).?.char.grapheme);

    // arrows between tiles point the way words go between nodes
    const chip = &t.chip;
    chip.nodes[0].suspended = false;
    const right = chip.nodes[0].ports[@backingInt(Chip.portToward(0, 0, .east))];
    right.port.?.state = .{ .writing = .{ .side = right.side, .value = 1 } };
    const up = chip.nodes[0].ports[@backingInt(Chip.portToward(0, 0, .north))];
    up.port.?.state = .{ .reading = up.side.other() };
    t.draw();
    try expectEqualStrings("▸", t.screen.readCell(1 + tiles.width + tiles.gap_x / 2, row + tiles.height / 2).?.char.grapheme);
    try expectEqualStrings("▴", t.screen.readCell(1 + tiles.width / 2, row - 1).?.char.grapheme);

    // and clicking a tile selects its node
    try t.click(1 + tiles.width + tiles.gap_x + 2, 2, .press);
    try expectEqual(chip.layout.index(101).?, t.tui.selected);
    // but not the gap beside it
    try t.click(1 + tiles.width, row + 1, .press);
    try expectEqual(chip.layout.index(101).?, t.tui.selected);
}

test "the map scrolls through tiles too large to show every node" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    t.tui.focus = .map;
    try t.press('f');
    try expectEqual(Tiles.comfortable, t.tui.tiles);
    // with the north edge in view, clicking the room below the last row in
    // view selects nothing
    for (0..7) |_| try t.press(vaxis.Key.up);
    const selected = t.tui.selected;
    try expect(t.tui.windows.get(.map).?.height > 5 * 5);
    try t.click(2, 1 + 5 * 5, .press);
    try expectEqual(selected, t.tui.selected);
    for (0..7) |_| try t.press(vaxis.Key.down);
    // eight columns of five rows fit, and node 000 at the bottom left is in
    // view, in the fifth
    try expect(try t.shows(1 + 4 * 5, "000 "));
    try expect(!try t.shows(1, "700 "));
    // and the title shows there are more nodes north and east
    const after_title = 3 + "1 chip 8x18".len;
    try expectEqualStrings("↑", t.screen.readCell(after_title, 0).?.char.grapheme);
    try expectEqualStrings("→", t.screen.readCell(after_title + 1, 0).?.char.grapheme);

    // the view follows the selected node to the top right
    for (0..17) |_| try t.press(vaxis.Key.right);
    for (0..7) |_| try t.press(vaxis.Key.up);
    try expectEqual(t.chip.layout.index(717).?, t.tui.selected);
    try expect(try t.shows(1, "717 "));
    try expect(try t.shows(1, "710 "));
    try expect(!try t.shows(1, "709 "));
    try expectEqualStrings("↓", t.screen.readCell(after_title, 0).?.char.grapheme);
    try expectEqualStrings("←", t.screen.readCell(after_title + 1, 0).?.char.grapheme);
}

test "t chooses the map's tiles" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    t.draw();
    // too little room for tiles of registers
    try expectEqual(1, t.tui.tiles.height);
    try t.press('t');
    try expect(try t.shows(0, "1 chip 8x18 numbers"));
    try expectEqual(Tiles.compact, t.tui.tiles);
    // tiles of registers anyway, to scroll through
    try t.press('t');
    try expect(try t.shows(0, "1 chip 8x18 registers"));
    try expectEqual(Tiles.comfortable, t.tui.tiles);
    try t.press('t');
    try expectEqual(1, t.tui.tiles.height);
}

/// whether a panel shows `text` on one of its rows, or in its title
fn panelShows(t: *TestTui, panel: Panel, text: []const u8) !bool {
    const w = t.tui.windows.get(panel).?;
    const top: usize = @intCast(w.y_off - 1);
    for (top..top + 1 + w.height) |row| if (try t.shows(@intCast(row), text)) return true;
    return false;
}

test "the debug panel traces, lists breakpoints and watches, and goes back" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("begin 1 + again");
    defer t.deinit();
    t.draw();
    // hidden until asked for
    try expectEqual(null, t.tui.windows.get(.debug));
    try t.pressWith('5', .{ .alt = true });
    try expectEqual(.debug, t.tui.focus);
    try expect(try panelShows(&t, .debug, "5 trace"));

    // tracing the steps that run code, of every node or the selected one's
    try t.press('t');
    try expect(t.chip.trace != null);
    for (0..3) |_| try t.press('n');
    try expect(try panelShows(&t, .debug, "5 trace, tracing"));
    try expect(try panelShows(&t, .debug, "000 000 "));
    t.tui.select(1);
    try t.press('o');
    try expect(!try panelShows(&t, .debug, "000 000 "));
    try expect(try panelShows(&t, .debug, "only node 001"));
    // stopping keeps what was traced, until cleared
    try t.press('t');
    try expectEqual(null, t.chip.trace);
    try expect(t.tui.trace.?.writer.end > 0);
    try t.press('c');
    try expectEqual(0, t.tui.trace.?.writer.end);

    // the breakpoints and watches, to show or remove
    try t.press('l');
    try expect(try panelShows(&t, .debug, "none: b sets a breakpoint"));
    _ = try t.chip.breakpoints.toggle(.init(0, 1));
    _ = try t.chip.watches.toggle(.{ .index = 0, .direction = .right, .write = false });
    t.draw();
    try expect(try panelShows(&t, .debug, "5 breakpoints 1, watches 1"));
    try expect(try panelShows(&t, .debug, "000 stops at 001"));
    try expect(try panelShows(&t, .debug, "000 stops reading right"));
    try t.press(vaxis.Key.enter);
    try expectEqual(0, t.tui.selected);
    try expectEqual(memoryRow(.fromWord(1)), t.tui.memory_cursor);
    try t.press('j');
    try t.press('x');
    try expectEqual(0, t.chip.watches.len);
    // one on an I/O register, as --break can set, shows only its node
    _ = try t.chip.breakpoints.toggle(.init(1, 0x15d));
    t.tui.select(5);
    try t.press('j');
    try t.press(vaxis.Key.enter);
    try expectEqual(1, t.tui.selected);
    try t.press('X');
    try expectEqual(0, t.chip.breakpoints.len);

    // the steps kept, the latest first, to go back to; the test keeps two
    try t.press('l');
    try expect(try panelShows(&t, .debug, "5 history 2 of 2"));
    try expect(try panelShows(&t, .debug, "before a step of one node"));
    try t.press('j');
    try t.press('j');
    try t.press(vaxis.Key.enter);
    try expectEqual(1, t.chip.steps);
    try expectEqual(0, t.tui.history_len);
}

test "the history shown while running keeps the run to go back before" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("begin 1 + again");
    defer t.deinit();
    try t.press('n');
    try t.pressWith('5', .{ .alt = true });
    try t.press('l');
    try t.press('l');
    try expectEqual(.history, t.tui.debug);
    // drawn as the run starts, before the chip has changed
    try t.press(' ');
    try t.press('j');
    try t.tui.run();
    try t.press(' ');
    try t.press('z');
    try expectEqual(1, t.chip.steps);
}

test "steps say what they stepped" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("begin 1 + again");
    defer t.deinit();
    try t.press('s');
    try expectEqualStrings("stepped node 000", t.tui.message.?);
    try t.press('S');
    try expectEqualStrings("took a round of steps, the furthest behind first", t.tui.message.?);
    t.tui.select(1);
    try t.press('n');
    try expectEqualStrings("node 001 is still waiting", t.tui.message.?);
}

test "the colorForth editor, on a screen of its own" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    const editor = try std.testing.allocator.create(Editor);
    defer std.testing.allocator.destroy(editor);
    var blocks: [2 * gasim.colorforth.block_size]u8 = @splat(0);
    editor.open(&blocks, 2);
    t.tui.options.colorforth = .{ .editor = editor, .path = "test.cf", .compressed = false };
    t.draw();

    try expect(try t.shows(0, "1 chip"));
    try t.pressWith('6', .{ .alt = true });
    try expect(try t.shows(0, "6 colorforth  block 0  test.cf"));
    try expect(try t.shows(1, "An empty block"));
    // the help opens at the editor's keys
    try t.press('?');
    try expect(try t.shows(1, "colorForth editor"));
    try t.press('q');
    try expect(try t.shows(0, "6 colorforth"));
    // typing a definition, and making its last word yellow
    for ("iinc 1 + ;") |c| try t.press(c);
    try expect(try t.shows(29, "insert"));
    try t.pressWith('y', .{ .ctrl = true });
    try t.press(vaxis.Key.escape);
    try expect(try t.shows(1, "inc 1 + ;"));
    try expectEqual(.execute, editor.tokens[3].tag);
    try expect(try t.shows(0, "block 0 +"));
    try expect(try t.shows(29, "4/256 cells"));
    // a count before g goes to a block, rather than the keys of the map
    try t.press('1');
    try t.press('g');
    try expect(try t.shows(0, "block 1 +"));
    try expect(t.tui.shown.contains(.map));
    // named keys, and not keys with alt, or text pasted in normal mode
    try t.press(vaxis.Key.page_up);
    try expect(try t.shows(0, "block 0 +"));
    try t.press(vaxis.Key.end);
    try expectEqual(3, editor.cursor);
    try t.pressWith('h', .{ .alt = true });
    try expectEqual(3, editor.cursor);
    try expect(try t.tui.handle(.{ .key_press = .{ .codepoint = 'x', .text = "xxx" } }));
    try expectEqual(4, editor.len);
    // what the editor cannot do is said, and f hides blue words
    try t.press('9');
    try t.press('g');
    try expect(try t.shows(29, "there is no such block"));
    try t.press('f');
    try expect(!t.tui.show_format);
    try t.press('f');

    // and back to the chip, until alt+6 again
    try t.pressWith('1', .{ .alt = true });
    try expect(try t.shows(0, "1 chip"));
    try t.pressWith('6', .{ .alt = true });

    // quitting with blocks not saved takes asking twice
    try t.press('q');
    try expect(try t.shows(29, "q again quits"));
    try expect(!try t.tui.handle(.{ .key_press = .{ .codepoint = 'q', .text = "q" } }));
}

test "compiling colorForth in the editor starts the chip again with its code" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    t.tui.start = try .init(std.testing.allocator, t.chip.layout);
    t.chip.save(&t.tui.start.?);
    var programs: [2]gasim.assembler.Program = undefined;
    var descriptors: [2]gasim.boot.Descriptor = undefined;
    var buffer: [forth_capacity]u8 = undefined;
    var output: Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    var session: Session = .init(&programs, &descriptors, &diagnostic, .{ .out = &output, .chip = &t.chip });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    t.tui.options.forth = .{ .session = &session, .output = &output, .diagnostic = &diagnostic, .arena = arena.allocator() };
    const editor = try std.testing.allocator.create(Editor);
    defer std.testing.allocator.destroy(editor);
    var blocks: [gasim.colorforth.block_size]u8 = @splat(0);
    editor.open(&blocks, 1);
    t.tui.options.colorforth = .{ .editor = editor, .path = "test.cf", .compressed = false };
    try t.pressWith('6', .{ .alt = true });

    // echo, typed in yellow, red and green
    try t.press('i');
    try t.pressWith('y', .{ .ctrl = true });
    for ("0 node 0 org ") |c| try t.press(c);
    try t.pressWith('r', .{ .ctrl = true });
    for ("main up b! begin @b !b end") |c| try t.press(c);
    try t.press(vaxis.Key.escape);
    try t.press('L');
    try expect(try t.shows(29, "with 1 nodes' code"));
    const echo = try gasim.arrayforth.assemble("ASM[ # 0 NODE ERS # 0 org : main up b! begin @b !b again >BIN ]ASM", &diagnostic);
    try expectEqualSlices(gasim.Word, echo.ram[0..echo.len], t.chip.nodes[0].mem[0..echo.len]);

    // an error moves the cursor to the word
    try t.press('0');
    try t.press('l');
    try t.press('l');
    try t.press('l');
    try t.press('l');
    try t.press('a');
    for ("nothing") |c| try t.press(c);
    try t.press(vaxis.Key.escape);
    editor.first();
    try t.press('L');
    try expect(try t.shows(29, "UnknownWord at nothing in block 0"));
    try expectEqualStrings("nothing", editor.current().?.text());
}

test "the editor's commands save, open and start files" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const editor = try std.testing.allocator.create(Editor);
    defer std.testing.allocator.destroy(editor);
    var blocks: [4 * gasim.colorforth.block_size]u8 = @splat(0);
    editor.open(&blocks, 0);
    t.tui.options.colorforth = .{ .editor = editor, .path = null, .compressed = false };
    try t.pressWith('6', .{ .alt = true });
    try expect(try t.shows(0, "block 0  new file"));

    const typeLine = struct {
        fn typeLine(tt: *TestTui, line: []const u8) !void {
            for (line) |c| try tt.press(c);
            try tt.press(vaxis.Key.enter);
        }
    }.typeLine;

    // saving a new file asks for its name
    for ("iinc") |c| try t.press(c);
    try t.press(vaxis.Key.escape);
    try t.press('s');
    try expectEqualStrings("w ", t.tui.command[0..t.tui.command_len.?]);
    try expect(try t.shows(29, "name the new file"));
    var path_buffer: [96]u8 = undefined;
    const one = try std.fmt.bufPrint(&path_buffer, "{s}/one.cf", .{dir});
    try typeLine(&t, one);
    try expect(try t.shows(29, "saved 1 blocks"));
    try expect(try t.shows(0, "block 0  one.cf"));
    try expect(!editor.unsaved());
    const saved = try tmp.dir.readFileAlloc(std.testing.io, "one.cf", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(saved);
    try expectEqual(gasim.colorforth.block_size, saved.len);

    // a new file, and opening one, let unsaved blocks go only with !
    try t.press('a');
    for (" dec") |c| try t.press(c);
    try t.press(vaxis.Key.escape);
    try typeLine(&t, ":new");
    try expect(try t.shows(29, ":new! lets them go"));
    try typeLine(&t, ":new!");
    try expect(try t.shows(0, "block 0  new file"));
    try expectEqual(0, editor.len);
    try typeLine(&t, ":e");
    try expect(try t.shows(29, "name the file to open"));
    // tab completes the name of a .cf file
    try t.press(':');
    for ("e ") |c| try t.press(c);
    for (dir) |c| try t.press(c);
    for ("/o") |c| try t.press(c);
    try t.press(vaxis.Key.tab);
    var expected: [96]u8 = undefined;
    try expectEqualStrings(try std.fmt.bufPrint(&expected, "e {s}", .{one}), t.tui.command[0..t.tui.command_len.?]);
    try t.press(vaxis.Key.enter);
    try expect(try t.shows(0, "block 0  one.cf"));
    try expect(try t.shows(1, "inc"));

    // saving as another file, which becomes the editor's
    const two = try std.fmt.bufPrint(&path_buffer, ":w {s}/two.cf", .{dir});
    try typeLine(&t, two);
    try expect(try t.shows(0, "block 0  two.cf"));
    try tmp.dir.access(std.testing.io, "two.cf", .{});
    // a file that is not there is new, and esc and an unknown command do nothing
    const three = try std.fmt.bufPrint(&path_buffer, ":e {s}/three.cf", .{dir});
    try typeLine(&t, three);
    try expect(try t.shows(29, "three.cf is new"));
    try t.press(':');
    try t.press('x');
    try t.press(vaxis.Key.escape);
    try expectEqual(null, t.tui.command_len);
    try typeLine(&t, ":nonsense");
    try expect(try t.shows(29, "no command nonsense"));
    // saving as a file that is there takes !
    const over = try std.fmt.bufPrint(&path_buffer, ":w {s}/one.cf", .{dir});
    try typeLine(&t, over);
    try expect(try t.shows(29, "one.cf exists: :w! saves over it"));
    try expect(try t.shows(0, "block 0  three.cf"));
    // a long command stops at the end of the line
    try t.press(':');
    for (0..300) |_| try t.press('a');
    try expectEqual(t.tui.command.len, t.tui.command_len.?);
    try t.press(vaxis.Key.escape);
    // a file as big as the blocks the editor has opens
    var full: [4 * gasim.colorforth.block_size]u8 = @splat(0);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "full.cf", .data = &full });
    const full_path = try std.fmt.bufPrint(&path_buffer, ":e {s}/full.cf", .{dir});
    try typeLine(&t, full_path);
    try expect(try t.shows(29, "opened 4 blocks"));
    // :q with blocks not saved asks for :q!, however often it is typed
    try t.press('i');
    try t.press('x');
    try t.press(vaxis.Key.escape);
    try typeLine(&t, ":q");
    try expect(try t.shows(29, ":q! quits"));
    try typeLine(&t, ":q");
    try expect(try t.shows(29, ":q! quits"));
    for (":q!") |c| try t.press(c);
    try expect(!try t.tui.handle(.{ .key_press = .{ .codepoint = vaxis.Key.enter } }));
}
