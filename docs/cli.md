# The CLI without the TUI

An agent, a script or CI should be able to do everything the TUI does, with
commands alone. The chip's state is a file: each command that advances the
chip reads one snapshot and writes another, so that a session is a series of
commands that can be repeated, branched and gone back on by keeping the files.

## Commands

```
gasim [file]                     the TUI on a terminal, and otherwise run
gasim tui [file]                 the TUI, on a terminal
gasim help [command]             as does --help on any command
gasim version

Source
gasim listing <source>           each node's words, as --listing does
gasim cf text <file.cf>          the source in blocks as text, as blocks does
gasim cf pack <text|-> -o <file.cf>
                                 text as blocks, creating the file
    --into <file.cf>             replacing only the blocks the text names
gasim cf expand <image> -o <file.cf>
                                 an arrayForth 2 image, decompressed

Running, which writes state
gasim start <source> -o <snapshot>
                                 load the program, taking no steps
gasim run <source> | --from <snapshot> [--to <snapshot>]
gasim step --from <snapshot> --to <snapshot> [--node <n>] [--count <n> | --rounds <n>]
gasim aforth [source] [--from <snapshot>] [--to <snapshot>] [-e <line>]...

Looking, which does not
gasim show <snapshot>            every node: status, P, what it waits on
gasim show <snapshot> <node>...  registers, stacks, time, slot and carry
    --mem [--rom-words] [--at <a> --count <n>]
                                 words, with their disassembly
    --ports                      what the ports are doing, as the map shows

Checking
gasim test <spec.zon>...         the output and node state a run should leave
```

| Options | | With |
| --- | --- | --- |
| The machine | `--chip` `--layout` `--board` `--jumper` `--rom` `--console` `--boot` | `start`, and `run`, `aforth` and `tui` from source; a snapshot holds them |
| Its serial ports | `--uart` `--usb` `--flash` | `start`, `run` |
| Its ptys | `--pty` | `run` |
| Blocks | `--load` | with a program |
| Stops | `--break` `--watch` `--hits <n>` | `run`, `step` |
| Limits | `--max-steps <n>` `--max-time <ps>` | `run` |
| Input | `--input <file\|-\|none>` | `run`, `step` |
| Output | `--show <nodes>` `--why` `--stats` `--trace` `--trace-node <n>` `--trace-file <file>` | `run`, `step` |
| | `--json` | every command but `tui`, `listing`, `cf text`, `help` and `version` |

Breakpoints and watches belong to a command rather than to a snapshot, so
adding or removing one is passing other options to the next command. Going
past a stop is `--hits`, or running on from where it stopped.

`--break` and `--watch` take what `parseBreak` and `parseWatch` in
`src/cli/options.zig` read, which return errors, for commands typed in the TUI
to share.

## Conventions

- stdout is data, and stderr diagnostics.
- With `--json`, stdout is one object, such as
  `{"stop":"breakpoint","node":"105","address":"003","steps":81,"time_ps":4500,"output":"Hi","snapshot":"b.snap"}`,
  and an error is an object too: `{"stop":"error","message":"..."}`.
  A trace is a line of JSON for each word. Words are hex in strings, as gasim
  writes them elsewhere, counts are numbers, and output has a character for
  each byte. `aforth` says `done` or `error`, with its `output`, the
  `console`'s, and `errors`, which keeps them apart.
- A command takes only the options it can act on, and refuses the rest.
- `aforth` reading a script, from a pipe or `-e`, writes errors to stderr and
  exits 1 if a line failed. Its chip does not run on its own: see
  [The prompt and IDE](ROADMAP.md#the-prompt-and-ide).
- SIGINT and SIGTERM stop a run as a breakpoint does: it still writes `--to`,
  its result, `--why` and `--stats`. A run that cannot stop in two seconds,
  such as one writing where nothing reads, ends without them. A signal again
  within half a second is the same one, as `timeout` sends a signal twice, and
  a later one ends gasim at once. Built without libc, a run waiting for input
  ends at once, as does one at any second signal.

| Exit status | |
| --- | --- |
| 0 | settled: every node is waiting, with nothing more to come, or `step` took the steps it was asked to, which says `"stop":"step"` |
| 1 | an error |
| 2 | wrong usage |
| 3 | a breakpoint |
| 4 | a watch |
| 5 | a limit: `--max-steps` or `--max-time` |
| 6 | `gasim test` found a difference, and says `"stop":"failed"` |
| 130, 143 | SIGINT, SIGTERM |

## A session

```sh
gasim start prog.ga --rom rom.txt -o 0.snap
gasim run --from 0.snap --to 1.snap --break 105:003 --max-steps 1000000 --input none --json
gasim show 1.snap 105 --mem --json
gasim step --from 1.snap --to 2.snap --node 105 --count 4 --json
gasim aforth --from 2.snap --to 3.snap -e '105 NODE 5. LIT'
printf 'hi\n' | gasim run --from 3.snap --to 4.snap --input - --json
gasim run --from 1.snap --to 5.snap --break 105:003 --hits 3 --json   # back to 1.snap
```

## What the TUI does, as commands

| TUI | Command |
| --- | --- |
| pausing, running on | `run --from ... --to ...` |
| `s` `S` `n` | `step`, `step --rounds`, `step --node` |
| `z`, the history | an earlier snapshot |
| breakpoints and watches | options to the next command |
| typing in the console | `--input` |
| the map, node panel, memory and arrows | `show`, `show <node> --mem`, `show --ports` |
| the trace, `t` `o` `w` | `--trace`, `--trace-node`, `--trace-file` on the run that matters |
| the editor | `cf text`, editing the text, `cf pack --into` |
| `L` | `start` or `run` with `--load` |
| completing words | `WORDS` |

`--pty` is the exception: `--to` refuses it, as the host on the other end of
the pty cannot be saved.

`ctrl+d` needs no command: the end of input ends a run, and a node never
sees it, so a later command can give more.

`gasim tui --from <snapshot>` opens a chip as a snapshot left it, on the chip
screen and paused, so that an agent can hand one over for a person to look
around in. Saving one from the TUI, as `:snap <file>`, is left for the `:`
commands the TUI shares with these, which take the same names and arguments.
The TUI knows one chip, so it does not open a snapshot of the EVB002, and
neither does `aforth`. Neither opens one with a serial port on stdin and stdout,
and the TUI does not open one with a flash, SRAM or synchronous line, which it
could not go back with.

## Snapshots

A snapshot holds the nodes, ports and queue, what the console, UARTs, boot
stream, synchronous line, flash, SRAM, SERDES links, reset lines and pins
hold, and what the machine was started with: the chip or board, jumpers and
attachments. ROM is in the nodes' memory.

`src/snapshot.zig` goes over the fields of each type, so a field added to a
node is saved with no more said. A field that does not belong, such as a
pointer, is named in the type's `snapshot_skip`, and a pointer that is not does
not compile. A hash of those fields starts the file, so one from a gasim with
other fields is refused rather than misread. The chip's own fields are written
by hand, as most are not state: `format_version` is raised when those change.
A file is written beside its path and moved there, so `--from a --to a` cannot
lose `a`. `--max-steps` counts from the snapshot, and `--max-time` is the time
on the chip.

With `--from` or `--to`, `--input` is `none` unless it is given, as a session
never waits on a terminal, and is read to its end before the chip runs. What
it gives goes with the chip, after what was left: a node that has not read it
yet reads it after the next `--from`, whatever stopped the run, so a session
runs the same however fast its input comes.

arrayForth's bins and labels are the session's, and not in a snapshot:
`aforth --from` can be given source alongside, for its labels.

`run --to a` stopped anywhere and then `run --from a --to b` must end as one
run does, step for step and in output, down to the bytes of the snapshot.
A snapshot taken with `--input none`, and given input later, is another run:
it arrives then, at the node's time.
`src/snapshot.zig` tests that of the console. It has been checked by hand of
each device but the SRAM, whose words are tested apart: a run through the
console, a ring of nodes, UARTs, the SERDES, 708's, 300's and 705's boot, and
the EVB002's two chips, each split at nine places.

## colorForth as text

`cf text` and `cf pack` make the source in a file of blocks and its text the
same thing: packing what `cf text` wrote gives back the same bytes, as it does
for all of OkadWork.cf's source. Empty blocks at the end are left out, and so
is anything after the zero cell that ends a block, which `cf text` warns of.
See [colorForth](colorForth.md#as-text).

## Tests

```
gasim test examples/test.zon
```

A spec is a ZON list of cases, each with a `.program` and any of `.name`,
`.args` for `run`, `.input`, `.max_steps`, `.stop`, `.output` and `.nodes`.
A case runs as `gasim run --json --to` in a process of its own, and `gasim show
--json` reads what it left, so any option for a program works in one, but not
`--pty` or `--from`. `zig build test` runs `examples/test.zon`.

## Still to come

- Saving a snapshot from the TUI, with the `:` commands it will share with
  these.
- A socket for sharing a chip that is running. `gasim tui --listen <path>`
  would take the same commands and answer with the same objects, as `gasim
  --attach <path> step --node 105`, one object to a line on a Unix socket,
  whose permissions are its access control. That is for a person and an agent
  at the same chip, and for looking at a run with `--pty`, which snapshots
  cannot do. It waits until one of those is wanted: requests arrive while the
  chip runs, so they must land between frames, and stops become events to
  subscribe to. The GUI has a loop of its own, and would come after the TUI.
