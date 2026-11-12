# Benchmarks

`zig build bench` builds gasim with `-Doptimize=ReleaseFast` and times it on
the workloads in `tools/bench`:

| Workload | What it does |
| --- | --- |
| `compute` | one node running opcodes, with no ports |
| `ring` | a token passed around a ring of 36 nodes |
| `upcase` | 1 MiB of text through the console and `examples/upcase.ga` |
| `boot` | the ring, booted through the UART and node 708's ROM, then run |
| `serial` | 64 KiB through the UART on node 708, a bit at a time |

`boot` needs the ROM, and is skipped without it. It has no console to print
to, so its output is not compared.

To run only some workloads, name them: `zig build bench -- ring`.

## Comparing with another version

`-Dbench-base=<ref>` also builds gasim from another git ref, such as `main`.
The benchmark then compares the two, and checks that they print the same
output.

```bash
zig build bench -Dbench-base=main
```

## Timing tools

The benchmark uses the first of these that it finds:

1. [poop](https://github.com/andrewrk/poop), which counts instructions.
   Instruction counts barely change between runs, unlike wall time.
2. [hyperfine](https://github.com/sharkdp/hyperfine).
3. Its own timer, over five runs.

The Nix dev shell has hyperfine, and poop on Linux.

## Disk space

Builds and inputs go in `.zig-cache/bench`. Each base ref's build is kept
there, and takes a few hundred MB. Delete the directory to free the space,
or to rebuild the base, such as after you upgrade Zig.

## Steps per second

For a quick measure without the benchmark, use `--stats`:

```
$ gasim run --stats tools/bench/ring.ga > /dev/null
info: 7300937 steps in 0.344 s, 21.2M steps/s, and 44.882 ms of the chip's time
```

See [`--stats`](options.md#debugging) for what a step is.
