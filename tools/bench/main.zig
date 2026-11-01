//! Times gasim on a fixed set of workloads, against another git ref's gasim
//! if one is given, with poop (instructions, cycles and cache misses as
//! well as wall time) or hyperfine, or else by timing a few runs itself.
//!
//! usage: bench <zig> <work dir> <base ref> <poop> <hyperfine> [workload...]
//!
//! The base ref, poop and hyperfine are empty arguments when there are none.
//! gasim is built for timing, ReleaseFast, from the working tree into the
//! work dir, and the base ref's from `git archive` of it there, once for
//! each commit. Each workload runs as a small shell script, as poop and
//! hyperfine take a command without a shell to redirect stdin.

const Workload = struct {
    name: []const u8,
    /// what it measures
    about: []const u8,
    program: []const u8,
    /// bytes of generated text for stdin, if any
    input: usize = 0,
    /// options for `gasim run`, such as board mode's `--uart`
    options: []const []const u8 = &.{},
    /// whether it needs a ROM, and is left out without one
    rom: bool = false,
};

const workloads = [_]Workload{
    .{ .name = "compute", .about = "one node's opcodes, with no ports", .program = "tools/bench/compute.ga" },
    .{ .name = "ring", .about = "port transfers around 36 nodes", .program = "tools/bench/ring.ga" },
    .{ .name = "upcase", .about = "1 MiB through the console and two nodes", .program = "examples/upcase.ga", .input = 1 << 20 },
    .{
        .name = "boot",
        // with no console, node 000's count is never output, so there is
        // nothing to compare with the base's
        .about = "board mode: the ring booted through the UART and 708's ROM, then run (no output)",
        .program = "tools/bench/ring.ga",
        .options = &.{ "--uart", "708", "--boot" },
        .rom = true,
    },
    .{
        .name = "serial",
        .about = "board mode: 64 KiB through the UART to 708, a bit at a time",
        .program = "tools/bench/serial.ga",
        .input = 1 << 16,
        .options = &.{ "--uart", "708" },
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 6) fatal("usage: bench <zig> <work dir> <base ref> <poop> <hyperfine> [workload...]", .{});
    const zig, const work = .{ args[1], args[2] };
    const base_ref, const poop, const hyperfine = .{ args[3], args[4], args[5] };
    try Io.Dir.cwd().createDirPath(io, work);

    var chosen: std.ArrayList(Workload) = .empty;
    for (args[6..]) |name| {
        for (workloads) |w| {
            if (std.mem.eql(u8, w.name, name)) break try chosen.append(arena, w);
        } else fatal("no workload {s}: there are compute, ring, upcase, boot and serial", .{name});
    }
    if (chosen.items.len == 0) try chosen.appendSlice(arena, &workloads);

    const head = try absolute(io, arena, try std.fs.path.join(arena, &.{ work, "head" }));
    try check(io, arena, &.{ zig, "build", "-Doptimize=ReleaseFast", "--prefix", head }, .inherit, .inherit);
    const gasim = try std.fs.path.join(arena, &.{ head, "bin", "gasim" });
    const base = if (base_ref.len > 0) try buildBase(io, arena, zig, work, base_ref) else null;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    for (chosen.items) |w| {
        try out.print("\n{s}: {s}\n", .{ w.name, w.about });
        const input = if (w.input > 0) try generateInput(io, arena, work, w.input) else "/dev/null";
        const script = try writeScript(io, arena, work, w, "head", gasim, input);
        const base_script = if (base) |b| try writeScript(io, arena, work, w, b.name, b.gasim, input) else null;

        // the steps once, and that both make the same output
        const run = try runScript(io, arena, script, true);
        if (!run.term.success()) {
            if (w.rom and std.mem.indexOf(u8, run.stderr, "needs a ROM") != null) {
                try out.print("  left out, as gasim has no ROM (see --rom in the README)\n", .{});
                continue;
            }
            fatal("{s} failed: {s}", .{ script, run.stderr });
        }
        try out.print("{s}", .{run.stderr});
        if (base_script) |s| {
            const base_run = try runScript(io, arena, s, false);
            if (!base_run.term.success()) fatal("{s} failed: {s}", .{ s, base_run.stderr });
            if (!std.mem.eql(u8, run.stdout, base_run.stdout)) try out.print("warning: {s}'s output differs from this one's\n", .{base.?.label});
        }
        try out.flush();

        var scripts: std.ArrayList([]const u8) = .empty;
        if (base_script) |s| try scripts.append(arena, s);
        try scripts.append(arena, script);
        var commands: std.ArrayList([]const u8) = .empty;
        for (scripts.items) |s| try commands.append(arena, try std.fmt.allocPrint(arena, "sh {s}", .{s}));
        if (poop.len + hyperfine.len > 0) for (scripts.items) |s| if (std.mem.indexOfScalar(u8, s, ' ') != null)
            fatal("{s}: poop and hyperfine split commands at spaces, so the work dir needs a path without them", .{s});

        // poop fails without perf counters, as where perf_event_paranoid
        // is 3 or more, and then hyperfine or our own timing are next
        if (poop.len > 0 and try spawn(io, arena, &.{poop}, commands.items)) continue;
        if (poop.len > 0) std.log.warn("poop failed, so timing without it", .{});
        if (hyperfine.len > 0 and try spawn(io, arena, &.{ hyperfine, "-N", "--warmup", "1" }, commands.items)) continue;
        if (hyperfine.len > 0) std.log.warn("hyperfine failed, so timing five runs", .{});
        for (scripts.items, 0..) |s, i| {
            const label = if (i + 1 < scripts.items.len) base.?.label else "head";
            try timeRuns(io, arena, out, label, s);
        }
    }
    try out.flush();
}

const Base = struct {
    gasim: []const u8,
    /// the ref and its commit, such as main (ab8bb99)
    label: []const u8,
    /// for its files, such as base-ab8bb99
    name: []const u8,
};

/// Builds gasim from the commit `ref` names, unless it was already
fn buildBase(io: Io, arena: Allocator, zig: []const u8, work: []const u8, ref: []const u8) !Base {
    const parsed = try std.process.run(arena, io, .{ .argv = &.{ "git", "rev-parse", "--verify", try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{ref}) } });
    if (!parsed.term.success()) fatal("{s}: not a commit: {s}", .{ ref, std.mem.trim(u8, parsed.stderr, "\n") });
    // the whole commit, which does not grow as a short one can
    const commit = std.mem.trim(u8, parsed.stdout, "\n");
    const name = try std.fmt.allocPrint(arena, "base-{s}", .{commit});
    const dir = try std.fs.path.join(arena, &.{ work, name });
    const exe = try absolute(io, arena, try std.fs.path.join(arena, &.{ dir, "zig-out", "bin", "gasim" }));
    const label = try std.fmt.allocPrint(arena, "{s} ({s})", .{ ref, commit[0..@min(commit.len, 7)] });

    const base: Base = .{ .gasim = exe, .label = label, .name = name };
    if (Io.Dir.cwd().access(io, exe, .{})) |_| return base else |_| {}
    std.log.info("building {s} in {s}", .{ label, dir });
    try Io.Dir.cwd().createDirPath(io, dir);
    const archive = try std.fmt.allocPrint(arena, "{s}.tar", .{dir});
    try check(io, arena, &.{ "git", "archive", try std.fmt.allocPrint(arena, "--output={s}", .{archive}), commit }, .inherit, .inherit);
    try check(io, arena, &.{ "tar", "-x", "-f", archive, "-C", dir }, .inherit, .inherit);
    try Io.Dir.cwd().deleteFile(io, archive);
    try check(io, arena, &.{ zig, "build", "-Doptimize=ReleaseFast" }, .{ .path = dir }, .inherit);
    return base;
}

/// Text for the console, the same each time: lines of words in both cases
fn generateInput(io: Io, arena: Allocator, work: []const u8, len: usize) ![]const u8 {
    const path = try absolute(io, arena, try std.fs.path.join(arena, &.{ work, try std.fmt.allocPrint(arena, "input-{d}.txt", .{len}) }));
    // unless a run stopped while writing it
    if (Io.Dir.cwd().statFile(io, path, .{})) |stat| {
        if (stat.size == len) return path;
    } else |_| {}
    const text = try arena.alloc(u8, len);
    var prng: std.Random.DefaultPrng = .init(0x6a5);
    const random = prng.random();
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ   ,.";
    for (text, 0..) |*c, i| c.* = if (i % 64 == 63) '\n' else chars[random.uintLessThan(usize, chars.len)];
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
    return path;
}

fn writeScript(io: Io, arena: Allocator, work: []const u8, w: Workload, name: []const u8, gasim: []const u8, input: []const u8) ![]const u8 {
    const path = try absolute(io, arena, try std.fs.path.join(arena, &.{ work, try std.fmt.allocPrint(arena, "{s}-{s}.sh", .{ w.name, name }) }));
    const program = try absolute(io, arena, w.program);
    var options: std.ArrayList(u8) = .empty;
    for (w.options) |o| try options.print(arena, "{f} ", .{Quoted{ .s = o }});
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = try std.fmt.allocPrint(arena, "exec {f} run {s}\"$@\" {f} < {f}\n", .{ Quoted{ .s = gasim }, options.items, Quoted{ .s = program }, Quoted{ .s = input } }),
    });
    return path;
}

/// a string as one word for sh, in single quotes
const Quoted = struct {
    s: []const u8,

    pub fn format(self: Quoted, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeByte('\'');
        for (self.s) |c| if (c == '\'') try writer.writeAll("'\\''") else try writer.writeByte(c);
        try writer.writeByte('\'');
    }
};

/// Runs a workload's script once, keeping its output to compare, with
/// --stats if it is this gasim, as a base ref's may not have it
fn runScript(io: Io, arena: Allocator, script: []const u8, stats: bool) !std.process.RunResult {
    const argv: []const []const u8 = if (stats) &.{ "sh", script, "--stats" } else &.{ "sh", script };
    return std.process.run(arena, io, .{ .argv = argv, .stdout_limit = .limited(64 << 20) });
}

fn timeRuns(io: Io, arena: Allocator, out: *Io.Writer, label: []const u8, script: []const u8) !void {
    var times: [5]i96 = undefined;
    for (&times) |*t| {
        const started: Io.Timestamp = .now(io, .awake);
        try check(io, arena, &.{ "sh", script }, .inherit, .ignore);
        t.* = started.durationTo(.now(io, .awake)).toNanoseconds();
    }
    std.mem.sort(i96, &times, {}, std.sort.asc(i96));
    try out.print("  {s}: {d:.3} s at best, {d:.3} s median, of {d} runs (no poop or hyperfine)\n", .{
        label,
        @as(f64, @floatFromInt(times[0])) / 1e9,
        @as(f64, @floatFromInt(times[times.len / 2])) / 1e9,
        times.len,
    });
    try out.flush();
}

/// Runs poop or hyperfine on the commands, returning whether it worked
fn spawn(io: Io, arena: Allocator, runner: []const []const u8, commands: []const []const u8) !bool {
    const argv = try std.mem.concat(arena, []const u8, &.{ runner, commands });
    var child = try std.process.spawn(io, .{ .argv = argv });
    return (try child.wait(io)).success();
}

fn check(io: Io, arena: Allocator, argv: []const []const u8, cwd: std.process.Child.Cwd, stdout: std.process.SpawnOptions.StdIo) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = cwd, .stdout = stdout });
    const term = try child.wait(io);
    if (!term.success()) fatal("{s} failed", .{try std.mem.join(arena, " ", argv)});
}

fn absolute(io: Io, arena: Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(io, arena), path });
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
