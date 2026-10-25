//! An interactive prompt for arrayForth 3: each line is interpreted by a
//! session that assembles code and acts on the simulated chip with the words
//! of arrayForth 3's IDE, answering `ok` as polyFORTH does, or with the error

/// the longest line that can be read
const max_line = 4096;

/// rounds the chip runs for nodes to settle, such as into warm after reset
const settle_rounds = 1_000_000;

/// Reads lines from stdin until it ends, interpreting each. Lines are kept
/// in `arena`, as the session's labels refer to them.
pub fn run(io: Io, arena: Allocator, chip: *Chip, session: *Session, diagnostic: *const Diagnostic, out: *Io.Writer) !void {
    // nodes start in warm, and wait for code once they get there
    for (0..settle_rounds) |_| if (!try chip.advance()) break;
    try out.flush();

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
    try std.testing.expectEqualStrings("3  ok\nerror: UnknownWord at 'nothing'\n", out.buffered());
}

const gasim = @import("gasim");
const Chip = gasim.Chip;
const Diagnostic = gasim.assembler.Diagnostic;
const Session = gasim.arrayforth.Session;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
