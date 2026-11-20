# serve

## Overview

`serve` is a small static file server for the web version. `zig build
serve` builds the web version into `zig-out/web` and serves it on
http://localhost:8080. It handles one request per connection, and one
connection at a time. That is enough for a page, its scripts and the
`.wasm` file on your own machine. See [Building](../../docs/building.md)
for the web version.

```bash
zig build serve
zig build serve -- 9000    # another port
```

The build runs it as `serve <dir> [port]`.

## Interface

- `main.zig:main` opens `<dir>`, listens on 127.0.0.1 at the port, and
  serves requests until you stop it with ctrl+c.
- `main.zig:handle` answers one request. It serves `index.html` for `/`.
- `main.zig:contentType` picks the content type from the file's
  extension. Unknown extensions get `application/octet-stream`.

## Invariants

These are the rules that the code relies on, and that a change must keep.

- It listens only on 127.0.0.1, not on other interfaces.
- It refuses any path with `..` in it, with status 400.
- It drops the query and fragment (`?` and `#`) from the path.
- It reads files of up to 16 MiB, and answers 404 for any it can't read.
- Every file it serves has `cache-control: no-store`, so the browser
  always loads the latest build. The 400 and 404 answers have no headers
  of their own.
- An error on one connection is printed, and the server keeps running.

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- It opens a TCP socket on 127.0.0.1, port 8080 by default.
- On wrong usage, it prints the usage line and exits with status 0. A port
  that isn't a number from 0 to 65535 ends it with an error.
- It reads files from `<dir>`. It prints the address and each 404 on
  stderr.

## Verification

- Run: `zig build serve`, then open http://localhost:8080.
- Run: `zig build test-web` to run the web version's tests, with Deno.
