# ga-tools

## Overview

`ga-tools-check` checks gasim against
[ga-tools](https://github.com/mschuldt/ga-tools), another toolchain for
the GA144. ga-tools' `ga` command compiles each program into a boot
stream for node 708. gasim boots node 708 from its ROM with that stream,
through a UART as on the evaluation board. The check then compares what
the program sends with its `\ expect:` line. It also compares each node's
RAM with what ga-tools compiled. Each program runs at 921600, 460800 and
115200 baud. [Building](../../docs/building.md) lists what the check
needs.

```bash
zig build ga-tools
zig build ga-tools -Dga=<path to ga> -Dga-rom=<disk or dump>
```

The build runs it as `ga-tools-check <ga> <rom> <program.ga>...`, with
`tests/ga-tools/words.ga` and `tests/ga-tools/row.ga`, from the
repository root.

## Interface

- `main.zig:main` checks each program at each baud in `main.zig:bauds`.
  It prints one line per check and exits with status 1 if any fails.
- `main.zig:check` runs `ga --bootstream 708 --baud <baud> --json` on one
  program, boots a `gasim.Chip` with a `gasim.Uart`, and compares the
  output and RAM. It returns a `main.zig:Result`.
- `main.zig:Compiled` holds the parts of ga-tools' JSON that are checked:
  each node's RAM and the boot stream.
- `main.zig:expectedWords` reads the words after `\ expect:` in a
  program's source.
- `main.zig:decode` reads what the program sent, as ga-tools' host side
  does.
- `main.zig:readRom` loads the ROM from a `.blk` disk, which it assembles,
  or from a ROM dump.

## Invariants

These are the rules that the code relies on, and that a change must keep.

- Each program needs a line such as `\ expect: 0x7c 3`. Without one, that
  program's checks fail.
- A program sends a byte of 0 and then a word in three bytes, lowest
  first. It sends a byte of 1 at the end. Any bytes after the end fail the
  check. The programs include `tests/ga-tools/serial.ga`, whose `send` and
  `done` words do this. The build doesn't run `serial.ga` as a program.
- Programs must not store into RAM, because the check compares RAM after
  they run.
- A run stops with a failure after twice the stream's time on the chip,
  plus a tenth of a second.
- With an empty `<rom>`, it looks for `rom/pFDISK.blk`, then the ROM gasim
  saved, `$XDG_DATA_HOME/gasim/ga144.txt` or
  `~/.local/share/gasim/ga144.txt`.
- The build runs it from the repository root, where `rom/pFDISK.blk` is
  looked for. It builds the tool with `ReleaseSafe`, as the streams at
  115200 baud run for seconds of the chip's time.

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- It runs ga-tools' `ga` command as a child process for each program and
  baud.
- It reads the programs and the ROM, and writes only to stdout and stderr.
- These end the whole run at once with status 1 (`main.zig:fatal`), not
  just one check:
  - no ROM is found, or a `<rom>` that was given is missing
  - a token on the `\ expect:` line is not a word
  - `ga` fails to start
- Neither CI nor `zig build test` runs this check, because it needs
  ga-tools and a ROM.

## Verification

- Run: `zig build ga-tools`
- The step fails at once if `ga` is not on PATH and `-Dga` is not given.
