//! The chip before each step or run, to go back to.
//!
//! The chip is saved before each step or run, and that snapshot is kept
//! once the chip has changed, so a step that does nothing leaves nothing to
//! go back to. The oldest kept is dropped to make room.

const History = @This();

/// the `len` kept start from the oldest at `first`, and the one after them
/// is the one saved last. Each is allocated the first time it is needed.
snapshots: []?Chip.Snapshot = &.{},
/// what each of `snapshots` was saved before
causes: []Cause = &.{},
first: usize = 0,
/// how many are kept, not counting one that is `pending`
len: usize = 0,
/// whether the snapshot after those kept was saved before the last step or
/// run, and is not yet kept
pending: bool = false,

/// what the chip was saved before. The web version gives these by number.
pub const Cause = enum(u8) {
    step,
    round,
    node,
    run,
    /// a line at the prompt
    line,
    reset,
    compile,
    /// a step of one opcode of a node
    slot,

    pub fn text(self: Cause) []const u8 {
        return switch (self) {
            .step => "a step",
            .round => "a round of steps",
            .node => "a step of one node",
            .slot => "a step of one opcode",
            .run => "a run",
            .line => "a line at the prompt",
            .reset => "starting again",
            .compile => "compiling a block",
        };
    }
};

/// one of the snapshots kept
pub const Moment = struct {
    /// the steps taken by then
    steps: u64,
    cause: Cause,
};

/// A history that keeps up to `capacity_` steps and runs
pub fn init(gpa: Allocator, capacity_: usize) Allocator.Error!History {
    // one more is saved before it is kept
    const snapshots = try gpa.alloc(?Chip.Snapshot, capacity_ + 1);
    errdefer gpa.free(snapshots);
    @memset(snapshots, null);
    return .{ .snapshots = snapshots, .causes = try gpa.alloc(Cause, capacity_ + 1) };
}

pub fn deinit(self: *History, gpa: Allocator) void {
    for (self.snapshots) |*snapshot| if (snapshot.*) |*s| s.deinit(gpa);
    gpa.free(self.snapshots);
    gpa.free(self.causes);
    self.* = .{};
}

/// how many steps and runs it can keep
pub fn capacity(self: History) usize {
    return self.snapshots.len -| 1;
}

/// Saves the chip, before `cause` steps or runs it, to go back to if it
/// changes. A history of no capacity saves nothing.
pub fn remember(self: *History, gpa: Allocator, chip: *const Chip, cause: Cause) Allocator.Error!void {
    if (self.capacity() == 0) return;
    self.keep(chip);
    const i = self.index(self.len);
    const snapshot = &self.snapshots[i];
    if (snapshot.* == null) snapshot.* = try .init(gpa, chip.layout);
    chip.save(&snapshot.*.?);
    self.causes[i] = cause;
    self.pending = true;
}

/// Keeps the snapshot saved last, unless the chip has not changed since.
/// While the chip runs it may not have changed yet, and keeping then would
/// drop the snapshot.
pub fn keep(self: *History, chip: *const Chip) void {
    if (!self.pending) return;
    self.pending = false;
    if (chip.matches(&self.snapshots[self.index(self.len)].?)) return;
    if (self.len == self.capacity()) {
        self.first = self.index(1);
    } else self.len += 1;
}

/// Goes back to before the last step or run that changed the chip. Returns
/// false with nothing to go back to.
pub fn back(self: *History, chip: *Chip) bool {
    self.keep(chip);
    if (self.len == 0) return false;
    return self.backTo(chip, self.len - 1);
}

/// Goes back to before the `n`th step or run kept, the oldest 0, forgetting
/// those after it. Returns false if there is no such step.
pub fn backTo(self: *History, chip: *Chip, n: usize) bool {
    self.keep(chip);
    if (n >= self.len) return false;
    self.len = n;
    chip.restore(&self.snapshots[self.index(n)].?);
    return true;
}

/// the `n`th step or run kept, the oldest 0
pub fn moment(self: History, n: usize) Moment {
    const i = self.index(n);
    return .{ .steps = self.snapshots[i].?.steps, .cause = self.causes[i] };
}

/// Forgets every step and run, keeping the memory for the next
pub fn forget(self: *History) void {
    self.first = 0;
    self.len = 0;
    self.pending = false;
}

/// the index in `snapshots` of the one `n` from the oldest
fn index(self: History, n: usize) usize {
    return (self.first + n) % self.snapshots.len;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Chip = @import("Chip.zig");

test "a step that changes nothing is not kept, and the oldest is dropped" {
    const gpa = std.testing.allocator;
    var chip: Chip = try .init(gpa, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(gpa);
    var history: History = try .init(gpa, 2);
    defer history.deinit(gpa);

    try history.remember(gpa, &chip, .step);
    history.keep(&chip);
    try expectEqual(0, history.len);
    try expect(!history.back(&chip));

    for ([_]Cause{ .step, .node, .run }) |cause| {
        try history.remember(gpa, &chip, cause);
        chip.nodes[0].a +%= 1;
        chip.steps += 1;
    }
    history.keep(&chip);
    try expectEqual(2, history.len);
    try expectEqual(Moment{ .steps = 1, .cause = .node }, history.moment(0));
    try expectEqual(Moment{ .steps = 2, .cause = .run }, history.moment(1));

    try expect(history.backTo(&chip, 0));
    try expectEqual(1, chip.steps);
    try expectEqual(0, history.len);
}

test "a history of no capacity saves nothing" {
    const gpa = std.testing.allocator;
    var chip: Chip = try .init(gpa, .{ .rows = 1, .columns = 1 });
    defer chip.deinit(gpa);
    var history: History = .{};
    try history.remember(gpa, &chip, .step);
    chip.nodes[0].a +%= 1;
    try expect(!history.back(&chip));
}
