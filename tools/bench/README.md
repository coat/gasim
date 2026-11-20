# bench

## Overview

`bench` times gasim on a fixed set of workloads. It builds gasim with
`-Doptimize=ReleaseFast` from the working tree. With `-Dbench-base=<ref>`,
it also builds gasim from another git ref and compares the two. It times
each workload with poop, then hyperfine, or else with five runs of its own.
[Benchmarks](../../docs/benchmarks.md) explains how to use it and read the
results.

```bash
zig build bench                       # all workloads
zig build bench -- ring serial        # only some
zig build bench -Dbench-base=main     # compare with main
```

The build runs it as
`bench <zig> <work dir> <base ref> <poop> <hyperfine> [workload...]`.
The base ref, poop and hyperfine are empty arguments when there are none.

## Interface

- `main.zig:main` reads the arguments, builds gasim, and runs each chosen
  workload. It exits with status 1 if a build or a run fails.
- `main.zig:Workload` describes one workload: its `name`, what it measures
  (`about`), its `program`, the bytes of generated `input`, the `options`
  for `gasim run`, and whether it needs a ROM (`rom`).
- `main.zig:workloads` lists the five workloads:

  | Name      | Program, from the repository root           | What it measures                                  |
  | --------- | ------------------------------------------- | ------------------------------------------------- |
  | `compute` | `tools/bench/compute.ga`                    | one node's opcodes, with no ports                 |
  | `ring`    | `tools/bench/ring.ga`                       | port transfers around 36 nodes                    |
  | `upcase`  | `examples/upcase.ga`                        | 1 MiB through the console and two nodes           |
  | `boot`    | `tools/bench/ring.ga`, `--uart 708 --boot`  | the ring booted through the UART and 708's ROM. It needs a ROM, and prints nothing. |
  | `serial`  | `tools/bench/serial.ga`, `--uart 708`       | 64 KiB through the UART to node 708, a bit at a time |

- `main.zig:buildBase` builds gasim from a base ref's commit, unless it is
  already built.
- `main.zig:generateInput`, `main.zig:writeScript`, `main.zig:runScript`,
  `main.zig:timeRuns` and `main.zig:spawn` make the input, write each
  workload's shell script, run it once, and time it.
- `compute.ga`, `ring.ga` and `serial.ga` are the workloads' programs.
  Each starts with a comment that says what it does.

## Invariants

These are the rules that the code relies on, and that a change must keep.

- Workload names must be unique. `main` rejects an unknown name and lists
  the valid ones, so keep that message in step with `workloads`.
- `generateInput` uses a fixed seed (`0x6a5`), so the input is the same on
  every run. Comparisons with a base ref depend on this.
- The first run of each script checks that the base ref's gasim prints the
  same output as this one. It prints a warning if they differ. `boot` has
  no console, so for it this check compares nothing.
- Only this gasim's run gets `--stats`, as a base ref's gasim may not have
  that option.
- A workload with `rom = true` is skipped, not failed, when gasim says it
  "needs a ROM". See [The ROM](../../docs/rom.md).
- poop and hyperfine split commands at spaces, so the work dir's path must
  have no spaces when either is used.
- The build runs `bench` from the repository root, as the programs' paths
  are relative to it.

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- It writes into `.zig-cache/bench`:

  | Path | What it holds |
  | --- | --- |
  | `head/` | this tree's build, from `zig build --prefix` |
  | `base-<commit>/` | a base ref's build, reused on later runs |
  | `input-<len>.txt` | the generated input, reused if its size is right |
  | `<workload>-<head or base-commit>.sh` | the script that each timing runs |
- It runs `zig build`, `git rev-parse`, `git archive` and `tar` as child
  processes. It runs poop or hyperfine too, when they are on PATH.
- It prints results on stdout and progress on stderr.

## Verification

- Run: `zig build bench`
- `zig build test` does not cover this tool.
