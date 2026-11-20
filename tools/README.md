# tools

## Overview

This folder holds the developer tools that the build runs. Each tool is a
small Zig program with one `main.zig`. Each tool has its own `zig build`
step, except `examples`, which the `web` step runs. None of them is part
of gasim itself, and `zig build test` does not run them.
[Building](../docs/building.md) explains the build and its steps.

| Tool       | Step                                | What it does                                       |
| ---------- | ----------------------------------- | -------------------------------------------------- |
| `bench`    | `zig build bench`                   | Times gasim on fixed workloads                     |
| `bins`     | `zig build bin-digests -- <OBJ-AF3>` | Prints the list for `src/af3-bins.zon`             |
| `examples` | `zig build web`                     | Writes the web version's list of examples          |
| `ga-tools` | `zig build ga-tools`                | Checks gasim against ga-tools' boot streams        |
| `serve`    | `zig build serve`                   | Serves the web version on localhost                |

## Folders

- [`bench`](./bench/README.md) builds gasim with ReleaseFast and times it
  on five workloads, against another git ref if you give one. It writes
  into `.zig-cache/bench`. See [Benchmarks](../docs/benchmarks.md).
- [`bins`](./bins/README.md) prints the SHA-256 of each bin of code in
  arrayForth 3's `OBJ-AF3`. You send its output to `src/af3-bins.zon`. The
  ROM tests check the stock code against it.
- [`examples`](./examples/README.md) writes the examples in `examples/`
  and their descriptions as `index.json`, for the web version's Examples
  menu. It uses `src/examples.zig:list`.
- [`ga-tools`](./ga-tools/README.md) boots node 708 with boot streams that
  ga-tools compiles from `tests/ga-tools`. It checks what they send and
  what each node's RAM holds. It needs ga-tools and a ROM.
- [`serve`](./serve/README.md) serves `zig-out/web` on 127.0.0.1, port
  8080 by default.

## Shared rules

- The build runs `bench` and `ga-tools` from the repository root, so
  their paths are relative to it.
- The build gives `examples` and `serve` their folders. You give `bins`
  its file, and `serve` its port, after `--`.
- Only `ga-tools` imports gasim's core (`src/root.zig`). `examples`
  imports `src/examples.zig`, which brings in `src/colorforth.zig`. The
  others use only Zig's standard library.
