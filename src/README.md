# src

## Overview

This folder is gasim's core: a simulator of the GreenArrays GA144 chip, and
the tools that put programs on it. `root.zig` is the core module, which the
build names `gasim`. The core does no I/O of its own. Callers pass it
bytes, buffers, writers and allocators.

The three front ends in the folders below import the core:

- [`cli/`](./cli/README.md) is the `gasim` command and its terminal UI.
- [`gui/`](./gui/README.md) is `gasim-gui`, the desktop app, built with
  `-Dgui`.
- [`web/`](./web/README.md) is the wasm module that the web version runs.

Two folders hold data, not code:

- `boards/` holds board files, such as `evb002.zon`. `Board.zig:evb002`
  imports it.
- `chips/` holds chip files, such as `ga144.zon`. `Spec.zig:ga144` imports
  it.

[docs/README.md](../docs/README.md) explains how to use gasim.
[docs/boot.md](../docs/boot.md), [docs/rom.md](../docs/rom.md),
[docs/boards.md](../docs/boards.md) and [docs/chips.md](../docs/chips.md)
explain the parts of the chip that this code models.

### How the parts fit together

1. An assembler turns source into one `Program` per node.
   `assembler.zig` reads gasim's own syntax (`.ga`), `arrayforth.zig` reads
   arrayForth 3 (`.af`, `.blk`), and `arrayforth.zig` with `colorforth.zig`
   reads colorForth (`.cf`).
2. `boot.zig` and `streamer.zig` turn programs and boot descriptors into
   boot streams, as the chip's ROM expects them.
3. `Chip.zig` runs the nodes. Each node is an F18A computer
   (`f18.zig:Computer`) that runs the opcodes in `opcodes.zig`. Nodes pass
   words through shared ports (`port.zig:Port`).
4. Devices sit around the chip and run at the nodes' times: a console, a
   UART, SPI flash, SRAM, a sync serial line and SERDES links.
5. `snapshot.zig` and `History.zig` save the chip, so a run can be resumed
   or undone.
6. `Sim.zig` puts these parts together for the GUI and the web version.

## Interface

### Exports of `root.zig`

`root.zig` exports these types and modules. Everything else in the folder
is private to the core.

- The types are `Address`, `Computer`, `Instruction` and `Word` from
  `f18.zig`, and `Direction` and `Port` from `port.zig`.
- The modules are `arrayforth`, `assembler`, `colorforth`, `boot`,
  `Board`, `Chip`, `Console`, `Device`, `Editor`, `Tail`, `Serdes`, `Sim`,
  `SourceMap`, `Spec`, `Uart`, `Flash`, `History`, `Sram`, `Sync`,
  `disassembler`, `examples`, `ga144`, `rom`, `snapshot`, `streamer`,
  `pins` and `port`.

`Builder.zig`, `opcodes.zig`, `stack.zig` and `fuzz.zig` are not exported.
The other files use them.

### The chip

- `Chip.zig:init` builds one chip from a `Spec`, and `Chip.zig:initChips`
  builds several identical chips. `Chip.zig:deinit` frees them.
- `Chip.zig:loadRom` loads the ROM. `Chip.zig:load` loads a program, and
  `Chip.zig:setUp` loads a boot descriptor.
- `Chip.zig:step` takes one round. `Chip.zig:stepNode`,
  `Chip.zig:stepSlot` and `Chip.zig:stepNext` step one node by a word or a
  slot.
- `Chip.zig:advance` serves the devices and takes a round.
  `Chip.zig:run` runs until the chip settles, a stop is hit, a limit is
  reached or a device is interrupted (`Chip.zig:interrupted`).
- The `attach` functions connect the chip to what is around it.
  `Chip.zig:attachPort`, `Chip.zig:attachFeeder`, `Chip.zig:attachDevice`,
  `Chip.zig:attachPin` and `Chip.zig:attachBus` put a device on a node's
  port, pin or bus. `Chip.zig:attachSerdes` joins two nodes with a SERDES
  link. `Chip.zig:attachReset` lets a pin reset a chip.
- `Chip.zig:Feeder` writes words into a node through a port, such as a
  boot stream.
- `Chip.zig:wire` joins the nets of two pins. `Chip.zig:pull` puts a
  resistor from a pin's net to high or low.
- `Chip.zig:flushOutput` flushes the writer of every device that has one.
- `Chip.zig:execute` gives a waiting node one instruction word, as
  arrayForth's IDE does. `Chip.zig:runUntilWaiting` runs until the node
  waits again.
- `Chip.zig:Breakpoint`, `Chip.zig:Watch` and `Chip.zig:Hazard` are the
  reasons a run can stop. `Chip.zig:hit` keeps the first one.
- `Chip.zig:Snapshot` is a save of the chip. `Chip.zig:save` makes one,
  `Chip.zig:restore` goes back to one, and `Chip.zig:matches` compares one
  with the chip.
- `Chip.zig:Layout` is the grid of nodes. `Chip.zig:parseNode` and
  `Chip.zig:nodeName` read and write node numbers, such as `708` or
  `1.708`.
- `f18.zig:Computer` is one F18A node. It has registers, stacks, 64 words
  of RAM and 64 of ROM, ports and pins, and its own time in picoseconds.
- `f18.zig:Word` is an 18-bit word. `f18.zig:Instruction` is an
  instruction word with its four slots.
- `opcodes.zig:Opcode` lists the 32 F18A opcodes. `opcodes.zig:opcodes` is
  the table of functions that run them.
- `port.zig:Port` is a port between two nodes. A word passes only when one
  side writes and the other reads.

### Devices

- `Device.zig` is the interface for anything outside the nodes that the
  chip runs with. A device fills in only the hooks of `Device.zig:VTable`
  that it needs.
- `Console.zig` is a terminal on a node's port. It outputs each word the
  node writes as one byte.
- `Uart.zig` is a UART on two pins, with 10-bit frames.
- `Flash.zig` is an SPI flash that answers only the read command (`0x03`).
- `Sram.zig` is an SRAM of 16-bit words on two nodes' buses and four pins.
- `Sync.zig` is a synchronous serial master that sends a boot stream.
- `Serdes.zig` is a SERDES link between two chips.
- `pins.zig:Wiring` holds the pins of all nodes, and the nets that join
  them.
- `Board.zig:parse` reads a board file. `Board.zig:check` checks it against
  a chip, and `Board.zig:apply` puts its devices and wires on the chip.
- `Spec.zig:parse` reads a chip file, and `Spec.zig:check` checks it.

### Programs and boot streams

- `assembler.zig:assembleNodes` and `assembler.zig:assemble` assemble
  gasim's own syntax into one `assembler.zig:Program` per node.
- `arrayforth.zig:assembleScript`, `arrayforth.zig:assembleBlocks` and
  `arrayforth.zig:assembleColorForth` assemble arrayForth 3 text,
  polyFORTH blocks and colorForth blocks.
- `arrayforth.zig:Session` is an arrayForth 3 session. It keeps its state
  between lines, and can act on a chip with the IDE's words.
- `arrayforth.zig:startCompiled` sets up a chip with the programs and boot
  descriptors that an assembler returned.
- `boot.zig:Descriptor` says what to load into a node, and how to start
  it.
- `boot.zig:stream` builds a boot stream for a port. `boot.zig:asyncStream`
  and `boot.zig:asyncBytes` build one for node 708's UART ROM.
- `streamer.zig:stream` builds a boot stream as arrayForth 3's STREAMER
  does. `streamer.zig:pack` packs it into bytes for flash.
- `rom.zig:assemble` assembles the ROM from arrayForth 3's disk.
  `rom.zig:write` writes it as a text dump, and `ga144.zig:parseRom` reads
  a dump.
- `disassembler.zig:write` turns words back into opcodes.
  `disassembler.zig:listing` writes a listing.
- `SourceMap.zig` finds the source line that each word came from.

### colorForth

- `colorforth.zig:decode` turns a 1,024-byte colorForth block into tokens,
  and `colorforth.zig:encode` turns tokens back into a block.
- `colorforth.zig:writeText` writes blocks as text with color marks, and
  `colorforth.zig:TextReader` reads that text back.
- `colorforth.zig:compress` and `colorforth.zig:decompress` compress and
  expand arrayForth 2 images.
- `Editor.zig` is a colorForth block editor in the style of vim. It returns
  an `Editor.zig:Action` for what the front end must do, such as save.

### For the front ends

- `Sim.zig` is one chip with a console on node 000, an arrayForth 3
  session, an editor, a history and a trace. Its views write JSON or text
  into one buffer, `Sim.zig:out`.
- `History.zig` keeps saves of the chip to go back to.
- `snapshot.zig:write` writes a chip and its devices to a file.
  `snapshot.zig:readMachine` and `snapshot.zig:readChip` read them back.
- `Tail.zig` is a writer that keeps the last lines written, for the trace.
- `examples.zig:list` lists the examples in a folder, with their
  descriptions.

## Invariants

These are the rules that the code relies on, and that a change must keep.

- A word is 18 bits (`f18.zig:Word`). An address is 9 bits
  (`f18.zig:Address`). Instruction words are stored XORed with `0x15555`
  (`f18.zig:Instruction`).
- Each node has 64 words of RAM, then 64 of ROM. Addresses repeat, so
  `Chip.zig:Breakpoint.init` treats RAM or ROM addresses that differ only
  in bit 6 as the same word.
- `Chip.zig:step` steps the node that is furthest behind in time first.
  Ties go to the lower node index, so every run takes the same order.
- Load the ROM before programs. Call the `attach` functions, `wire` and
  `pull` before the first step (doc comments in `Chip.zig`).
- These are the caps on a chip:

  | Cap | Limit |
  | --- | --- |
  | `Chip.zig:max_breakpoints` | 32 |
  | `Chip.zig:max_watches` | 32 |
  | `Chip.zig:max_devices` | 16 |
  | `Chip.zig:max_hazards` | 16 |
  | `Chip.zig:max_serdes` | 4 |
  | `Chip.zig:max_resets` | 4 |

  A board has at most 4 serial ports (`Board.zig:max_serial`).
- With `Chip.zig:strict` set, a hazard stops the run. Otherwise the chip
  records it and goes on.
- `Sim.zig` and `Tail.zig` keep pointers to their own fields, so they must
  not move once they are in use.
- A slice that `Sim.zig` returns from `out` is valid only until the next
  call that writes `out`.
- `History.zig:keep` keeps a save only if the chip changed after it. The
  history drops the oldest save when it is full.
- A snapshot starts with `gasimsnp` and a hash of the saved types and of
  `snapshot.zig:format_version` (`snapshot.zig:typeHash`). A file from
  another version fails with `error.OtherVersion`. Raise `format_version`
  when you change what `snapshot.zig:write` writes by hand.
- The assemblers write into buffers that the caller gives, such as
  `[]Program`. Labels and diagnostics point into the source, so the source
  must outlive them (`arrayforth.zig:Session.interpret`, `Builder.zig`).
- `rom.zig:af3_bins` comes from `af3-bins.zon`. `zig build bin-digests`
  makes that file, so don't edit it by hand. See
  [tools/bins/README.md](../tools/bins/README.md).

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- The core reads no files, except `examples.zig:list`, which reads the
  folder of examples it is given.
- Test helpers read files relative to the working folder.
  `rom.zig:testRom` reads `rom/pFDISK.blk`, and `fuzz.zig:read` reads fuzz
  seeds. A test that can't find `pFDISK.blk` is skipped.
- `Board.zig:evb002`, `Spec.zig:ga144` and `rom.zig:af3_bins` get
  `boards/evb002.zon`, `chips/ga144.zon` and `af3-bins.zon` with
  `@import`. The data is compiled in as Zig values, so the core reads no
  file for them.
- `Chip.zig:init` and `Sim.zig:init` allocate from the allocator they are
  given. The matching `deinit` frees everything.
- `Chip.zig:run` can block while it waits for input from a device's queue
  (`Device.zig:Queue`). `Device.zig` has two atomic flags: `interrupted`,
  which another thread sets to end a run, and `waiting`.
- `Console.zig` and `Uart.zig` write the chip's output to the writer they
  were given.
- `Chip.zig:stepQueued` writes trace lines to `Chip.zig:trace` when it is
  set.

## Verification

- Run the core's tests, and the command's: `zig build test`. The test
  block in `root.zig` pulls in the files in this folder. Assembling the ROM
  needs more than 1 MiB of stack, because arrayForth 3's interpreter keeps
  its state on the stack (see the comment on `wasm.stack_size` in
  `build.zig`).
- Build the core for wasm: `zig build wasm`
- Fuzz with LLVM: `zig build test -Dfuzz --fuzz`
