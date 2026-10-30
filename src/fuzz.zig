//! Seeds for fuzz tests that take their input as a single `Smith.slice`,
//! from files that may be missing, such as GreenArrays' disks in rom/, which
//! git ignores. Without the fuzzer, `zig build test` runs each seed once.

/// Adds `bytes` to `seeds` as one input, framed as `Smith.slice` reads it:
/// its length, little-endian, then its bytes
pub fn add(arena: Allocator, seeds: *std.ArrayList([]const u8), bytes: []const u8) !void {
    const seed = try arena.alloc(u8, 4 + bytes.len);
    std.mem.writeInt(u32, seed[0..4], @intCast(bytes.len), .little);
    @memcpy(seed[4..], bytes);
    try seeds.append(arena, seed);
}

/// Adds each of `paths` that exists, whole or, given `chunk`, cut into
/// chunks of that many bytes, skipping chunks of only spaces and zeros
pub fn addFiles(arena: Allocator, seeds: *std.ArrayList([]const u8), paths: []const []const u8, chunk: ?usize) !void {
    for (paths) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        const size = chunk orelse bytes.len;
        var i: usize = 0;
        while (i < bytes.len) : (i += size) {
            const part = bytes[i..@min(i + size, bytes.len)];
            if (std.mem.trim(u8, part, " \x00").len > 0) try add(arena, seeds, part);
        }
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
