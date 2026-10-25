//! gasim

const usage =
    \\usage: gasim [run] [options] <program.ga | program.af>
    \\
    \\Opens the program in a terminal user interface, reading .af files as
    \\arrayForth 3 source. With run, or when stdin
    \\or stdout is not a terminal, runs it instead with the console on stdin
    \\and stdout, until every node is waiting, or one reaches a breakpoint or
    \\makes a watched transfer. With --listing, writes the assembled program
    \\instead.
    \\
    \\options:
    \\  --layout <rows>x<columns>  size of the array of nodes (default 8x18)
    \\  --console <node>:<port>    where the console is attached (default 000:up)
    \\  --rom <file>               ROM dump to load into the nodes
    \\                             (default rom/ga144.txt, if it exists)
    \\  --boot                     load programs with a boot stream through the
    \\                             SERDES port of node 001, which needs ROM
    \\  --break <node>:<address>   stop when the node is about to fetch the word
    \\                             at the address, in hex, such as 105:003. Can
    \\                             be given more than once.
    \\  --watch <node>:<port>[:read|:write]
    \\                             stop when the node reads from or writes to the
    \\                             port, such as 105:right:write. Can be given
    \\                             more than once.
    \\  --trace                    with run, write a line to stderr for each
    \\                             word a node executes
    \\  --why                      with run, say what each node is waiting on
    \\                             once every node is waiting
    \\  --listing                  write each node's words with their
    \\                             disassembly and source lines to stdout,
    \\                             instead of running
;

const default_rom_path = "rom/ga144.txt";

const max_source_len = 64 * 1024;

/// the console stopped by ctrl+c
var interruptible: ?*Console = null;

const Command = enum { run, tui };

/// restores the terminal from the user interface before reporting a panic
pub const panic = std.debug.FullPanic(struct {
    fn call(msg: []const u8, first_trace_addr: ?usize) noreturn {
        vaxis.recover();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.call);

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) fatal(usage, .{});
    const run_command = std.mem.eql(u8, args[1], "run");
    // a pipe or file wants plain output rather than a user interface
    const command: Command = if (run_command or !try Io.File.stdin().isTty(io) or !try Io.File.stdout().isTty(io)) .run else .tui;

    var layout: Chip.Layout = .ga144;
    var console_node: u16 = 0;
    var console_port: Direction = .up;
    var path: ?[]const u8 = null;
    var rom_path: ?[]const u8 = null;
    var boot = false;
    var trace = false;
    var why = false;
    var listing = false;
    var breakpoints: [Chip.max_breakpoints]struct { node: u16, address: u9 } = undefined;
    var breakpoints_len: usize = 0;
    var watches: [Chip.max_watches]struct { node: u16, direction: Direction, read: bool, write: bool } = undefined;
    var watches_len: usize = 0;
    var i: usize = if (run_command) 2 else 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--layout") or std.mem.eql(u8, arg, "--console") or std.mem.eql(u8, arg, "--rom") or std.mem.eql(u8, arg, "--break") or std.mem.eql(u8, arg, "--watch")) {
            i += 1;
            if (i == args.len) fatal("{s} needs a value\n{s}", .{ arg, usage });
            const value = args[i];
            if (std.mem.eql(u8, arg, "--rom")) {
                rom_path = value;
            } else if (std.mem.eql(u8, arg, "--break")) {
                const colon = std.mem.indexOfScalar(u8, value, ':') orelse
                    fatal("invalid breakpoint '{s}', expected for example 105:003", .{value});
                if (breakpoints_len == breakpoints.len) fatal("more than {d} breakpoints", .{breakpoints.len});
                breakpoints[breakpoints_len] = .{
                    .node = std.fmt.parseInt(u16, value[0..colon], 10) catch
                        fatal("invalid breakpoint node '{s}'", .{value[0..colon]}),
                    .address = std.fmt.parseInt(u9, value[colon + 1 ..], 16) catch
                        fatal("invalid breakpoint address '{s}', expected 000 to 1ff", .{value[colon + 1 ..]}),
                };
                breakpoints_len += 1;
            } else if (std.mem.eql(u8, arg, "--watch")) {
                var parts = std.mem.splitScalar(u8, value, ':');
                const node = parts.first();
                const direction = parts.next() orelse
                    fatal("invalid watch '{s}', expected for example 105:right or 105:right:write", .{value});
                const kind = parts.next();
                if (parts.next() != null) fatal("invalid watch '{s}', expected for example 105:right or 105:right:write", .{value});
                if (kind) |k| if (!std.mem.eql(u8, k, "read") and !std.mem.eql(u8, k, "write"))
                    fatal("invalid watch '{s}', expected read or write after the port", .{value});
                if (watches_len == watches.len) fatal("more than {d} watches", .{watches.len});
                watches[watches_len] = .{
                    .node = std.fmt.parseInt(u16, node, 10) catch fatal("invalid watch node '{s}'", .{node}),
                    .direction = std.meta.stringToEnum(Direction, direction) orelse
                        fatal("invalid watch port '{s}', expected right, down, left or up", .{direction}),
                    .read = kind == null or std.mem.eql(u8, kind.?, "read"),
                    .write = kind == null or std.mem.eql(u8, kind.?, "write"),
                };
                watches_len += 1;
            } else if (std.mem.eql(u8, arg, "--layout")) {
                layout = Chip.Layout.parse(value) catch fatal("invalid layout '{s}', expected for example 8x18", .{value});
            } else {
                const colon = std.mem.indexOfScalar(u8, value, ':') orelse
                    fatal("invalid console '{s}', expected for example 000:up", .{value});
                console_node = std.fmt.parseInt(u16, value[0..colon], 10) catch
                    fatal("invalid console node '{s}'", .{value[0..colon]});
                console_port = std.meta.stringToEnum(Direction, value[colon + 1 ..]) orelse
                    fatal("invalid console port '{s}', expected right, down, left or up", .{value[colon + 1 ..]});
            }
        } else if (std.mem.eql(u8, arg, "--boot")) {
            boot = true;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            trace = true;
        } else if (std.mem.eql(u8, arg, "--why")) {
            why = true;
        } else if (std.mem.eql(u8, arg, "--listing")) {
            listing = true;
        } else if (path == null and !std.mem.startsWith(u8, arg, "-")) {
            path = arg;
        } else fatal(usage, .{});
    }
    const source_path = path orelse fatal(usage, .{});
    if (!listing and trace and command == .tui) fatal("--trace needs run, as the terminal user interface uses stderr's terminal", .{});
    if (!listing and why and command == .tui) fatal("--why needs run, as the terminal user interface shows what nodes wait on", .{});

    // one spare byte tells a full buffer apart from a longer file
    var source_buffer: [max_source_len + 1]u8 = undefined;
    const source = Io.Dir.cwd().readFile(io, source_path, &source_buffer) catch |err|
        fatal("{s}: {t}", .{ source_path, err });
    if (source.len > max_source_len) fatal("{s}: file is too large", .{source_path});

    var chip: Chip = try .init(init.gpa, layout);
    defer chip.deinit(init.gpa);

    const roms = readRom(io, arena, rom_path);
    if (roms) |r| chip.loadRom(r) catch
        fatal("{s}: has no ROM for node {d}, which nodes without their own ROM use", .{ rom_path orelse default_rom_path, ga144.basic_node });

    const program_buffer = try arena.alloc(assembler.Program, layout.count());
    var diagnostic: assembler.Diagnostic = .{};
    const programs = assemble(source_path, source, program_buffer, &diagnostic) catch |err| switch (err) {
        error.TooManyNodes => fatal("{s}:{d}: more nodes than a {d}x{d} layout has at '{s}'", .{ source_path, diagnostic.line, layout.rows, layout.columns, diagnostic.token }),
        else => fatal("{s}:{d}: {t} at '{s}'", .{ source_path, diagnostic.line, err, diagnostic.token }),
    };
    for (programs) |program| if (layout.index(program.node) == null)
        fatal("{s}: node {d:0>3} is not in a {d}x{d} layout", .{ source_path, program.node, layout.rows, layout.columns });
    if (listing) {
        var buffer: [4096]u8 = undefined;
        var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
        const writer = &file_writer.interface;
        for (programs, 0..) |program, n| {
            if (n > 0) try writer.writeByte('\n');
            if (program.bin) |bin| try writer.print("bin {d} ", .{bin});
            try writer.print("node {d:0>3}\n", .{program.node});
            try gasim.disassembler.listing(writer, program, source);
        }
        try writer.flush();
        return;
    }
    // code saved in other bins than its node's is not loaded
    var loaded: usize = 0;
    for (programs) |program| if (program.bin == null) {
        programs[loaded] = program;
        loaded += 1;
    };
    const loadable = programs[0..loaded];

    if (roms == null) for (loadable) |program| if (program.rom_word) |word|
        fatal("{s}:{d}: '{s}' is in ROM, which is not loaded (see --rom)", .{ source_path, word.line, word.token });

    for (breakpoints[0..breakpoints_len]) |b| {
        const index = layout.index(b.node) orelse
            fatal("breakpoint node {d:0>3} is not in a {d}x{d} layout", .{ b.node, layout.rows, layout.columns });
        // the same breakpoint twice is still set
        chip.breakpoints.insert(.init(index, b.address)) catch unreachable;
    }

    for (watches[0..watches_len]) |w| {
        const index = layout.index(w.node) orelse
            fatal("watch node {d:0>3} is not in a {d}x{d} layout", .{ w.node, layout.rows, layout.columns });
        for ([_]bool{ false, true }) |write| {
            if (!(if (write) w.write else w.read)) continue;
            chip.watches.insert(.{ .index = index, .direction = w.direction, .write = write }) catch
                fatal("more than {d} watches", .{Chip.max_watches});
        }
    }

    var feeder: Chip.Feeder = .{ .words = &.{} };
    if (boot) {
        if (console_node == 1 and console_port == .up) fatal("--boot streams into node 001's up port, so the console cannot use it", .{});
        if (roms == null) fatal("--boot needs a ROM, for node 001 to boot from (see --rom)", .{});
        const buffer = try arena.alloc(gasim.Word, gasim.boot.maxLen(layout, loadable));
        feeder.words = gasim.boot.stream(init.gpa, layout, 1, .up, loadable, buffer) catch |err| switch (err) {
            error.NoSuchNode => fatal("--boot needs node 001, which is not in a {d}x{d} layout", .{ layout.rows, layout.columns }),
            error.StreamTooLong => fatal("--boot: the boot stream is too long for a node to copy on", .{}),
            else => |e| return e,
        };
        chip.attachFeeder(&feeder, 1, .up) catch fatal("--boot needs node 001's up port to face off the chip", .{});
    } else for (loadable) |program| chip.load(program) catch unreachable;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    // the terminal user interface shows console output from here
    var screen_buffer: [tui.console_capacity]u8 = undefined;
    var screen: Io.Writer = .fixed(&screen_buffer);

    var input_buffer: [1024]u8 = undefined;
    var input: Io.Queue(u8) = .init(&input_buffer);
    var console: Console = .{
        .io = io,
        .input = &input,
        .output = switch (command) {
            .run => &stdout_file_writer.interface,
            .tui => &screen,
        },
    };
    chip.attachConsole(&console, console_node, console_port) catch |err| switch (err) {
        error.NoSuchNode => fatal("console node {d:0>3} is not in a {d}x{d} layout", .{ console_node, layout.rows, layout.columns }),
        error.PortConnected => fatal("console port {t} of node {d:0>3} is connected to another node", .{ console_port, console_node }),
    };

    if (command == .tui) return tui.run(io, init.gpa, init.environ_map, &chip, .{
        .source_path = source_path,
        .console = &console,
        .console_node = console_node,
        .console_port = console_port,
    });

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    if (trace) chip.trace = &stderr_file_writer.interface;
    // what was traced up to an error or a breakpoint. Exiting without
    // returning skips this, so those paths flush first.
    defer stderr_file_writer.interface.flush() catch {};

    interruptible = &console;
    if (have_sigint) posix.sigaction(.INT, &.{
        .handler = .{ .handler = handleInterrupt },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    // read stdin on its own thread, so the chip runs while it waits for input
    var reading = io.concurrent(Console.readInput, .{ io, &stdin_file_reader.interface, &input }) catch |err|
        fatal("cannot read input concurrently: {t}", .{err});
    errdefer reading.cancel(io) catch {};
    try chip.run();
    // stops a read blocked waiting for input that will no longer be taken
    reading.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        error.ReadFailed => if (stdin_file_reader.err.? != error.Canceled) {
            stderr_file_writer.interface.flush() catch {};
            fatal("stdin: {t}", .{stdin_file_reader.err.?});
        },
    };
    if (chip.hit) |hit| {
        // after what was traced up to it
        stderr_file_writer.interface.flush() catch {};
        const n = &chip.nodes[hit.index()];
        std.log.info("{f}", .{hit.describe(layout)});
        std.log.info("P {x:0>3}  T {x:0>5}  S {x:0>5}  R {x:0>5}  A {x:0>5}  B {x:0>3}", .{
            @as(u10, @bitCast(n.p)),
            @as(u18, @bitCast(n.data_stack.t)),
            @as(u18, @bitCast(n.data_stack.s)),
            @as(u18, @bitCast(n.return_stack.t)),
            @as(u18, @bitCast(n.a)),
            n.b,
        });
        return;
    }
    // the conventional status for a program stopped by SIGINT
    if (console.interrupted.load(.monotonic)) {
        stderr_file_writer.interface.flush() catch {};
        std.process.exit(128 + @as(u8, @backingInt(posix.SIG.INT)));
    }
    if (why) logWaiting(chip);
    // most likely the console is on a port the program does not use
    if (!console.used) std.log.warn("node {d:0>3} never used the console on its {t} port", .{ console_node, console_port });
}

/// Logs what each node is waiting on, such as `node 001 waiting to read
/// right`. Nodes waiting on several ports for code, or in ROM, as they do
/// after reset, are counted rather than listed.
fn logWaiting(chip: Chip) void {
    var idle: usize = 0;
    for (chip.nodes, 0..) |n, i| {
        const number = chip.layout.nodeNumber(@intCast(i));
        const status = n.status();
        switch (status) {
            .running => std.log.info("node {d:0>3} running", .{number}),
            inline .code, .reading, .writing => |address, waiting| {
                const ports = gasim.port.select(address) orelse gasim.port.Select.empty;
                if (ports.count() > 1 and (waiting == .code or n.word_address.rom)) {
                    idle += 1;
                    continue;
                }
                std.log.info("node {d:0>3} waiting {s} {s}", .{ number, switch (waiting) {
                    .code => "for code from",
                    .reading => "to read",
                    .writing => "to write",
                    else => unreachable,
                }, ioName(address) });
            },
        }
    }
    if (idle > 0) std.log.info("{d} {s} waiting on several ports, as after reset", .{ idle, if (idle == 1) "node" else "nodes" });
}

/// Reads a ROM dump from `path`, or the default dump if there is one
fn readRom(io: Io, arena: std.mem.Allocator, path: ?[]const u8) ?[]const ga144.NodeRom {
    const text = Io.Dir.cwd().readFileAlloc(io, path orelse default_rom_path, arena, .limited(1024 * 1024)) catch |err| {
        if (path == null and err == error.FileNotFound) return null;
        fatal("{s}: {t}", .{ path orelse default_rom_path, err });
    };
    const roms = arena.alloc(ga144.NodeRom, 144) catch fatal("out of memory", .{});
    return ga144.parseRom(text, roms) catch |err|
        fatal("{s}: {t}", .{ path orelse default_rom_path, err });
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

/// Assembles source in gasim's syntax, or in arrayForth 3's for .af files
fn assemble(path: []const u8, source: []const u8, programs: []assembler.Program, diagnostic: *assembler.Diagnostic) gasim.arrayforth.Error![]assembler.Program {
    if (std.mem.endsWith(u8, path, ".af")) return gasim.arrayforth.assembleNodes(source, programs, diagnostic);
    return assembler.assembleNodes(source, programs, diagnostic);
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
const ga144 = gasim.ga144;
const ioName = gasim.disassembler.ioName;
const tui = @import("tui.zig");
const vaxis = @import("vaxis");

test {
    _ = tui;
}
