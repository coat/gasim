pub const DataStack = struct {
    t: Word,
    s: Word,
    stack: [8]Word,
    index: u3 = 0,

    pub fn push(self: *@This(), value: Word) void {
        self.stack[self.index] = self.s;
        self.s = self.t;

        self.t = value;
        self.index +%= 1;
    }

    pub fn pop(self: *@This()) Word {
        self.index -%= 1;
        const old_t = self.t;
        self.t = self.s;
        self.s = self.stack[self.index];

        return old_t;
    }

    pub const empty: @This() = .{
        .stack = @splat(0),
        .index = 0,
        .t = 0,
        .s = 0,
    };
};

pub const ReturnStack = struct {
    t: Word,
    stack: [8]Word,
    index: u3 = 0,

    pub fn push(self: *@This(), value: Word) void {
        self.stack[self.index] = self.t;

        self.t = value;
        self.index +%= 1;
    }

    pub fn pop(self: *@This()) Word {
        self.index -%= 1;
        const old_t = self.t;
        self.t = self.stack[self.index];

        return old_t;
    }

    pub const empty: @This() = .{
        .stack = @splat(0),
        .index = 0,
        .t = 0,
    };
};

test "DataStack works" {
    var stack: DataStack = .empty;

    // initalized to zeroes
    try expectEqual(stack.index, 0);
    try expectEqual(0, stack.t);
    try expectEqual(0, stack.s);

    // push
    stack.push(55);
    try expectEqual(55, stack.t);
    try expectEqual(0, stack.s);
    try expectEqual(1, stack.index);
    try expectEqual(0, stack.stack[0]);

    stack.push(123);
    try expectEqual(123, stack.t);
    try expectEqual(55, stack.s);
    try expectEqual(2, stack.index);
    try expectEqual(0, stack.stack[0]);

    stack.push(999);
    try expectEqual(999, stack.t);
    try expectEqual(123, stack.s);
    try expectEqual(3, stack.index);
    try expectEqual(55, stack.stack[stack.index - 1]);

    // pop
    _ = stack.pop();

    try expectEqual(123, stack.pop());
    try expectEqual(55, stack.t);
    try expectEqual(0, stack.s);

    try expectEqual(55, stack.pop());
    try expectEqual(0, stack.index);
    try expectEqual(0, stack.t);
    try expectEqual(0, stack.s);

    inline for (0..10) |i| {
        stack.push(i);
    }
    try expectEqual(2, stack.index);

    try expectEqual(9, stack.pop());
    try expectEqual(1, stack.index);

    stack.push(123);
    try expectEqual(2, stack.index);
    try expectEqual(123, stack.pop());
    try expectEqual(1, stack.index);

    try expectEqual(8, stack.pop());

    for (0..7) |_| {
        _ = stack.pop();
    }

    try expectEqual(1, stack.index);
    try expectEqual(0, stack.pop());
}

test ReturnStack {
    var stack: ReturnStack = .empty;

    // initalized to zeroes
    try expectEqual(stack.index, 0);
    try expectEqual(0, stack.t);

    // push
    stack.push(55);
    try expectEqual(55, stack.t);
    try expectEqual(1, stack.index);
    try expectEqual(0, stack.stack[0]);

    stack.push(123);
    try expectEqual(123, stack.t);
    try expectEqual(2, stack.index);
    try expectEqual(55, stack.stack[stack.index - 1]);

    // pop
    try expectEqual(123, stack.pop());
    try expectEqual(0, stack.stack[stack.index - 1]);

    try expectEqual(55, stack.pop());
    try expectEqual(0, stack.index);
    try expectEqual(0, stack.t);

    // circular stack
    stack.push(123);
    stack.push(123);
    for (0..31) |_| {
        stack.push(0x15555);
    }

    for (0..31) |_| {
        _ = stack.pop();
    }
    try expectEqual(0x15555, stack.pop());
}

const f18 = @import("f18.zig");
const Word = f18.Word;

const std = @import("std");
const expectEqual = std.testing.expectEqual;
