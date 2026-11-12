//! gasim

const max_source_len = 64 * 1024;

/// the most a .blk file may hold, which is more than arrayForth 3's disks
const max_blocks_len = 64 * 1024 * 1024;

/// symbolic links to ptys, which the end of a run or ctrl+c removes
var links: [Chip.max_uarts]struct { link: [:0]const u8, target: []const u8 } = undefined;
var links_len: usize = 0;
/// written by ctrl+c, to ring the doorbell a run with ptys waits on
var interrupt_pipe: ?posix.fd_t = null;
/// the signal that stopped the run
var interrupt_signal: std.atomic.Value(u8) = .init(0);
/// milliseconds on the clock when it did
var interrupted_at: i64 = 0;
/// a signal this soon after the first is the same one: `timeout` sends its
/// signal to gasim, and then to the group gasim is in
const repeat_ms = 500;
/// how long a signal leaves a run to stop and say so
const signal_grace: Io.Duration = .fromSeconds(2);

/// what ctrl+c stops: the console, or the UART
var interruptible: ?struct { interrupted: *std.atomic.Value(bool), waiting: *std.atomic.Value(bool) } = null;

/// restores the terminal from the user interface before reporting a panic
pub const panic = std.debug.FullPanic(struct {
    fn call(msg: []const u8, first_trace_addr: ?usize) noreturn {
        vaxis.recover();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.call);

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    report.io = io;

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |arg| if (std.mem.eql(u8, arg, "--json")) {
        report.json = true;
    };
    const terminal = try Io.File.stdin().isTty(io) and try Io.File.stdout().isTty(io);
    const options = try arena.create(Options);
    options.* = cli_options.parse(arena, args, terminal);
    const o = options;
    const command = o.command;
    switch (command) {
        .help => return writeOut(io, cli_options.helpText(o.topic)),
        .version => return writeOut(io, build_options.version ++ "\n"),
        .cf_pack => return packText(io, arena, o),
        .cf_expand => return expandImage(io, arena, o),
        .@"test" => return spec_file.run(io, arena, init.environ_map, o.specs, o.json),
        else => {},
    }
    if (command == .tui and !terminal) report.usage("tui needs stdin and stdout to be a terminal", .{});
    return simulate(init, arena, o) catch |err| switch (err) {
        // a reader such as head that has what it wants
        error.WriteFailed => report.status_error,
        else => |e| fatal("{t}", .{e}),
    };
}

/// Says what a command wrote, with --json
fn writeWritten(io: Io, path: []const u8, blocks: usize) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    var jw: std.json.Stringify = .{ .writer = writer };
    try jw.beginObject();
    try jw.objectField("stop");
    try jw.write("done");
    try jw.objectField("file");
    try report.bytes(&jw, path);
    try jw.objectField("blocks");
    try jw.write(blocks);
    try jw.endObject();
    try writer.writeByte('\n');
    try writer.flush();
}

/// Reads a file of blocks, decompressed if it is a compressed arrayForth 2
/// image, or nothing if it does not exist yet and `new` allows that
fn readBlocks(io: Io, arena: Allocator, path: []const u8, new: bool) ![]u8 {
    const colorforth = gasim.colorforth;
    const read = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_blocks_len)) catch |err| switch (err) {
        error.FileNotFound => if (new) "" else fatal("{s}: {t}", .{ path, err }),
        else => fatal("{s}: {t}", .{ path, err }),
    };
    const blocks = colorforth.compressedBlocks(read) orelse {
        const file = try arena.alloc(u8, colorforth.blockCount(read) * colorforth.block_size);
        @memset(file, 0);
        @memcpy(file[0..read.len], read);
        return file;
    };
    if (blocks * colorforth.block_size > max_blocks_len) fatal("{s}: has too many blocks", .{path});
    const file = try arena.alloc(u8, blocks * colorforth.block_size);
    colorforth.decompress(read, file) catch |err| fatal("{s}: {t}", .{ path, err });
    return file;
}

/// Writes text as blocks, into those of `--into` if there is one
fn packText(io: Io, arena: Allocator, o: *const Options) !u8 {
    const colorforth = gasim.colorforth;
    const source = o.path orelse usage("cf pack needs text, or - for stdin", .{});
    const text = if (std.mem.eql(u8, source, "-")) text: {
        var buffer: [4096]u8 = undefined;
        var stdin: Io.File.Reader = .init(.stdin(), io, &buffer);
        break :text stdin.interface.allocRemaining(arena, .limited(max_blocks_len)) catch |err| fatal("stdin: {t}", .{err});
    } else Io.Dir.cwd().readFileAlloc(io, source, arena, .limited(max_blocks_len)) catch |err| fatal("{s}: {t}", .{ source, err });

    var blocks: std.ArrayList(u8) = .empty;
    if (o.into) |into| try blocks.appendSlice(arena, try readBlocks(io, arena, into, true));
    const reader = try arena.create(colorforth.TextReader);
    reader.* = .init(text);
    while (true) {
        const block = reader.next() catch |err| fatal("{s}:{d}: {t} at '{s}'", .{ source, reader.line, err, reader.word }) orelse break;
        if (block.number >= max_blocks_len / colorforth.block_size) fatal("{s}:{d}: block {d} is past the most a file holds", .{ source, reader.line, block.number });
        const end = (block.number + 1) * colorforth.block_size;
        if (end > blocks.items.len) try blocks.appendNTimes(arena, 0, end - blocks.items.len);
        colorforth.encode(block.tokens, blocks.items[block.number * colorforth.block_size ..][0..colorforth.block_size]) catch |err|
            fatal("{s}: block {d}: {t}", .{ source, block.number, err });
    }
    const path = o.output orelse o.into.?;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = blocks.items }) catch |err| fatal("{s}: {t}", .{ path, err });
    if (o.json) try writeWritten(io, path, blocks.items.len / colorforth.block_size);
    return 0;
}

/// Writes a compressed arrayForth 2 image uncompressed
fn expandImage(io: Io, arena: Allocator, o: *const Options) !u8 {
    const colorforth = gasim.colorforth;
    const source = o.path orelse usage("cf expand needs an image", .{});
    const read = Io.Dir.cwd().readFileAlloc(io, source, arena, .limited(max_blocks_len)) catch |err| fatal("{s}: {t}", .{ source, err });
    if (colorforth.compressedBlocks(read) == null) fatal("{s}: is not a compressed arrayForth 2 image", .{source});
    const blocks = try readBlocks(io, arena, source, false);
    const path = o.output.?;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = blocks }) catch |err| fatal("{s}: {t}", .{ path, err });
    if (o.json) try writeWritten(io, path, blocks.len / colorforth.block_size);
    return 0;
}

/// a snapshot read as far as what the machine was, to build it, and its
/// chip's state to read into that
const Loaded = struct {
    machine: gasim.snapshot.Machine,
    reader: *Io.Reader,
};

/// the most a snapshot may take, with a flash and an SRAM all in use
const max_snapshot_len = 256 * 1024 * 1024;

fn readSnapshot(io: Io, arena: Allocator, path: []const u8) !Loaded {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_snapshot_len)) catch |err| fatal("{s}: {t}", .{ path, err });
    const reader = try arena.create(Io.Reader);
    reader.* = .fixed(bytes);
    const machine = gasim.snapshot.readMachine(reader, arena) catch |err| switch (err) {
        error.OtherVersion => fatal("{s}: is a snapshot from another gasim", .{path}),
        error.Invalid, error.EndOfStream => fatal("{s}: is not a snapshot", .{path}),
        else => |e| return e,
    };
    return .{ .machine = machine, .reader = reader };
}

/// Sets options as a snapshot's machine was set up
fn takeMachine(o: *Options, m: gasim.snapshot.Machine) void {
    if (m.board.len > 0) o.board_path = m.board;
    if (m.board_text.len > 0) o.board_text = m.board_text;
    if (m.chip_text.len > 0) o.chip_text = m.chip_text;
    if (m.rows > 0) o.layout = .{ .rows = m.rows, .columns = m.columns };
    for (m.settings, 0..) |setting, i| o.settings[i] = .{ .name = setting.name, .on = setting.on };
    o.settings_len = m.settings.len;
    o.console_node = m.console_node;
    o.console_port = m.console_port;
    // which a board's serial port says otherwise
    if (m.board.len == 0) o.uart_node = m.uart_node;
    o.uart_baud = m.uart_baud;
    if (m.usb.len > 0) o.usb = m.usb;
}

/// Writes a snapshot beside `path` and then moves it there, as `path` can be
/// the only copy of what it was read from
fn writeSnapshot(io: Io, arena: Allocator, path: []const u8, machine: gasim.snapshot.Machine, chip: *const Chip, devices: gasim.snapshot.Devices) !void {
    const temporary = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    const file = Io.Dir.cwd().createFile(io, temporary, .{}) catch |err| fatal("{s}: {t}", .{ temporary, err });
    var buffer: [65536]u8 = undefined;
    var file_writer: Io.File.Writer = .initStreaming(file, io, &buffer);
    gasim.snapshot.write(&file_writer.interface, machine, chip, devices) catch |err| fatal("{s}: {t}", .{ temporary, err });
    file_writer.interface.flush() catch |err| fatal("{s}: {t}", .{ temporary, err });
    file.close(io);
    Io.Dir.rename(.cwd(), temporary, .cwd(), path, io) catch |err| fatal("{s}: {t}", .{ path, err });
}

fn writeStarted(writer: *Io.Writer, path: []const u8) !void {
    var jw: std.json.Stringify = .{ .writer = writer };
    try jw.beginObject();
    try jw.objectField("stop");
    try jw.write("done");
    try jw.objectField("snapshot");
    try report.bytes(&jw, path);
    try jw.endObject();
    try writer.writeByte('\n');
    try writer.flush();
}

/// how far `step` got
const Stepped = struct {
    /// the last node stepped
    last: ?u16 = null,
    /// every node is waiting
    settled: bool = false,
};

/// Takes the steps or rounds the options say, up to a stop, as the keys of
/// the terminal user interface do
fn stepChip(chip: *Chip, o: *const Options, layout: Chip.Layout) !Stepped {
    var stepped: Stepped = .{};
    var hits_left = o.hits;
    chip.hit = null;
    const node: ?u16 = if (o.step_node) |n| layout.index(n) orelse usage("--node {f} is not in {f}", .{ Chip.nodeName(n), layout }) else null;
    for (0..o.rounds orelse o.count orelse 1) |_| {
        if (chip.interrupted()) break;
        if (o.rounds != null) {
            stepped.settled = !try chip.advance();
        } else if (node) |i| {
            _ = try chip.service();
            if (o.slot) chip.stepSlot(i) else chip.stepNode(i);
            stepped.last = i;
        } else {
            stepped.last = try chip.stepNext() orelse {
                stepped.settled = true;
                break;
            };
        }
        if (stepped.settled) break;
        if (chip.hit != null) {
            if (hits_left <= 1) break;
            hits_left -= 1;
            chip.hit = null;
        }
    }
    try chip.flushOutput();
    return stepped;
}

/// the nodes `show` is about, by index, or every one
fn shownNodes(arena: Allocator, chip: *const Chip, o: *const Options) ![]const u16 {
    const indices = try arena.alloc(u16, if (o.nodes.len > 0) o.nodes.len else chip.nodes.len);
    for (indices, 0..) |*index, k| index.* = if (o.nodes.len > 0)
        chip.layout.index(o.nodes[k]) orelse usage("node {f} is not in {f}", .{ Chip.nodeName(o.nodes[k]), chip.layout })
    else
        @intCast(k);
    return indices;
}

/// Says what is in a snapshot, as the options ask
fn show(arena: Allocator, writer: *Io.Writer, chip: *const Chip, o: *const Options) !void {
    const indices = try shownNodes(arena, chip, o);
    const first: u9 = o.at orelse if (o.rom_words) 0x80 else 0;
    const span: report.Span = .{ .first = first, .count = o.count orelse 64 };
    if (o.json) {
        var jw: std.json.Stringify = .{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("steps");
        try jw.write(chip.steps);
        try jw.objectField("time_ps");
        try jw.write(report.chipTime(chip));
        try jw.objectField("nodes");
        try jw.beginArray();
        for (indices) |i| if (o.nodes.len > 0) {
            try report.node(&jw, chip, i);
        } else {
            try jw.beginObject();
            try jw.objectField("node");
            try report.nodeNumber(&jw, chip.layout.nodeNumber(i));
            try report.statusFields(&jw, &chip.nodes[i]);
            try jw.objectField("p");
            try report.hex(&jw, @as(u10, @bitCast(chip.nodes[i].p)), 3);
            try jw.endObject();
        };
        try jw.endArray();
        if (o.mem) {
            try jw.objectField("memory");
            try jw.beginArray();
            for (indices) |i| {
                try jw.beginObject();
                try jw.objectField("node");
                try report.nodeNumber(&jw, chip.layout.nodeNumber(i));
                try jw.objectField("words");
                try report.memory(&jw, &chip.nodes[i], span);
                try jw.endObject();
            }
            try jw.endArray();
        }
        if (o.ports) {
            try jw.objectField("ports");
            try jw.beginArray();
            for (indices) |i| try report.ports(&jw, chip, i);
            try jw.endArray();
        }
        try jw.endObject();
        try writer.writeByte('\n');
    } else {
        for (indices) |i| {
            if (o.nodes.len > 0) {
                try report.nodeText(writer, chip, i);
            } else if (!o.mem and !o.ports) {
                const n = &chip.nodes[i];
                const name = Chip.nodeName(chip.layout.nodeNumber(i));
                try writer.print("{f} {x:0>3} ", .{ name, @as(u10, @bitCast(n.p)) });
                switch (n.status()) {
                    .running => try writer.writeAll("running\n"),
                    .code => |a| try writer.print("code {s}\n", .{ioName(a)}),
                    .reading => |a| try writer.print("reading {s}\n", .{ioName(a)}),
                    .writing => |a| try writer.print("writing {s}\n", .{ioName(a)}),
                }
            }
            if (o.mem) {
                if (o.nodes.len != 1) try writer.print("node {f}\n", .{Chip.nodeName(chip.layout.nodeNumber(i))});
                try report.memoryText(writer, &chip.nodes[i], span);
            }
            if (o.ports) try report.portsText(writer, chip, i);
        }
    }
    try writer.flush();
}

/// Writes text to stdout, for a command to end with
fn writeOut(io: Io, text: []const u8) !u8 {
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    try file_writer.interface.writeAll(text);
    try file_writer.interface.flush();
    return 0;
}

/// where stdin and stdout go, and the chip's file, once a board has had its
/// say
const Wiring = struct {
    chip_path: ?[]const u8,
    /// the board's serial port on stdin and stdout
    serial: ?gasim.Board.Serial = null,
    /// the node whose UART is on stdin and stdout
    uart_node: ?u16,
    uart_baud: u32,
};

/// Checks the options given with a board against it, and finds which of its
/// serial ports is on stdin and stdout
fn wire(arena: Allocator, o: *const Options, board: ?gasim.Board, from_snapshot: bool) !Wiring {
    var wiring: Wiring = .{ .chip_path = o.chip_path, .uart_node = o.uart_node, .uart_baud = o.uart_baud };
    const b = board orelse return wiring;
    const settings = o.settings[0..o.settings_len];
    const ptys = o.pty_ports[0..o.pty_len];
    // the terminal user interface and arrayForth 3 know one chip
    if (b.chips > 1 and (o.command == .tui or o.command == .aforth)) usage("--board with more than one chip needs run", .{});
    for (settings) |setting| {
        for (b.jumpers) |j| {
            if (std.mem.eql(u8, j.name, setting.name)) break;
        } else usage("--jumper {s}: {s} has no such jumper", .{ setting.name, b.name });
    }
    // relative to the board file, unless absolute
    if (!from_snapshot) wiring.chip_path = if (std.mem.eql(u8, b.chip, "ga144")) null else try std.fs.path.resolve(arena, &.{ std.fs.path.dirname(o.board_path.?) orelse ".", b.chip });
    if (b.serial.len > 0 and o.console_given) usage("--board puts its serial port on stdin and stdout, so there is no console for --console", .{});
    if (o.flash_path != null and b.flash == null) usage("--flash: {s} has no SPI flash", .{b.name});
    // the ports on ptys, and the one on stdin and stdout, if any
    for (ptys, 0..) |p, k| {
        const s = b.serialPort(p.name) orelse usage("--pty {s}: {s} has no such serial port", .{ p.name, b.name });
        for (ptys[0..k]) |other| if (std.mem.eql(u8, other.name, p.name)) usage("--pty {s} is given twice", .{p.name});
        if (o.usb) |name| if (std.mem.eql(u8, name, p.name)) usage("--usb {s} puts port {s} on stdin and stdout, so --pty cannot", .{ name, name });
        if (!b.jumperOn(s.rx.jumper, settings) and !b.jumperOn(s.tx.jumper, settings))
            usage("--jumper leaves both of port {s}'s lines unconnected, so nothing reaches its pty", .{s.name});
    }
    if (ptys.len == o.pty_ports.len and o.usb != null) usage("more than {d} serial ports, with --usb's", .{Chip.max_uarts});
    // with ptys, stdin and stdout are on a port only if --usb says
    wiring.serial = port: {
        if (o.usb) |name| break :port b.serialPort(name) orelse usage("--usb {s}: {s} has no such serial port", .{ name, b.name });
        break :port if (b.serial.len > 0 and ptys.len == 0) b.serial[0] else null;
    };
    const s = wiring.serial orelse {
        if (ptys.len > 0) {
            if (o.input != .stdin) usage("--input has nothing to read it, with --pty and no --usb", .{});
            if (o.boot) usage("--boot sends through the port on stdin and stdout, which --pty leaves on none without --usb", .{});
            if (o.console_given) usage("--board with --pty has no console for --console", .{});
        }
        return wiring;
    };
    const rx = b.jumperOn(s.rx.jumper, settings);
    const tx = b.jumperOn(s.tx.jumper, settings);
    if (!rx and !tx) usage("--jumper leaves both of port {s}'s lines unconnected, so nothing reaches stdin or stdout", .{s.name});
    if (!rx and (o.boot or o.path == null) and !from_snapshot)
        usage("--jumper {s}=off leaves port {s}'s rx unconnected, so nothing can boot node {f} from it", .{ s.rx.jumper.?, s.name, Chip.nodeName(s.rx.ref().node) });
    wiring.uart_node = if (rx) s.rx.ref().node else s.tx.ref().node;
    wiring.uart_baud = s.baud;
    return wiring;
}

/// Exits with what is wrong with a board on its chip, if anything is
fn checkBoard(b: gasim.Board, spec: gasim.Spec, path: []const u8) void {
    var fault: gasim.Board.Fault = .none;
    b.check(spec, &fault) catch |err| switch (fault) {
        .none => fatal("{s}: {t}", .{ path, err }),
        .name => |name| fatal("{s}: {s}: {t}", .{ path, name, err }),
        .pin => |pin| fatal("{s}: {f}.{d}: {t}, on {s}", .{ path, Chip.nodeName(pin.node), pin.pin, err, spec.name }),
        .node => |node| fatal("{s}: {f}: {t}, on {s}", .{ path, Chip.nodeName(node), err, spec.name }),
        .link => unreachable,
    };
}

/// a program's file
const Source = struct {
    /// its bytes, or none for colorForth, whose blocks have room to grow
    file: []const u8 = "",
    /// as lines of text, which a listing shows and blocks are numbered by
    text: []const u8 = "",
    colorforth: ?ColorForthBlocks = null,
};

fn readSource(io: Io, arena: Allocator, o: *const Options, kind: Kind) !Source {
    const path = o.path orelse return .{};
    // the editor creates a file that does not exist yet
    const colorforth: ?ColorForthBlocks = if (kind == .cf) try readColorForth(io, arena, path, o.command == .tui) else null;
    const file = switch (kind) {
        .cf => "",
        .blk => Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_blocks_len)) catch |err| fatal("{s}: {t}", .{ path, err }),
        // one spare byte tells a file of the most allowed from a longer one
        .ga, .af => Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_source_len + 1)) catch |err| switch (err) {
            error.StreamTooLong => fatal("{s}: file is too large", .{path}),
            else => fatal("{s}: {t}", .{ path, err }),
        },
    };
    return .{
        .file = file,
        // blocks are listed as lines of text, numbered the same way
        .text = if (kind == .cf and o.command == .listing)
            try colorForthText(arena, colorforth.?)
        else if (kind == .blk)
            gasim.arrayforth.blockText(file, try arena.alloc(u8, gasim.arrayforth.blockCount(file) * 16 * 65))
        else
            file,
        .colorforth = colorforth,
    };
}

/// Exits with where a source failed to assemble
fn failAssembling(err: anyerror, where: Where, diagnostic: *const assembler.Diagnostic, layout: Chip.Layout) noreturn {
    switch (err) {
        error.TooManyNodes => fatal("{f}: more nodes than {f} has at '{s}'", .{ where, layout, diagnostic.token }),
        error.NoSuchBlock => if (diagnostic.line == 0) fatal("{s}: has fewer blocks than --load needs", .{where.path}),
        error.NoSuchBin => if (diagnostic.line == 0) fatal("{s}: a boot descriptor loads a bin that was never saved", .{where.path}),
        else => {},
    }
    fatal("{f}: {t} at '{s}'", .{ where, err, diagnostic.token });
}

/// Warns of what a source assembled with that a real chip or arrayForth
/// would not take as gasim did
fn warnAssembled(assembled: gasim.arrayforth.Assembled, path: []const u8, kind: Kind) void {
    if (assembled.first_difference) |first| std.log.warn("{f}: arrayForth 2 noted {x:0>3} here, where gasim is at {x:0>3}, and {d} more gray numbers differ", .{
        Where{ .path = path, .line = first.line, .kind = .cf },
        first.noted,
        first.found,
        assembled.feedback_differs - 1,
    });
    for (assembled.programs) |program| if (program.unsettled_add) |add| std.log.warn("{f}: '{s}' runs straight after an opcode that changes S or T, which on a real chip needs a . between (DB001 2.3.3){s}", .{
        Where{ .path = path, .line = add.line, .kind = kind },
        add.token,
        if (program.unsettled_adds > 1) ", as do others in its node" else "",
    });
    if (assembled.unresolved_then) |line| std.log.warn("{f}: then has nothing to resolve, which arrayForth 2 went past", .{
        Where{ .path = path, .line = line, .kind = .cf },
    });
}

/// Writes each program as its words beside its source, and the boot
/// descriptors
fn writeListing(io: Io, assembled: gasim.arrayforth.Assembled, source: []const u8) !u8 {
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    for (assembled.programs, 0..) |program, n| {
        if (n > 0) try writer.writeByte('\n');
        if (program.bin) |bin| try writer.print("bin {d} ", .{bin});
        try writer.print("node {f}\n", .{Chip.nodeName(program.node)});
        try gasim.disassembler.listing(writer, program, source);
    }
    for (assembled.descriptors) |descriptor| try writer.print("\n{f}", .{descriptor});
    try writer.flush();
    return 0;
}

/// how a program gets into the chip
const Start = enum {
    /// set up in its nodes, as if they had booted
    direct,
    /// as a stream in the board's SPI flash, which node 705's ROM reads
    flash,
    /// as a stream sent to the serial port's node, as to 708
    uart,
    /// as a stream clocked into node 300's synchronous line
    sync,
    /// as a stream fed into node 001's up port, as from its SERDES
    serdes,
};

/// How the program gets into the chip, exiting if gasim cannot send what it
/// has that way.
///
/// Boot descriptors say what to load into nodes and how to start them, as a
/// stream's frame does even if it describes no node. The parts of a stream
/// set nodes up one after another, and /ROOT and FORWARD are for the root's
/// ROM, which only the STREAMER's stream does, through 708's UART, 300's
/// synchronous line or 705's flash.
fn startOf(o: *const Options, assembled: gasim.arrayforth.Assembled, uart_node: ?u16, on_board: bool, path: []const u8) Start {
    const interactive = o.command == .tui or o.command == .aforth;
    // Streams and pF/144's nucleus sent one after another, as block 1665
    // sends them, are not yet (ROADMAP step 6).
    if (assembled.sends().len > 0)
        fatal("{s} sends streams or pF/144's nucleus with !STREAM, !stream or !NUCLEUS, which gasim doesn't send yet", .{path});
    const root: ?u16 = if (assembled.stream) |s| s.root else null;
    const start: Start = if (!o.boot) .direct else if (root == 705) .flash else if (uart_node != null) .uart else if (root == 300) .sync else .serdes;
    if (o.boot and root == 207)
        fatal("--boot: {s}'s stream is for node 207, which pF/144's snorkel sends, and gasim does not run pF/144", .{path});
    // a board's pins are the board's, and its serial port the root it
    // boots from
    if (o.boot and root == 300 and on_board)
        fatal("--boot clocks {s}'s stream into node 300's pins itself, which --board leaves to the board", .{path});
    if (assembled.stream) |s| {
        if (s.root == 207 and s.frame_count > 1)
            fatal("{s}'s stream from node 207 has several frames, which pF/144's snorkel sends, and gasim sets up the nodes of only one", .{path});
        if ((s.part_count != s.frame_count or s.frame_count > 1) and (start == .direct or start == .serdes))
            fatal("{s}'s stream has several frames, or /ROOT or FORWARD, which only --boot sends to the root's ROM, with --uart 708, a --board's flash for 705, or 300's synchronous line", .{path});
    }
    // the flash is not in the chip's snapshots, which the interface
    // restarts from
    if (start == .flash and interactive) fatal("--boot from a board's flash needs run", .{});
    if (start == .sync and interactive) fatal("--boot through node 300's synchronous line needs run", .{});
    return start;
}

/// a program assembled, and the chip it is for
const Loading = struct {
    path: []const u8,
    assembled: gasim.arrayforth.Assembled,
    descriptors: []const gasim.boot.Descriptor,
    spec: *const gasim.Spec,
    layout: Chip.Layout,
    /// whether the chip's ROM is loaded
    rom: bool,
};

/// The program's stream packed for a board's flash, which 705's ROM reads
/// it from
fn flashStream(arena: Allocator, o: *const Options, board: ?gasim.Board, l: *const Loading) ![]const u8 {
    const b = board orelse fatal("--boot: {s}'s stream is for node 705, which boots from a board's SPI flash (see --board)", .{l.path});
    const pins = b.flash orelse fatal("--boot: {s}'s stream is for node 705, which boots from an SPI flash, and {s} has none", .{ l.path, b.name });
    const settings = o.settings[0..o.settings_len];
    if (o.flash_path != null) fatal("--boot puts {s}'s stream in the flash, so --flash cannot", .{l.path});
    if (!std.meta.eql(pins.data_in.ref(), Chip.PinRef{ .node = 705, .pin = 17 }))
        fatal("--boot: {s}'s flash sends on {f}.{d}, not 705.17, which 705's ROM reads", .{ b.name, Chip.nodeName(pins.data_in.ref().node), pins.data_in.pin });
    if (l.spec.node(705).rom != .spi_boot) fatal("--boot needs node 705 to have an SPI boot ROM, as the GA144's does", .{});
    if (!l.rom) fatal("--boot needs a ROM, for node 705 to boot from (see --rom)", .{});
    for (b.pulls) |pull| if (pull.high and std.meta.eql(pull.terminal().ref(), pins.data_in.ref()) and b.jumperOn(pull.jumper, settings))
        fatal("--boot: {s} holds 705.17 high{s}{s}, so 705 does not boot from the flash", .{ b.name, if (pull.jumper != null) " through " else "", pull.jumper orelse "" });
    const words = layOut(arena, l.layout, l.assembled, l.path);
    return gasim.streamer.pack(words, try arena.alloc(u8, (words.len * 18 + 15) / 16 * 2)) catch
        fatal("--boot: {s}'s stream is too long for the STREAMER to pack", .{l.path});
}

/// The bytes that boot the chip through the UART of node `root`: the
/// program's stream, or gasim's own for a program without one
fn uartStream(gpa: Allocator, arena: Allocator, l: *const Loading, root: u16, uart_option: []const u8) ![]const u8 {
    // gasim's boot stream sets up nodes of the chip it goes to, where
    // the STREAMER's paths can go on to another
    if (l.assembled.stream == null) for (l.descriptors) |descriptor| if (descriptor.node / Chip.Layout.chip_numbers != root / Chip.Layout.chip_numbers)
        fatal("--boot through node {f} boots its chip, not node {f}", .{ Chip.nodeName(root), Chip.nodeName(descriptor.node) });
    if (l.spec.node(root).rom != .async_boot)
        fatal("--boot with {s} needs a node whose ROM boots from its pins, as 708's does, not node {f}", .{ uart_option, Chip.nodeName(root) });
    if (!l.rom) fatal("--boot needs a ROM, for node {f} to boot from (see --rom)", .{Chip.nodeName(root)});
    // laid out as arrayForth 3's STREAMER does, for a STREAM[ ]STREAM
    const words = if (l.assembled.stream) |s| streamer: {
        if (root != s.root) fatal("--boot: {s}'s stream is for node {f}, not the --uart node {f}", .{ l.path, Chip.nodeName(s.root), Chip.nodeName(root) });
        break :streamer layOut(arena, l.layout, l.assembled, l.path);
    } else gasim: {
        const buffer = try arena.alloc(gasim.Word, gasim.boot.maxLen(l.layout, l.descriptors) + 3 * (l.descriptors.len + 2));
        break :gasim gasim.boot.asyncStream(gpa, l.layout, root, l.descriptors, l.assembled.programs, buffer) catch |err| switch (err) {
            error.NoSuchNode => fatal("--uart node {f} is not in {f}", .{ Chip.nodeName(root), l.layout }),
            error.StreamTooLong => fatal("--boot: the boot stream is too long for a node to copy on", .{}),
            error.RootTooLong => fatal("--boot: node {f}'s program leaves no room in its RAM for the code that sets it up", .{Chip.nodeName(root)}),
            else => |e| return e,
        };
    };
    return gasim.boot.asyncBytes(words, try arena.alloc(u8, 3 * words.len));
}

/// The program's stream to clock into node 300's pins, as the EVB002's host
/// 300 would its target's, whose pins are the board's
fn syncStream(arena: Allocator, o: *const Options, l: *const Loading) []gasim.Word {
    if (o.console_node == 300 and o.console_port == .left) fatal("--boot clocks the stream into node 300's wakeup pin, which its left port reads, so the console cannot use it", .{});
    if (l.spec.node(300).rom != .sync_boot) fatal("--boot needs node 300 to have a sync boot ROM, as the GA144's does", .{});
    if (!l.rom) fatal("--boot needs a ROM, for node 300 to boot from (see --rom)", .{});
    return layOut(arena, l.layout, l.assembled, l.path);
}

/// gasim's boot stream to feed into node 001's up port
fn serdesStream(gpa: Allocator, arena: Allocator, o: *const Options, l: *const Loading) ![]const gasim.Word {
    if (o.console_node == 1 and o.console_port == .up) fatal("--boot streams into node 001's up port, so the console cannot use it", .{});
    if (l.spec.node(1).rom != .serdes_boot) fatal("--boot needs node 001 to have a SERDES boot ROM, as the GA144's does", .{});
    if (!l.rom) fatal("--boot needs a ROM, for node 001 to boot from (see --rom)", .{});
    for (l.descriptors) |descriptor| if (descriptor.node >= Chip.Layout.chip_numbers)
        fatal("--boot through node 001 boots its chip, not node {f}", .{Chip.nodeName(descriptor.node)});
    const buffer = try arena.alloc(gasim.Word, gasim.boot.maxLen(l.layout, l.descriptors));
    return gasim.boot.stream(gpa, l.layout, 1, .up, l.descriptors, l.assembled.programs, buffer) catch |err| switch (err) {
        error.NoSuchNode => fatal("--boot needs node 001, which is not in {f}", .{l.layout}),
        error.StreamTooLong => fatal("--boot: the boot stream is too long for a node to copy on", .{}),
        error.NoSuchBin => fatal("{s}: a node loads a bin that was not saved", .{l.path}),
        else => |e| return e,
    };
}

/// Sets the breakpoints and watches the options name
fn setStops(chip: *Chip, o: *const Options) void {
    const layout = chip.layout;
    for (o.breakpoints[0..o.breakpoints_len]) |b| {
        const index = layout.index(b.node) orelse
            fatal("breakpoint node {f} is not in {f}", .{ Chip.nodeName(b.node), layout });
        // the same breakpoint twice is still set
        chip.breakpoints.insert(.init(index, b.address)) catch unreachable;
    }
    for (o.watches[0..o.watches_len]) |w| {
        const index = layout.index(w.node) orelse
            fatal("watch node {f} is not in {f}", .{ Chip.nodeName(w.node), layout });
        for ([_]bool{ false, true }) |write| {
            if (!(if (write) w.write else w.read)) continue;
            chip.watches.insert(.{ .index = index, .direction = w.direction, .write = write }) catch
                fatal("more than {d} watches", .{Chip.max_watches});
        }
    }
}

/// The serial ports on ptys, each with its UART. Each is read on its own
/// thread, as stdin is, ringing the doorbell that a run waiting for any
/// input waits on.
///
/// It keeps pointers to its own fields, so it must not move once `open`.
const Ptys = struct {
    ports: []const Options.Pty,
    devices: [max]Pty,
    uarts: [max]gasim.Uart,
    inputs: [max]Io.Queue(u8),
    input_buffers: [max][1024]u8,
    output_buffers: [max][1024]u8,
    queue_buffers: [max][4096]u8,
    read_buffers: [max][1024]u8,
    readers: [max]Io.File.Reader,
    reading: [max]Io.Future((error{ReadFailed} || Io.Cancelable)!void),
    writing: [max]Io.Future((Io.File.Writer.Error || Io.QueueClosedError)!void),

    const max = Chip.max_uarts;

    fn open(self: *Ptys, io: Io, arena: Allocator, ports: []const Options.Pty) void {
        self.ports = ports;
        for (ports, 0..) |p, k| {
            self.devices[k] = Pty.open(io, arena, &self.output_buffers[k], &self.queue_buffers[k]) catch |err| fatal("--pty {s}: {t}", .{ p.name, err });
            self.inputs[k] = .init(&self.input_buffers[k]);
            self.readers[k] = .initStreaming(self.devices[k].master, io, &self.read_buffers[k]);
        }
    }

    fn close(self: *Ptys, io: Io) void {
        for (self.devices[0..self.ports.len]) |*device| device.close(io);
    }

    /// the UART of port `k`, at `baud`, on its pty
    fn uart(self: *Ptys, io: Io, k: usize, baud: u32) *gasim.Uart {
        self.uarts[k] = .init(baud, &self.devices[k].writer);
        self.uarts[k].input = .{ .io = io, .queue = &self.inputs[k] };
        return &self.uarts[k];
    }

    /// Starts reading and writing each, saying where it is
    fn start(self: *Ptys, io: Io, doorbell: *Io.Queue(u8)) void {
        for (self.ports, 0..) |p, k| {
            self.reading[k] = io.concurrent(readRinging, .{ io, &self.readers[k].interface, &self.inputs[k], doorbell }) catch |err|
                fatal("cannot read input concurrently: {t}", .{err});
            self.writing[k] = io.concurrent(Pty.writeOut, .{&self.devices[k]}) catch |err|
                fatal("cannot write output concurrently: {t}", .{err});
            std.log.info("port {s}: {s}", .{ p.name, self.devices[k].path });
        }
    }

    fn stop(self: *Ptys, io: Io) void {
        for (self.writing[0..self.ports.len]) |*future| future.cancel(io) catch {};
        for (self.reading[0..self.ports.len]) |*future| future.cancel(io) catch {};
    }

    fn warnDropped(self: *const Ptys) void {
        for (self.ports, 0..) |p, k| if (self.devices[k].dropped > 0)
            std.log.warn("port {s}: {d} bytes were dropped, as nothing read them from {s}", .{ p.name, self.devices[k].dropped, self.devices[k].path });
    }
};

/// Attaches a board's serial ports, jumpers and pulls to the chip, and its
/// flash and SRAM if asked for. Returns the SRAM.
fn attachBoard(
    io: Io,
    arena: Allocator,
    o: *const Options,
    b: gasim.Board,
    chip: *Chip,
    /// the port on stdin and stdout, with its UART
    serial: ?gasim.Board.Serial,
    uart: *gasim.Uart,
    ptys: *Ptys,
    flash: ?*gasim.Flash,
    with_sram: bool,
) !?*gasim.Sram {
    const path = o.board_path.?;
    const settings = o.settings[0..o.settings_len];
    var fault: gasim.Board.Fault = .none;
    var attachments: [Chip.max_uarts]gasim.Board.Attachment = undefined;
    var count: usize = 0;
    if (serial) |s| {
        attachments[0] = .{ .uart = uart, .port = s };
        count = 1;
    }
    for (ptys.ports, 0..) |p, k| {
        const s = b.serialPort(p.name).?;
        attachments[count] = .{ .uart = ptys.uart(io, k, s.baud), .port = s };
        count += 1;
    }
    b.apply(chip, attachments[0..count], settings, &fault) catch |err| switch (fault) {
        .none => fatal("{s}: {t}", .{ path, err }),
        .name => |name| fatal("{s}: port {s}: {t}", .{ path, name, err }),
        .pin => |pin| fatal("{s}: {f}.{d}: {t}", .{ path, Chip.nodeName(pin.node), pin.pin, err }),
        .node => |node| fatal("{s}: {f}: {t}", .{ path, Chip.nodeName(node), err }),
        .link => |link| fatal("{s}: SERDES {f} to {f}: {t}", .{ path, Chip.nodeName(link[0]), Chip.nodeName(link[1]), err }),
    };
    if (flash) |f| b.attachFlash(chip, f, settings) catch |err|
        fatal("{s}: the SPI flash's pins: {t}", .{ path, err });
    const m = b.sram orelse return null;
    if (!with_sram) return null;
    // zeroed
    const sram = try arena.create(gasim.Sram);
    const words = try arena.alloc(u16, m.words);
    @memset(words, 0);
    sram.* = .init(words);
    b.attachSram(chip, sram, settings) catch |err|
        fatal("{s}: the SRAM: {t}", .{ path, err });
    return sram;
}

/// Runs arrayForth 3's prompt, or the lines given, on the chip
fn runAforth(
    init: std.process.Init,
    arena: Allocator,
    o: *const Options,
    chip: *Chip,
    session: *gasim.arrayforth.Session,
    diagnostic: *const assembler.Diagnostic,
    /// the terminal
    terminal: *Io.Writer,
    /// with --json, what the prompt wrote, and what the console did
    said: *Io.Writer.Allocating,
    console_said: *Io.Writer.Allocating,
    saving: Saving,
    settle: bool,
) !u8 {
    const io = init.io;
    const out = if (o.json) &said.writer else terminal;
    const edit = try Io.File.stdin().isTty(io) and try Io.File.stdout().isTty(io) and o.lines_len == 0;
    var stderr_lines_buffer: [1024]u8 = undefined;
    var stderr_lines: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_lines_buffer);
    var errors: Io.Writer.Allocating = .init(arena);
    const failed = try aforth.run(io, arena, chip, session, diagnostic, out, .{
        .edit = edit,
        .history = historyPath(io, arena, init.environ_map),
        .lines = o.lines[0..o.lines_len],
        .errors = if (o.json) &errors.writer else if (edit) out else &stderr_lines.interface,
        .settle = settle,
    });
    if (o.to) |p| try saving.write(io, arena, p, chip);
    if (o.json) {
        var jw: std.json.Stringify = .{ .writer = terminal };
        try jw.beginObject();
        try jw.objectField("stop");
        try jw.write(if (failed) "error" else "done");
        try jw.objectField("output");
        try report.bytes(&jw, said.written());
        try jw.objectField("console");
        try report.bytes(&jw, console_said.written());
        try jw.objectField("errors");
        try report.bytes(&jw, errors.written());
        if (o.to) |p| {
            try jw.objectField("snapshot");
            try report.bytes(&jw, p);
        }
        try jw.endObject();
        try terminal.writeByte('\n');
        try terminal.flush();
    }
    return if (failed) report.status_error else 0;
}

/// what a snapshot of the chip is written with
const Saving = struct {
    machine: gasim.snapshot.Machine,
    devices: gasim.snapshot.Devices,

    fn write(self: Saving, io: Io, arena: Allocator, path: []const u8, chip: *const Chip) !void {
        return writeSnapshot(io, arena, path, self.machine, chip, self.devices);
    }
};

/// how a run or the steps of `step` ended
const Ended = struct {
    stop: report.Stop,
    stepped: Stepped,
    elapsed: Io.Duration,
};

/// Writes how a run ended as one JSON object, with the `output` its nodes
/// wrote
fn writeEnded(writer: *Io.Writer, o: *const Options, chip: *const Chip, ended: Ended, output: []const u8) !void {
    const layout = chip.layout;
    var jw: std.json.Stringify = .{ .writer = writer };
    try jw.beginObject();
    try report.stopFields(&jw, chip, ended.stop);
    try jw.objectField("steps");
    try jw.write(chip.steps);
    try jw.objectField("time_ps");
    try jw.write(report.chipTime(chip));
    try jw.objectField("output");
    try report.bytes(&jw, output);
    if (ended.stepped.last) |i| {
        try jw.objectField("stepped");
        try report.nodeNumber(&jw, layout.nodeNumber(i));
    }
    if (o.to) |p| {
        try jw.objectField("snapshot");
        try report.bytes(&jw, p);
    }
    if (o.stats) {
        try jw.objectField("seconds");
        try jw.write(@as(f64, @floatFromInt(ended.elapsed.toNanoseconds())) / 1e9);
    }
    if (o.why) {
        try jw.objectField("waiting");
        try report.waiting(&jw, chip);
    }
    if (chip.hazard_count > 0) {
        try jw.objectField("hazards");
        try report.hazards(&jw, chip);
        try jw.objectField("hazard_count");
        try jw.write(chip.hazard_count);
    }
    if (o.show != .none) {
        try jw.objectField("nodes");
        try jw.beginArray();
        switch (o.show) {
            .none => {},
            .all => for (0..chip.nodes.len) |i| try report.node(&jw, chip, @intCast(i)),
            .nodes => |nodes| for (nodes) |node| try report.node(&jw, chip, layout.index(node).?),
        }
        try jw.endArray();
    }
    try jw.endObject();
    try writer.writeByte('\n');
    try writer.flush();
}

/// Logs how a run ended, and what the options ask to see of it
fn logEnded(o: *const Options, chip: *const Chip, ended: Ended) void {
    const layout = chip.layout;
    if (o.stats) logStats(chip.*, ended.elapsed);
    if (chip.hit) |hit| {
        std.log.info("{f}", .{hit.describe(layout)});
        logRegisters(&chip.nodes[hit.index()]);
    }
    if (ended.stepped.last) |i| std.log.info("stepped node {f}", .{Chip.nodeName(layout.nodeNumber(i))});
    if (ended.stop == .limit) std.log.info("stopped at a limit, after {d} steps and {d} ps of the chip's time", .{ chip.steps, report.chipTime(chip) });
    if (o.why) logWaiting(chip.*);
    switch (o.show) {
        .none => {},
        .all => for (0..chip.nodes.len) |i| logNode(chip, @intCast(i)),
        .nodes => |nodes| for (nodes) |node| logNode(chip, layout.index(node).?),
    }
}

/// Sets the chip up as the options say, and does what the command does with
/// it, returning the status to exit with
fn simulate(init: std.process.Init, arena: Allocator, given: *const Options) !u8 {
    const io = init.io;
    const loaded: ?Loaded = if (given.from) |p| try readSnapshot(io, arena, p) else null;
    var from_snapshot = given.*;
    if (loaded) |l| {
        takeMachine(&from_snapshot, l.machine);
        // which the interface does not go back with
        if (given.command == .tui and (l.machine.flash or l.machine.sram or l.machine.sync))
            usage("{s}: tui cannot go back with its flash, SRAM or synchronous line, so it needs run or step", .{given.from.?});
    }
    const o = &from_snapshot;
    const command = o.command;
    const interactive = command == .tui or command == .aforth;
    const settings = o.settings[0..o.settings_len];

    // the board, its chip, and the serial port on stdin and stdout, which is
    // as --uart is
    if (o.board_path != null) {
        if (o.chip_path != null or o.layout != null) usage("--board gives the chip, so --chip and --layout cannot", .{});
        if (o.uart_node != null) usage("--board puts its serial port on stdin and stdout, so --uart cannot", .{});
    } else if (o.usb != null or o.settings_len > 0 or o.pty_len > 0 or o.flash_path != null) usage("--usb, --pty, --jumper and --flash need --board", .{});
    var board_text: []const u8 = o.board_text orelse "";
    var chip_text: []const u8 = o.chip_text orelse "";
    const board: ?gasim.Board = if (o.board_path) |p| readBoard(io, arena, init.gpa, p, &board_text) else null;
    const wiring = try wire(arena, o, board, loaded != null);
    const serial = wiring.serial;
    const uart_node = wiring.uart_node;
    var flash: gasim.Flash = .init(if (o.flash_path) |p| Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(gasim.Flash.max_len + 1)) catch |err| switch (err) {
        error.StreamTooLong => fatal("--flash {s} is larger than a flash's 16 MB", .{p}),
        else => fatal("--flash {s}: {t}", .{ p, err }),
    } else &.{});
    // for messages, what put stdin and stdout on a UART
    const uart_option = if (board != null) "--board" else "--uart";
    if (o.path == null and loaded == null and needsProgram(command, uart_node != null or o.pty_len > 0)) usage("{s} needs a program: gasim help {s} says more", .{ command.name(), command.name() });
    if (command == .blocks) {
        try writeBlocks(io, arena, o.path.?, o.loads[0..o.loads_len]);
        return 0;
    }

    // the chip
    if (wiring.chip_path != null and o.layout != null) usage("--chip and --layout both give the chip", .{});
    const spec: gasim.Spec = if (wiring.chip_path != null or chip_text.len > 0)
        readChip(io, arena, init.gpa, wiring.chip_path orelse "the snapshot's chip", &chip_text)
    else if (o.layout) |l|
        .{ .rows = l.rows, .columns = l.columns }
    else
        .ga144;
    const layout = if (board) |b| b.layout(spec) else spec.layout();
    if (board) |b| checkBoard(b, spec, o.board_path.?);

    // the program
    const source_path = o.path orelse "";
    const kind: Kind = .ofPath(source_path);
    // colorForth blocks, which the terminal user interface edits, and only
    // compiles at the start with --load
    const compile_colorforth = kind == .cf and (o.loads_len > 0 or command != .tui);
    if (uart_node != null and interactive) usage("{s} needs run, as stdin and stdout are its serial port's", .{if (loaded != null) "the snapshot's serial port" else if (board != null) "--board" else "--uart"});
    if (uart_node != null and o.console_given) usage("--uart puts stdin and stdout on the UART, so there is no console for --console", .{});
    if (uart_node != null and o.boot and o.path == null) usage("--boot needs a program to send node {f}", .{Chip.nodeName(uart_node.?)});
    if (o.loads_len > 0 and kind != .blk and kind != .cf) usage("--load needs a .blk or .cf file of blocks", .{});
    const loads: []const u32 = if (o.loads_len > 0) o.loads[0..o.loads_len] else &.{0};
    const source = try readSource(io, arena, o, kind);
    const file = source.file;

    var chip: Chip = try .initChips(init.gpa, spec, layout.chips);
    defer chip.deinit(init.gpa);
    chip.strict = o.strict;

    // a snapshot's nodes hold theirs
    const roms = if (loaded != null and o.path == null) null else readRom(io, arena, init.environ_map, o.rom_path);
    // which readRom checks for
    if (roms) |r| chip.loadRom(r) catch unreachable;
    if (uart_node != null and o.path == null and roms == null and loaded == null)
        fatal("--uart without a program needs a ROM, for node {f} to boot from its input (see --rom)", .{Chip.nodeName(uart_node.?)});
    if (o.flash_path != null and roms == null) std.log.warn("--flash without a ROM: no node boots from the flash (see --rom)", .{});

    const program_buffer = try arena.alloc(assembler.Program, layout.count());
    // each frame of a stream has descriptors of its own
    const descriptor_buffer = try arena.alloc(gasim.boot.Descriptor, layout.count() * gasim.arrayforth.Stream.max_frames);
    var diagnostic: assembler.Diagnostic = .{};
    // the prompt, and the console with it, write here
    var aforth_buffer: [4096]u8 = undefined;
    var aforth_writer: Io.File.Writer = .init(.stdout(), io, &aforth_buffer);
    // or with --json, here, and the console apart
    var aforth_captured: Io.Writer.Allocating = .init(arena);
    var captured: Io.Writer.Allocating = .init(arena);
    // and the terminal user interface's forth panel here
    var forth_buffer: [tui.forth_capacity]u8 = undefined;
    var forth_output: Io.Writer = .fixed(&forth_buffer);
    // arrayForth 3 at the prompt or in the forth panel keeps the bins and
    // labels of an arrayForth 3 program
    const session: ?*gasim.arrayforth.Session = if (interactive) session: {
        const session = try arena.create(gasim.arrayforth.Session);
        session.* = .init(program_buffer, descriptor_buffer, &diagnostic, .{
            .out = if (command == .tui) &forth_output else if (o.json) &aforth_captured.writer else &aforth_writer.interface,
            .chip = &chip,
            .blocks = if (kind == .blk) file else null,
        });
        break :session session;
    } else null;
    const assembled = (if (kind == .cf)
        compileColorForth(session, source.colorforth.?, if (compile_colorforth) loads else &.{}, program_buffer, descriptor_buffer, &diagnostic)
    else if (session != null and (kind != .ga or o.path == null))
        loadSession(arena, session.?, &diagnostic, file, kind == .blk, loads, o.path != null)
    else if (kind == .blk)
        gasim.arrayforth.assembleBlocks(file, loads, program_buffer, descriptor_buffer, &diagnostic)
    else
        assemble(&spec, source_path, file, program_buffer, descriptor_buffer, &diagnostic)) catch |err|
        failAssembling(err, .{ .path = source_path, .line = diagnostic.line, .kind = kind }, &diagnostic, layout);
    const programs = assembled.programs;
    // arrayForth 3 and colorForth know the GA144's ROM words only
    if (kind != .ga) for (programs) |program| {
        if (spec.node(program.node).rom != gasim.Spec.ga144.node(program.node).rom)
            fatal("{s}: node {f} has another ROM than the GA144's {d:0>3}, and arrayForth 3 and colorForth programs are assembled for the GA144's ROMs", .{ source_path, Chip.nodeName(program.node), program.node % Chip.Layout.chip_numbers });
    };
    warnAssembled(assembled, source_path, kind);
    if (command == .listing) return writeListing(io, assembled, source.text);

    // how it gets into the chip. Without boot descriptors, each program in
    // its node's own bin is loaded and started at its entry.
    const start = startOf(o, assembled, uart_node, board != null, source_path);
    const descriptors = if (assembled.descriptors.len > 0 or assembled.stream != null) assembled.descriptors else gasim.boot.ownDescriptors(programs, descriptor_buffer);
    for (descriptors) |descriptor| if (layout.index(descriptor.node) == null)
        fatal("{s}: node {f} is not in {f}", .{ source_path, Chip.nodeName(descriptor.node), layout });
    if (roms == null and loaded == null) if (gasim.boot.romUse(descriptors, programs)) |use| switch (use) {
        .word => |word| fatal("{f}: '{s}' is in ROM, which is not loaded (see --rom)", .{ Where{ .path = source_path, .line = word.line, .kind = kind }, word.token }),
        .start => |descriptor| fatal("{s}: node {f} starts in ROM at {x:0>3}, which is not loaded (see --rom)", .{ source_path, Chip.nodeName(descriptor.node), descriptor.p }),
    };
    setStops(&chip, o);
    const loading: Loading = .{ .path = source_path, .assembled = assembled, .descriptors = descriptors, .spec = &spec, .layout = layout, .rom = roms != null };

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    // the node's output, which an object says with --json
    const run_output = if (o.json) &captured.writer else &stdout_file_writer.interface;
    var uart: gasim.Uart = .init(wiring.uart_baud, run_output);
    var ptys: Ptys = undefined;
    ptys.open(io, arena, o.pty_ports[0..o.pty_len]);
    defer ptys.close(io);
    var doorbell_buffer: [64]u8 = undefined;
    var doorbell: Io.Queue(u8) = .init(&doorbell_buffer);
    var feeder: Chip.Feeder = .{ .words = &.{} };
    var sync: gasim.Sync = .init(&.{});
    switch (start) {
        .flash => flash = .init(try flashStream(arena, o, board, &loading)),
        .uart => uart.preload = try uartStream(init.gpa, arena, &loading, uart_node.?, uart_option),
        .sync => {
            sync = .init(syncStream(arena, o, &loading));
            chip.attachSyncPins(&sync, .{ .node = 300, .pin = 17 }, .{ .node = 300, .pin = 1 }) catch |err|
                fatal("--boot needs node 300's pins 17 and 1, free for its synchronous line ({t})", .{err});
        },
        .serdes => {
            feeder.words = try serdesStream(init.gpa, arena, o, &loading);
            chip.attachFeeder(&feeder, 1, .up) catch fatal("--boot needs node 001's up port to face off the chip", .{});
        },
        .direct => for (descriptors) |descriptor| chip.setUp(descriptor, programs) catch |err| switch (err) {
            error.NoSuchBin => fatal("{s}: node {f} loads a bin that was not saved", .{ source_path, Chip.nodeName(descriptor.node) }),
            error.NoSuchNode => unreachable,
        },
    }

    // what a snapshot says was going on, which reading it fills in
    if (loaded) |l| {
        if (l.machine.feeder) chip.attachFeeder(&feeder, 1, .up) catch fatal("the snapshot's boot stream needs node 001's up port", .{});
        if (l.machine.sync) chip.attachSyncPins(&sync, .{ .node = 300, .pin = 17 }, .{ .node = 300, .pin = 1 }) catch |err|
            fatal("the snapshot's synchronous line needs node 300's pins 17 and 1 ({t})", .{err});
    }

    // the console, or the UART, and what else is on the board
    var stdin_buffer: [1024]u8 = undefined;
    const input_file: Io.File = switch (o.input) {
        .file => |p| Io.Dir.cwd().openFile(io, p, .{}) catch |err| fatal("--input {s}: {t}", .{ p, err }),
        else => .stdin(),
    };
    var stdin_file_reader: Io.File.Reader = .init(input_file, io, &stdin_buffer);
    // the terminal user interface shows console output from here
    var screen_buffer: [tui.console_capacity]u8 = undefined;
    var screen: Io.Writer = .fixed(&screen_buffer);

    var input_buffer: [1024]u8 = undefined;
    var input: Io.Queue(u8) = .init(&input_buffer);
    var console: Console = .{
        .input = .{ .io = io, .queue = &input },
        .output = switch (command) {
            .tui => &screen,
            .aforth => if (o.json) &captured.writer else &aforth_writer.interface,
            else => run_output,
        },
    };
    const flash_attached = board != null and (o.flash_path != null or start == .flash or (loaded != null and loaded.?.machine.flash));
    // the SRAM is not in the chip's snapshots, so only for run, as a board
    // of more than one chip such as the EVB002 is
    const attached_sram = if (board) |b|
        try attachBoard(io, arena, o, b, &chip, serial, &uart, &ptys, if (flash_attached) &flash else null, if (loaded) |l| l.machine.sram else !interactive)
    else
        null;
    if (uart_node) |node| {
        uart.input = .{ .io = io, .queue = &input };
        if (board == null) chip.attachUart(&uart, node) catch |err| switch (err) {
            error.NoSuchNode => fatal("--uart node {f} is not in {f}", .{ Chip.nodeName(node), layout }),
            error.NoPins => fatal("--uart node {f} has no pins 17 and 1", .{Chip.nodeName(node)}),
        };
        // booting from ROM waits for pin 17 through the port facing off the
        // chip, up on the top and bottom rows and left on the others
        if ((o.boot or o.path == null) and loaded == null) {
            if (spec.node(node).rom != .async_boot)
                fatal("{s} without a program boots node {f} from its ROM, which is not an asynchronous boot ROM, as 708's is", .{ uart_option, Chip.nodeName(node) });
            if (chip.nodes[layout.index(node).?].wake_port == null)
                fatal("node {f} has no port facing off the chip that pin 17 could wake it through to boot: up on the top and bottom rows, left on the others", .{Chip.nodeName(node)});
        }
    } else if (o.pty_len == 0) chip.attachConsole(&console, o.console_node, o.console_port) catch |err| switch (err) {
        error.NoSuchNode => fatal("console node {f} is not in {f}", .{ Chip.nodeName(o.console_node), layout }),
        error.PortConnected => fatal("console port {t} of node {f} is connected to another node", .{ o.console_port, Chip.nodeName(o.console_node) }),
    };

    const devices: gasim.snapshot.Devices = .{ .flash = if (flash_attached) &flash else null, .sram = attached_sram };
    if (loaded) |l| gasim.snapshot.readChip(l.reader, arena, &chip, devices) catch |err|
        fatal("{s}: {t}", .{ given.from.?, err });
    // the machine, as a snapshot says it
    const settings_saved = try arena.alloc(gasim.snapshot.Machine.Setting, settings.len);
    for (settings_saved, settings) |*saved, setting| saved.* = .{ .name = setting.name, .on = setting.on };
    const saving: Saving = .{ .devices = devices, .machine = .{
        .board = o.board_path orelse "",
        .board_text = board_text,
        .chip_text = chip_text,
        .rows = if (o.layout) |l| l.rows else 0,
        .columns = if (o.layout) |l| l.columns else 0,
        .settings = settings_saved,
        .console_node = o.console_node,
        .console_port = o.console_port,
        .uart_node = if (board == null) uart_node else null,
        .uart_baud = wiring.uart_baud,
        .usb = o.usb orelse "",
        .feeder = chip.feeder != null,
        .sync = chip.sync != null,
        .flash = flash_attached,
        .sram = attached_sram != null,
    } };
    // input for a session goes with its snapshot, after what it has kept
    const session_input = (command == .run or command == .step) and (o.from != null or o.to != null);
    if (session_input and o.input != .none) {
        const more = stdin_file_reader.interface.allocRemaining(arena, .unlimited) catch |err| fatal("input: {t}", .{err});
        if (uart_node != null) {
            try uart.addPreload(arena, more, chip.nodes[chip.uarts.items[0].index].time);
        } else console.preload = try std.mem.concat(arena, u8, &.{ console.preload, more });
    }

    // what the command does with the chip
    switch (command) {
        .start => {
            try saving.write(io, arena, o.to.?, &chip);
            if (o.json) try writeStarted(&stdout_file_writer.interface, o.to.?);
            return 0;
        },
        .show => {
            try show(arena, &stdout_file_writer.interface, &chip, o);
            return 0;
        },
        .aforth => return runAforth(init, arena, o, &chip, session.?, &diagnostic, &aforth_writer.interface, &aforth_captured, &captured, saving, loaded == null),
        .tui => {
            // a snapshot alone has no source
            const source_map: ?gasim.SourceMap = if (o.path != null) try .init(arena, layout, programs, descriptors, file, source_path, switch (kind) {
                .ga, .af => .text,
                .blk => .blocks,
                .cf => .colorforth,
            }) else null;
            try tui.run(io, init.gpa, init.environ_map, &chip, .{
                .source_map = if (source_map) |*map| map else null,
                .source_path = source_path,
                .console = &console,
                .console_node = o.console_node,
                .console_port = o.console_port,
                .forth = .{ .session = session.?, .output = &forth_output, .diagnostic = &diagnostic, .arena = arena },
                // without a .cf file, on a new file of blocks, to name when it is saved
                .colorforth = try editColorForth(arena, source.colorforth orelse try newColorForth(arena), if (kind == .cf) source_path else null),
            });
            return 0;
        },
        else => {},
    }

    // run, or step
    var stderr_buffer: [4096]u8 = undefined;
    // streaming, as std.log writes to stderr too: a positional writer would
    // write over its lines when stderr is a file
    var stderr_file_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    var trace_buffer: [4096]u8 = undefined;
    var trace_file_writer: Io.File.Writer = undefined;
    if (o.trace_file) |p| trace_file_writer = .initStreaming(Io.Dir.cwd().createFile(io, p, .{}) catch |err| fatal("--trace-file {s}: {t}", .{ p, err }), io, &trace_buffer);
    if (o.trace) chip.trace = if (o.trace_file != null) &trace_file_writer.interface else &stderr_file_writer.interface;
    defer if (o.trace_file != null) trace_file_writer.interface.flush() catch {};
    chip.trace_json = o.json;
    if (o.trace_node) |node| chip.trace_only = layout.index(node) orelse
        usage("--trace-node {f} is not in {f}", .{ Chip.nodeName(node), layout });
    switch (o.show) {
        .nodes => |nodes| for (nodes) |node| if (layout.index(node) == null)
            usage("--show node {f} is not in {f}", .{ Chip.nodeName(node), layout }),
        else => {},
    }
    if (o.max_steps) |steps| chip.step_limit = chip.steps +| steps;
    if (o.max_time) |time| chip.time_limit = time;
    // what was traced up to an error or a breakpoint. Exiting without
    // returning skips this, so those paths flush first.
    defer stderr_file_writer.interface.flush() catch {};

    // a run with several UARTs waits on the first's (see `Chip.waitForInput`)
    interruptible = if (chip.uarts.len > 0)
        .{ .interrupted = &chip.uarts.items[0].device.interrupted, .waiting = &chip.uarts.items[0].device.waiting }
    else
        .{ .interrupted = &console.interrupted, .waiting = &console.waiting };
    if (have_sigint) for ([_]posix.SIG{ .INT, .TERM }) |signal| posix.sigaction(signal, &.{
        .handler = .{ .handler = handleInterrupt },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    // read stdin on its own thread, so the chip runs while it waits for
    // input, unless nothing is on it, as reading it in the background would
    // stop gasim
    const stdin_used = !(board != null and serial == null and o.pty_len > 0) and o.input != .none and !session_input;
    if (o.input == .none or session_input) input.close(io);
    var reading = if (stdin_used) io.concurrent(readRinging, .{ io, &stdin_file_reader.interface, &input, if (o.pty_len > 0) &doorbell else null }) catch |err|
        fatal("cannot read input concurrently: {t}", .{err}) else null;
    errdefer if (reading) |*r| r.cancel(io) catch {};
    ptys.start(io, &doorbell);
    defer ptys.stop(io);
    // a signal ends the run as it would otherwise, through a pipe, as it
    // can only ring the doorbell or end the input from outside the handler
    var watching: ?Io.Future((error{ReadFailed} || Io.Cancelable)!void) = null;
    var pipe_buffer: [1]u8 = undefined;
    var pipe_reader: Io.File.Reader = undefined;
    if (comptime Pty.supported) {
        if (o.pty_len > 0) chip.doorbell = .{ .io = io, .queue = &doorbell };
        var fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) fatal("cannot make a pipe for ctrl+c", .{});
        pipe_reader = .initStreaming(.{ .handle = fds[0], .flags = .{ .nonblocking = false } }, io, &pipe_buffer);
        watching = io.concurrent(endOnInterrupt, .{ &pipe_reader.interface, io, if (o.pty_len > 0) &doorbell else null, &input }) catch |err|
            fatal("cannot read input concurrently: {t}", .{err});
        interrupt_pipe = fds[1];
    }
    defer if (watching) |*w| w.cancel(io) catch {};
    // the links last, after everything that could fail, removed at the end
    // of the run, or by ctrl+c
    for (ptys.ports, 0..) |p, k| if (p.link) |link| {
        makeLink(io, link, ptys.devices[k].path);
        links[links_len] = .{ .link = try arena.dupeSentinel(u8, link, 0), .target = ptys.devices[k].path };
        links_len += 1;
    };
    defer removeLinks();
    stderr_file_writer.interface.flush() catch {};
    const started: Io.Timestamp = .now(io, .awake);
    var stepped: Stepped = .{};
    if (command == .step) {
        stepped = try stepChip(&chip, o, layout);
    } else {
        // stops before the last are gone past
        var hits_left = o.hits;
        while (true) {
            try chip.run();
            if (chip.hit == null or hits_left <= 1) break;
            hits_left -= 1;
        }
    }
    const elapsed = started.durationTo(.now(io, .awake));
    ptys.warnDropped();
    // stops a read blocked waiting for input that will no longer be taken
    if (reading) |*r| r.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        error.ReadFailed => if (stdin_file_reader.err.? != error.Canceled) {
            stderr_file_writer.interface.flush() catch {};
            fatal("stdin: {t}", .{stdin_file_reader.err.?});
        },
    };
    const stop: report.Stop = if (chip.hit) |hit| switch (hit) {
        .breakpoint => .breakpoint,
        .watch => .watch,
        .hazard => .hazard,
    } else if (chip.limited) .limit else if (interruptible.?.interrupted.load(.monotonic)) .interrupted else if (command == .step and !stepped.settled) .step else .settled;
    // after what was traced up to it
    stderr_file_writer.interface.flush() catch {};

    if (o.to) |p| try saving.write(io, arena, p, &chip);

    const ended: Ended = .{ .stop = stop, .stepped = stepped, .elapsed = elapsed };
    if (o.json) try writeEnded(&stdout_file_writer.interface, o, &chip, ended, captured.written()) else logEnded(o, &chip, ended);
    if (chip.wiring.contention) |c| logContention(chip, c);
    logHazards(&chip);
    if (stop == .settled) {
        if (uart_node) |node| {
            if (!uart.used) {
                if (serial) |s| {
                    std.log.warn("port {s} ({f}.{d} in, {f}.{d} out) never carried a byte", .{ s.name, Chip.nodeName(s.rx.ref().node), s.rx.pin, Chip.nodeName(s.tx.ref().node), s.tx.pin });
                } else std.log.warn("node {f} never sent a byte on the UART or woke on its input", .{Chip.nodeName(node)});
            }
        } else if (!console.used) {
            // most likely the console is on a port the program does not use
            std.log.warn("node {f} never used the console on its {t} port", .{ Chip.nodeName(o.console_node), o.console_port });
        }
    }
    return stop.status(interrupt_signal.load(.monotonic));
}

/// Reads input into `input`, as `Console.readInput` does, ringing
/// `doorbell` as it arrives and at its end, for a run waiting for any input
fn readRinging(io: Io, reader: *Io.Reader, input: *Io.Queue(u8), doorbell: ?*Io.Queue(u8)) (error{ReadFailed} || Io.Cancelable)!void {
    const bell = doorbell orelse return Console.readInput(io, reader, input);
    defer input.close(io);
    // a full doorbell has rung already
    defer _ = bell.put(io, &.{0}, 0) catch {};
    while (true) {
        const bytes = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        reader.toss(input.put(io, bytes, 1) catch |err| switch (err) {
            error.Closed => return,
            else => |e| return e,
        });
        _ = bell.put(io, &.{0}, 0) catch |err| switch (err) {
            error.Closed => return,
            else => |e| return e,
        };
    }
}

/// Once a signal writes to the pipe, rings the doorbell, or without one ends
/// the input, for a run waiting for either, and ends gasim if it has not
/// ended in `signal_grace`, as it can be stuck writing where nothing reads
fn endOnInterrupt(pipe: *Io.Reader, io: Io, doorbell: ?*Io.Queue(u8), input: *Io.Queue(u8)) (error{ReadFailed} || Io.Cancelable)!void {
    _ = pipe.takeByte() catch |err| switch (err) {
        error.EndOfStream => return,
        else => |e| return e,
    };
    if (doorbell) |bell| {
        _ = bell.put(io, &.{0}, 0) catch {};
    } else input.close(io);
    try io.sleep(signal_grace, .awake);
    const signal: posix.SIG = @fromBackingInt(@intCast(interrupt_signal.load(.monotonic)));
    posix.sigaction(signal, &.{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
    posix.raise(signal) catch {};
}

/// whether `link` is a symbolic link to `target`, with only calls safe in a
/// signal handler
fn pointsAt(link: [:0]const u8, target: []const u8) bool {
    if (comptime !Pty.supported) return false;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.c.readlink(link, &buffer, buffer.len);
    return len >= 0 and std.mem.eql(u8, buffer[0..@intCast(len)], target);
}

/// removes the links to ptys that still point at them
fn removeLinks() void {
    if (comptime !Pty.supported) return;
    for (links[0..links_len]) |l| if (pointsAt(l.link, l.target)) {
        _ = std.c.unlink(l.link);
    };
    links_len = 0;
}

/// Makes a symbolic link at `link` to a pty's `path`, in place of a link
/// there already to another pty, such as one left from an earlier run, or
/// to nothing. A link to anything else, such as a serial port Wine found,
/// is kept, and refused.
fn makeLink(io: Io, link: []const u8, path: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().readLink(io, link, &buffer)) |len| {
        const old = buffer[0..len];
        const dangling = if (Io.Dir.cwd().access(io, link, .{})) false else |_| true;
        if (!dangling and !Pty.isPtyPath(old))
            fatal("--pty: {s} is a link to {s} already; remove it to link it to the pty", .{ link, old });
        Io.Dir.cwd().deleteFile(io, link) catch |err| fatal("--pty: {s}: {t}", .{ link, err });
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.NotLink => fatal("--pty: {s} is there already, and not a symbolic link", .{link}),
        else => fatal("--pty: {s}: {t}", .{ link, err }),
    }
    Io.Dir.cwd().symLink(io, path, link, .{}) catch |err| fatal("--pty: {s}: {t}", .{ link, err });
}

/// only the terminal user interface and the prompt start without a program,
/// and a run with a UART, which input can boot
fn needsProgram(command: Command, uart: bool) bool {
    return ((command == .run or command == .start) and !uart) or command == .blocks or command == .listing;
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

/// no blocks yet, with room for as many as a file read has
fn newColorForth(arena: Allocator) !ColorForthBlocks {
    const bytes = try arena.alloc(u8, editor_blocks * gasim.colorforth.block_size);
    @memset(bytes, 0);
    return .{ .bytes = bytes, .count = 0, .compressed = false };
}

/// an editor on colorForth blocks, which compiling in the editor reads
fn editColorForth(arena: Allocator, blocks: ColorForthBlocks, path: ?[]const u8) !tui.ColorForth {
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
        var encoded: [colorforth.block_size]u8 = undefined;
        if (colorforth.encode(decoded, &encoded)) {
            if (!std.mem.eql(u8, &encoded, &block)) std.log.warn("{s}: block {d} holds more than its source, which text leaves out", .{ path, n });
        } else |_| std.log.warn("{s}: block {d} holds more than its source, which text leaves out", .{ path, n });
        if (decoded.len == 0 and loads.len == 0) continue;
        try writer.print("{s}block {d}\n", .{ if (separate) "\n" else "", n });
        separate = true;
        try colorforth.writeText(decoded, writer);
    }
    try writer.flush();
}

/// Steps taken, how fast, and the time on the chip, which is as far as any
/// node has got
fn logStats(chip: Chip, elapsed: Io.Duration) void {
    const time = report.chipTime(&chip);
    const seconds = @as(f64, @floatFromInt(elapsed.toNanoseconds())) / 1e9;
    const steps: f64 = @floatFromInt(chip.steps);
    std.log.info("{d} steps in {d:.3} s, {d:.1}M steps/s, and {d:.3} ms of the chip's time", .{
        chip.steps,
        seconds,
        if (seconds > 0) steps / seconds / 1e6 else 0,
        @as(f64, @floatFromInt(time)) / 1e9,
    });
}

/// Says a node's registers
fn logRegisters(n: *const gasim.Computer) void {
    var buffer: [128]u8 = undefined;
    var text: Io.Writer = .fixed(&buffer);
    report.registersText(&text, n) catch unreachable;
    std.log.info("{s}", .{std.mem.trimEnd(u8, text.buffered(), "\n")});
}

/// Says what a node is doing, its registers and its stacks
fn logNode(chip: *const Chip, i: u16) void {
    var buffer: [512]u8 = undefined;
    var text: Io.Writer = .fixed(&buffer);
    report.nodeText(&text, chip, i) catch unreachable;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text.buffered(), "\n"), '\n');
    while (lines.next()) |line| std.log.info("{s}", .{line});
}

/// Warns of what nodes did that a real chip may not do as gasim does, each
/// place once, and says how many times in all if that is more. The one the
/// run stopped at with --strict is said already, as why it stopped.
fn logHazards(chip: *const Chip) void {
    const stopped_at: ?Chip.Hazard = if (chip.hit) |hit| switch (hit) {
        .hazard => |h| h,
        else => null,
    } else null;
    for (chip.hazards.items()) |h| {
        if (stopped_at) |s| if (std.meta.eql(s, h)) continue;
        std.log.warn("{f}", .{h.describe(chip.layout)});
    }
    if (stopped_at == null and chip.hazard_count > chip.hazards.len)
        std.log.warn("{d} times in all, which a real chip may not do as gasim does (--strict stops at the first)", .{chip.hazard_count});
}

/// Warns of pins driven both ways on the same net, naming the nodes on it
fn logContention(chip: Chip, contention: gasim.pins.Contention) void {
    var buffer: [256]u8 = undefined;
    var nodes: Io.Writer = .fixed(&buffer);
    var it = chip.wiring.members(contention.net);
    while (it.next()) |p| nodes.print(" {f}", .{Chip.nodeName(chip.layout.nodeNumber(p.node))}) catch break;
    std.log.warn("pins were driven both ways on the same net, of nodes{s}, first at {d}.{d:0>3} us", .{ nodes.buffered(), contention.time / 1_000_000, contention.time / 1000 % 1000 });
}

/// Logs what each node is waiting on, such as `node 001 waiting to read
/// right`. Nodes waiting on several ports for code, or in ROM, as they do
/// after reset, are counted rather than listed.
fn logWaiting(chip: Chip) void {
    var idle: usize = 0;
    for (0..chip.layout.chips) |k| if (chip.isHeld(@intCast(k))) std.log.info("chip {d} held in reset", .{k});
    for (chip.nodes, 0..) |n, i| {
        const number = chip.layout.nodeNumber(@intCast(i));
        if (chip.isHeld(@intCast(number / Chip.Layout.chip_numbers))) continue;
        const status = n.status();
        switch (status) {
            .running => std.log.info("node {f} running", .{Chip.nodeName(number)}),
            inline .code, .reading, .writing => |address, waiting| {
                if (report.isIdle(&n)) {
                    idle += 1;
                    continue;
                }
                std.log.info("node {f} waiting {s} {s}", .{ Chip.nodeName(number), switch (waiting) {
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
        const where: Where = .{ .path = disk, .line = diagnostic.line, .kind = .blk };
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

/// Stops the console or UART so its output is flushed and the run says how it
/// ended. A signal again later ends gasim at once. Where the pipe to
/// `endOnInterrupt` is, that ends a run waiting for input; without it, there
/// is nothing to flush then, so a signal ends gasim at once.
fn handleInterrupt(signal: posix.SIG) callconv(.c) void {
    const device = interruptible orelse return;
    const again = device.interrupted.swap(true, .monotonic);
    if (!again) interrupt_signal.store(@intCast(@backingInt(signal)), .monotonic);
    if (comptime Pty.supported) {
        if (!again) interrupted_at = milliseconds();
        if (again and milliseconds() - interrupted_at < repeat_ms) return;
        if (!again) if (interrupt_pipe) |fd| {
            _ = std.c.write(fd, "x", 1);
            return;
        };
    }
    if (device.waiting.load(.acquire) or again) {
        // as readlink and unlink are safe to do here, with ptys
        if (comptime Pty.supported)
            for (links[0..links_len]) |l| if (pointsAt(l.link, l.target)) {
                _ = std.c.unlink(l.link);
            };
        posix.sigaction(signal, &.{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
        posix.raise(signal) catch {};
    }
}

/// the time, which is safe to read in a signal handler
fn milliseconds() i64 {
    var time: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &time);
    return @as(i64, time.sec) * 1000 + @divTrunc(@as(i64, time.nsec), 1_000_000);
}

/// where aforth keeps its history: in gasim under XDG_STATE_HOME, or
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
    kind: Kind,

    pub fn format(self: Where, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self.kind) {
            .ga, .af => try writer.print("{s}:{d}", .{ self.path, self.line }),
            .blk => try writer.print("{s}: block {d} line {d}", .{ self.path, (self.line -| 1) / 16, (self.line -| 1) % 16 }),
            .cf => {
                const place = gasim.colorforth.place(self.line);
                try writer.print("{s}: block {d} word {d}", .{ self.path, place.block, place.token });
            },
        }
    }
};

/// Assembles source in gasim's syntax, or in arrayForth 3's for .af files
fn assemble(
    spec: *const gasim.Spec,
    path: []const u8,
    source: []const u8,
    programs: []assembler.Program,
    descriptors: []gasim.boot.Descriptor,
    diagnostic: *assembler.Diagnostic,
) gasim.arrayforth.Error!gasim.arrayforth.Assembled {
    if (Kind.ofPath(path) == .af) return gasim.arrayforth.assembleNodes(source, programs, descriptors, diagnostic);
    return .{ .programs = try assembler.assembleNodesFor(spec, source, programs, diagnostic), .descriptors = &.{} };
}

/// Lays out a source's stream as arrayForth 3's STREAMER does
fn layOut(arena: Allocator, layout: Chip.Layout, assembled: gasim.arrayforth.Assembled, source_path: []const u8) []gasim.Word {
    const root = assembled.stream.?.root;
    var part_buffer: [gasim.arrayforth.Stream.max_parts]gasim.streamer.Part = undefined;
    const parts = assembled.parts(&part_buffer);
    // which the STREAMER leaves out, as a node off its default path may be
    for (parts) |part| if (part == .frame) for (part.frame.descriptors) |d| if (std.mem.indexOfScalar(u16, part.frame.path, d.node) == null)
        std.log.warn("--boot: {s} describes node {f} off its frame's COURSE, which leaves it as it is", .{ source_path, Chip.nodeName(d.node) });
    const buffer = arena.alloc(gasim.Word, gasim.streamer.maxLen(parts)) catch fatal("out of memory", .{});
    return gasim.streamer.stream(layout, parts, assembled.programs, buffer) catch |err| switch (err) {
        error.NoSuchNode, error.NotNeighbours, error.RepeatedNode => fatal("--boot: {s}'s COURSE is not a path of neighbours in {f}, each once ({t})", .{ source_path, layout, err }),
        error.RootTooManyLoads, error.RootNotInPlace => fatal("--boot: node {f} can only be loaded with one part of a bin, to the addresses it comes from ({t})", .{ Chip.nodeName(root), err }),
        error.RootStopsReading => fatal("--boot: a part of {s} before the last leaves node {f} at warm, not reading the next (see ser-exec and spi-exec)", .{ source_path, Chip.nodeName(root) }),
        error.StreamTooLong => fatal("--boot: the boot stream is too long for a node to copy on", .{}),
        error.ForwardNoRoot => fatal("--boot: {s}'s FORWARD follows no frame whose root's frame loads node {f} with x32 words or more, of which it patches x23 and x31", .{ source_path, Chip.nodeName(root) }),
        error.ForwardTooFar => fatal("--boot: {s}'s FORWARD is to past the first 16 KB of flash, which 16 bits of the address reach", .{source_path}),
        // which gasim's arrayForth makes sure of
        error.UnknownRoot, error.PathTooShort, error.NoSuchBin, error.MixedRoots, error.ForwardNotFlash, error.RootPastRam => unreachable,
        // a stream from 207, which --boot refuses
        error.RootNotSetUp, error.RootFrameNoRom => unreachable,
    };
}

/// Reads a board file, or the EVB002's for evb002, exiting with what is
/// wrong with it if anything is. It is checked once its chip is read.
fn readBoard(io: Io, arena: Allocator, gpa: Allocator, path: []const u8, kept: *[]const u8) gasim.Board {
    if (std.mem.eql(u8, path, "evb002")) return .evb002;
    const text = if (kept.len > 0) kept.* else Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| fatal("{s}: {t}", .{ path, err });
    kept.* = text;
    const source = arena.dupeSentinel(u8, text, 0) catch fatal("out of memory", .{});
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return gasim.Board.parse(gpa, arena, source, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
        error.ParseZon => {
            diagnostics.log(path);
            fatal("{s}: does not parse", .{path});
        },
    };
}

/// Reads and checks a chip file, exiting with what is wrong with it if
/// anything is
fn readChip(io: Io, arena: Allocator, gpa: Allocator, path: []const u8, kept: *[]const u8) gasim.Spec {
    const text = if (kept.len > 0) kept.* else Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| fatal("{s}: {t}", .{ path, err });
    kept.* = text;
    const source = arena.dupeSentinel(u8, text, 0) catch fatal("out of memory", .{});
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const spec = gasim.Spec.parse(gpa, arena, source, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
        error.ParseZon => {
            diagnostics.log(path);
            fatal("{s}: does not parse", .{path});
        },
    };
    var bad_node: ?u16 = null;
    spec.check(&bad_node) catch |err| {
        const why = switch (err) {
            error.InvalidSize => "rows and columns must each be from 1 to 100",
            error.NoSuchNode => "is not in the array",
            error.NodeListedTwice => "is listed more than once",
            error.InvalidPin => "has a pin that is not 17, 5, 3 or 1",
            error.PinListedTwice => "lists a pin more than once",
            error.NoSuchResetWord => "resets to a word its ROM does not have",
        };
        if (bad_node) |n| fatal("{s}: node {d:0>3} {s}", .{ path, n, why });
        fatal("{s}: {s}", .{ path, why });
    };
    return spec;
}

const have_sigint = builtin.os.tag != .windows and builtin.os.tag != .wasi;

const fatal = report.fatal;
const usage = report.usage;

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;

const gasim = @import("gasim");
const assembler = gasim.assembler;
const Chip = gasim.Chip;
const Console = gasim.Console;
const Direction = gasim.Direction;
const Kind = gasim.Sim.Kind;
const ga144 = gasim.ga144;
const ioName = gasim.disassembler.ioName;
const aforth = @import("aforth.zig");
const build_options = @import("build_options");
const cli_options = @import("options.zig");
const Command = cli_options.Command;
const Options = cli_options.Options;
const report = @import("report.zig");
const spec_file = @import("spec.zig");
const tui = @import("tui.zig");
const Pty = @import("pty.zig");
const vaxis = @import("vaxis");

test {
    _ = aforth;
    _ = cli_options;
    _ = report;
    _ = spec_file;
    _ = tui;
    _ = Pty;
}

test "the terminal user interface and the prompt start without a program" {
    try expect(!needsProgram(.tui, false));
    try expect(!needsProgram(.aforth, false));
    // but running a program, or listing one, needs one
    try expect(needsProgram(.run, false));
    try expect(needsProgram(.listing, false));
    // except a run with a UART, booted from its input
    try expect(!needsProgram(.run, true));
}
