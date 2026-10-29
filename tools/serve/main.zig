//! serve: a small static file server for the web build (`zig build serve`).
//! One request per connection, one connection at a time: enough for a page,
//! its scripts and the .wasm on localhost.
//!
//!   serve <dir> [port]
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) {
        std.debug.print("usage: serve <dir> [port]\n", .{});
        return;
    }
    const port = if (args.len == 3) try std.fmt.parseInt(u16, args[2], 10) else 8080;
    var dir = try Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);

    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    std.debug.print("gasim: http://localhost:{d}/  (serving {s}; ctrl+c stops)\n", .{ port, args[1] });
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("serve: accept: {t}\n", .{err});
            continue;
        };
        defer stream.close(io);
        handle(io, init.gpa, dir, stream) catch |err| std.debug.print("serve: {t}\n", .{err});
    }
}

fn handle(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, stream: Io.net.Stream) !void {
    var in_buf: [8192]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var r = stream.reader(io, &in_buf);
    var w = stream.writer(io, &out_buf);
    var http: std.http.Server = .init(&r.interface, &w.interface);
    var req = http.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };
    const target = req.head.target;
    const path = target[0 .. std.mem.findAny(u8, target, "?#") orelse target.len];
    const rel = if (std.mem.eql(u8, path, "/")) "index.html" else std.mem.trimStart(u8, path, "/");
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = contentType(rel) },
        .{ .name = "cache-control", .value = "no-store" },
    };
    if (std.mem.find(u8, rel, "..") != null) {
        return req.respond("bad path\n", .{ .status = .bad_request, .keep_alive = false });
    }
    const data = dir.readFileAlloc(io, rel, gpa, .limited(16 << 20)) catch {
        std.debug.print("  404 {s}\n", .{path});
        return req.respond("not found\n", .{ .status = .not_found, .keep_alive = false });
    };
    defer gpa.free(data);
    try req.respond(data, .{ .keep_alive = false, .extra_headers = &headers });
}

fn contentType(path: []const u8) []const u8 {
    const types = [_][2][]const u8{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
        .{ ".png", "image/png" },
        .{ ".svg", "image/svg+xml" },
        .{ ".json", "application/json" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".ico", "image/x-icon" },
    };
    for (types) |t| if (std.mem.endsWith(u8, path, t[0])) return t[1];
    return "application/octet-stream";
}
