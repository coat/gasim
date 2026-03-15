//! gasim

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    var node: Computer = .reset;
    for (0..1024) |_| node.step();

    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("Total simulated time: {d}us\n", .{node.execution_time});

    try stdout_writer.flush(); // Don't forget to flush!
}

const std = @import("std");
const Io = std.Io;

const Computer = @import("gasim").Computer;
