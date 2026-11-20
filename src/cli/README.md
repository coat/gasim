# cli

## Overview

This folder is the `gasim` command. It reads the command line, builds a
chip from the core in [`src/`](../README.md), and then does one of these
things:

- runs or steps the chip, and reports how it stopped
- opens the terminal UI (TUI)
- opens the arrayForth 3 prompt
- runs spec tests
- converts colorForth block files

[docs/cli.md](../../docs/cli.md) and [docs/options.md](../../docs/options.md)
describe the commands and options for users. [docs/tui.md](../../docs/tui.md)
describes the TUI.

| File | What it does |
| --- | --- |
| `main.zig` | The entry point. Sends each command to its handler, and builds the machine for the commands that run a chip. |
| `options.zig` | Defines the commands, their options and help text, and parses the command line. |
| `report.zig` | Ends commands: prints errors, picks exit codes, and writes nodes, memory and ports as text or JSON. |
| `tui.zig` | The terminal UI, built on [libvaxis](https://github.com/rockorager/libvaxis). |
| `aforth.zig` | The arrayForth 3 prompt: reads lines from `-e`, from isocline, or from stdin. |
| `spec.zig` | Runs `gasim test` spec files. It runs gasim itself for each case. |
| `pty.zig` | Opens a raw pseudo-terminal (pty) for a board's serial port. |
| `isocline.zig` | Declares the isocline C functions that the prompt uses to edit lines. |

## Interface

### Commands

`options.zig:Command` lists the commands: `run`, `tui`, `aforth`,
`listing`, `start`, `step`, `show`, `blocks` (typed as `cf text`),
`cf pack`, `cf expand`, `test`, `help` and `version`.

`main.zig:main` handles `help`, `version`, `cf pack`, `cf expand` and `test`
itself. It sends every other command to `main.zig:simulate`.

`--listing` anywhere on the command line turns the command into `listing`
(`options.zig:parse`).

### Entry points

- `main.zig:main` parses the command line, runs the command, and returns
  the exit code.
- `main.zig:simulate` builds the machine from a snapshot or from the
  options: the board, chip, ROM and program. Then it chooses how the
  program boots, attaches the devices, and runs the command.
- `main.zig:startOf` chooses how the program gets into the chip: direct,
  flash, UART, sync or SERDES.
- `main.zig:readRom` finds the ROM. With `--rom`, it reads that dump or
  disk, or looks for a disk in that folder. If that fails, gasim ends with
  an error. Without `--rom`, it tries the saved `ga144.txt`, then
  arrayForth 3 where it is usually installed.
- `main.zig:packText`, `main.zig:expandImage` and `main.zig:writeBlocks`
  run the `cf pack`, `cf expand` and `cf text` commands.
- `main.zig:writeListing`, `main.zig:show`, `main.zig:stepChip` and
  `main.zig:runAforth` run the `listing`, `show`, `step` and `aforth`
  commands.
- `options.zig:parse` turns the arguments into `options.zig:Options`. It
  ends the process with a usage error if anything is wrong.
- `options.zig:helpText` returns the help text for a command, or the
  general help.
- `report.zig:fatal` and `report.zig:usage` print an error and exit with
  status 1 or 2.
- `report.zig:Stop` says how a run ended. `report.zig:Stop.status` turns it
  into an exit code.
- `tui.zig:run` starts the TUI and runs its event loop until the user
  quits.
- `aforth.zig:run` runs the arrayForth 3 prompt. It returns whether any
  line failed.
- `aforth.zig:interpret` interprets one line, then writes ` ok` or the
  error.
- `spec.zig:run` runs every case in the spec files. It returns 6 if any
  case failed.
- `pty.zig:open` opens a raw pty, and `pty.zig:close` closes it.
  `pty.zig:writeOut` writes the chip's output to it.

### Exit codes

| Code | Meaning | Where |
| --- | --- | --- |
| 0 | The chip settled, or the steps asked for were taken. | `report.zig:Stop.status` |
| 1 | An error. | `report.zig:status_error` |
| 2 | A usage error. | `report.zig:status_usage` |
| 3 | A breakpoint was hit. | `report.zig:Stop.status` |
| 4 | A watch was hit. | `report.zig:Stop.status` |
| 5 | A step or time limit was reached. | `report.zig:Stop.status` |
| 6 | A spec case failed. | `spec.zig:status_failed` |
| 7 | A hazard stopped the chip. | `report.zig:Stop.status` |
| 128 + signal | A signal stopped the run. | `report.zig:Stop.status` |

## Invariants

These are the rules that the code relies on, and that a change must keep.

- `options.zig:parse` refuses any option that the command does not act on,
  so no option is quietly ignored. The `flags` table lists the commands
  that each option goes with.
- With no command, `options.zig:commandOf` picks `tui` when stdin and
  stdout are a terminal, and `run` when they are not. `main.zig:main`
  refuses `tui` when they are not a terminal.
- With `--from`, the options that build the machine are refused, because
  the snapshot already describes the machine (`options.zig:parse`).
- `main.zig:max_source_len` limits `.ga` and `.af` sources to 64 KiB.
  `main.zig:max_blocks_len` limits block files to 64 MiB.
  `main.zig:max_snapshot_len` limits snapshots to 256 MiB.
- `main.zig:readSnapshot` refuses a snapshot from another version of gasim.
- `main.zig:Ptys` keeps pointers to its own fields, so it must not move
  after it is opened.
- `main.zig:handleInterrupt` treats a second signal within 500 ms
  (`main.zig:repeat_ms`) as the same signal. This needs pty support. After
  2 seconds (`main.zig:signal_grace`), `main.zig:endOnInterrupt` restores
  the default handler and raises the signal again.
- `tui.zig:Tui.run` steps the chip for at most 15 ms per frame
  (`tui.zig:frame_budget`). It checks the clock every 256 rounds.
- The TUI can go back at most 64 times (`tui.zig:history_capacity`). One
  `:step` command takes at most 1,000,000 steps
  (`tui.zig:max_command_steps`).
- A line read from stdin can be at most 4,096 bytes
  (`aforth.zig:max_line`). A longer line fails, and the prompt goes on.
- `pty.zig:supported` is true only when gasim links libc on Linux, macOS or
  BSD. Otherwise `--pty` is refused.
- When the pty's output queue is full, `pty.zig:send` drops bytes and counts
  them, instead of blocking the chip.

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- Files that gasim reads and writes outside the working folder:

  | File | Who uses it |
  | --- | --- |
  | `$XDG_DATA_HOME/gasim/ga144.txt`, or `~/.local/share/gasim/ga144.txt` | `main.zig:readRom` saves the ROM it assembled here, and reads it next time. |
  | `$XDG_STATE_HOME/gasim/history`, or `~/.local/state/gasim/history` | `main.zig:historyPath` creates the folder. isocline keeps the prompt's line history in the file. |
  | arrayForth 3's disk under `C:\GreenArrays`, `$WINEPREFIX/drive_c/GreenArrays` or `~/.wine/drive_c/GreenArrays` | `main.zig:installedDisk` looks for the ROM source here. |

- `main.zig:writeSnapshot` writes `<path>.tmp` first, then renames it over
  the `--to` path.
- `main.zig:makeLink` creates the symbolic links that `--pty name=link`
  asks for. `main.zig:removeLinks` removes them, but only while they still
  point at their pty.
- `main.zig:simulate` installs a handler for SIGINT and SIGTERM. It also
  starts tasks that read stdin, or the `--input` file, and the ptys.
- `main.zig:panic` calls `vaxis.recover` to restore the terminal before it
  panics.
- `tui.zig:run` takes over the terminal: it opens the alternate screen and
  turns on the mouse.
- `tui.zig:Tui.saveTrace` writes `trace.txt` in the working folder.
  `tui.zig:Tui.save` writes the colorForth blocks being edited.
- `spec.zig:run` writes temporary files to `$TMPDIR` or `$TEMP` (default
  `/tmp`), runs gasim for each case, and deletes the files.
- `pty.zig:open` calls libc's `posix_openpt`, `grantpt`, `unlockpt` and
  `ptsname`, and sets the terminal side to raw mode.
- `report.zig:json` and `report.zig:io` are global. With `--json`, errors
  go to stdout as JSON objects. Otherwise they go to stderr.

## Verification

- Run the unit tests: `zig build test`. This builds the tests from
  `main.zig` and every file it imports. It also runs `gasim test` on
  `examples/test.zon`.
- Build without isocline, which needs no libc: `zig build -Disocline=false`
