//! Something outside the nodes that a chip runs with, such as a console on
//! a port, a UART on two pins or a flash memory. A device meets its nodes
//! through a port (`Chip.attachPort`), the nets of pins (`Chip.attachPin`)
//! or a parallel bus (`Chip.attachBus`). This is the rest of what a chip
//! asks of it: to be serviced as the chip runs, to say when a pin it drives
//! next changes, and to be saved and read back with the chip. A device
//! gives only what it has, and the chip needs to know nothing else of it.

const Device = @This();

context: *anyopaque,
vtable: *const VTable,
/// what it writes to, which the chip flushes once it has been quiet for a
/// while
output: ?*Io.Writer = null,
/// set from outside the run to end it, as by ctrl+c
interrupted: ?*std.atomic.Value(bool) = null,
/// set while the run waits for the device's input, for whatever interrupts
/// it to know that the wait has to be ended too
waiting: ?*std.atomic.Value(bool) = null,

/// the device's side of a port it shares with a node, which uses the other
pub const side: port.Side = .b;

/// a queue of input, closed at the end of it, and the `Io` it is used with
pub const Queue = struct {
    io: Io,
    queue: *Io.Queue(u8),
};

/// what servicing a device can fail with: writing its output, or waiting
/// for its input
pub const ServiceError = Io.Writer.Error || Io.Cancelable;

pub const VTable = struct {
    /// Gives its node what it has for it, and takes what the node has for
    /// it, at the node's `time`. Returns whether there was anything to do.
    /// With `wait`, and nothing to do until more input arrives, waits for
    /// input, returning false at its end.
    service: ?*const fn (context: *anyopaque, time: u64, wait: bool) ServiceError!bool = null,
    /// when the wakeup pin it drives next changes after `time`, if that is
    /// known
    nextEdge: ?*const fn (context: *anyopaque, time: u64) ?u64 = null,
    /// told that the node read the wakeup pin it drives, or woke on it
    pinRead: ?*const fn (context: *anyopaque) void = null,
    /// what of it goes back with the chip to an earlier time in the run
    save: ?*const fn (context: *anyopaque) Saved = null,
    restore: ?*const fn (context: *anyopaque, saved: Saved) void = null,
    /// how it is written to a snapshot file and read from one
    state: State,
};

/// What of a device goes back with the chip: its port, and how far it is
/// through what it has for the node. A device keeps its input and output.
pub const Saved = struct {
    port: Port = .{},
    next: usize = 0,
};

/// A device's state in a snapshot file
pub const State = struct {
    /// of the fields it is written with, so that a file with others is
    /// refused
    hash: u64,
    write: *const fn (context: *anyopaque, writer: *Io.Writer) snapshot.Error!void,
    read: *const fn (context: *anyopaque, reader: *Io.Reader, arena: Allocator) snapshot.Error!void,

    /// The state of a `T`, written field by field as `snapshot` writes any
    /// type: see `snapshot_skip` there
    pub fn of(comptime T: type) State {
        const fns = struct {
            fn write(context: *anyopaque, writer: *Io.Writer) snapshot.Error!void {
                const self: *T = @ptrCast(@alignCast(context));
                try snapshot.put(writer, self.*);
            }

            fn read(context: *anyopaque, reader: *Io.Reader, arena: Allocator) snapshot.Error!void {
                const self: *T = @ptrCast(@alignCast(context));
                try snapshot.get(reader, arena, self);
            }
        };
        return .{ .hash = snapshot.typeHash(T), .write = fns.write, .read = fns.read };
    }
};

/// whether it takes input from outside the run, or gives output to it, so
/// that a run with it has to look out for both
pub fn interactive(self: Device) bool {
    return self.output != null or self.interrupted != null;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const port = @import("port.zig");
const Port = port.Port;
const snapshot = @import("snapshot.zig");
const Word = @import("f18.zig").Word;
const assembler = @import("assembler.zig");
const Chip = @import("Chip.zig");

/// a device the chip knows nothing of: it adds up the words a node writes
const TestSum = struct {
    port: Port = .{},
    total: u32 = 0,

    fn device(self: *TestSum) Device {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: VTable = .{ .service = service, .save = save, .restore = restore, .state = .of(TestSum) };

    fn service(context: *anyopaque, _: u64, _: bool) ServiceError!bool {
        const self: *TestSum = @ptrCast(@alignCast(context));
        if (!self.port.otherWriting(side)) return false;
        self.total += @as(u18, @bitCast(self.port.read(side).?));
        return true;
    }

    fn save(context: *anyopaque) Saved {
        const self: *TestSum = @ptrCast(@alignCast(context));
        return .{ .port = self.port, .next = self.total };
    }

    fn restore(context: *anyopaque, saved: Saved) void {
        const self: *TestSum = @ptrCast(@alignCast(context));
        self.port = saved.port;
        self.total = @intCast(saved.next);
    }
};

/// a GA144 with `sum` on the up port of node 000, which writes it 1, 2 and 3
fn testChip(sum: *TestSum) !Chip {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    errdefer chip.deinit(std.testing.allocator);
    try chip.attachPort(0, .up, &sum.port, sum.device());
    var programs: [1]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes("up b! 1 !b 2 !b 3 !b", &programs, &diagnostic)) |program| try chip.load(program);
    return chip;
}

test "a chip runs a device it knows only by this interface, and goes back with it" {
    const gpa = std.testing.allocator;
    var sum: TestSum = .{};
    var chip = try testChip(&sum);
    defer chip.deinit(gpa);
    var before: Chip.Snapshot = try .init(gpa, chip.layout);
    defer before.deinit(gpa);

    while (sum.total == 0) {
        _ = try chip.service();
        _ = chip.step();
    }
    try std.testing.expectEqual(1, sum.total);
    chip.save(&before);

    try chip.run();
    try std.testing.expectEqual(6, sum.total);
    try std.testing.expect(!chip.matches(&before));

    chip.restore(&before);
    try std.testing.expectEqual(1, sum.total);
    try chip.run();
    try std.testing.expectEqual(6, sum.total);
}

/// a device that interrupts the run once its node waits for a word from
/// it, and notes whether the run went on to wait for its input
const TestInterrupter = struct {
    port: Port = .{},
    interrupted: std.atomic.Value(bool) = .init(false),
    waited: bool = false,

    fn device(self: *TestInterrupter) Device {
        return .{ .context = self, .vtable = &vtable, .interrupted = &self.interrupted };
    }

    const vtable: VTable = .{ .service = service, .state = .of(Port) };

    fn service(context: *anyopaque, _: u64, wait: bool) ServiceError!bool {
        const self: *TestInterrupter = @ptrCast(@alignCast(context));
        if (wait) self.waited = true;
        if (self.port.otherReading(side)) self.interrupted.store(true, .monotonic);
        return false;
    }
};

test "a run that is interrupted with every node waiting does not wait for input" {
    const gpa = std.testing.allocator;
    var chip: Chip = try .init(gpa, .ga144);
    defer chip.deinit(gpa);
    var interrupter: TestInterrupter = .{};
    try chip.attachPort(0, .up, &interrupter.port, interrupter.device());
    var programs: [1]assembler.Program = undefined;
    var diagnostic: assembler.Diagnostic = .{};
    for (try assembler.assembleNodes("up b! @b", &programs, &diagnostic)) |program| try chip.load(program);

    try chip.run();
    try std.testing.expect(interrupter.interrupted.load(.monotonic));
    try std.testing.expect(!interrupter.waited);
}

test "a snapshot file holds a device, and is refused for a device of other fields" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var file: Io.Writer.Allocating = .init(arena);
    {
        var sum: TestSum = .{};
        var chip = try testChip(&sum);
        defer chip.deinit(gpa);
        while (sum.total == 0) {
            _ = try chip.service();
            _ = chip.step();
        }
        try snapshot.write(&file.writer, .{}, &chip);
    }

    var sum: TestSum = .{};
    var chip = try testChip(&sum);
    defer chip.deinit(gpa);
    var reader: Io.Reader = .fixed(file.written());
    _ = try snapshot.readMachine(&reader, arena);
    try snapshot.readChip(&reader, arena, &chip);
    try chip.run();
    try std.testing.expectEqual(6, sum.total);

    // a feeder where the file has the sum
    var other: Chip = try .init(gpa, .ga144);
    defer other.deinit(gpa);
    var feeder: Chip.Feeder = .{ .words = &.{} };
    try other.attachFeeder(&feeder, 0, .up);
    reader = .fixed(file.written());
    _ = try snapshot.readMachine(&reader, arena);
    try std.testing.expectError(error.OtherVersion, snapshot.readChip(&reader, arena, &other));
}
