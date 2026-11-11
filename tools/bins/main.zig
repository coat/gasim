//! Writes the SHA-256 of each bin of code in arrayForth 3's object file,
//! `sF/OBJ-AF3` in its distribution, as the ZON list in `src/af3-bins.zon`.
//! gasim's tests check the bins it assembles from arrayForth 3's source
//! against them. `zig build bin-digests -- <OBJ-AF3>` runs it.
//!
//! The file's first 576 blocks are the bins of four chips' nodes. A bin's
//! block starts with the 64 words of RAM, each 4 bytes with the highest
//! first, which is what is hashed. A bin whose RAM is all `call warm`, as
//! arrayForth 3's ERS leaves it, has no code, and is left out.
//!
//!   bins <OBJ-AF3>
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const block_size = 1024;
const bins = 4 * 144;
const ram_size = 64 * 4;
/// `call warm`, which unused RAM holds
const empty: [4]u8 = .{ 0x00, 0x01, 0x34, 0xa9 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: bins <OBJ-AF3>\n", .{});
        std.process.exit(2);
    }
    const file = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 * 1024 * 1024));
    if (file.len < bins * block_size) {
        std.debug.print("{s}: not an object file of {d} bins\n", .{ args[1], bins });
        std.process.exit(1);
    }

    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\// The SHA-256 of the RAM of each bin of code in arrayForth 3's object
        \\// file, sF/OBJ-AF3 in its distribution 03d: what GreenArrays' own
        \\// assembler made of the stock code. Written by
        \\// `zig build bin-digests -- <OBJ-AF3>` (tools/bins), not by hand.
        \\//
        \\// bin: the bin's number, counting the nodes of a chip row by row, and
        \\//   the chips one after another, 144 each
        \\.{
        \\
    );
    for (0..bins) |bin| {
        const ram = file[bin * block_size ..][0..ram_size];
        var code = false;
        for (0..64) |word| {
            if (!std.mem.eql(u8, ram[word * 4 ..][0..4], &empty)) code = true;
        }
        if (!code) continue;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(ram, &digest, .{});
        try writer.print("    .{{ .bin = {d}, .sha256 = \"{x}\" }},\n", .{ bin, &digest });
    }
    try writer.writeAll("}\n");
    try writer.flush();
}
