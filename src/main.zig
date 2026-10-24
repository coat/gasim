//! gasim

const usage = "usage: gasim <program.ga>";

const max_source_len = 64 * 1024;

/// the console stopped by ctrl+c
var interruptible: ?*Console = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) fatal(usage, .{});
    const path = args[1];

    // one spare byte tells a full buffer apart from a longer file
    var source_buffer: [max_source_len + 1]u8 = undefined;
    const source = Io.Dir.cwd().readFile(io, path, &source_buffer) catch |err|
        fatal("{s}: {t}", .{ path, err });
    if (source.len > max_source_len) fatal("{s}: file is too large", .{path});

    var diagnostic: assembler.Diagnostic = .{};
    const program = assembler.assemble(source, &diagnostic) catch |err|
        fatal("{s}:{d}: {t} at '{s}'", .{ path, diagnostic.line, err, diagnostic.token });

    var node: Computer = .reset;
    program.load(&node);

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);

    var console: Console = .{
        .input = &stdin_file_reader.interface,
        .output = &stdout_file_writer.interface,
    };
    console.attach(&node, .up);

    interruptible = &console;
    if (have_sigint) posix.sigaction(.INT, &.{
        .handler = .{ .handler = handleInterrupt },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    try console.run(&node);
    // the conventional status for a program stopped by SIGINT
    if (console.interrupted.load(.monotonic)) std.process.exit(128 + @as(u8, @backingInt(posix.SIG.INT)));
}

/// Stops the console so its output is flushed. While it is blocked waiting
/// for input there is nothing to flush, so ctrl+c terminates as usual, as it
/// does when pressed a second time.
fn handleInterrupt(_: posix.SIG) callconv(.c) void {
    const console = interruptible orelse return;
    if (console.waiting.load(.acquire) or console.interrupted.swap(true, .monotonic)) {
        posix.sigaction(.INT, &.{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
        posix.raise(.INT) catch {};
    }
}

const have_sigint = builtin.os.tag != .windows and builtin.os.tag != .wasi;

const fatal = std.process.fatal;

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const gasim = @import("gasim");
const assembler = gasim.assembler;
const Computer = gasim.Computer;
const Console = gasim.Console;
