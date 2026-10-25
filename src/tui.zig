//! A terminal user interface for watching and controlling a chip: a map of
//! its nodes, the registers, stacks and memory of the selected node, the
//! console, and arrayForth 3 typed at the chip with the words of its IDE.
//! Panels can be hidden, zoomed to fill the screen, resized and scrolled.

/// bytes of console output kept for display
pub const console_capacity = 16 * 1024;

pub const Options = struct {
    source_path: []const u8,
    /// attached to the chip, with its output writing into a fixed buffer of
    /// `console_capacity` bytes
    console: *Console,
    console_node: u16,
    console_port: Direction,
    /// arrayForth 3 typed into the forth panel, if it is shown
    forth: ?Forth = null,
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

/// bytes of the forth panel's output kept for display
pub const forth_capacity = 16 * 1024;

/// lines typed into the forth panel that up and down recall
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

const Panel = enum { map, console, forth, node };

/// the border between the left panels and the node panel, or between the
/// map and the console
const Border = enum { columns, rows };

const colors = struct {
    const label: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true };
    const address: vaxis.Style = .{ .fg = .{ .index = 4 } };
    const raw: vaxis.Style = .{ .fg = .{ .index = 8 } };
    const literal: vaxis.Style = .{ .fg = .{ .index = 3 } };
    const heading: vaxis.Style = .{ .bold = true };
    const dim: vaxis.Style = .{ .dim = true };
    const breakpoint: vaxis.Style = .{ .fg = .{ .index = 1 }, .bold = true };
};

/// a key and what it does, for the status bar
const Hint = struct { []const u8, []const u8 };

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
    focus: Panel = .map,
    shown: std.EnumSet(Panel) = .full,
    zoomed: ?Panel = null,
    /// sizes chosen by the user, rather than fitting the chip
    left_width: ?u16 = null,
    map_height: ?u16 = null,
    /// a border being moved, by dragging it, or by tapping it and then
    /// where it should go, for touch screens that do not report drags
    dragging: ?Border = null,
    /// whether the border being moved has been dragged
    dragged: bool = false,

    input: [256]u8 = undefined,
    input_len: u8 = 0,
    /// rows of console output scrolled back from the end
    console_scroll: usize = 0,
    /// the line being typed into the forth panel, and rows of its output
    /// scrolled back from the end
    forth_input: [256]u8 = undefined,
    forth_input_len: u8 = 0,
    forth_scroll: usize = 0,
    /// lines typed into the forth panel, the latest last, and how far back
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
    /// a message for the status bar, until the next key
    message: ?[]const u8 = null,
    message_buffer: [64]u8 = undefined,
    /// the next key chooses a port of the selected node to watch
    choosing_watch: bool = false,
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

    /// where panels were last drawn, for the mouse
    windows: std.EnumArray(Panel, ?vaxis.Window) = .initFill(null),
    memory_window: ?vaxis.Window = null,
    /// the column of the border between the left panels and the node panel,
    /// and the row of the border between the map and the console
    column_border: ?u16 = null,
    row_border: ?u16 = null,

    /// text drawn in a frame, which must last until the frame is rendered
    frame_buffer: [64 * 1024]u8 = undefined,
    frame: std.heap.FixedBufferAllocator = undefined,

    fn init(io: Io, gpa: Allocator, chip: *Chip, options: Options) Tui {
        var tui: Tui = .{ .io = io, .gpa = gpa, .chip = chip, .options = options, .selected = chip.layout.index(options.console_node) orelse 0 };
        if (options.forth == null) tui.shown.remove(.forth);
        return tui;
    }

    fn deinit(self: *Tui) void {
        for (self.history) |*snapshot| if (snapshot.*) |*s| s.deinit(self.gpa);
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
                // a key ends moving a border by tapping
                self.dragging = null;
                if (k.matches('c', .{ .ctrl = true })) return false;
                if (self.focus == .console and try self.consoleKey(k)) return true;
                if (self.focus == .forth and try self.forthKey(k)) return true;
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
        if (k.matches('q', .{})) return false;
        // matching text would take tab for shift+tab too
        if (k.codepoint == vaxis.Key.tab) self.cycleFocus(if (k.mods.shift) -1 else 1);
        if (k.matches(vaxis.Key.escape, .{})) self.zoomed = null;
        if (k.matches('f', .{})) self.zoomed = if (self.zoomed == null) self.focus else null;
        for ([_]Panel{ .map, .console, .node, .forth }, "1234") |panel, digit| {
            if (k.matches(digit, .{}) and (panel != .forth or self.options.forth != null)) self.toggle(panel);
        }

        // resizing
        if (k.matches('<', .{})) self.left_width = (self.left_width orelse self.defaultLeftWidth()) -| 2;
        if (k.matches('>', .{})) self.left_width = (self.left_width orelse self.defaultLeftWidth()) + 2;
        if (k.matches('-', .{})) self.map_height = (self.map_height orelse self.defaultMapHeight()) -| 1;
        if (k.matchesAny(&.{ '+', '=' }, .{})) self.map_height = (self.map_height orelse self.defaultMapHeight()) + 1;

        // running and stepping
        if (k.matches(' ', .{})) {
            if (!self.running) self.remember();
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
            if (stepping) self.remember();
            if (k.matches('s', .{})) {
                // the next node to run, which the view follows
                self.trimOutput();
                if (try self.chip.stepNext()) |i| {
                    self.select(i);
                } else self.message = "every node is waiting";
            }
            if (k.matches('S', .{})) {
                if (!try self.advance()) self.message = "every node is waiting";
            }
            if (k.matches('n', .{})) {
                self.trimOutput();
                _ = try self.chip.service();
                self.chip.stepNode(self.selected);
                self.memory_scroll = null;
                if (self.chip.nodes[self.selected].suspended) self.message = "the node is waiting";
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
            .console, .forth => {},
        }
        return true;
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
    }

    /// Handles keys typed into the console, returning false for keys it
    /// leaves to the panels: tab to move on, and escape to leave
    fn consoleKey(self: *Tui, k: vaxis.Key) !bool {
        if (k.codepoint == vaxis.Key.tab) {
            return false;
        } else if (k.matches(vaxis.Key.escape, .{})) {
            // to a panel in view, rather than one hidden by zooming
            self.zoomed = null;
            for ([_]Panel{ .map, .node }) |panel| if (self.shown.contains(panel)) {
                self.focus = panel;
                break;
            };
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
                self.options.console.input.close(self.io);
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

    /// Handles keys typed into the forth panel, returning false for keys it
    /// leaves to the panels: tab to move on, and escape to leave
    fn forthKey(self: *Tui, k: vaxis.Key) !bool {
        if (k.codepoint == vaxis.Key.tab) {
            return false;
        } else if (k.matches(vaxis.Key.escape, .{})) {
            self.zoomed = null;
            for ([_]Panel{ .map, .node }) |panel| if (self.shown.contains(panel)) {
                self.focus = panel;
                break;
            };
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

    /// puts the line typed `lines_back` lines ago into the forth panel's
    /// input, or an empty line for none
    fn recall(self: *Tui, lines_back: usize) void {
        self.recalling = lines_back;
        const line: []const u8 = if (lines_back == 0) "" else self.recalled[(self.recalled_len - lines_back) % recall_capacity];
        const len = @min(line.len, self.forth_input.len);
        @memcpy(self.forth_input[0..len], line[0..len]);
        self.forth_input_len = @intCast(len);
    }

    /// Interprets the line typed into the forth panel, with the selected node
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
        if (!self.running) self.remember();
        forth.session.setTarget(layout.nodeNumber(self.selected));
        output.print("{d:0>3}> {s}\n", .{ layout.nodeNumber(self.selected), line }) catch {};
        repl.interpret(forth.session, line, forth.diagnostic, output) catch {
            self.message = "the forth panel's output is full";
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
        const sent = self.options.console.input.put(self.io, text, 0) catch |err| switch (err) {
            error.Closed => {
                self.message = "the console's input has ended";
                return;
            },
            else => |e| return e,
        };
        if (sent < text.len) self.message = "the console's input is full";
    }

    fn mouse(self: *Tui, m: vaxis.Mouse) void {
        if (m.type == .drag) if (self.dragging) |border| {
            self.moveBorder(border, m);
            self.dragged = true;
            return;
        };
        // a tap leaves the border to move with the next tap
        if (m.type == .release and self.dragged) self.dragging = null;
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
            return;
        }
        if (m.type != .press or m.button != .left) return;

        if (self.onBorder(m)) |border| {
            self.dragging = border;
            self.dragged = false;
            self.message = "drag the border, or tap where it should go";
            return;
        }

        for ([_]Panel{ .map, .console, .forth, .node }) |panel| {
            const w = self.windows.get(panel) orelse continue;
            if (w.hasMouse(m) == null) continue;
            self.focus = panel;
            if (panel == .node) if (self.memory_window) |listing| if (listing.hasMouse(m) != null) {
                const row = self.memoryFirstRow() + @as(u16, @intCast(m.row - listing.y_off));
                if (rowAddress(row) == null) return;
                // the left edge sets and clears breakpoints
                if (m.col - listing.x_off < 2) return self.toggleBreakpoint(row);
                self.memory_scroll = self.memoryFirstRow();
                self.memory_cursor = row;
            };
            if (panel == .map) {
                const column: u16 = @intCast(@divFloor(m.col - w.x_off, cell_width) + self.map_scroll.x);
                const row: u16 = @intCast(m.row - w.y_off + self.map_scroll.y);
                const layout = self.chip.layout;
                if (column < layout.columns and row < layout.rows) self.select((layout.rows - 1 - row) * layout.columns + column);
            }
        }
    }

    /// the border between panels under the mouse
    fn onBorder(self: Tui, m: vaxis.Mouse) ?Border {
        if (self.column_border) |column| if (m.col == column or m.col + 1 == column) return .columns;
        if (self.row_border) |row| if ((m.row == row or m.row + 1 == row) and (self.column_border == null or m.col < self.column_border.?)) return .rows;
        return null;
    }

    fn moveBorder(self: *Tui, border: Border, m: vaxis.Mouse) void {
        switch (border) {
            .columns => self.left_width = @intCast(@max(m.col, 0)),
            .rows => self.map_height = @intCast(@max(m.row, 0)),
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
    fn remember(self: *Tui) void {
        // one is saved before it is kept
        if (self.history.len < 2) return;
        self.keepPending();
        const snapshot = &self.history[self.historyIndex(self.history_len)];
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

    /// goes back to before the last step or run
    fn back(self: *Tui) void {
        self.keepPending();
        if (self.history_len == 0) {
            self.message = "nothing to go back to";
            return;
        }
        self.history_len -= 1;
        self.chip.restore(&self.history[self.historyIndex(self.history_len)].?);
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

    fn toggle(self: *Tui, panel: Panel) void {
        // keep one panel in view
        if (self.shown.contains(panel) and self.shown.count() == 1) return;
        self.shown.toggle(panel);
        if (self.zoomed == panel) self.zoomed = null;
        // rather than the console, where keys would be typed as input
        if (!self.shown.contains(self.focus)) {
            for ([_]Panel{ .node, .map, .console, .forth }) |other| if (self.shown.contains(other)) {
                self.focus = other;
                break;
            };
        }
    }

    /// moves the focus to the next panel in view
    fn cycleFocus(self: *Tui, direction: i2) void {
        const panels = [_]Panel{ .map, .console, .forth, .node };
        var i: usize = @backingInt(self.focus);
        for (0..panels.len) |_| {
            i = @intCast(@mod(@as(isize, @intCast(i)) + direction, panels.len));
            if (self.visible().contains(panels[i])) break;
        }
        self.focus = panels[i];
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

    /// rows of output a page of the console or forth panel shows
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
        win.clear();
        // until the console shows it
        win.hideCursor();
        self.windows = .initFill(null);
        self.memory_window = null;
        self.column_border = null;
        self.row_border = null;
        if (win.width < 30 or win.height < 8) {
            _ = win.printSegment(.{ .text = "The terminal is too small" }, .{});
            return;
        }

        const layout = self.chip.layout;
        const body_height = win.height - 1;
        const shown = self.visible();
        const below_map = shown.contains(.console) or shown.contains(.forth);
        const left = shown.contains(.map) or below_map;

        // the map and console on the left, and the node on the right
        var left_width: u16 = win.width;
        if (shown.contains(.node)) {
            left_width = if (left) std.math.clamp(self.left_width orelse @min(self.defaultLeftWidth(), win.width -| 36), 12, win.width - 12) else 0;
            if (left) {
                self.column_border = left_width;
                // so resizing back takes effect at once
                if (self.left_width != null) self.left_width = left_width;
            }
        }
        var map_height: u16 = body_height;
        if (shown.contains(.map) and below_map) {
            map_height = std.math.clamp(self.map_height orelse @min(self.defaultMapHeight(), body_height -| 5), 3, body_height - 3);
            self.row_border = map_height;
            if (self.map_height != null) self.map_height = map_height;
        } else if (!shown.contains(.map)) map_height = 0;

        if (shown.contains(.map)) {
            self.drawMap(self.drawPanel(win, .map, 0, 0, left_width, map_height, self.print("1 chip {d}x{d}", .{ layout.rows, layout.columns })));
        }
        // the console above the forth panel, sharing the rest of the column
        const rest = body_height - map_height;
        const console_height = if (shown.contains(.console) and shown.contains(.forth)) rest / 2 else rest;
        if (shown.contains(.console)) {
            self.drawConsole(self.drawPanel(win, .console, 0, map_height, left_width, console_height, self.print("2 console {d:0>3}:{t}", .{ self.options.console_node, self.options.console_port })));
        }
        if (shown.contains(.forth)) {
            const y = if (shown.contains(.console)) map_height + console_height else map_height;
            self.drawForth(self.drawPanel(win, .forth, 0, y, left_width, body_height - y, "4 forth"));
        }
        if (shown.contains(.node)) {
            self.drawNode(self.drawPanel(win, .node, left_width, 0, win.width - left_width, body_height, self.print("3 node {d:0>3}", .{layout.nodeNumber(self.selected)})));
        }
        self.drawStatus(win.child(.{ .y_off = body_height, .height = 1 }));
    }

    /// Draws a bordered panel with a title, returning the window inside it
    fn drawPanel(self: *Tui, win: vaxis.Window, which: Panel, x: u16, y: u16, width: u16, height: u16, title: []const u8) vaxis.Window {
        const style: vaxis.Style = if (self.focus == which) .{ .fg = .{ .index = 6 } } else colors.dim;
        const inside = win.child(.{ .x_off = x, .y_off = y, .width = width, .height = height, .border = .{ .where = .all, .style = style } });
        // within the top border
        const heading = win.child(.{ .x_off = x + 2, .y_off = y, .width = width -| 3, .height = 1 });
        _ = heading.printSegment(.{ .text = title, .style = .{ .bold = true } }, .{ .wrap = .none });
        self.windows.set(which, inside);
        return inside;
    }

    fn drawMap(self: *Tui, win: vaxis.Window) void {
        const layout = self.chip.layout;
        const columns = @max(win.width / cell_width, 1);
        const rows = @max(win.height, 1);

        // keep the selected node in view
        const x = self.selected % layout.columns;
        const row = layout.rows - 1 - self.selected / layout.columns;
        if (x < self.map_scroll.x) self.map_scroll.x = x;
        if (x >= self.map_scroll.x + columns) self.map_scroll.x = x + 1 - columns;
        if (row < self.map_scroll.y) self.map_scroll.y = row;
        if (row >= self.map_scroll.y + rows) self.map_scroll.y = row + 1 - rows;

        for (self.map_scroll.y..@min(layout.rows, self.map_scroll.y + rows)) |r| {
            const y = layout.rows - 1 - r;
            for (self.map_scroll.x..@min(layout.columns, self.map_scroll.x + columns)) |c| {
                const i: u16 = @intCast(y * layout.columns + c);
                var style = statusStyle(self.chip.nodes[i].status());
                if (i == self.selected) style.reverse = true;
                _ = win.printSegment(.{ .text = self.print("{d:0>3}", .{layout.nodeNumber(i)}), .style = style }, .{
                    .row_offset = @intCast(r - self.map_scroll.y),
                    .col_offset = @intCast((c - self.map_scroll.x) * cell_width),
                });
            }
        }
    }

    fn drawConsole(self: *Tui, win: vaxis.Window) void {
        const prompt = if (self.console_scroll > 0)
            self.print("  {d} lines back, pgdn to return", .{self.console_scroll})
        else
            self.print("> {s}", .{self.input[0..self.input_len]});
        self.drawText(win, .console, self.options.console.output.buffered(), &self.console_scroll, prompt);
    }

    fn drawForth(self: *Tui, win: vaxis.Window) void {
        const prompt = if (self.forth_scroll > 0)
            self.print("  {d} lines back, pgdn to return", .{self.forth_scroll})
        else
            self.print("{d:0>3}> {s}", .{ self.chip.layout.nodeNumber(self.selected), self.forth_input[0..self.forth_input_len] });
        self.drawText(win, .forth, self.options.forth.?.output.buffered(), &self.forth_scroll, prompt);
    }

    /// Draws the end of some output, `scroll` rows back from it, above a
    /// prompt with the cursor at its end when the panel has the focus and
    /// is not scrolled back
    fn drawText(self: *Tui, win: vaxis.Window, panel: Panel, output: []const u8, scroll: *usize, prompt: []const u8) void {
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
            var line_rows = @max(std.math.divCeil(usize, line.len, width) catch unreachable, 1);
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
            return self.drawText(win, panel, output, scroll, prompt);
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
        if (self.focus == panel and scroll.* == 0) win.showCursor(@intCast(@min(prompt.len, win.width - 1)), win.height - 1);
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
        const n = self.chip.nodes[self.selected];
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
        self.fields(win, 5, &.{.{ "time", self.print("{d:.1} ns", .{n.execution_time}) }});

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
    fn drawMemory(self: *Tui, win: vaxis.Window, n: Computer) void {
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

    fn drawStatus(self: *Tui, win: vaxis.Window) void {
        // reversed, so the text takes the theme's background colour
        const state: vaxis.Segment = if (!self.running)
            .{ .text = " paused ", .style = .{ .reverse = true, .bold = true } }
        else if (self.settled)
            .{ .text = " waiting ", .style = .{ .fg = .{ .index = 3 }, .reverse = true, .bold = true } }
        else
            .{ .text = " running ", .style = .{ .fg = .{ .index = 2 }, .reverse = true, .bold = true } };
        const hints: []const Hint = switch (self.focus) {
            .map => &.{ .{ "space", "run" }, .{ "s", "step" }, .{ "S", "round" }, .{ "n", "step node" }, .{ "z", "back" }, .{ "arrows", "select" }, .{ if (self.options.forth == null) "1-3" else "1-4", "panels" }, .{ "f", "zoom" }, .{ "tab", "next" }, .{ "q", "quit" } },
            .console => &.{ .{ "enter", "send" }, .{ "ctrl+d", "end input" }, .{ "pgup/pgdn", "scroll" }, .{ "tab", "next" }, .{ "esc", "map" } },
            .forth => &.{ .{ "enter", "interpret" }, .{ "up/down", "recall" }, .{ "pgup/pgdn", "scroll" }, .{ "tab", "next" }, .{ "esc", "map" } },
            .node => &.{ .{ "space", "run" }, .{ "s", "step" }, .{ "n", "step node" }, .{ "z", "back" }, .{ "b", "breakpoint" }, .{ "w", "watch" }, .{ "up/down", "move" }, .{ "g", "follow" }, .{ "f", "zoom" }, .{ "tab", "next" } },
        };
        var segments: [4 + 2 * 10]vaxis.Segment = undefined;
        var len: usize = 0;
        segments[len] = state;
        len += 1;
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
        const gpa = std.testing.allocator;
        self.chip = try .init(gpa, .ga144);
        errdefer self.chip.deinit(gpa);
        var programs: [4]gasim.assembler.Program = undefined;
        var diagnostic: gasim.assembler.Diagnostic = .{};
        for (try gasim.assembler.assembleNodes(source, &programs, &diagnostic)) |program| try self.chip.load(program);

        self.input = .init(&self.input_buffer);
        self.output = .fixed(&self.output_buffer);
        self.console = .{ .io = std.testing.io, .input = &self.input, .output = &self.output };
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
        try std.testing.expect(try self.tui.handle(.{ .key_press = .{ .codepoint = codepoint, .text = text } }));
        self.draw();
    }

    fn click(self: *TestTui, col: u16, row: u16, kind: vaxis.Mouse.Type) !void {
        try std.testing.expect(try self.tui.handle(.{ .mouse = .{ .col = @intCast(col), .row = @intCast(row), .button = .left, .mods = .{}, .type = kind } }));
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

    try std.testing.expect(try t.shows(0, "1 chip 8x18"));
    try std.testing.expect(try t.shows(0, "3 node 000"));
    try std.testing.expect(try t.shows(1, "700 701"));
    try std.testing.expect(try t.shows(8, "000 001"));
    try std.testing.expect(try t.shows(10, "2 console 000:up"));
    try std.testing.expect(try t.shows(14, "RAM"));
    try std.testing.expect(try t.shows(15, ">000"));

    // stepping follows the node that runs, and the console shows its output
    try t.press('s');
    try t.press('s');
    try std.testing.expect(try t.shows(0, "3 node 001"));
    for (0..4) |_| try t.press('n');
    try t.press(vaxis.Key.left);
    try std.testing.expect(try t.shows(0, "3 node 000"));
    // node 000 writes to the console, which takes it in the next round
    try t.press('S');
    try t.press('S');
    try std.testing.expect(try t.shows(11, "H"));

    // hiding and zooming panels
    try t.press('1');
    try std.testing.expect(try t.shows(0, "2 console"));
    try t.press('1');
    // tab moves on from the map, to the console, to the node
    t.tui.focus = .map;
    try t.press(vaxis.Key.tab);
    try std.testing.expectEqual(.console, t.tui.focus);
    try t.press(vaxis.Key.tab);
    try std.testing.expectEqual(.node, t.tui.focus);
    try t.press('f');
    try std.testing.expect(!try t.shows(0, "1 chip"));
    try std.testing.expect(try t.shows(0, "3 node 000"));
    try t.press(vaxis.Key.page_down);
    try std.testing.expect(t.tui.memory_scroll != null);
    try t.press('g');
    try std.testing.expectEqual(null, t.tui.memory_scroll);
    try t.press(vaxis.Key.escape);
    try std.testing.expect(try t.shows(0, "1 chip"));

    // borders move by dragging, or by tapping them and then where they go
    const border = t.tui.column_border.?;
    try t.click(border, 5, .press);
    try t.click(border - 10, 5, .drag);
    try t.click(border - 10, 5, .release);
    try std.testing.expectEqual(border - 10, t.tui.column_border.?);
    try t.click(border - 10, 5, .press);
    try t.click(border - 10, 5, .release);
    try t.click(border - 4, 5, .press);
    try t.click(border - 4, 5, .release);
    try std.testing.expectEqual(border - 4, t.tui.column_border.?);
    // clicking a node selects it
    try t.click(1, 8, .press);
    try std.testing.expectEqual(.map, t.tui.focus);
    try std.testing.expect(try t.shows(0, "3 node 000"));

    // typing into the console, after the map
    try t.press(vaxis.Key.tab);
    try std.testing.expectEqual(.console, t.tui.focus);
    try t.press('h');
    try t.press('i');
    try std.testing.expect(try t.shows(27, "> hi"));
    try t.press(vaxis.Key.enter);
    var sent: [3]u8 = undefined;
    try std.testing.expectEqual(3, try t.input.get(std.testing.io, &sent, 0));
    try std.testing.expectEqualStrings("hi\n", &sent);
}

test "escapes from the console, and ends moving a border with a key" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("");
    defer t.deinit();
    t.draw();

    // the cursor shows only in the console
    t.tui.focus = .console;
    t.draw();
    try std.testing.expect(t.screen.cursor_vis);
    try t.press(vaxis.Key.tab);
    try std.testing.expect(!t.screen.cursor_vis);

    // escape from a zoomed console shows the map again
    t.tui.focus = .console;
    t.tui.zoomed = .console;
    try t.press(vaxis.Key.escape);
    try std.testing.expectEqual(null, t.tui.zoomed);
    try std.testing.expectEqual(.map, t.tui.focus);
    try std.testing.expect(try t.shows(0, "1 chip"));

    // escape with the map hidden goes to the node
    t.tui.focus = .console;
    t.tui.shown.remove(.map);
    try t.press(vaxis.Key.escape);
    try std.testing.expectEqual(.node, t.tui.focus);
    t.tui.shown.insert(.map);
    t.draw();

    // a key after tapping a border leaves it where it is
    const border = t.tui.column_border.?;
    try t.click(border, 5, .press);
    try t.click(border, 5, .release);
    try t.press('j');
    try t.click(1, 8, .press);
    try std.testing.expectEqual(border, t.tui.column_border.?);
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
    try std.testing.expect(try t.shows(13, "#aaaa "));
    try std.testing.expect(try t.shows(14, "#end "));
    // scrolling back past the start stops at the first page
    t.tui.console_scroll = 100;
    t.draw();
    try std.testing.expectEqual(0, t.tui.console_scroll);

    // ctrl+d sends text typed so far, and then ends the input
    t.tui.focus = .console;
    try t.press('h');
    const ctrl_d: Event = .{ .key_press = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } };
    try std.testing.expect(try t.tui.handle(ctrl_d));
    try std.testing.expect(try t.tui.handle(ctrl_d));
    var sent: [2]u8 = undefined;
    try std.testing.expectEqual(1, try t.input.get(std.testing.io, &sent, 0));
    try std.testing.expectEqual('h', sent[0]);
    try std.testing.expectError(error.Closed, t.input.get(std.testing.io, &sent, 0));
    try t.press('x');
    try t.press(vaxis.Key.enter);
    try std.testing.expectEqualStrings("the console's input has ended", t.tui.message.?);

    // stepping waits for a pause
    t.tui.focus = .map;
    t.tui.running = true;
    try t.press('s');
    try std.testing.expectEqualStrings("pause with space to step", t.tui.message.?);
    t.tui.running = false;

    // growing a panel past the screen, and back
    for (0..100) |_| try t.press('>');
    try t.press('<');
    try std.testing.expectEqual(120 - 12 - 2, t.tui.column_border.?);

    // titles stay within their panels
    t.tui.left_width = 12;
    t.draw();
    try std.testing.expect(try t.shows(t.tui.row_border.?, "2 console"));
    try std.testing.expect(!try t.shows(t.tui.row_border.?, "000:up"));
}

test "stops at breakpoints set in the memory listing" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("begin dup drop again");
    defer t.deinit();
    t.tui.focus = .node;
    t.draw();

    // on the current word, and then the next one
    try t.press('b');
    try std.testing.expect(t.tui.chip.breakpoints.contains(.init(0, 0)));
    try std.testing.expect(try t.shows(15, "#>000"));
    try t.press(vaxis.Key.down);
    try t.press('b');
    try std.testing.expect(t.tui.chip.breakpoints.contains(.init(0, 1)));
    // and cleared by clicking the left edge
    const left: u16 = @intCast(t.tui.memory_window.?.x_off);
    try t.click(left, 16, .press);
    try std.testing.expect(!t.tui.chip.breakpoints.contains(.init(0, 1)));
    // clicking a word moves the cursor to it
    try t.click(left + 4, 17, .press);
    try std.testing.expectEqual(3, t.tui.memory_cursor);

    // running stops when the node loops back
    t.tui.running = true;
    try t.tui.run();
    try std.testing.expect(!t.tui.running);
    try std.testing.expectEqualStrings("node 000 reached 000", t.tui.message.?);
}

test "breakpoints need a word in memory" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("dup");
    defer t.deinit();
    t.tui.focus = .node;
    // node 001 is waiting for code from its ports
    t.tui.select(1);
    try t.press('b');
    try std.testing.expectEqualStrings("move to a word in memory first", t.tui.message.?);
    try std.testing.expectEqual(0, t.tui.chip.breakpoints.len);

    // moving down starts at its first word
    try t.press('j');
    try t.press('b');
    try std.testing.expect(t.tui.chip.breakpoints.contains(.init(1, 0)));
}

test "stops at watched transfers" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("up b! 72 !b left b! @b");
    defer t.deinit();
    t.tui.focus = .node;
    t.draw();
    try std.testing.expect(try t.shows(12, "watch none"));

    // writes to up, and reads from left
    try t.press('w');
    try t.press('U');
    try t.press('w');
    try t.press('l');
    try std.testing.expect(try t.shows(12, "watch writes up, reads left"));
    // another key leaves the watches as they were
    try t.press('w');
    try t.press('x');
    try std.testing.expectEqual(2, t.tui.chip.watches.len);

    // the console reads the write in the round after
    t.tui.running = true;
    try t.tui.run();
    try std.testing.expectEqualStrings("node 000 wrote 00048 to up", t.tui.message.?);
}

test memoryRow {
    try std.testing.expectEqual(1, memoryRow(Address.fromWord(0)));
    try std.testing.expectEqual(64, memoryRow(Address.fromWord(0x3f)));
    // RAM repeats at x040
    try std.testing.expectEqual(1, memoryRow(Address.fromWord(0x40)));
    try std.testing.expectEqual(66, memoryRow(Address.fromWord(0x80)));
    try std.testing.expectEqual(76, memoryRow(Address.fromWord(0xca)));
    try std.testing.expectEqual(null, memoryRow(Address.fromWord(0x1d5)));
}

test "goes back before steps" {
    var t: TestTui = .{ .chip = undefined };
    try t.init("begin 1 + again");
    defer t.deinit();
    try t.press('z');
    try std.testing.expectEqualStrings("nothing to go back to", t.tui.message.?);

    for (0..3) |_| try t.press('n');
    try std.testing.expectEqual(3, t.tui.chip.steps);
    try t.press('z');
    try std.testing.expectEqual(2, t.tui.chip.steps);
    try std.testing.expectEqualStrings("back to 2 steps", t.tui.message.?);
    // the test history only keeps the last two
    try t.press('z');
    try std.testing.expectEqual(1, t.tui.chip.steps);
    try t.press('z');
    try std.testing.expectEqual(1, t.tui.chip.steps);
    try std.testing.expectEqualStrings("nothing to go back to", t.tui.message.?);

    // and before running
    try t.press(' ');
    try t.tui.run();
    try t.press('z');
    try std.testing.expectEqualStrings("pause with space to go back", t.tui.message.?);
    try t.press(' ');
    try t.press('z');
    try std.testing.expectEqual(1, t.tui.chip.steps);
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
    try std.testing.expectEqualStrings("nothing to go back to", t.tui.message.?);
    // each saved over the one before, so only one was allocated
    try std.testing.expect(t.tui.history[0] != null and t.tui.history[1] == null);
}

const gasim = @import("gasim");
const Address = gasim.Address;
const Chip = gasim.Chip;
const Computer = gasim.Computer;
const Console = gasim.Console;
const Diagnostic = gasim.assembler.Diagnostic;
const Direction = gasim.Direction;
const Instruction = gasim.Instruction;
const Word = gasim.Word;
const disassembler = gasim.disassembler;
const Session = gasim.arrayforth.Session;
const repl = @import("repl.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vaxis = @import("vaxis");

test "the forth panel interprets arrayForth 3 at the selected node" {
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
    t.tui.focus = .forth;
    t.draw();
    try std.testing.expect(try t.shows(19, "4 forth"));

    // NODE selects the node, and LIT pushes onto its stack
    for ("707 NODE x15. LIT") |c| try t.press(c);
    try std.testing.expect(try t.shows(27, "000> 707 NODE x15. LIT"));
    try t.press(vaxis.Key.enter);
    const i = t.chip.layout.index(707).?;
    try std.testing.expectEqual(i, t.tui.selected);
    try std.testing.expectEqual(0x15, t.chip.nodes[i].data_stack.t);
    try std.testing.expect(try t.shows(0, "3 node 707"));
    try std.testing.expect(try t.shows(20, "000> 707 NODE x15. LIT"));
    try std.testing.expect(try t.shows(21, " ok"));

    // the selected node is the target, and errors are shown
    for ("nothing") |c| try t.press(c);
    try t.press(vaxis.Key.enter);
    try std.testing.expect(try t.shows(23, "error: UnknownWord at 'nothing'"));

    // up recalls lines typed before
    try t.press(vaxis.Key.up);
    try t.press(vaxis.Key.up);
    try std.testing.expect(try t.shows(27, "707> 707 NODE x15. LIT"));

    // and the chip can go back to before a line, as before a step
    try t.press(vaxis.Key.escape);
    try t.press('z');
    try std.testing.expectEqual(0, t.chip.nodes[i].data_stack.t);
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
