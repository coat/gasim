# Building

You need [Zig 0.17.0](https://ziglang.org/download/). The Nix dev shell
(`nix develop`) has Zig, SDL3, Deno and the benchmark tools.

## gasim

```bash
zig build -Doptimize=ReleaseFast
```

This puts `gasim` in `./zig-out/bin/`.

## The GUI

The GUI uses [dvui](https://github.com/david-vanderson/dvui) and SDL3. It is
built only when you pass `-Dgui`, which fetches them.

| Command | What it does |
| --- | --- |
| `zig build -Dgui` | builds `./zig-out/bin/gasim-gui` beside `gasim` |
| `zig build -Dgui run-gui` | builds and runs the GUI |
| `zig build -Dgui test-gui` | runs the GUI's tests in a hidden window |

On Linux, the build links the system's SDL3, which the Nix dev shell has.
To build SDL3 from source instead, as the releases do, add `-fno-sys=sdl3`.

## The web version

`zig build web` builds the web version into `./zig-out/web`.

`zig build test-web` runs its tests. They need [Deno](https://deno.com/).

## Tests

`zig build test` runs the tests, including the examples in
`examples/test.zon`.

Some tests need the GA144's ROM. They are skipped unless arrayForth 3's disk
is in `rom/pFDISK.blk`. See [ROM](rom.md#checking-the-arrayforth-3-assembler).

## Fuzzing

```bash
zig build test -Dfuzz --fuzz
```

This fuzzes the assemblers, and colorForth's blocks and images. It opens a
web page that shows coverage. Use `--fuzz=1M` to stop after a million inputs
each.

`-Dfuzz` builds the tests with LLVM, which the fuzzer needs to measure
coverage. The examples are the fuzzer's first inputs. So is arrayForth 3's
disk, if it is in `rom/`.

## Checking against ga-tools

`zig build ga-tools` checks gasim against
[ga-tools](https://github.com/mschuldt/ga-tools):

1. ga-tools' `ga` command compiles each program in `tests/ga-tools` into an
   async boot stream, at a few baud rates.
2. gasim boots node 708 from ROM with each stream, through a UART, as on the
   evaluation board.
3. The step checks the words each program sends, and checks each node's RAM
   against what ga-tools compiled.

It needs:

- `ga` on your `PATH`, or `-Dga=<path>`
- the ROM: `rom/pFDISK.blk`, the ROM gasim saved, or `-Dga-rom=<path>`
- Python 3.11 or older, because ga-tools' `--json` option fails on newer
  versions of `argparse`

Neither `zig build test` nor CI runs this step.

## Benchmarks

See [Benchmarks](benchmarks.md).
