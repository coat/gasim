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
- **The chip:** the GA144 by default, or one a chip file describes
  (`--chip`), or an `RxC` array of basic nodes (`--layout`), with GA144
  port naming, a run-queue scheduler, ROM from a dump of a real chip or assembled from
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
simulated chip with `20 DRIVE HI AFORTH` at its prompt. ✓ marks what is
done.

1. **Chip and board files.**
   - ✓ A chip file gives the size and, per node, the ROM type, pins and
     reset word, in ZON read on the host side
     (`--chip`). The GA144 is the default, `src/chips/ga144.zon` instead
     of code in `ga144.zig`. `--layout` gives basic nodes with no pins,
     where it used to borrow the GA144's by node number.
   - Buses, such as node 007, 008 and 009's to external memory, in the
     chip file, once something uses them.
   - ✓ A board file lists serial ports on the chip's pins, pull-ups, wires
     and jumpers (`--board`, `--usb`, `--jumper`), and ships as `evb002`:
     its host chip, with USB ports A and B, NO BOOT and its pull-ups.
   - ✓ Boards of more than one chip, alike, whose nodes run under one
     scheduler and are numbered k.yxx on chip k: the EVB002's target,
     joined to the host by SERDES (701 to 001, word by word as DB001 §3.6
     describes it, with no flow control) and through J34 and J35 by node
     300, and its USB port C. Within 1% of the instructions before on the
     benchmarks.
   - ✓ The EVB002's reset line from host 500.17 to the target through
     J22, against the target's reset circuit: a chip held in reset while
     RESET- is low, and starting again as after reset, with its RAM, when
     it rises.
   - RTS and DTR, which ptys don't carry, as reset sources: port A's for
     the host (J20) and port C's for the target (J22.3-4).
   - Chips after the first in arrayForth 3 programs and the IDE's words.
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
   - ✓ Pins as connections with drivers: nets join node pins and devices,
     driven strongly, by a pull resistor, by a node's weak pulldown (01 in
     io, as after reset) or not at all; contention is reported; and nodes
     read a net as it was at their own time (`pins.zig`, `Chip.wire`,
     `Chip.pull`). The UART is a device on two nets.
   - ✓ A board's serial ports on ptys, several at once (`--pty`), each a
     UART on its node's pins, with a doorbell that the readers ring so a
     run waits for input on any; ga-tools boots node 708 of either chip
     through one, its RTS calls stubbed out.
   - ✓ The EVB002's SPI flash, backed by a file (`--flash`): a device on
     host 705's four pins that answers reads (`src/Flash.zig`).
   - ✓ The EVB002's 2 MB SRAM, on host 007's and 009's parallel buses
     (`Computer.BusDevice`, DB in io) and 008's pins (`src/Sram.zig`),
     which the disk's SRAM cluster writes and reads back.
   - The UART on TCP or the TUI; writing the flash; the parallel buses'
     phantom wakeups and Up port; the analog nodes' outputs.
   - Pin activity dumped as VCD files for GTKWave.
   - The console stays, for playing and debugging.
   - The UART's state in snapshots, and a UART in the TUI, GUI and web.
4. **The real boot paths.**
   - ✓ Async boot of node 708 from its ROM, through the UART (`--boot
     --uart 708`, or any stream on stdin).
   - ✓ Streams made by [ga-tools](https://github.com/mschuldt/ga-tools)
     booting 708 (`zig build ga-tools`): a check that doesn't involve
     GreenArrays' code.
   - ✓ Code from the host chip running on the target's SERDES boot ROM.
   - ✓ SPI boot through 705's ROM, from the flash, with J26 (NO BOOT) off.
   - The host booting the target over SERDES and 300↔300 with
     GreenArrays' own code.
5. **arrayForth 3's streams, from files.** Its applications booting 708
   through the EVB002's USB port A, each node checked as it starts against
   its descriptor, with no ptys, RTS or Wine in gasim.
   - ✓ With the streams gasim builds from their descriptors (`--boot`):
     the SRAM cluster and the NIC, in `zig build test` with the disk.
   - ✓ With streams laid out as arrayForth 3's STREAMER (block 1602, which
     loads 1603–1618) lays them out for root 708 (`src/streamer.zig`):
     frames along a path, pumped from node to node, not gasim's tree. The
     SRAM cluster along `sr708` (block 1897) and the NIC along `s708`
     (block 2333).
   - ✓ The STREAMER's words in gasim's arrayForth (`STREAM[`, `FRAME[`,
     `]FRAME`, `]STREAM`, `ORGN`, `TO`, `COURSE`, `'`), with `STREAMER
     LOAD` loading nothing, so that block 1897 builds its stream as it is,
     up to its `]STREAM`, and `--boot` with `--uart` lays out a stream
     that has them as the STREAMER does.
   - ✓ Streams of several frames, up to 8, each along its own `COURSE`
     with descriptors of its own, the root reading the next at `ser-exec`,
     and `ENTIRE` for the default path. The disk's (blocks 1668 and 1671)
     are for root 705, so the tests are gasim's own.
   - ✓ Root 705, from the EVB002's SPI flash: `spiORG`'s frames, packed
     as `PACK` does (`streamer.pack`), `/ROOT`'s frames for the root alone
     and `FORWARD` (`--board evb002 --jumper J26=off --boot`). Block
     1671's stream, without the polyFORTH VM, boots its first frame (block
     1672's) as described, takes the nucleus through 108 to the SRAM, and
     boots the next frame, from where `FORWARD` says, as described too.
     That address is bin 1710's own x3A38: the stream so far pads to as
     many words as arrayForth 3's, 1656.
   - ✓ Root 300, through its synchronous line: `synORG`'s frames, for
     the sync ROM's `ser-exec`, clocked in by `Sync`, which clocks words
     as the disk's sync master, bin 1901's `18o`, does (`--boot`, without
     `--board`).
   - ✓ Root 207, pF/144's snorkel: frames with no header and no frame for
     the root. The disk's streams from it (blocks 1581 and 1583, with
     `?CLK 1`) boot as described in the tests, which stand in for the
     snorkel.
   - ✓ The STREAMER's two-chip paths: from a node to the same node of
     the other chip through their up ports, as the STREAMER's `MWALL`
     (block 1603) has it, which the EVB002's sync bridge (bins 1907, 1904 and 1901)
     joins. Block 1668's two-chip stream for flash, without the polyFORTH
     VM and with its own test of target 500 and 100, builds the bridge in
     its second frame and boots its last across it as described, and
     block 1582's test boots target 500 from root 207 across a bridge set
     up as block 1670's frame sets it. Descriptors off a frame's path are
     left out, as the STREAMER leaves them, which block 1668 relies on.
   - A stream captured once from arrayForth 3 under Wine and kept beside
     the ROM, as it is GreenArrays', would check the port byte for byte.
     Capturing needs RTS on a pty, which a preload library gives (branch
     `pty-reset`, #55, parked).
   - Driving gasim from the unmodified `sF5b2-af3.exe` under Wine, its IDE
     and flash burning, needs that library too, and would come back as a
     bridge program of its own, not in gasim.
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

An agent should be able to do everything the TUI does without one.
[docs/cli.md](cli.md) lays out the commands, and the order they come in. Each
new feature should come with a CLI form, or a reason it can't.

### The prompt and IDE

- Words to let the chip run freely from `gasim aforth`, as the TUI already
  can, past the rounds it settles for at the start. `run` and `step` go on
  from a snapshot `aforth` wrote, and `aforth --from` from theirs.
- Paths (`HOOK PATH -HOOK`) are accepted but do nothing, as gasim reaches
  every node directly. Simulating the real IDE's wire and end nodes could
  come later, if driving GreenArrays' IDE scripts unchanged is wanted.
- GreenArrays' drivers that use the internals of their own tools, such as
  `?RAM` in block 1982 and `HIGH`/`HRAY` in block 2220, still do not
  assemble.

### colorForth

Not done: `kind`/`reset` for the ROM builds, the ROM labels arrayForth 2 has
that arrayForth 3's tables lack (`-++`), host words that use host memory
but for system variables, and node state kept across
`node`. Also not done: host words that read the compiler's object code,
as block 1172's `resume` does; magenta variables defined outside the
system's blocks; the names of blocks 34 and 36, which block 18 loads
through `env` (`serial`); `/root` and the IDE's other words around boot
descriptors; and the chip configuration's words, such as `nns` and
`n-nn`, which polyFORTH's top descriptor block 362 uses. polyFORTH's
descriptors (blocks 364–368 and 266) compile with its code but don't
boot: block 394 ends at an `exit` before its `1705 bin`, so the bin node
205's descriptor loads is never saved, in both images. In the editor: the
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
