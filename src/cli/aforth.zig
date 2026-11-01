//! An interactive prompt for arrayForth 3: each line is interpreted by a
//! session that assembles code and acts on the simulated chip with the words
//! of arrayForth 3's IDE, answering `ok` as polyFORTH does, or with the error.
//! On a terminal, lines are edited with isocline, with history and Tab
//! completion of words and labels, unless gasim is built without it.

pub const Options = struct {
    /// edit lines, as stdin and stdout are a terminal
    edit: bool = false,
    /// where to keep the history of lines between runs
    history: ?[:0]const u8 = null,
};

/// the longest line that can be read
const max_line = 4096;

/// rounds the chip runs for nodes to settle, such as into warm after reset
const settle_rounds = 1_000_000;

/// Reads lines from stdin until it ends, interpreting each. Lines are kept
/// in `arena`, as the session's labels refer to them.
pub fn run(io: Io, arena: Allocator, chip: *Chip, session: *Session, diagnostic: *const Diagnostic, out: *Io.Writer, options: Options) !void {
    // nodes start in warm, and wait for code once they get there
    for (0..settle_rounds) |_| if (!try chip.advance()) break;
    try out.flush();
    if (build_options.isocline and options.edit) return edit(arena, session, diagnostic, out, options.history);

    var buffer: [max_line]u8 = undefined;
    var stdin: Io.File.Reader = .init(.stdin(), io, &buffer);
    const reader = &stdin.interface;
    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // the rest of the line is not interpreted
                _ = try reader.discardDelimiterInclusive('\n');
                try out.print("error: lines are at most {d} characters\n", .{max_line});
                try out.flush();
                continue;
            },
            error.ReadFailed => return stdin.err.?,
        } orelse break;
        try interpret(session, try arena.dupe(u8, line), diagnostic, out);
        try out.flush();
    }
}

/// Reads lines with isocline, prompting with the target node, until ctrl+d
fn edit(arena: Allocator, session: *Session, diagnostic: *const Diagnostic, out: *Io.Writer, history: ?[:0]const u8) !void {
    ic.ic_set_prompt_marker("> ", "  ");
    _ = ic.ic_enable_multiline(false);
    if (history) |path| ic.ic_set_history(path, 1000);
    ic.ic_set_default_completer(&complete, session);
    while (true) {
        var prompt: [8]u8 = undefined;
        const text = if (session.target()) |node| try std.fmt.bufPrintSentinel(&prompt, "{d:0>3}", .{node}, 0) else "";
        const line = ic.ic_readline(text) orelse break;
        defer ic.ic_free(line);
        try interpret(session, try arena.dupe(u8, std.mem.span(line)), diagnostic, out);
        try out.flush();
    }
}

/// completes the word before the cursor
fn complete(cenv: *ic.CompletionEnv, prefix: [*:0]const u8) callconv(.c) void {
    const session: *const Session = @ptrCast(@alignCast(ic.ic_completion_arg(cenv) orelse return));
    const input = std.mem.span(prefix);
    const start = if (std.mem.findLastAny(u8, input, " \t")) |space| space + 1 else 0;
    var completer: Completer = .{ .cenv = cenv, .partial = input[start..] };
    session.complete(completer.partial, &completer);
}

const Completer = struct {
    cenv: *ic.CompletionEnv,
    /// the part of the word typed, which completions replace
    partial: []const u8,

    pub fn add(self: *Completer, word: []const u8) void {
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buffer, "{s}", .{word}, 0) catch return;
        _ = ic.ic_add_completion_prim(self.cenv, text, null, null, @intCast(self.partial.len), 0);
    }
};

/// Interprets a line, then answers `ok`, or the error and where it was
pub fn interpret(session: *Session, line: []const u8, diagnostic: *const Diagnostic, out: *Io.Writer) Io.Writer.Error!void {
    session.interpret(line) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => return out.print("error: {t} at '{s}'\n", .{ err, diagnostic.token }),
    };
    try out.writeAll(" ok\n");
}

test interpret {
    var programs: [1]gasim.assembler.Program = undefined;
    var descriptors: [1]gasim.boot.Descriptor = undefined;
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    var session: Session = .init(&programs, &descriptors, &diagnostic, .{ .out = &out });
    try interpret(&session, "1 2 + .", &diagnostic, &out);
    try interpret(&session, "1 nothing", &diagnostic, &out);
    try expectEqualStrings("3  ok\nerror: UnknownWord at 'nothing'\n", out.buffered());
}

const build_options = @import("build_options");
const gasim = @import("gasim");
const ic = @import("isocline.zig");
const Chip = gasim.Chip;
const Diagnostic = gasim.assembler.Diagnostic;
const Session = gasim.arrayforth.Session;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const expectEqualStrings = std.testing.expectEqualStrings;
