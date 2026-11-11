# Scripting with the CLI

You can do everything the TUI does with commands alone. This is useful for
scripts, CI and AI agents.

gasim keeps the chip's state in a snapshot file. Each command that moves the
chip forward reads one snapshot and writes another. So a session is a list
of commands. You can repeat it, branch it, or go back by keeping the files.

For every command and option, see [Options](options.md).

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

1. `start` loads the program and saves a snapshot, without running it. Give
   the machine's options, such as `--rom` or `--board`, here. The snapshot
   remembers them.
2. `run` runs until the breakpoint, and saves where it stopped.
3. `show` looks at a snapshot without changing it.
4. `step` takes four steps of node 105.
5. `aforth` runs a line of arrayForth 3 on the chip.
6. `run` gives the chip input.
7. The last `run` goes back to `1.snap`, and runs to the third time the
   breakpoint is hit.

Breakpoints and watches belong to a command, not to a snapshot. To add or
remove one, give different options to the next command. To go past a stop,
use `--hits`, or run on from where it stopped.

## Conventions

- stdout is for data, and stderr for messages.
- A command refuses options it cannot use.
- With `--json`, stdout is one JSON object, such as:

  ```json
  {"stop":"breakpoint","node":"105","address":"003","steps":81,"time_ps":4500,"output":"Hi","snapshot":"b.snap"}
  ```

  An error is an object too: `{"stop":"error","message":"..."}`.
- In JSON, words are hex strings, as gasim writes them elsewhere. Counts are
  numbers. `output` has one character for each byte.
- A trace with `--json` is one line of JSON for each word.
- `aforth --json` says `done` or `error`. It gives the `output` of its
  words, the `console`'s output, and the `errors`, each apart.
- `aforth` reading a script, from a pipe or `-e`, writes errors to stderr. It
  exits 1 if a line failed. Its chip does not run on its own: see [The
  prompt and IDE](ROADMAP.md#the-prompt-and-ide).

See [Exit codes](options.md#exit-codes).

## Signals

SIGINT and SIGTERM stop a run as a breakpoint does. The run still writes
`--to`, its result, `--why` and `--stats`.

- If a run cannot stop within two seconds, such as one writing where
  nothing reads, it ends without those.
- A second signal within half a second counts as the same one, because
  `timeout` sends a signal twice. A signal after that ends gasim at once.
- In a build without libc, a run waiting for input ends at once, as does
  any run at a second signal.

## What the TUI does, as commands

| TUI | Command |
| --- | --- |
| pausing, running on | `run --from ... --to ...` |
| `s` `S` `n` `N` | `step`, `step --rounds`, `step --node`, `step --node --slot` |
| `z`, the history | an earlier snapshot |
| breakpoints and watches | options to the next command |
| typing in the console | `--input` |
| the map, node panel, memory and arrows | `show`, `show <node> --mem`, `show --ports` |
| the trace, `t` `o` `w` | `--trace`, `--trace-node`, `--trace-file` on the run that matters |
| the editor | `cf text`, editing the text, `cf pack --into` |
| `L` | `start` or `run` with `--load` |
| completing words | `WORDS` |
| `ctrl+d` | nothing: the end of input ends a run. A node never sees it, so a later command can give more input. |

`--pty` is the exception. `--to` refuses it, because gasim cannot save the
program on the other end of the pty.

### Handing a snapshot to the TUI

`gasim tui --from <snapshot>` opens a chip as a snapshot left it, paused on
the map. An agent can use this to hand a chip over for a person to look
around in.

The TUI and `aforth` simulate one chip, so they cannot open a snapshot of the
EVB002. Neither opens a snapshot with a serial port on stdin and stdout. The
TUI also cannot open one with a flash, SRAM or synchronous line, because it
could not undo steps with them.

## Snapshots

A snapshot holds:

- the nodes, ports and event queue
- what the console, UARTs, boot stream, synchronous line, flash, SRAM,
  SERDES links, reset lines and pins hold
- what the machine was started with: the chip or board, jumpers and
  attachments

The ROM is in the nodes' memory, so the snapshot holds it too.

arrayForth's bins and labels belong to the session, not the snapshot. To
use a program's labels with `aforth --from`, give the program's source too.

### Input

With `--from` or `--to`, `--input` is `none` unless you give it. A session
never waits on a terminal.

gasim reads all the input before the chip runs. The input goes with the
chip, after any input left from before. If a node has not read it yet when
the run stops, it reads it after the next `--from`. So a session runs the
same however fast its input comes.

### Limits

`--max-steps` counts from the snapshot. `--max-time` is the time on the
chip.

### Running in parts

Running to a snapshot and then on from it must give the same result as one
run. `run --to a`, stopped anywhere, then `run --from a --to b`, must match
one run step for step, in output, and down to the bytes of the snapshot.

A snapshot taken with `--input none` and given input later is a different
run. The input arrives then, at the node's time.

`src/snapshot.zig` tests this for the console. It has been checked by hand
for each device except the SRAM, whose words are tested on their own. Each
of these was split at nine places: a run through the console, a ring of
nodes, UARTs, the SERDES, the boot of 708, 300 and 705, and the EVB002's two
chips.

### How snapshots are written

`src/snapshot.zig` goes through the fields of each type. So a field added to
a node is saved without any more code.

- A field that does not belong in a snapshot, such as a pointer, is named in
  the type's `snapshot_skip`. A pointer that is not named there does not
  compile.
- The file starts with a hash of those fields. gasim refuses a snapshot from
  a version with other fields, rather than misread it.
- The chip's own fields are written by hand, because most are not state.
  When they change, `format_version` goes up.
- gasim writes a file beside its path, then moves it into place. So
  `--from a --to a` cannot lose `a`.

`--break` and `--watch` are parsed by `parseBreak` and `parseWatch` in
`src/cli/options.zig`. They return errors, so that commands typed in the TUI
can share them.

## colorForth as text

`cf text` and `cf pack` turn a file of blocks into text and back. Packing
what `cf text` wrote gives back the same bytes. This is true of all of
OkadWork.cf's source.

`cf text` leaves out empty blocks at the end. It also leaves out anything
after the zero cell that ends a block, and warns about it. See
[colorForth](colorForth.md#as-text).

## Tests

```
gasim test examples/test.zon
```

A spec is a ZON list of cases. Each case has a `.program`, and can have:

- `.name`
- `.args`, for `run`
- `.input`
- `.max_steps`
- `.stop`, such as `.breakpoint`, or `.hazard` with `--strict` in `.args`
- `.output`
- `.nodes`: each with a `.node` (as a string), the registers `.p` `.a` `.b`
  `.io` `.t` `.s` `.r` it should leave, and `.ram`, a list of `.address` and
  `.word`

The `.program` path is relative to the spec.

Each case runs as `gasim run --json --to` in its own process. Then `gasim
show --json` reads what it left. So any option for a program works in a
case, except `--pty` and `--from`.

`gasim test` exits 6 if any case fails. `zig build test` runs
`examples/test.zon`.

## Still to come

- Saving a snapshot from the TUI, as `:snap <file>`, with the `:` commands
  it shares with the CLI.
- A socket for sharing a running chip, between a person and an agent, or
  for looking at a run with `--pty`, which snapshots cannot do. `gasim tui
  --listen <path>` would take the same commands and answer with the same
  objects, such as `gasim --attach <path> step --node 105`. It would send one
  object per line, on a Unix socket whose permissions control access.

  This waits until someone needs it. Requests arrive while the chip runs, so
  they must land between frames, and stops become events to subscribe to.
  The GUI has its own loop, so it would come after the TUI.
