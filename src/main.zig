//! gasim

const usage =
    \\usage: gasim [options] <program.ga>
    \\
    \\  --layout <rows>x<columns>  size of the array of nodes (default 8x18)
    \\  --console <node>:<port>    where the console is attached (default 000:up)
;

const max_source_len = 64 * 1024;

/// the console stopped by ctrl+c
var interruptible: ?*Console = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var layout: Chip.Layout = .ga144;
    var console_node: u16 = 0;
    var console_port: Direction = .up;
    var path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--layout") or std.mem.eql(u8, arg, "--console")) {
            i += 1;
            if (i == args.len) fatal("{s} needs a value\n{s}", .{ arg, usage });
            const value = args[i];
            if (std.mem.eql(u8, arg, "--layout")) {
                layout = Chip.Layout.parse(value) catch fatal("invalid layout '{s}', expected for example 8x18", .{value});
            } else {
                const colon = std.mem.indexOfScalar(u8, value, ':') orelse
                    fatal("invalid console '{s}', expected for example 000:up", .{value});
                console_node = std.fmt.parseInt(u16, value[0..colon], 10) catch
                    fatal("invalid console node '{s}'", .{value[0..colon]});
                console_port = std.meta.stringToEnum(Direction, value[colon + 1 ..]) orelse
                    fatal("invalid console port '{s}', expected right, down, left or up", .{value[colon + 1 ..]});
            }
        } else if (path == null and !std.mem.startsWith(u8, arg, "-")) {
            path = arg;
        } else fatal(usage, .{});
    }
    const source_path = path orelse fatal(usage, .{});

    // one spare byte tells a full buffer apart from a longer file
    var source_buffer: [max_source_len + 1]u8 = undefined;
    const source = Io.Dir.cwd().readFile(io, source_path, &source_buffer) catch |err|
        fatal("{s}: {t}", .{ source_path, err });
    if (source.len > max_source_len) fatal("{s}: file is too large", .{source_path});

    var chip: Chip = try .init(init.gpa, layout);
    defer chip.deinit(init.gpa);

    const program_buffer = try arena.alloc(assembler.Program, layout.count());
    var diagnostic: assembler.Diagnostic = .{};
    const programs = assembler.assembleNodes(source, program_buffer, &diagnostic) catch |err| switch (err) {
        error.TooManyNodes => fatal("{s}:{d}: more nodes than a {d}x{d} layout has at '{s}'", .{ source_path, diagnostic.line, layout.rows, layout.columns, diagnostic.token }),
        else => fatal("{s}:{d}: {t} at '{s}'", .{ source_path, diagnostic.line, err, diagnostic.token }),
    };
    for (programs) |program| chip.load(program) catch
        fatal("{s}: node {d:0>3} is not in a {d}x{d} layout", .{ source_path, program.node, layout.rows, layout.columns });

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);

    var console: Console = .{
        .input = &stdin_file_reader.interface,
        .output = &stdout_file_writer.interface,
    };
    chip.attachConsole(&console, console_node, console_port) catch |err| switch (err) {
        error.NoSuchNode => fatal("console node {d:0>3} is not in a {d}x{d} layout", .{ console_node, layout.rows, layout.columns }),
        error.PortConnected => fatal("console port {t} of node {d:0>3} is connected to another node", .{ console_port, console_node }),
    };

    interruptible = &console;
    if (have_sigint) posix.sigaction(.INT, &.{
        .handler = .{ .handler = handleInterrupt },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    try chip.run();
    // the conventional status for a program stopped by SIGINT
    if (console.interrupted.load(.monotonic)) std.process.exit(128 + @as(u8, @backingInt(posix.SIG.INT)));
    // most likely the console is on a port the program does not use
    if (!console.used) std.log.warn("node {d:0>3} never used the console on its {t} port", .{ console_node, console_port });
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
const Chip = gasim.Chip;
const Console = gasim.Console;
const Direction = gasim.Direction;
