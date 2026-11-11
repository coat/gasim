//! gasim's commands, the options each takes, and what `help` says of them.
//! A command refuses an option it would not act on, so that nothing given
//! is quietly ignored.

const synopsis =
    \\usage: gasim [options] [program.ga | program.af | program.blk | source.cf]
    \\       gasim tui [options] [program]
    \\       gasim start [options] <program> -o <snapshot>
    \\       gasim run [options] <program> | --from <snapshot> [--to <snapshot>]
    \\       gasim step [options] --from <snapshot> --to <snapshot>
    \\       gasim show [options] <snapshot> [node]...
    \\       gasim aforth [options] [program] [--from <snapshot>] [--to <snapshot>] [-e <line>]...
    \\       gasim listing [options] <program>
    \\       gasim cf text [--load <block>]... <source.cf>
    \\       gasim cf pack <text | -> [--into <source.cf>] [-o <source.cf>]
    \\       gasim cf expand <image.cf> -o <source.cf>
    \\       gasim test [--json] <spec.zon>...
    \\       gasim help [command]
    \\       gasim version
    \\
;

const about =
    \\Opens the chip in a terminal user interface, with the program loaded if
    \\there is one, or when stdin or stdout is not a terminal, runs it. Programs
    \\are .ga source, .af arrayForth 3 source, .blk blocks of it, or a .cf file
    \\of colorForth blocks, such as an arrayForth 2 image. gasim help <command>
    \\says more, and docs/cli.md how the commands work together.
    \\
;

const about_tui =
    \\Opens the chip in a terminal user interface, with the program loaded if
    \\there is one. A .cf file opens in its editor, compiled at the start only
    \\with --load, and is created if it does not exist. Without one, the editor
    \\starts a new file, to name when it is saved.
    \\
;

const about_run =
    \\Runs the program, with the console on stdin and stdout, until every node
    \\is waiting, one reaches a breakpoint or makes a watched transfer, a limit
    \\is reached, or a signal stops it. A .cf file is compiled as arrayForth 2
    \\compiles F18 code, from block 0 or the blocks --load names.
    \\
    \\Exits 0 when every node is waiting, 3 at a breakpoint, 4 at a watch, 5 at
    \\a limit, 7 at a hazard with --strict, 128 and the signal if one stopped
    \\it, 2 for wrong usage and 1 for any other error.
    \\
;

const about_aforth =
    \\Reads lines of arrayForth 3 from stdin, or -e, and interprets them, to
    \\assemble code and act on the chip with the words of arrayForth 3's IDE,
    \\such as 708 NODE UPD, after loading the program if there is one. WORDS
    \\lists the words.
    \\
    \\Except at a terminal's prompt, errors go to stderr, and gasim exits 1 if
    \\a line failed.
    \\
;

const about_listing =
    \\Writes each node's words with their disassembly and source lines.
    \\
;

const about_blocks =
    \\Writes the colorForth source in a file of blocks as text, each block that
    \\holds any, or those --load names. arrayForth 2 images are decompressed,
    \\and the kernel's blocks before block 18 left out.
    \\
;

const about_pack =
    \\Writes colorForth text, as gasim cf text writes it, as a file of blocks,
    \\from a file or from stdin with -. The text says each block with a line
    \\block <n>, or is block 0 without one. Each word is marked with its color
    \\where it changes: : red, [ yellow, ] green, \ cyan, ( white, @ magenta,
    \\^ gray and ~ blue, with a word after a red or magenta one green unless
    \\marked. A word that reads as a number has ' before it, and a number in a
    \\cell of its own that would fit in one has #.
    \\
;

const options_pack =
    \\  --into <source.cf>         keep this file's other blocks, replacing only
    \\                             those the text names. A compressed arrayForth
    \\                             2 image is decompressed. Written back, unless
    \\                             -o says otherwise.
    \\  -o <source.cf>             the file to write
    \\  --json                     write an object saying what was written
    \\
;

const about_expand =
    \\Writes a compressed arrayForth 2 image uncompressed, as the editor saves it.
    \\
;

const options_expand =
    \\  -o <source.cf>             the file to write
    \\  --json                     write an object saying what was written
    \\
;

const options_chip =
    \\  --chip <file>              the chip, described in a chip file, such as
    \\                             src/chips/ga144.zon (default the GA144)
    \\  --layout <rows>x<columns>  a chip of that size, of basic nodes with no
    \\                             pins, instead of the GA144
    \\  --rom <path>               ROM to load into the nodes: a dump of it, or
    \\                             arrayForth 3's disk (sF/pFDISK.blk) or the
    \\                             directory it is installed in, such as
    \\                             GreenArrays, to assemble it from. Without
    \\                             it, the ROM last assembled, or assembled
    \\                             from arrayForth 3 installed in C:\GreenArrays
    \\                             or Wine's C: drive, if it is.
    \\  --board <file>             the board around the chips, described in a
    \\                             board file, such as src/boards/evb002.zon,
    \\                             or evb002 for that. With run, stdin and
    \\                             stdout are on a serial port. Nodes of chips
    \\                             after the first are numbered with the chip,
    \\                             such as 1.708.
    \\  --jumper <name>=on|off     set one of the board's jumpers otherwise
    \\                             than as shipped, such as J26=off. Can be
    \\                             given more than once.
    \\
;

const options_console =
    \\  --console <node>:<port>    where the console is attached (default 000:up)
    \\
;

const options_load =
    \\  --load <block>             with a .blk or .cf file, the block to load
    \\                             (default 0). Can be given more than once, to
    \\                             load blocks such as configuration first.
    \\
;

const options_boot =
    \\  --boot                     load programs with a boot stream through the
    \\                             SERDES port of node 001, or with --uart,
    \\                             through the UART to the node's ROM, before
    \\                             stdin. This needs ROM. An arrayForth 3
    \\                             source's STREAM[ ... ]STREAM is laid out
    \\                             as arrayForth 3's STREAMER does: from 708,
    \\                             with --uart, from 705, packed into the
    \\                             --board's SPI flash, such as with --board
    \\                             evb002 --jumper J26=off, or from 300, with
    \\                             run and no --board, clocked into its pins 17
    \\                             and 1 as a synchronous line's master does.
    \\                             A stream from 207 is pF/144's to send.
    \\
;

const options_stops =
    \\  --break <node>:<address>   stop when the node is about to fetch the word
    \\                             at the address, in hex, such as 105:003. Can
    \\                             be given more than once.
    \\  --watch <node>:<port>[:read|:write]
    \\                             stop when the node reads from or writes to the
    \\                             port, such as 105:right:write. Can be given
    \\                             more than once.
    \\  --strict                   stop when a node does what a real chip may not
    \\                             do as gasim does, such as + straight after
    \\                             an opcode that changed S or T, rather than
    \\                             only warn of it
    \\
;

const options_serial =
    \\  --usb <port>               the board's serial port on stdin and stdout
    \\                             (default its first not on a pty, such as A)
    \\  --flash <file>             the contents of the board's SPI flash, up to
    \\                             16 MB, erased past the end. The EVB002's host
    \\                             705 boots from it with --jumper J26=off (NO
    \\                             BOOT), and the ROM.
    \\  --uart <node>[:<baud>]     put stdin and stdout on a UART on the node's
    \\                             pins 17 and 1 instead of the console, as USB
    \\                             serial ports are wired to node 708 on
    \\                             GreenArrays' evaluation boards, with both
    \\                             lines inverted (default 921600 baud). Bytes
    \\                             from a host such as ga-tools boot node 708
    \\                             from ROM.
    \\
;

const options_pty =
    \\  --pty <port>[=<link>]      put one of the board's serial ports on a
    \\                             pseudo-terminal, such as for arrayForth 3
    \\                             under Wine, saying its path, and making a
    \\                             symbolic link to it at <link> if given,
    \\                             such as ~/.wine/dosdevices/com3. Can be
    \\                             given more than once. stdin and stdout
    \\                             are then on --usb's port, or none, and
    \\                             the run goes on until ctrl+c.
    \\
;

const options_hits =
    \\  --hits <n>                 stop at the nth stop, going on past the ones
    \\                             before it (default 1)
    \\
;

const options_limits =
    \\  --max-steps <n>            stop once the nodes have taken this many more
    \\                             steps, checked after each round of steps
    \\  --max-time <ps>            stop once every node that is running has
    \\                             reached this time on the chip, in picoseconds
    \\
;

const options_output =
    \\  --input <file|-|none>      what the console or UART reads: a file, stdin
    \\                             (-, the default), or nothing, which ends the
    \\                             run once nodes wait for input however stdin
    \\                             is left open
    \\  --json                     write an object saying how the run ended to
    \\                             stdout, with what nodes wrote to the console
    \\                             or UART as its output, each byte a character,
    \\                             rather than the output itself
    \\  --show <nodes>             when it stops, say the registers and stacks
    \\                             of these nodes, such as 105,708, or all
    \\  --why                      say what each node is waiting on when it stops
    \\  --stats                    say how many steps the nodes took (each word
    \\                             run, 4096 passes of a longer unext loop, or
    \\                             a word tried while waiting on a port), how
    \\                             fast, and how long that is on the chip
    \\  --trace                    write a line to stderr for each word a node
    \\                             executes, with --json, an object
    \\  --trace-node <node>        trace only this node
    \\  --trace-file <file>        write the trace to this file
    \\
;

const options_aforth =
    \\  -e <line>                  a line to interpret, instead of reading stdin.
    \\                             Can be given more than once.
    \\  --json                     write an object to stdout at the end, with
    \\                             what the lines and the console wrote and any
    \\                             errors, rather than writing them as they come
    \\
;

const options_blocks =
    \\  --load <block>             a block to write. Can be given more than once.
    \\
;

const about_start =
    \\Loads the program onto the chip and writes a snapshot of it, with no steps
    \\taken, for run, step and aforth to go on from. A snapshot holds the chip
    \\or board and how it was set up, so those options are given here, and not
    \\with --from.
    \\
;

const options_snapshot =
    \\  --from <snapshot>          go on from a snapshot, instead of a program
    \\  --to <snapshot>            write a snapshot of the chip when it stops.
    \\                             With either, --input is none unless it is
    \\                             given, and is read to its end first, and what
    \\                             a node has not read stays in the snapshot.
    \\
;

const about_step =
    \\Steps the chip from one snapshot to another: the next node to run, or as
    \\the options say, until a breakpoint or watch.
    \\
;

const options_step =
    \\  --node <node>              step this node
    \\  --count <n>                take this many steps (default 1)
    \\  --rounds <n>               take this many rounds of steps instead, the
    \\                             furthest behind first
    \\  --slot                     step one opcode of the node, or fetch its next
    \\                             word, instead of the rest of its word
    \\
;

const about_show =
    \\Says what is in a snapshot: for each node, what it is doing and its P, or
    \\with nodes, their registers and stacks.
    \\
;

const options_show =
    \\  --mem                      the words in the nodes' RAM, with disassembly
    \\  --rom-words                their ROM
    \\  --at <address>             words from this address, in hex
    \\  --count <n>                this many words (default 64)
    \\  --ports                    what the ports between nodes are doing
    \\  --json                     write an object
    \\
;

const about_test =
    \\Runs the cases in spec files and says which do as they should, exiting 6
    \\if any do not. A spec is a ZON list of cases, each with a .program, relative
    \\to the spec, and any of .name, .args for run, .input, .max_steps, .stop
    \\(such as .breakpoint), .output, and .nodes, each with a .node, as a string,
    \\and registers .p .a .b .io .t .s .r, and .ram, of .address and .word, that
    \\it should leave. examples/test.zon is one.
    \\
;

const about_help =
    \\Says what a command does and the options it takes.
    \\
;

const about_version =
    \\Says which gasim this is.
    \\
;

/// what `help` says of a command, or without one of gasim
pub fn helpText(topic: ?Command) []const u8 {
    const command = topic orelse return synopsis ++ "\n" ++ about ++ "\noptions:\n" ++ options_chip ++ options_console ++ options_load ++ options_boot ++ options_stops;
    return switch (command) {
        .tui => "usage: gasim tui [options] [program]\n\n" ++ about_tui ++ "\noptions:\n  --from <snapshot>          open the chip as a snapshot left it\n" ++ options_chip ++ options_console ++ options_load ++ options_boot ++ options_stops,
        .run => "usage: gasim run [options] <program> | --from <snapshot> [--to <snapshot>]\n\n" ++ about_run ++ "\noptions:\n" ++ options_snapshot ++ options_chip ++ options_console ++ options_load ++ options_boot ++ options_serial ++ options_pty ++ options_stops ++ options_hits ++ options_limits ++ options_output,
        .aforth => "usage: gasim aforth [options] [program] [--from <snapshot>] [--to <snapshot>] [-e <line>]...\n\n" ++ about_aforth ++ "\noptions:\n" ++ options_aforth ++ options_snapshot ++ options_chip ++ options_console ++ options_load ++ options_boot,
        .start => "usage: gasim start [options] <program> -o <snapshot>\n\n" ++ about_start ++ "\noptions:\n  -o <snapshot>              the snapshot to write\n  --json                     write an object saying what was written\n" ++ options_chip ++ options_console ++ options_load ++ options_boot ++ options_serial,
        .step => "usage: gasim step [options] --from <snapshot> --to <snapshot>\n\n" ++ about_step ++ "\noptions:\n" ++ options_step ++ options_snapshot ++ options_stops ++ options_hits ++ options_output,
        .show => "usage: gasim show [options] <snapshot> [node]...\n\n" ++ about_show ++ "\noptions:\n" ++ options_show,
        .listing => "usage: gasim listing [options] <program>\n\n" ++ about_listing ++ "\noptions:\n" ++ options_chip ++ options_load,
        .blocks => "usage: gasim cf text [--load <block>]... <source.cf>\n\n" ++ about_blocks ++ "\noptions:\n" ++ options_blocks,
        .cf_pack => "usage: gasim cf pack <text | -> [--into <source.cf>] [-o <source.cf>]\n\n" ++ about_pack ++ "\noptions:\n" ++ options_pack,
        .cf_expand => "usage: gasim cf expand <image.cf> -o <source.cf>\n\n" ++ about_expand ++ "\noptions:\n" ++ options_expand,
        .@"test" => "usage: gasim test [--json] <spec.zon>...\n\n" ++ about_test,
        .help => "usage: gasim help [command]\n\n" ++ about_help,
        .version => "usage: gasim version\n\n" ++ about_version,
    };
}

pub const Command = enum {
    run,
    tui,
    aforth,
    listing,
    start,
    step,
    show,
    /// also `cf text`
    blocks,
    cf_pack,
    cf_expand,
    @"test",
    help,
    version,

    /// as it is typed
    pub fn name(self: Command) []const u8 {
        return switch (self) {
            .cf_pack => "cf pack",
            .cf_expand => "cf expand",
            else => @tagName(self),
        };
    }
};

const Commands = std.EnumSet(Command);

/// the commands that load a program onto a chip
const on_chip: Commands = .initMany(&.{ .run, .tui, .aforth, .listing, .start });
/// the commands that set a chip going, to load programs for
const going: Commands = .initMany(&.{ .run, .tui, .aforth, .start });
/// the commands that run a program for it to be stopped
const stopping: Commands = .initMany(&.{ .run, .tui, .step });
/// the commands that have stdin and stdout on a board's serial port
const serial: Commands = .initMany(&.{ .run, .start });
const running: Commands = .initMany(&.{ .run, .step });

const Flag = struct {
    name: []const u8,
    /// that the next argument is its value
    value: bool = true,
    commands: Commands,
    /// that it says what the machine is, which a snapshot holds
    machine: bool = false,
};

const flags = [_]Flag{
    .{ .name = "--board", .commands = on_chip, .machine = true },
    .{ .name = "--jumper", .commands = on_chip, .machine = true },
    .{ .name = "--chip", .commands = on_chip, .machine = true },
    .{ .name = "--layout", .commands = on_chip, .machine = true },
    .{ .name = "--console", .commands = going, .machine = true },
    .{ .name = "--rom", .commands = on_chip, .machine = true },
    .{ .name = "--boot", .value = false, .commands = going, .machine = true },
    .{ .name = "--load", .commands = .initMany(&.{ .run, .tui, .aforth, .listing, .blocks, .start }) },
    .{ .name = "--usb", .commands = serial, .machine = true },
    .{ .name = "--pty", .commands = .initOne(.run), .machine = true },
    .{ .name = "--flash", .commands = serial, .machine = true },
    .{ .name = "--uart", .commands = serial, .machine = true },
    .{ .name = "--from", .commands = .initMany(&.{ .run, .tui, .aforth, .step }) },
    .{ .name = "--to", .commands = .initMany(&.{ .run, .aforth, .step }) },
    .{ .name = "--node", .commands = .initOne(.step) },
    .{ .name = "--rounds", .commands = .initOne(.step) },
    .{ .name = "--slot", .value = false, .commands = .initOne(.step) },
    .{ .name = "--count", .commands = .initMany(&.{ .step, .show }) },
    .{ .name = "--mem", .value = false, .commands = .initOne(.show) },
    .{ .name = "--rom-words", .value = false, .commands = .initOne(.show) },
    .{ .name = "--at", .commands = .initOne(.show) },
    .{ .name = "--ports", .value = false, .commands = .initOne(.show) },
    .{ .name = "--break", .commands = stopping },
    .{ .name = "--watch", .commands = stopping },
    .{ .name = "--hits", .commands = running },
    .{ .name = "--max-steps", .commands = .initOne(.run) },
    .{ .name = "--max-time", .commands = .initOne(.run) },
    .{ .name = "--input", .commands = running },
    .{ .name = "--json", .value = false, .commands = .initMany(&.{ .run, .aforth, .start, .step, .show, .cf_pack, .cf_expand, .@"test" }) },
    .{ .name = "--show", .commands = running },
    .{ .name = "--why", .value = false, .commands = running },
    .{ .name = "--strict", .value = false, .commands = stopping },
    .{ .name = "--stats", .value = false, .commands = running },
    .{ .name = "--trace", .value = false, .commands = running },
    .{ .name = "--trace-node", .commands = running },
    .{ .name = "--trace-file", .commands = running },
    .{ .name = "-e", .commands = .initOne(.aforth) },
    .{ .name = "-o", .commands = .initMany(&.{ .start, .cf_pack, .cf_expand }) },
    .{ .name = "--into", .commands = .initOne(.cf_pack) },
};

pub const Input = union(enum) { stdin, none, file: []const u8 };

pub const Show = union(enum) { none, all, nodes: []const u16 };

pub const max_lines = 64;

pub const Options = struct {
    command: Command = .run,
    /// the command `help` is asked about
    topic: ?Command = null,
    path: ?[]const u8 = null,
    /// the file a command writes
    output: ?[]const u8 = null,
    /// the file of blocks that `cf pack` changes
    into: ?[]const u8 = null,
    /// the snapshot to go on from, and the one to write
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    /// the board's and the chip's files, as a snapshot holds them
    board_text: ?[]const u8 = null,
    chip_text: ?[]const u8 = null,
    /// what `step` steps: a node, and how many steps or rounds
    step_node: ?u16 = null,
    count: ?u32 = null,
    rounds: ?u32 = null,
    /// step one slot at a time
    slot: bool = false,
    /// what `show` shows: nodes, their memory, and ports
    nodes: []const u16 = &.{},
    /// the specs `test` runs
    specs: []const []const u8 = &.{},
    mem: bool = false,
    rom_words: bool = false,
    at: ?u9 = null,
    ports: bool = false,
    chip_path: ?[]const u8 = null,
    board_path: ?[]const u8 = null,
    usb: ?[]const u8 = null,
    pty_ports: [Chip.max_uarts]Pty = undefined,
    pty_len: usize = 0,
    settings: [32]gasim.Board.Setting = undefined,
    settings_len: usize = 0,
    flash_path: ?[]const u8 = null,
    layout: ?Chip.Layout = null,
    console_node: u16 = 0,
    console_port: Direction = .up,
    console_given: bool = false,
    uart_node: ?u16 = null,
    uart_baud: u32 = 921600,
    rom_path: ?[]const u8 = null,
    boot: bool = false,
    trace: bool = false,
    trace_node: ?u16 = null,
    trace_file: ?[]const u8 = null,
    why: bool = false,
    strict: bool = false,
    stats: bool = false,
    json: bool = false,
    show: Show = .none,
    hits: u32 = 1,
    max_steps: ?u64 = null,
    max_time: ?u64 = null,
    input: Input = .stdin,
    loads: [16]u32 = undefined,
    loads_len: usize = 0,
    breakpoints: [Chip.max_breakpoints]Breakpoint = undefined,
    breakpoints_len: usize = 0,
    watches: [Chip.max_watches]Watch = undefined,
    watches_len: usize = 0,
    lines: [max_lines][]const u8 = undefined,
    lines_len: usize = 0,

    pub const Pty = struct { name: []const u8, link: ?[]const u8 };
    pub const Breakpoint = struct { node: u16, address: u9 };
    pub const Watch = struct { node: u16, direction: Direction, read: bool, write: bool };
};

/// The command the arguments name, and where its options start. Without one,
/// the terminal user interface, unless stdin or stdout is not a terminal: a
/// pipe or file wants plain output rather than a user interface
fn commandOf(args: []const []const u8, terminal: bool) struct { Command, usize } {
    if (args.len > 1 and std.mem.eql(u8, args[1], "cf")) {
        if (args.len == 2) report.usage("cf needs text, pack or expand", .{});
        const is = std.mem.eql;
        return .{ if (is(u8, args[2], "text")) .blocks else if (is(u8, args[2], "pack")) .cf_pack else if (is(u8, args[2], "expand")) .cf_expand else report.usage("cf needs text, pack or expand, not {s}", .{args[2]}), 3 };
    }
    if (args.len > 1) if (topicOf(args[1])) |command| return .{ command, 2 };
    return .{ if (terminal) .tui else .run, 1 };
}

/// the command a word names on its own
fn topicOf(word: []const u8) ?Command {
    if (std.mem.eql(u8, word, "cf_pack") or std.mem.eql(u8, word, "cf_expand")) return null;
    return std.meta.stringToEnum(Command, word);
}

fn wantsHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub const BreakError = error{ ExpectedColon, InvalidNode, InvalidAddress };
pub const WatchError = error{ ExpectedPort, TooManyParts, InvalidKind, InvalidNode, InvalidPort };

/// Reads a breakpoint such as `105:003`
pub fn parseBreak(value: []const u8) BreakError!Options.Breakpoint {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.ExpectedColon;
    return .{
        .node = Chip.parseNode(value[0..colon]) catch return error.InvalidNode,
        .address = std.fmt.parseInt(u9, value[colon + 1 ..], 16) catch return error.InvalidAddress,
    };
}

/// Reads a watch such as `105:right` or `105:right:write`
pub fn parseWatch(value: []const u8) WatchError!Options.Watch {
    var parts = std.mem.splitScalar(u8, value, ':');
    const node = parts.first();
    const direction = parts.next() orelse return error.ExpectedPort;
    const kind = parts.next();
    if (parts.next() != null) return error.TooManyParts;
    if (kind) |k| if (!std.mem.eql(u8, k, "read") and !std.mem.eql(u8, k, "write")) return error.InvalidKind;
    return .{
        .node = Chip.parseNode(node) catch return error.InvalidNode,
        .direction = std.meta.stringToEnum(Direction, direction) orelse return error.InvalidPort,
        .read = kind == null or std.mem.eql(u8, kind.?, "read"),
        .write = kind == null or std.mem.eql(u8, kind.?, "write"),
    };
}

/// what is wrong with a breakpoint, for an error
pub fn breakErrorText(err: BreakError) []const u8 {
    return switch (err) {
        error.ExpectedColon => "expected for example 105:003",
        error.InvalidNode => "no such node",
        error.InvalidAddress => "expected an address from 000 to 1ff",
    };
}

/// what is wrong with a watch, for an error
pub fn watchErrorText(err: WatchError) []const u8 {
    return switch (err) {
        error.ExpectedPort, error.TooManyParts => "expected for example 105:right or 105:right:write",
        error.InvalidKind => "expected read or write after the port",
        error.InvalidNode => "no such node",
        error.InvalidPort => "expected right, down, left or up",
    };
}

/// Reads the arguments, ending gasim with what is wrong with them if
/// anything is
pub fn parse(arena: Allocator, args: []const []const u8, terminal: bool) Options {
    var o: Options = .{};
    o.command, var i = commandOf(args, terminal);
    const named = i >= 2;
    // which listing replaces, for any command
    for (args[i..]) |arg| if (std.mem.eql(u8, arg, "--listing")) {
        o.command = .listing;
    };
    for (args[i..]) |arg| if (wantsHelp(arg)) {
        o.topic = if (named) o.command else null;
        o.command = .help;
        return o;
    };
    if (o.command == .help) {
        if (args.len == 4 and std.mem.eql(u8, args[2], "cf")) {
            o.topic = commandOf(args[1..], false)[0];
            return o;
        }
        if (args.len > 3) report.usage("help takes one command", .{});
        if (args.len == 3) o.topic = topicOf(args[2]) orelse
            report.usage("no command {s}", .{args[2]});
        return o;
    }
    if (o.command == .version) {
        if (args.len > 2) report.usage("version takes no options", .{});
        return o;
    }

    var nodes: std.ArrayList(u16) = .empty;
    var specs: std.ArrayList([]const u8) = .empty;
    var machine_flag: ?[]const u8 = null;
    var input_given = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--listing")) continue;
        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-") and o.command == .cf_pack) {
            if (o.command == .@"test") {
                specs.append(arena, arg) catch report.fatal("out of memory", .{});
                continue;
            }
            if (o.command == .show) {
                if (o.from == null) {
                    o.from = arg;
                } else nodes.append(arena, Chip.parseNode(arg) catch report.usage("invalid node '{s}'", .{arg})) catch report.fatal("out of memory", .{});
                continue;
            }
            if (o.path != null) report.usage("more than one program, '{s}' and '{s}'", .{ o.path.?, arg });
            o.path = arg;
            continue;
        }
        const flag = for (&flags) |*f| {
            if (std.mem.eql(u8, f.name, arg)) break f;
        } else report.usage("no option {s}: gasim help says what there is", .{arg});
        if (!flag.commands.contains(o.command)) report.usage("{s} does not go with {s}: gasim help {s} says what does", .{ arg, o.command.name(), o.command.name() });
        if (flag.machine) machine_flag = arg;
        if (std.mem.eql(u8, arg, "--input")) input_given = true;
        if (!flag.value) {
            setSwitch(&o, arg);
            continue;
        }
        i += 1;
        if (i == args.len) report.usage("{s} needs a value", .{arg});
        setValue(arena, &o, arg, args[i]);
    }
    o.nodes = nodes.items;
    o.specs = specs.items;
    if (o.command == .@"test" and o.specs.len == 0) report.usage("test needs a spec", .{});
    if (o.trace_node != null or o.trace_file != null) o.trace = true;
    if (o.command == .start) {
        o.to = o.output orelse report.usage("start needs -o, to say what to write", .{});
        if (o.path == null and o.uart_node == null and o.board_path == null) report.usage("start needs a program", .{});
    }
    if (o.command == .step and (o.from == null or o.to == null)) report.usage("step needs --from and --to", .{});
    if (o.command == .step and o.count != null and o.rounds != null) report.usage("step takes --count or --rounds", .{});
    if (o.command == .step and o.step_node != null and o.rounds != null) report.usage("--rounds step every node, so --node cannot", .{});
    if (o.command == .step and o.slot and o.step_node == null) report.usage("--slot steps one node, so it needs --node", .{});
    if (o.command == .show and o.from == null) report.usage("show needs a snapshot", .{});
    if (o.rom_words and o.at != null and o.at.? & 0x80 == 0) report.usage("--at {x:0>3} is in RAM, so --rom-words cannot", .{o.at.?});
    if ((o.command == .show) and (o.rom_words or o.at != null or o.count != null) and !o.mem) o.mem = true;
    if (o.from != null) {
        if (machine_flag) |flag| report.usage("{s}: the snapshot says what the machine is", .{flag});
        if (o.path != null and o.command != .aforth) report.usage("{s} takes a program or --from, not both", .{o.command.name()});
    }
    if (o.to != null and o.pty_len > 0) report.usage("--to cannot save what is on the other end of a pty", .{});
    // nothing waits on a terminal, and a session's input goes in order
    if ((o.from != null or o.to != null) and !input_given) o.input = .none;
    if (o.command == .cf_pack and o.output == null and o.into == null) report.usage("cf pack needs -o or --into, to say what to write", .{});
    if (o.command == .cf_expand and o.output == null) report.usage("cf expand needs -o, to say what to write", .{});
    if (o.hits > 1 and o.breakpoints_len == 0 and o.watches_len == 0) report.usage("--hits needs --break or --watch", .{});
    return o;
}

fn setSwitch(o: *Options, arg: []const u8) void {
    const is = std.mem.eql;
    if (is(u8, arg, "--boot")) {
        o.boot = true;
    } else if (is(u8, arg, "--trace")) {
        o.trace = true;
    } else if (is(u8, arg, "--why")) {
        o.why = true;
    } else if (is(u8, arg, "--strict")) {
        o.strict = true;
    } else if (is(u8, arg, "--slot")) {
        o.slot = true;
    } else if (is(u8, arg, "--stats")) {
        o.stats = true;
    } else if (is(u8, arg, "--json")) {
        o.json = true;
    } else if (is(u8, arg, "--mem")) {
        o.mem = true;
    } else if (is(u8, arg, "--rom-words")) {
        o.rom_words = true;
    } else if (is(u8, arg, "--ports")) {
        o.ports = true;
    } else unreachable;
}

fn setValue(arena: Allocator, o: *Options, arg: []const u8, value: []const u8) void {
    const is = std.mem.eql;
    const usage = report.usage;
    if (is(u8, arg, "--rom")) {
        o.rom_path = value;
    } else if (is(u8, arg, "--load")) {
        if (o.loads_len == o.loads.len) usage("more than {d} blocks to load", .{o.loads.len});
        o.loads[o.loads_len] = std.fmt.parseInt(u32, value, 10) catch usage("invalid block '{s}'", .{value});
        o.loads_len += 1;
    } else if (is(u8, arg, "--break")) {
        if (o.breakpoints_len == o.breakpoints.len) usage("more than {d} breakpoints", .{o.breakpoints.len});
        o.breakpoints[o.breakpoints_len] = parseBreak(value) catch |err|
            usage("invalid breakpoint '{s}': {s}", .{ value, breakErrorText(err) });
        o.breakpoints_len += 1;
    } else if (is(u8, arg, "--watch")) {
        if (o.watches_len == o.watches.len) usage("more than {d} watches", .{o.watches.len});
        o.watches[o.watches_len] = parseWatch(value) catch |err|
            usage("invalid watch '{s}': {s}", .{ value, watchErrorText(err) });
        o.watches_len += 1;
    } else if (is(u8, arg, "--uart")) {
        var parts = std.mem.splitScalar(u8, value, ':');
        const node = parts.first();
        o.uart_node = Chip.parseNode(node) catch usage("invalid UART node '{s}'", .{node});
        if (parts.next()) |baud| {
            o.uart_baud = std.fmt.parseInt(u32, baud, 10) catch usage("invalid baud '{s}'", .{baud});
            if (o.uart_baud == 0) usage("invalid baud '{s}'", .{baud});
        }
        if (parts.next() != null) usage("invalid UART '{s}', expected for example 708 or 708:460800", .{value});
    } else if (is(u8, arg, "--chip")) {
        o.chip_path = value;
    } else if (is(u8, arg, "--board")) {
        o.board_path = value;
    } else if (is(u8, arg, "--usb")) {
        o.usb = value;
    } else if (is(u8, arg, "--pty")) {
        if (!PtyDevice.supported) usage("--pty needs pseudo-terminals, which this system does not have", .{});
        if (o.pty_len == o.pty_ports.len) usage("more than {d} --pty ports", .{o.pty_ports.len});
        const equals = std.mem.indexOfScalar(u8, value, '=');
        o.pty_ports[o.pty_len] = .{ .name = value[0 .. equals orelse value.len], .link = if (equals) |e| value[e + 1 ..] else null };
        o.pty_len += 1;
    } else if (is(u8, arg, "--jumper")) {
        const equals = std.mem.indexOfScalar(u8, value, '=') orelse
            usage("invalid jumper '{s}', expected for example J26=off", .{value});
        const state = value[equals + 1 ..];
        const on = if (is(u8, state, "on")) true else if (is(u8, state, "off")) false else usage("invalid jumper '{s}', expected on or off after =", .{value});
        if (o.settings_len == o.settings.len) usage("too many --jumper settings, at most {d}", .{o.settings.len});
        o.settings[o.settings_len] = .{ .name = value[0..equals], .on = on };
        o.settings_len += 1;
    } else if (is(u8, arg, "--flash")) {
        o.flash_path = value;
    } else if (is(u8, arg, "--layout")) {
        o.layout = Chip.Layout.parse(value) catch usage("invalid layout '{s}', expected for example 8x18", .{value});
    } else if (is(u8, arg, "--console")) {
        o.console_given = true;
        const colon = std.mem.indexOfScalar(u8, value, ':') orelse
            usage("invalid console '{s}', expected for example 000:up", .{value});
        o.console_node = Chip.parseNode(value[0..colon]) catch
            usage("invalid console node '{s}'", .{value[0..colon]});
        o.console_port = std.meta.stringToEnum(Direction, value[colon + 1 ..]) orelse
            usage("invalid console port '{s}', expected right, down, left or up", .{value[colon + 1 ..]});
    } else if (is(u8, arg, "--hits")) {
        o.hits = std.fmt.parseInt(u32, value, 10) catch usage("invalid --hits '{s}'", .{value});
        if (o.hits == 0) usage("invalid --hits '{s}', the first stop is 1", .{value});
    } else if (is(u8, arg, "--max-steps")) {
        o.max_steps = std.fmt.parseInt(u64, value, 10) catch usage("invalid --max-steps '{s}'", .{value});
    } else if (is(u8, arg, "--max-time")) {
        o.max_time = std.fmt.parseInt(u64, value, 10) catch usage("invalid --max-time '{s}'", .{value});
    } else if (is(u8, arg, "--input")) {
        o.input = if (is(u8, value, "-")) .stdin else if (is(u8, value, "none")) .none else .{ .file = value };
    } else if (is(u8, arg, "--show")) {
        o.show = parseShow(arena, value);
    } else if (is(u8, arg, "--trace-node")) {
        o.trace_node = Chip.parseNode(value) catch usage("invalid --trace-node '{s}'", .{value});
    } else if (is(u8, arg, "--trace-file")) {
        o.trace_file = value;
    } else if (is(u8, arg, "--from")) {
        o.from = value;
    } else if (is(u8, arg, "--to")) {
        o.to = value;
    } else if (is(u8, arg, "--node")) {
        o.step_node = Chip.parseNode(value) catch usage("invalid --node '{s}'", .{value});
    } else if (is(u8, arg, "--count")) {
        o.count = std.fmt.parseInt(u32, value, 10) catch usage("invalid --count '{s}'", .{value});
    } else if (is(u8, arg, "--rounds")) {
        o.rounds = std.fmt.parseInt(u32, value, 10) catch usage("invalid --rounds '{s}'", .{value});
    } else if (is(u8, arg, "--at")) {
        o.at = std.fmt.parseInt(u9, value, 16) catch usage("invalid --at '{s}', expected 000 to 1ff", .{value});
    } else if (is(u8, arg, "-o")) {
        o.output = value;
    } else if (is(u8, arg, "--into")) {
        o.into = value;
    } else if (is(u8, arg, "-e")) {
        if (o.lines_len == o.lines.len) usage("more than {d} lines of -e", .{o.lines.len});
        o.lines[o.lines_len] = value;
        o.lines_len += 1;
    } else unreachable;
}

fn parseShow(arena: Allocator, value: []const u8) Show {
    if (std.mem.eql(u8, value, "all")) return .all;
    const nodes = arena.alloc(u16, std.mem.countScalar(u8, value, ',') + 1) catch report.fatal("out of memory", .{});
    var parts = std.mem.splitScalar(u8, value, ',');
    for (nodes) |*node| {
        const part = parts.next().?;
        node.* = Chip.parseNode(part) catch report.usage("invalid node '{s}' in --show", .{part});
    }
    return .{ .nodes = nodes };
}

test "the terminal user interface starts without a command, on a terminal" {
    try expectEqual(.tui, commandOf(&.{"gasim"}, true)[0]);
    try expectEqual(.run, commandOf(&.{"gasim"}, false)[0]);
    try expectEqual(.aforth, commandOf(&.{ "gasim", "aforth" }, true)[0]);
    try expectEqual(.aforth, commandOf(&.{ "gasim", "aforth" }, false)[0]);
    try expectEqual(.run, commandOf(&.{ "gasim", "run" }, true)[0]);
    try expectEqual(.tui, commandOf(&.{ "gasim", "tui" }, false)[0]);
    // and a file is not a command
    try expectEqual(.{ Command.tui, 1 }, commandOf(&.{ "gasim", "hello.ga" }, true));
}

test "help is for the command it follows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const asked = parse(a, &.{ "gasim", "run", "--help" }, false);
    try expectEqual(.help, asked.command);
    try expectEqual(.run, asked.topic.?);
    try expectEqual(null, parse(a, &.{ "gasim", "--help" }, false).topic);
    try expectEqual(.aforth, parse(a, &.{ "gasim", "help", "aforth" }, false).topic.?);
}

test "options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = parse(a, &.{ "gasim", "run", "--max-steps", "5", "--show", "105,1.708", "--input", "none", "--trace-node", "3", "x.ga" }, false);
    try expectEqual(5, o.max_steps.?);
    try expectEqual(.none, std.meta.activeTag(o.input));
    try expectEqual(2, o.show.nodes.len);
    try expectEqual(105, o.show.nodes[0]);
    // which says to trace
    try expect(o.trace);
    try expectEqual(.listing, parse(a, &.{ "gasim", "--listing", "x.ga" }, true).command);
}

test "colorForth's commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEqual(.blocks, parse(a, &.{ "gasim", "cf", "text", "x.cf" }, false).command);
    const pack = parse(a, &.{ "gasim", "cf", "pack", "-", "--into", "x.cf" }, false);
    try expectEqual(.cf_pack, pack.command);
    try std.testing.expectEqualStrings("-", pack.path.?);
    try expectEqual(.cf_pack, parse(a, &.{ "gasim", "help", "cf", "pack" }, false).topic.?);
    try expectEqual(.cf_expand, parse(a, &.{ "gasim", "cf", "expand", "--help" }, false).topic.?);
}

test "breakpoints and watches" {
    const breakpoint = try parseBreak("105:01f");
    try expectEqual(105, breakpoint.node);
    try expectEqual(0x1f, breakpoint.address);
    try std.testing.expectError(error.ExpectedColon, parseBreak("105"));
    try std.testing.expectError(error.InvalidNode, parseBreak("x:003"));
    try std.testing.expectError(error.InvalidAddress, parseBreak("105:zz"));

    const watch = try parseWatch("105:right:write");
    try expectEqual(.right, watch.direction);
    try expect(watch.write and !watch.read);
    const both = try parseWatch("105:up");
    try expect(both.write and both.read);
    try std.testing.expectError(error.ExpectedPort, parseWatch("105"));
    try std.testing.expectError(error.InvalidKind, parseWatch("105:up:both"));
    try std.testing.expectError(error.InvalidPort, parseWatch("105:sideways"));
    try std.testing.expectError(error.TooManyParts, parseWatch("105:up:read:x"));
}

test "a snapshot's commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const show = parse(a, &.{ "gasim", "show", "a.snap", "105", "1.708", "--rom-words" }, false);
    try std.testing.expectEqualStrings("a.snap", show.from.?);
    try expectEqual(2, show.nodes.len);
    // which asks for memory
    try expect(show.mem);
    const start = parse(a, &.{ "gasim", "start", "x.ga", "-o", "a.snap" }, false);
    try std.testing.expectEqualStrings("a.snap", start.to.?);
    // a session's input is what it says
    try expectEqual(.none, std.meta.activeTag(parse(a, &.{ "gasim", "run", "--from", "a.snap" }, false).input));
    try expectEqual(.stdin, std.meta.activeTag(parse(a, &.{ "gasim", "run", "--from", "a.snap", "--input", "-" }, false).input));
}

test "help says only what a command takes" {
    for (std.enums.values(Command)) |command| {
        var lines = std.mem.splitScalar(u8, helpText(command), '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "  -")) continue;
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            const name = words.next().?;
            const flag = for (&flags) |*f| {
                if (std.mem.eql(u8, f.name, name)) break f;
            } else return error.NoSuchFlag;
            if (!flag.commands.contains(command)) {
                std.debug.print("help for {t} says {s}\n", .{ command, name });
                return error.NotTaken;
            }
        }
    }
}

test "every flag is one a command takes, and its help says so" {
    for (flags) |flag| {
        try expect(flag.commands.count() > 0);
        var commands = flag.commands.iterator();
        while (commands.next()) |command| {
            if (std.mem.indexOf(u8, helpText(command), flag.name) == null) {
                std.debug.print("help for {t} does not say {s}\n", .{ command, flag.name });
                return error.NotInHelp;
            }
        }
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const gasim = @import("gasim");
const Chip = gasim.Chip;
const Direction = gasim.Direction;
const PtyDevice = @import("pty.zig");
const report = @import("report.zig");
