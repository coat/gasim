//! `gasim test`: runs the cases in a spec file and says which do what they
//! should. A spec is a ZON list of cases, each a program and what a run of it
//! should end with. Each runs as `gasim run --json` does, in a process of its
//! own, so that a case can use any option, and `gasim show --json` reads the
//! nodes it left.

pub const Case = struct {
    /// what to call the case, by default its program
    name: []const u8 = "",
    /// relative to the spec
    program: []const u8,
    /// more options for run, such as "--uart", "708"
    args: []const []const u8 = &.{},
    /// what the console or UART reads
    input: []const u8 = "",
    max_steps: u64 = 100_000_000,
    /// how the run should end
    stop: report.Stop = .settled,
    /// what it should output, if it matters
    output: ?[]const u8 = null,
    /// what it should leave in nodes
    nodes: []const NodeCheck = &.{},
};

pub const NodeCheck = struct {
    node: []const u8,
    /// registers, in the case's numbers
    p: ?u32 = null,
    a: ?u32 = null,
    b: ?u32 = null,
    io: ?u32 = null,
    t: ?u32 = null,
    s: ?u32 = null,
    r: ?u32 = null,
    /// words of RAM
    ram: []const RamCheck = &.{},
};

pub const RamCheck = struct { address: u6, word: u18 };

/// what was wrong with each case that failed
const Failures = std.ArrayList([]const u8);

/// Runs the cases in each spec, returning the status to exit with
pub fn run(io: Io, arena: Allocator, environ: *const std.process.Environ.Map, specs: []const []const u8, json: bool) !u8 {
    const self = std.process.executablePathAlloc(io, arena) catch |err| report.fatal("cannot find gasim: {t}", .{err});
    const dir = environ.get("TMPDIR") orelse environ.get("TEMP") orelse "/tmp";
    const stamp = Io.Timestamp.now(io, .awake).nanoseconds;
    const input_path = try std.fmt.allocPrint(arena, "{s}/gasim-test-{d}.input", .{ dir, stamp });
    const snapshot_path = try std.fmt.allocPrint(arena, "{s}/gasim-test-{d}.snapshot", .{ dir, stamp });
    defer Io.Dir.cwd().deleteFile(io, input_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, snapshot_path) catch {};

    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    const out = &file_writer.interface;
    var passed: usize = 0;
    var failed: usize = 0;
    var failures: Failures = .empty;
    for (specs) |spec| {
        for (try readSpec(io, arena, spec)) |case| {
            const name = if (case.name.len > 0) case.name else case.program;
            var problems: Failures = .empty;
            try runCase(io, arena, self, spec, case, input_path, snapshot_path, &problems);
            if (problems.items.len == 0) {
                passed += 1;
                if (!json) try out.print("ok {s}\n", .{name});
            } else {
                failed += 1;
                if (!json) try out.print("FAIL {s}\n", .{name});
                for (problems.items) |problem| {
                    if (!json) try out.print("  {s}\n", .{problem});
                    try failures.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ name, problem }));
                }
            }
            try out.flush();
        }
    }
    if (json) {
        var jw: std.json.Stringify = .{ .writer = out };
        try jw.beginObject();
        try jw.objectField("stop");
        try jw.write(if (failed > 0) "failed" else "done");
        try jw.objectField("passed");
        try jw.write(passed);
        try jw.objectField("failed");
        try jw.write(failed);
        try jw.objectField("failures");
        try jw.beginArray();
        for (failures.items) |failure| try report.bytes(&jw, failure);
        try jw.endArray();
        try jw.endObject();
        try out.writeByte('\n');
    } else try out.print("{d} passed, {d} failed\n", .{ passed, failed });
    try out.flush();
    return if (failed > 0) status_failed else 0;
}

/// the status for a difference
const status_failed = 6;

fn readSpec(io: Io, arena: Allocator, path: []const u8) ![]const Case {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| report.fatal("{s}: {t}", .{ path, err });
    const source = try arena.dupeSentinel(u8, text, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice([]const Case, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diagnostics }) catch |err| switch (err) {
        error.OutOfMemory => report.fatal("out of memory", .{}),
        error.ParseZon => {
            diagnostics.log(path);
            report.fatal("{s}: does not parse", .{path});
        },
    };
}

/// the stdout of gasim with `args`, which it may leave with any status
fn gasimOutput(io: Io, arena: Allocator, self: []const u8, args: []const []const u8) ![]const u8 {
    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = self;
    @memcpy(argv[1..], args);
    const result = try std.process.run(arena, io, .{ .argv = argv });
    return result.stdout;
}

fn runCase(io: Io, arena: Allocator, self: []const u8, spec: []const u8, case: Case, input_path: []const u8, snapshot_path: []const u8, problems: *Failures) !void {
    Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = case.input }) catch |err| report.fatal("{s}: {t}", .{ input_path, err });
    const program = if (std.fs.path.isAbsolute(case.program)) case.program else try std.fs.path.join(arena, &.{ std.fs.path.dirname(spec) orelse ".", case.program });
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "run", program, "--json", "--input", input_path, "--to", snapshot_path, "--max-steps", try std.fmt.allocPrint(arena, "{d}", .{case.max_steps}) });
    try args.appendSlice(arena, case.args);
    const result = std.json.parseFromSliceLeaky(std.json.Value, arena, try gasimOutput(io, arena, self, args.items), .{}) catch
        return problems.append(arena, "the run said nothing that could be read");
    try checkResult(arena, case, result, problems);
    if (case.nodes.len == 0 or problems.items.len > 0) return;

    args.clearRetainingCapacity();
    try args.appendSlice(arena, &.{ "show", snapshot_path, "--mem", "--json" });
    for (case.nodes) |check| try args.append(arena, check.node);
    const shown = std.json.parseFromSliceLeaky(std.json.Value, arena, try gasimOutput(io, arena, self, args.items), .{}) catch
        return problems.append(arena, "show said nothing that could be read");
    try checkNodes(arena, case, shown, problems);
}

/// the bytes of a string in which each is a character
fn outputBytes(arena: Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, text.len);
    var len: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return text).iterator();
    while (it.nextCodepoint()) |c| {
        out[len] = std.math.cast(u8, c) orelse return text;
        len += 1;
    }
    return out[0..len];
}

fn checkResult(arena: Allocator, case: Case, result: std.json.Value, problems: *Failures) !void {
    const object = switch (result) {
        .object => |o| o,
        else => return problems.append(arena, "the run said nothing that could be read"),
    };
    const stop = object.get("stop").?.string;
    if (std.mem.eql(u8, stop, "error")) return problems.append(arena, try std.fmt.allocPrint(arena, "{s}", .{object.get("message").?.string}));
    if (!std.mem.eql(u8, stop, @tagName(case.stop)))
        try problems.append(arena, try std.fmt.allocPrint(arena, "stop: expected {t}, got {s}", .{ case.stop, stop }));
    if (case.output) |expected| {
        const output = try outputBytes(arena, object.get("output").?.string);
        if (!std.mem.eql(u8, expected, output))
            try problems.append(arena, try std.fmt.allocPrint(arena, "output: expected \"{f}\", got \"{f}\"", .{ std.zig.fmtString(expected), std.zig.fmtString(output) }));
    }
}

fn checkNodes(arena: Allocator, case: Case, shown: std.json.Value, problems: *Failures) !void {
    const object = switch (shown) {
        .object => |o| o,
        else => return problems.append(arena, "show said nothing that could be read"),
    };
    if (object.get("stop")) |_| return problems.append(arena, try std.fmt.allocPrint(arena, "{s}", .{object.get("message").?.string}));
    const nodes = object.get("nodes").?.array.items;
    const memory = object.get("memory").?.array.items;
    for (case.nodes, nodes, memory) |check, node, words| {
        inline for (.{ "p", "a", "b", "io", "t", "s", "r" }) |register| if (@field(check, register)) |expected| {
            const value = try std.fmt.parseInt(u32, node.object.get(register).?.string, 16);
            if (value != expected) try problems.append(arena, try std.fmt.allocPrint(arena, "node {s} {s}: expected {x}, got {x}", .{ check.node, register, expected, value }));
        };
        for (check.ram) |ram| {
            const word = words.object.get("words").?.array.items[ram.address].object.get("word").?.string;
            const value = try std.fmt.parseInt(u18, word, 16);
            if (value != ram.word) try problems.append(arena, try std.fmt.allocPrint(arena, "node {s} RAM {x:0>3}: expected {x}, got {x}", .{ check.node, ram.address, ram.word, value }));
        }
    }
}

test "a run's output compares as bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualSlices(u8, "a\xff", try outputBytes(a, "a\u{ff}"));
    try std.testing.expectEqualStrings("plain", try outputBytes(a, "plain"));
}

test "checks say what differs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"stop\":\"breakpoint\",\"output\":\"hi\"}", .{});
    var problems: Failures = .empty;
    try checkResult(a, .{ .program = "x", .output = "ho" }, result, &problems);
    try std.testing.expectEqual(2, problems.items.len);
    try std.testing.expectEqualStrings("stop: expected settled, got breakpoint", problems.items[0]);
    try std.testing.expectEqualStrings("output: expected \"ho\", got \"hi\"", problems.items[1]);
    problems.clearRetainingCapacity();
    try checkResult(a, .{ .program = "x", .stop = .breakpoint, .output = "hi" }, result, &problems);
    try std.testing.expectEqual(0, problems.items.len);

    const shown = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"nodes":[{"t":"00005","a":"00001"}],"memory":[{"words":[{"word":"00007"}]}]}
    , .{});
    const check: NodeCheck = .{ .node = "000", .t = 5, .a = 2, .ram = &.{.{ .address = 0, .word = 8 }} };
    try checkNodes(a, .{ .program = "x", .nodes = &.{check} }, shown, &problems);
    try std.testing.expectEqual(2, problems.items.len);
    try std.testing.expectEqualStrings("node 000 a: expected 2, got 1", problems.items[0]);
    try std.testing.expectEqualStrings("node 000 RAM 000: expected 8, got 7", problems.items[1]);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const report = @import("report.zig");
