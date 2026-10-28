//! gasim

const usage =
    \\usage: gasim [options] [program.ga | program.af | program.blk | source.cf]
    \\       gasim run [options] <program.ga | program.af | program.blk | source.cf>
    \\       gasim repl [options] [program.ga | program.af | program.blk | source.cf]
    \\       gasim blocks [--load <block>]... <source.cf>
    \\
    \\Opens the chip in a terminal user interface, with the program loaded if
    \\there is one, reading .af files as arrayForth 3 source and .blk files as
    \\blocks of it. With run, or when stdin or stdout is not a terminal, runs
    \\the program instead with the console on stdin and stdout, until every
    \\node is waiting, or one reaches a breakpoint or makes a watched transfer.
    \\With --listing, writes the assembled program instead. A .cf file of
    \\colorForth blocks, such as an arrayForth 2 image, is compiled as
    \\arrayForth 2 compiles F18 code, from block 0 or the blocks --load
    \\names. The interface opens it in its editor instead, compiling it at
    \\the start only with --load, and creates it if it does not exist.
    \\
    \\With repl, reads lines of arrayForth 3 from stdin and interprets them,
    \\to assemble code and act on the chip with the words of arrayForth 3's
    \\IDE, such as 708 NODE UPD, after loading the program if there is one.
    \\
    \\With blocks, writes the colorForth source in a file of blocks as text,
    \\each block that holds any, or those --load names. arrayForth 2 images
    \\are decompressed, and the kernel's blocks before block 18 left out.
    \\
    \\options:
    \\  --layout <rows>x<columns>  size of the array of nodes (default 8x18)
    \\  --console <node>:<port>    where the console is attached (default 000:up)
    \\  --rom <path>               ROM to load into the nodes: a dump of it, or
    \\                             arrayForth 3's disk (sF/pFDISK.blk) or the
    \\                             directory it is installed in, such as
    \\                             GreenArrays, to assemble it from. Without
    \\                             it, the ROM last assembled, or assembled
    \\                             from arrayForth 3 installed in C:\GreenArrays
    \\                             or Wine's C: drive, if it is.
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
    \\  --load <block>             with a .blk or .cf file, the block to load
    \\                             (default 0). Can be given more than once, to
    \\                             load blocks such as configuration first.
    \\                             With blocks, a block to write.
    \\  --listing                  write each node's words with their
    \\                             disassembly and source lines to stdout,
    \\                             instead of running
;

const max_source_len = 64 * 1024;

/// the most a .blk file may hold, which is more than arrayForth 3's disks
const max_blocks_len = 64 * 1024 * 1024;

/// the console stopped by ctrl+c
var interruptible: ?*Console = null;

const Command = enum { run, tui, repl, blocks };

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
    const command = commandOf(args, try Io.File.stdin().isTty(io) and try Io.File.stdout().isTty(io));

    var layout: Chip.Layout = .ga144;
    var console_node: u16 = 0;
    var console_port: Direction = .up;
    var path: ?[]const u8 = null;
    var rom_path: ?[]const u8 = null;
    var boot = false;
    var trace = false;
    var why = false;
    var listing = false;
    var loads: [16]u32 = undefined;
    var loads_len: usize = 0;
    var breakpoints: [Chip.max_breakpoints]struct { node: u16, address: u9 } = undefined;
    var breakpoints_len: usize = 0;
    var watches: [Chip.max_watches]struct { node: u16, direction: Direction, read: bool, write: bool } = undefined;
    var watches_len: usize = 0;
    var i: usize = if (named(args)) 2 else 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--layout") or std.mem.eql(u8, arg, "--console") or std.mem.eql(u8, arg, "--rom") or std.mem.eql(u8, arg, "--break") or std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "--load")) {
            i += 1;
            if (i == args.len) fatal("{s} needs a value\n{s}", .{ arg, usage });
            const value = args[i];
            if (std.mem.eql(u8, arg, "--rom")) {
                rom_path = value;
            } else if (std.mem.eql(u8, arg, "--load")) {
                if (loads_len == loads.len) fatal("more than {d} blocks to load", .{loads.len});
                loads[loads_len] = std.fmt.parseInt(u32, value, 10) catch fatal("invalid block '{s}'", .{value});
                loads_len += 1;
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
    if (path == null and needsProgram(command, listing)) fatal(usage, .{});
    if (command == .blocks) return writeBlocks(io, arena, path.?, loads[0..loads_len]);
    const source_path = path orelse "";
    // colorForth blocks, which the terminal user interface edits, and only
    // compiles at the start with --load
    const colorforth = std.mem.endsWith(u8, source_path, ".cf");
    const compile_colorforth = colorforth and (loads_len > 0 or command != .tui);
    if (!listing and trace and command == .tui) fatal("--trace needs run, as the terminal user interface uses stderr's terminal", .{});
    if (!listing and why and command == .tui) fatal("--why needs run, as the terminal user interface shows what nodes wait on", .{});

    const blocks = std.mem.endsWith(u8, source_path, ".blk");
    if (loads_len > 0 and !blocks and !colorforth) fatal("--load needs a .blk or .cf file of blocks", .{});
    if (loads_len == 0) {
        loads[0] = 0;
        loads_len = 1;
    }
    // one spare byte tells a full buffer apart from a longer file
    var source_buffer: [max_source_len + 1]u8 = undefined;
    // the editor creates a file that does not exist yet
    const colorforth_blocks: ?ColorForthBlocks = if (colorforth) try readColorForth(io, arena, source_path, command == .tui) else null;
    const file = if (path == null or colorforth)
        ""
    else if (blocks)
        Io.Dir.cwd().readFileAlloc(io, source_path, arena, .limited(max_blocks_len)) catch |err|
            fatal("{s}: {t}", .{ source_path, err })
    else
        Io.Dir.cwd().readFile(io, source_path, &source_buffer) catch |err|
            fatal("{s}: {t}", .{ source_path, err });
    if (!blocks and file.len > max_source_len) fatal("{s}: file is too large", .{source_path});
    // blocks are listed as lines of text, numbered the same way
    const source = if (colorforth and listing)
        try colorForthText(arena, colorforth_blocks.?)
    else if (blocks)
        gasim.arrayforth.blockText(file, try arena.alloc(u8, gasim.arrayforth.blockCount(file) * 16 * 65))
    else
        file;

    var chip: Chip = try .init(init.gpa, layout);
    defer chip.deinit(init.gpa);

    const roms = readRom(io, arena, init.environ_map, rom_path);
    // which readRom checks for
    if (roms) |r| chip.loadRom(r) catch unreachable;

    const program_buffer = try arena.alloc(assembler.Program, layout.count());
    const descriptor_buffer = try arena.alloc(gasim.boot.Descriptor, layout.count());
    var diagnostic: assembler.Diagnostic = .{};
    // the prompt, and the console with it, write here
    var repl_buffer: [4096]u8 = undefined;
    var repl_writer: Io.File.Writer = .init(.stdout(), io, &repl_buffer);
    // and the terminal user interface's forth panel here
    var forth_buffer: [tui.forth_capacity]u8 = undefined;
    var forth_output: Io.Writer = .fixed(&forth_buffer);
    // arrayForth 3 at the prompt or in the forth panel keeps the bins and
    // labels of an arrayForth 3 program
    const session: ?*gasim.arrayforth.Session = if (command != .run) session: {
        const session = try arena.create(gasim.arrayforth.Session);
        session.* = .init(program_buffer, descriptor_buffer, &diagnostic, .{
            .out = if (command == .tui) &forth_output else &repl_writer.interface,
            .chip = &chip,
            .blocks = if (blocks) file else null,
        });
        break :session session;
    } else null;
    const ga = path != null and !blocks and !colorforth and !std.mem.endsWith(u8, source_path, ".af");
    const assembled = (if (colorforth)
        compileColorForth(session, colorforth_blocks.?, if (compile_colorforth) loads[0..loads_len] else &.{}, program_buffer, descriptor_buffer, &diagnostic)
    else if (session != null and !ga)
        loadSession(arena, session.?, &diagnostic, file, blocks, loads[0..loads_len], path != null)
    else if (blocks)
        gasim.arrayforth.assembleBlocks(file, loads[0..loads_len], program_buffer, descriptor_buffer, &diagnostic)
    else
        assemble(source_path, file, program_buffer, descriptor_buffer, &diagnostic)) catch |err| {
        const where: Where = .{ .path = source_path, .line = diagnostic.line, .kind = if (blocks) .blocks else if (colorforth) .colorforth else .text };
        switch (err) {
            error.TooManyNodes => fatal("{f}: more nodes than a {d}x{d} layout has at '{s}'", .{ where, layout.rows, layout.columns, diagnostic.token }),
            error.NoSuchBlock => if (diagnostic.line == 0) fatal("{s}: has fewer blocks than --load needs", .{source_path}),
            else => {},
        }
        fatal("{f}: {t} at '{s}'", .{ where, err, diagnostic.token });
    };
    const programs = assembled.programs;
    if (assembled.first_difference) |first| std.log.warn("{f}: arrayForth 2 noted {x:0>3} here, where gasim is at {x:0>3}, and {d} more gray numbers differ", .{
        Where{ .path = source_path, .line = first.line, .kind = .colorforth },
        first.noted,
        first.found,
        assembled.feedback_differs - 1,
    });
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
        for (assembled.descriptors) |descriptor| try writer.print("\n{f}", .{descriptor});
        try writer.flush();
        return;
    }
    // boot descriptors say what to load into nodes and how to start them.
    // Without them, each program in its node's own bin is loaded and started
    // at its entry, and code saved in other bins is not loaded.
    const descriptors = if (assembled.descriptors.len > 0) assembled.descriptors else own: {
        var count: usize = 0;
        for (programs) |program| if (program.bin == null) {
            descriptor_buffer[count] = .ofProgram(program);
            count += 1;
        };
        break :own descriptor_buffer[0..count];
    };
    for (descriptors) |descriptor| if (layout.index(descriptor.node) == null)
        fatal("{s}: node {d:0>3} is not in a {d}x{d} layout", .{ source_path, descriptor.node, layout.rows, layout.columns });

    if (roms == null) for (descriptors) |descriptor| {
        for (descriptor.loads[0..descriptor.load_count]) |part| {
            const program = gasim.boot.findBin(programs, part.bin) orelse continue;
            if (program.rom_word) |word|
                fatal("{f}: '{s}' is in ROM, which is not loaded (see --rom)", .{ Where{ .path = source_path, .line = word.line, .kind = if (blocks) .blocks else if (colorforth) .colorforth else .text }, word.token });
        }
        if (descriptor.p & 0x180 == 0x080)
            fatal("{s}: node {d:0>3} starts in ROM at {x:0>3}, which is not loaded (see --rom)", .{ source_path, descriptor.node, descriptor.p });
    };

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
        const buffer = try arena.alloc(gasim.Word, gasim.boot.maxLen(layout, descriptors));
        feeder.words = gasim.boot.stream(init.gpa, layout, 1, .up, descriptors, programs, buffer) catch |err| switch (err) {
            error.NoSuchNode => fatal("--boot needs node 001, which is not in a {d}x{d} layout", .{ layout.rows, layout.columns }),
            error.StreamTooLong => fatal("--boot: the boot stream is too long for a node to copy on", .{}),
            else => |e| return e,
        };
        chip.attachFeeder(&feeder, 1, .up) catch fatal("--boot needs node 001's up port to face off the chip", .{});
    } else for (descriptors) |descriptor| chip.setUp(descriptor, programs) catch |err| switch (err) {
        error.NoSuchBin => fatal("{s}: node {d:0>3} loads a bin that was not saved", .{ source_path, descriptor.node }),
        error.NoSuchNode => unreachable,
    };

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
            .repl => &repl_writer.interface,
            .blocks => unreachable,
        },
    };
    chip.attachConsole(&console, console_node, console_port) catch |err| switch (err) {
        error.NoSuchNode => fatal("console node {d:0>3} is not in a {d}x{d} layout", .{ console_node, layout.rows, layout.columns }),
        error.PortConnected => fatal("console port {t} of node {d:0>3} is connected to another node", .{ console_port, console_node }),
    };

    if (command == .repl) return repl.run(io, arena, &chip, session.?, &diagnostic, &repl_writer.interface, .{
        .edit = try Io.File.stdin().isTty(io) and try Io.File.stdout().isTty(io),
        .history = historyPath(io, arena, init.environ_map),
    });

    if (command == .tui) return tui.run(io, init.gpa, init.environ_map, &chip, .{
        .source_path = source_path,
        .console = &console,
        .console_node = console_node,
        .console_port = console_port,
        .forth = .{ .session = session.?, .output = &forth_output, .diagnostic = &diagnostic, .arena = arena },
        .colorforth = if (colorforth_blocks) |cf| try editColorForth(arena, cf, source_path) else null,
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

/// whether the arguments start with a command, run or repl
fn named(args: []const []const u8) bool {
    return args.len > 1 and (std.mem.eql(u8, args[1], "run") or std.mem.eql(u8, args[1], "repl") or std.mem.eql(u8, args[1], "blocks"));
}

/// The command the arguments start with, or without one the terminal user
/// interface, unless stdin or stdout is not a terminal: a pipe or file wants
/// plain output rather than a user interface
fn commandOf(args: []const []const u8, terminal: bool) Command {
    if (named(args)) return std.meta.stringToEnum(Command, args[1]).?;
    return if (terminal) .tui else .run;
}

/// only the terminal user interface and the prompt start without a program
fn needsProgram(command: Command, listing: bool) bool {
    return command == .run or command == .blocks or listing;
}

/// the blocks an arrayForth 2 image has, which a file opened in the editor
/// can grow to
const editor_blocks = 1440;

/// a file of colorForth blocks, with room to grow
const ColorForthBlocks = struct {
    bytes: []u8,
    /// blocks in the file
    count: usize,
    /// the file was a compressed arrayForth 2 image
    compressed: bool,
};

/// Reads a file of colorForth blocks, decompressing an arrayForth 2 image,
/// or none if the file does not exist yet and `new` allows that
fn readColorForth(io: Io, arena: Allocator, path: []const u8, new: bool) !ColorForthBlocks {
    const colorforth = gasim.colorforth;
    const read = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_blocks_len)) catch |err| switch (err) {
        error.FileNotFound => if (new) "" else fatal("{s}: {t}", .{ path, err }),
        else => fatal("{s}: {t}", .{ path, err }),
    };
    const compressed = colorforth.compressedBlocks(read);
    const count = compressed orelse colorforth.blockCount(read);
    if (count * colorforth.block_size > max_blocks_len) fatal("{s}: has too many blocks", .{path});
    const bytes = try arena.alloc(u8, @max(count, editor_blocks) * colorforth.block_size);
    @memset(bytes, 0);
    if (compressed != null) {
        colorforth.decompress(read, bytes[0 .. count * colorforth.block_size]) catch |err| fatal("{s}: {t}", .{ path, err });
    } else @memcpy(bytes[0..read.len], read);
    return .{ .bytes = bytes, .count = count, .compressed = compressed != null };
}

/// an editor on colorForth blocks, which compiling in the editor reads
fn editColorForth(arena: Allocator, blocks: ColorForthBlocks, path: []const u8) !tui.ColorForth {
    const editor = try arena.create(gasim.Editor);
    editor.open(blocks.bytes, blocks.count);
    return .{ .editor = editor, .path = path, .compressed = blocks.compressed };
}

/// colorForth blocks as text for a listing, 256 lines to a block, as
/// `colorforth.line` numbers them
fn colorForthText(arena: Allocator, blocks: ColorForthBlocks) ![]const u8 {
    const colorforth = gasim.colorforth;
    var text: Io.Writer.Allocating = .init(arena);
    var block_text: Io.Writer.Allocating = .init(arena);
    var tokens: [colorforth.cells_per_block]colorforth.Token = undefined;
    for (0..blocks.count) |n| {
        block_text.clearRetainingCapacity();
        const decoded = colorforth.decode(blocks.bytes[n * colorforth.block_size ..][0..colorforth.block_size], &tokens) catch &.{};
        try colorforth.writeText(decoded, &block_text.writer);
        var lines = std.mem.splitScalar(u8, block_text.written(), '\n');
        for (0..colorforth.cells_per_block) |_| try text.writer.print("{s}\n", .{lines.next() orelse ""});
    }
    return text.written();
}

/// Compiles colorForth blocks, loading each of `loads` in turn, in the
/// session if there is one, as the terminal user interface goes on to load
/// more
fn compileColorForth(
    session: ?*gasim.arrayforth.Session,
    blocks: ColorForthBlocks,
    loads: []const u32,
    programs: []assembler.Program,
    descriptors: []gasim.boot.Descriptor,
    diagnostic: *assembler.Diagnostic,
) gasim.arrayforth.Error!gasim.arrayforth.Assembled {
    const file = blocks.bytes[0 .. blocks.count * gasim.colorforth.block_size];
    const s = session orelse return gasim.arrayforth.assembleColorForth(file, loads, programs, descriptors, diagnostic);
    for (loads) |block| try s.loadColorForth(file, block);
    return s.assembled();
}

/// Writes the colorForth source in the blocks of a file as text, those
/// `loads` names or every one that is not empty
fn writeBlocks(io: Io, arena: Allocator, path: []const u8, loads: []const u32) !void {
    const colorforth = gasim.colorforth;
    const read = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_blocks_len)) catch |err|
        fatal("{s}: {t}", .{ path, err });
    // arrayForth 2 images compress all but their first blocks
    const file = if (colorforth.compressedBlocks(read)) |blocks| file: {
        if (blocks * colorforth.block_size > max_blocks_len) fatal("{s}: has too many blocks", .{path});
        const file = try arena.alloc(u8, blocks * colorforth.block_size);
        colorforth.decompress(read, file) catch |err| fatal("{s}: {t}", .{ path, err });
        break :file file;
    } else read;
    // and the kernel's code is in the blocks before their source
    const first: usize = if (colorforth.isImage(file)) colorforth.header_block else 0;
    const count = colorforth.blockCount(file);
    for (loads) |n| if (n >= count) fatal("{s}: has no block {d}", .{ path, n });

    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    var tokens: [colorforth.cells_per_block]colorforth.Token = undefined;
    var separate = false;
    for (0..count) |n| {
        if (if (loads.len > 0) std.mem.indexOfScalar(u32, loads, @intCast(n)) == null else n < first) continue;
        // a partial block at the end of the file reads as if zeros follow
        var block: [colorforth.block_size]u8 = @splat(0);
        const bytes = file[n * colorforth.block_size ..][0..@min(colorforth.block_size, file.len - n * colorforth.block_size)];
        @memcpy(block[0..bytes.len], bytes);
        const decoded = colorforth.decode(&block, &tokens) catch |err| {
            try writer.print("{s}block {d}: {t}\n", .{ if (separate) "\n" else "", n, err });
            separate = true;
            continue;
        };
        if (decoded.len == 0 and loads.len == 0) continue;
        try writer.print("{s}block {d}\n", .{ if (separate) "\n" else "", n });
        separate = true;
        try colorforth.writeText(decoded, writer);
    }
    try writer.flush();
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

/// Reads the ROM from `path`: a dump of it, or arrayForth 3's disk or a
/// directory it is installed in, to assemble the ROM from its source.
/// Without a path, reads the ROM saved the last time it was assembled, or
/// assembles it from arrayForth 3 where it is usually installed, if it is.
/// A ROM assembled is saved for next time.
fn readRom(io: Io, arena: Allocator, environ: *const std.process.Environ.Map, path: ?[]const u8) ?[]const ga144.NodeRom {
    const saved = dataPath(arena, environ, "ga144.txt");
    const disk = if (path) |p| disk: {
        const stat = Io.Dir.cwd().statFile(io, p, .{}) catch |err| fatal("{s}: {t}", .{ p, err });
        if (stat.kind == .directory) break :disk findDisk(io, arena, p) orelse
            fatal("{s}: has no arrayForth 3 disk, {s}", .{ p, gasim.rom.disk_path });
        if (std.mem.endsWith(u8, p, ".blk")) break :disk p;
        return readDump(io, arena, p) catch |err| fatal("{s}: {t}", .{ p, err });
    } else disk: {
        if (saved) |s| if (readDump(io, arena, s)) |roms| return roms else |err| switch (err) {
            error.FileNotFound => {},
            else => fatal("{s}: {t}", .{ s, err }),
        };
        break :disk installedDisk(io, arena, environ) orelse return null;
    };

    const text = Io.Dir.cwd().readFileAlloc(io, disk, arena, .limited(max_blocks_len)) catch |err|
        fatal("{s}: {t}", .{ disk, err });
    const roms = arena.create([144]ga144.NodeRom) catch fatal("out of memory", .{});
    var diagnostic: assembler.Diagnostic = .{};
    const assembled = gasim.rom.assemble(arena, text, roms, &diagnostic) catch |err| {
        const where: Where = .{ .path = disk, .line = diagnostic.line, .kind = .blocks };
        // arrayForth 3 found where it is usually installed is only used if
        // it assembles
        if (path == null) {
            std.log.warn("{f}: {t} at '{s}', assembling the ROM", .{ where, err, diagnostic.token });
            return null;
        }
        fatal("{f}: {t} at '{s}', assembling the ROM", .{ where, err, diagnostic.token });
    };
    if (!gasim.rom.isG144A12(assembled)) std.log.warn("{s}: assembles to a ROM that is not a G144A12's", .{disk});

    const s = saved orelse return assembled;
    var text_buffer: Io.Writer.Allocating = .init(arena);
    gasim.rom.write(&text_buffer.writer, assembled) catch fatal("out of memory", .{});
    if (std.fs.path.dirname(s)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.log.warn("{s}: {t}, saving the ROM", .{ dir, err });
        return assembled;
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = s, .data = text_buffer.written() }) catch |err| {
        std.log.warn("{s}: {t}, saving the ROM", .{ s, err });
        return assembled;
    };
    std.log.info("assembled the ROM from {s}, and saved it in {s}", .{ disk, s });
    return assembled;
}

/// Reads a ROM dump, which has to have the ROM of the node that nodes
/// without their own ROM use
fn readDump(io: Io, arena: Allocator, path: []const u8) ![]const ga144.NodeRom {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
    const roms = try ga144.parseRom(text, try arena.alloc(ga144.NodeRom, 144));
    for (roms) |rom| {
        if (rom.node == ga144.basic_node) return roms;
    } else return error.NoBasicNodeRom;
}

/// arrayForth 3's disk in a directory it is installed in, such as
/// GreenArrays/EVB002, or in one of the directories of one, such as
/// GreenArrays
fn findDisk(io: Io, arena: Allocator, path: []const u8) ?[]const u8 {
    const disk = std.fs.path.join(arena, &.{ path, gasim.rom.disk_path }) catch return null;
    if (Io.Dir.cwd().access(io, disk, .{})) |_| return disk else |_| {}
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch return null) |entry| {
        if (entry.kind != .directory) continue;
        const nested = std.fs.path.join(arena, &.{ path, entry.name, gasim.rom.disk_path }) catch return null;
        if (Io.Dir.cwd().access(io, nested, .{})) |_| return nested else |_| {}
    }
    return null;
}

/// arrayForth 3's disk where its installer puts it, in C:\GreenArrays, and
/// so in Wine's C: drive, in WINEPREFIX or ~/.wine
fn installedDisk(io: Io, arena: Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    if (builtin.os.tag == .windows) return findDisk(io, arena, "C:\\GreenArrays");
    if (environ.get("WINEPREFIX")) |prefix| {
        const dir = std.fmt.allocPrint(arena, "{s}/drive_c/GreenArrays", .{prefix}) catch return null;
        if (findDisk(io, arena, dir)) |disk| return disk;
    }
    const home = environ.get("HOME") orelse return null;
    return findDisk(io, arena, std.fmt.allocPrint(arena, "{s}/.wine/drive_c/GreenArrays", .{home}) catch return null);
}

/// where gasim keeps a file of data: in gasim under XDG_DATA_HOME, or
/// ~/.local/share, or on Windows LOCALAPPDATA
fn dataPath(arena: Allocator, environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const dir = if (environ.get("XDG_DATA_HOME")) |data|
        std.fs.path.join(arena, &.{ data, "gasim" }) catch return null
    else if (builtin.os.tag == .windows)
        std.fs.path.join(arena, &.{ environ.get("LOCALAPPDATA") orelse return null, "gasim" }) catch return null
    else
        std.fs.path.join(arena, &.{ environ.get("HOME") orelse return null, ".local", "share", "gasim" }) catch return null;
    return std.fs.path.join(arena, &.{ dir, name }) catch null;
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

/// where the repl keeps its history: in gasim under XDG_STATE_HOME, or
/// ~/.local/state
fn historyPath(io: Io, arena: Allocator, environ: *const std.process.Environ.Map) ?[:0]const u8 {
    const dir = if (environ.get("XDG_STATE_HOME")) |state|
        std.fmt.allocPrint(arena, "{s}/gasim", .{state}) catch return null
    else if (environ.get("HOME")) |home|
        std.fmt.allocPrint(arena, "{s}/.local/state/gasim", .{home}) catch return null
    else
        return null;
    Io.Dir.cwd().createDirPath(io, dir) catch return null;
    return std.fmt.allocPrintSentinel(arena, "{s}/history", .{dir}, 0) catch null;
}

/// Interprets a program in a session: a .af file, or for blocks each block
/// to load in turn
fn loadSession(
    arena: Allocator,
    session: *gasim.arrayforth.Session,
    diagnostic: *assembler.Diagnostic,
    file: []const u8,
    blocks: bool,
    loads: []const u32,
    has_program: bool,
) gasim.arrayforth.Error!gasim.arrayforth.Assembled {
    if (blocks) {
        for (loads) |block| {
            if (block >= gasim.arrayforth.blockCount(file)) {
                diagnostic.* = .{};
                return error.NoSuchBlock;
            }
            try session.interpret(std.fmt.allocPrint(arena, "{d} LOAD", .{block}) catch fatal("out of memory", .{}));
        }
    } else if (has_program) try session.interpret(file);
    try session.finish();
    return session.assembled();
}

/// where a line of source is, such as `hello.ga:3`, or for blocks
/// `app.blk: block 2 line 5` with lines numbered from 0 as polyFORTH lists
/// them
const Where = struct {
    path: []const u8,
    line: usize,
    kind: enum { text, blocks, colorforth },

    pub fn format(self: Where, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self.kind) {
            .text => try writer.print("{s}:{d}", .{ self.path, self.line }),
            .blocks => try writer.print("{s}: block {d} line {d}", .{ self.path, (self.line -| 1) / 16, (self.line -| 1) % 16 }),
            .colorforth => {
                const place = gasim.colorforth.place(self.line);
                try writer.print("{s}: block {d} word {d}", .{ self.path, place.block, place.token });
            },
        }
    }
};

/// Assembles source in gasim's syntax, or in arrayForth 3's for .af files
fn assemble(
    path: []const u8,
    source: []const u8,
    programs: []assembler.Program,
    descriptors: []gasim.boot.Descriptor,
    diagnostic: *assembler.Diagnostic,
) gasim.arrayforth.Error!gasim.arrayforth.Assembled {
    if (std.mem.endsWith(u8, path, ".af")) return gasim.arrayforth.assembleNodes(source, programs, descriptors, diagnostic);
    return .{ .programs = try assembler.assembleNodes(source, programs, diagnostic), .descriptors = &.{} };
}

const have_sigint = builtin.os.tag != .windows and builtin.os.tag != .wasi;

const fatal = std.process.fatal;

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const gasim = @import("gasim");
const assembler = gasim.assembler;
const Chip = gasim.Chip;
const Console = gasim.Console;
const Direction = gasim.Direction;
const ga144 = gasim.ga144;
const ioName = gasim.disassembler.ioName;
const repl = @import("repl.zig");
const tui = @import("tui.zig");
const vaxis = @import("vaxis");

test {
    _ = repl;
    _ = tui;
}

test "the terminal user interface and the prompt start without a program" {
    try std.testing.expectEqual(.tui, commandOf(&.{"gasim"}, true));
    try std.testing.expectEqual(.repl, commandOf(&.{ "gasim", "repl" }, true));
    try std.testing.expect(!needsProgram(.tui, false));
    try std.testing.expect(!needsProgram(.repl, false));
    // but running a program, or listing one, needs one
    try std.testing.expectEqual(.run, commandOf(&.{ "gasim", "run" }, true));
    try std.testing.expect(needsProgram(.run, false));
    try std.testing.expect(needsProgram(.tui, true));
    // as does a pipe or file, which runs it
    try std.testing.expectEqual(.run, commandOf(&.{"gasim"}, false));
    try std.testing.expectEqual(.repl, commandOf(&.{ "gasim", "repl" }, false));
}
