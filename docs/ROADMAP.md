# gasim roadmap

The goal is a small, fast, dependency-light GA144 simulator that is useful
with real hardware and fun to play with. It assembles GreenArrays' current
arrayForth 3 source into the same object code their tools make, and reads,
edits and compiles colorForth. It should be good enough to work through
AshleyF's
[Chuck Moore's Creations](https://github.com/AshleyF/Color/blob/master/Docs/chuck_moores_creations.md)
series, and, further on, to stand in for GreenArrays' EVB002 evaluation board
well enough that their own tools and polyFORTH run on it.

It serves two kinds of use, without either making the other slower or
harder to use:

1. **An environment for F18 programs:** writing, assembling, running and
   debugging them, with the console to talk to the host. This should be as
   fast as gasim can be, and need nothing about boards.
2. **A stand-in for a real board:** pins, devices and timing accurate enough
   that software written with GreenArrays' tools, gasim's, or
   [ga-tools](https://github.com/mschuldt/ga-tools) (whose formats gasim
   should read where it can) behaves as it would on an EVB002. Only this
   pays for keeping time.

Everything should also work without a terminal, so that an agent, a script
or CI can write programs and assemble, run, test and debug them with CLI
commands alone (see [The CLI without the TUI](#the-cli-without-the-tui)).

## Where things stand

- **The F18A computer:** all 32 opcodes, stacks, the memory map, extended
  arithmetic and per-opcode timing. Instruction words are XORed with `x15555`
  as on real hardware.
- **The chip:** any `RxC` layout (8x18 by default) with GA144 port naming, a
  run-queue scheduler, ROM from a dump of a real chip or assembled from
  arrayForth 3's `pFDISK.blk` (every node's ROM matches a G144A12's), reset
  into warm or cold, and boot streams through node 001's SERDES port
  (`--boot`).
- **gasim's own assembler** (`src/assembler.zig`): `node` directives, ROM
  words, every control word, `..` and `<sl`, listings.
- **arrayForth 3** (`src/arrayforth.zig`): `.af` text and `.blk` block disks,
  bins, boot descriptors, host definitions and control flow, and the IDE's
  target words acting on the chip directly. 105 RAM bins match `OBJ-AF3`. No
  GreenArrays source is vendored. `gasim aforth` is its prompt, with line
  editing, and the TUI, GUI and web version have an aforth panel.
- **colorForth** (`src/colorforth.zig`, `src/Editor.zig`): packed blocks and
  arrayForth 2's compressed `.cf` images round-trip byte for byte, the
  compiler drives the same session as arrayForth 3, and there is a vim-like
  block editor.
- **The debugger:** breakpoints, port watches, a trace log, `--why`, and
  snapshots to go back before steps and runs.
- **Front ends:** the TUI (libvaxis), a dvui desktop GUI (`-Dgui`), and a web
  version built from the same core for wasm.
- **Fuzzing** of the assemblers and colorForth's blocks and images
  (`-Dfuzz`).
- **The EVB002, begun** (PR #33): node times in picoseconds, synced as words
  pass between neighbours; pin 17 wakeup; a UART on node 708's pins
  (`--uart`), inverted as the board's FTDI chips are; and async boot of 708
  from its ROM through it.

## Architecture

```
          ┌──────────────────── host (std.Io, allocators, OS) ──────────────────┐
          │  CLI runner   aforth (isocline)   TUI (libvaxis)   GUI (dvui)   web  │
          │      └──────────┬───────┴────────────────┬──────────────┘           │
          │      devices (Console, UART; later SPI flash, SRAM, VGA…)            │
          └─────────────────┼────────────────────────┼───────────────────────────┘
                            │                        │
          ┌─────────────────┴── core (no I/O, no allocation) ───────────────────┐
          │  Chip: nodes, ports, scheduler, layout, snapshots                   │
          │  Computer (F18A)   Port (rendezvous)   boot streams                 │
          │  Builder ← gasim assembler, arrayForth 3, colorForth                │
          └─────────────────────────────────────────────────────────────────────┘
```

### Core rules

- **No I/O and no allocation in the core.** It works on caller-provided
  memory and `std.Io.Reader` and `std.Io.Writer` interfaces, so the same code
  builds for native, tests and wasm. `main.zig`, `tui.zig`, `aforth.zig` and
  the GUI and web front ends are the host side.
- **No libc in the core.** Only the executable links libc, for isocline, and
  `-Disocline=false` builds without it.
- **Deterministic.** The same program and the same input always produce the
  same trace, which keeps stepping, breakpoints, golden traces and going back
  simple.
- **Front ends share one backend.** `Builder` packs words, slots, literals and
  jumps, with options for arrayForth 3's packing. gasim's syntax, arrayForth
  3 and colorForth are front ends over it.

### Concurrency and time

Nodes are explicit state machines stepped by a cooperative scheduler, not
`std.Io` tasks: a debugger has to pause and step single nodes, threads make
runs non-deterministic, and fibers are not available on wasm. A node waiting
on a port is suspended and costs nothing until a port operation wakes it.
`std.Io` belongs at the host edge: files, the console, the UI event loops.

Ports are blocking rendezvous, so a program that only talks through ports
computes the same thing in any order of stepping, and simulated time cannot
change its output. Time matters only when something watches it: a pin and
the device on its other end.

- **Programs (use 1):** the console, a convenience device with no
  counterpart on a real board (like semihosting), on a port facing off the
  chip, a byte per word.
- **The board (use 2):** pins wired to devices that keep real time (the UART
  today; SPI flash, SRAM and VGA later).

Both run the same way: each node's time counts, nodes take the later of
their times as a word passes between them, and the node furthest behind
steps next, its queue a heap ordered by time. For a while only board mode,
with a timed device such as `--uart`, did so, and the console stepped
round-robin without syncing times; once measured, that saved 3–7% of
instructions on console runs, which did not pay for two schedulers, and
node times that meant something different in each.

## Next: the EVB002

The aim is that GreenArrays' arrayForth 3 drives a simulated EVB002 as it
drives the real one, and then that pF/144, their polyFORTH, runs on the
simulated chip with `20 DRIVE HI AFORTH` at its prompt. ✓ marks what PR #33
did.

1. **Chip and board files.** A chip file gives the size and, per node, the
   ROM type, pins, buses and reset address, and the GA144 becomes the default
   chip file instead of code (`ga144.zig`). A board file lists the chips, the
   connections between pins, devices and other chips, pull-ups and jumpers.
   Ship `ga144` and `evb002`. ZON, read on the host side, so the core still
   does no allocation. Custom layouts would get no pins unless their file
   declares them, which changes how they behave today.
2. **A shared clock.**
   - ✓ Each node's time in integer picoseconds, and neighbours taking the
     later of their times as a word passes between them.
   - ✓ Running fast again. Most of the cost of the time sync turned out
     to be copying each node, RAM and all, on every fetch from memory,
     through a method that took the node by value; without that, the
     benchmarks run 9–23% fewer instructions than before.
   - ✓ Stepping the node furthest behind in time, benchmarked against
     round-robin: the same output and chip time on the UART workloads.
     Round-robin retries a waiting node once a round however many of its
     ports changed, while furthest behind first would retry it at once on
     each change, as it is behind, which cost 15% more instructions on
     `boot`. So a change wakes a waiting neighbour only when it lets it go
     on (`Computer.retryWaits`).
   - ✓ Instruction times from the G144A12's data book (DB002 §5.3),
     including the time to fetch each word, and 2.4 ns per `unext`, as
     ga-tools takes it, rather than DB001's approximate 2.0.
3. **Pins and devices.**
   - ✓ Pin 17 wakeup (DB001 §3.4.1), and a bit-level UART on stdin and
     stdout (`--uart`).
   - ✓ Pins read and driven at the node's time as it reads or writes io,
     not at the start of the word, which can run a long `unext` loop
     first, as a bit loop usually does.
   - Pins as connections with drivers: node outputs, devices and pull-ups.
   - The UART on a pty, TCP or the TUI; SPI flash backed by a file; the 2 MB
     SRAM on 007, 008 and 009; reset lines; the analog nodes' outputs.
   - Pin activity dumped as VCD files for GTKWave.
   - The console stays, for playing and debugging.
   - The UART's state in snapshots, and a UART in the TUI, GUI and web.
4. **The real boot paths.**
   - ✓ Async boot of node 708 from its ROM, through the UART (`--boot
     --uart 708`, or any stream on stdin).
   - ✓ Streams made by [ga-tools](https://github.com/mschuldt/ga-tools)
     booting 708 (`zig build ga-tools`): a check that doesn't involve
     GreenArrays' code.
   - SPI boot through 705's ROM, and two chips over SERDES and 300↔300.
5. **arrayForth 3 under Wine, driving gasim.** The board's USB ports A, B and
   C as ptys, mapped to Wine COM ports, so that the unmodified
   `sF5b2-af3.exe` boots the chip, runs its IDE and burns flash. Risk:
   arrayForth 3 resets the chip with RTS on port A, which ptys don't carry,
   so that needs a workaround (tty0tty, a reset command, or a break). This
   proves the board model against the real tools.
6. **pF/144 in the simulator.** Its nucleus in the simulated SRAM, booted by
   the streamer in block 1665 (run by gasim's arrayForth, or captured from
   step 5), with `pFDISK.blk` served as the serial disk its terminal emulator
   normally provides (DB006 §5.5). Its license only covers GreenArrays'
   chips, so it stays bring-your-own-distribution, and GreenArrays should be
   asked first. gasim would never ship it.

Later: the target chip driven from pF/144's IDE (`HOST`, `TARGET`,
`BRIDGE`); eForth, which the EVB001 shipped in flash, as arrayForth 2's
counterpart; and a board and pin view in the TUI, GUI and web.

### VGA

The EVB001 and EVB002 have a site for a VGA connector (J70, DB014 §7.4.3)
whose RED, GREEN, BLUE, HSYNC and VSYNC lines are left for jumpers. The
analog nodes 709, 713 and 717 suit the colours, and GPIO pins the syncs.
Emulating it needs the board file's wiring, the analog outputs and the shared
clock, then sampling the levels at each node's time, finding frames from the
syncs, and painting them in the GUI and web (and roughly in the TUI, with
half blocks). A pixel at 640x480 lasts about 40 ns, around 25 instructions,
so expect a few frames a second, which is enough for AshleyF's bouncing
ball.

## Other work

### Benchmarks

The time sync made long runs slower, and the scheduler will cost more, so
regressions need catching with consistent numbers:

- ✓ `zig build bench`: ReleaseFast, on a fixed set of workloads in
  `tools/bench`: one node computing, a ring of 36 nodes, and 1 MiB through
  `upcase.ga`.
- ✓ Comparing with another git ref (`-Dbench-base=<ref>`), with
  [poop](https://github.com/andrewrk/poop) (instructions, cycles and cache
  misses, which vary far less than wall time; Linux only), falling back to
  [hyperfine](https://github.com/sharkdp/hyperfine) elsewhere.
- ✓ Steps per second from gasim itself (`run --stats`), as `Chip.steps` is
  deterministic.
- ✓ Workloads on the UART: a `--boot` stream and a long UART stream.
- Wall time stays out of CI, where shared runners are too noisy; instruction
  counts could gate later.

### The CLI without the TUI

An agent should be able to do everything the TUI does without one. What the
CLI lacks today:

- **Limits:** a step or simulated-time limit for `run`, as a program that
  never settles runs until it is killed.
- **State:** dumping nodes' RAM, stacks and registers when a run stops, for
  any node, not only one at a breakpoint.
- **Going on:** continuing past breakpoints and watches, a given number of
  times, and stepping a node a given number of steps.
- **Snapshots:** saving the chip to a file when a run stops, and starting a
  run from one, as the TUI goes back in memory.
- **Machine-readable output:** JSON for listings, traces, `--why` and state,
  and exit codes that say how a run ended (settled, breakpoint, watch,
  limit, error).
- **colorForth:** `gasim blocks` writes a `.cf` file's source as text; the
  reverse would let an agent edit colorForth as text.
- **Tests:** a way to state what a run should output or leave in a node,
  for checking programs as `examples/test.zig` does.

Each new feature should come with a CLI form, or a reason it can't.

### The prompt and IDE

- Words to let the chip run freely from `gasim aforth`, as the TUI already
  can.
- Paths (`HOOK PATH -HOOK`) are accepted but do nothing, as gasim reaches
  every node directly. Simulating the real IDE's wire and end nodes could
  come later, if driving GreenArrays' IDE scripts unchanged is wanted.
- GreenArrays' drivers that use the internals of their own tools, such as
  `?RAM` in block 1982 and `HIGH`/`HRAY` in block 2220, still do not
  assemble.

### colorForth

Not done: `kind`/`reset` for the ROM builds, the ROM labels arrayForth 2 has
that arrayForth 3's tables lack (`-++`), host words with control flow or that
use host memory, and node state kept across `node`. In the editor: the
selected node's stacks beside it, and finding a word's definition across
blocks.

### Worth considering

- **Golden traces.** Compare register traces with SOFTSIM (arrayForth 3 under
  Wine) or ga144-sim, to catch subtle opcode and timing bugs.
- **Energy estimate.** Power figures from the datasheets, with time running
  versus suspended, give a rough per-node energy readout.
- **Profiling.** Per-node instruction counts, time suspended versus running,
  hot addresses.
- **Saving the chip.** `Chip.Snapshot` is plain arrays, so it can be written
  to a file and read back.

## Open questions

- **Instruction timing on a board.** gasim takes DB002's typical times, but
  DB001 §2.4.1 and DB002 §5.3 say they vary with temperature, voltage and
  process. Should board files set them, such as DB002's minimum and maximum,
  and should a real board be measured?
- **Pins on custom layouts.** Today they come from the GA144 by node number,
  so a 9x18 layout's 708 has pins but no wakeup. Should custom layouts have
  no pins unless a chip file declares them?
- Should `.af` stay the extension for arrayForth 3 text, or should the syntax
  be chosen by a flag or by finding `ASM[`?
- Should going back in the TUI also restore the forth session's stack and
  bins, or only the chip, as now?
- Should the console byte protocol stay one byte per word, or pack two or
  three characters per word as colorForth programs usually emit text?

Settled: ROM comes from a dump of a real chip, and the arrayForth 3 ROM source
is checked against it. The TUI is drawn on raw cells, not vxfw. The ROM can't
be changed on a real chip (DB002 §3: a new ROM is a new part number), but
`--rom` loads any dump into gasim.
