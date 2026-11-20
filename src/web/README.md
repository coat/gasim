# src/web

## Overview

This folder is the wasm side of gasim's web version. `main.zig` wraps one
`Sim` from the core in plain `export fn`s, so that JavaScript can drive the
chip. The build compiles it for wasm32-freestanding, with no libc and no
I/O. The page that calls these functions lives in
[`web/`](../../web/README.md), and `web/engine.js` wraps them in a
JavaScript API.

Data crosses the boundary in two ways:

- **In:** JavaScript copies bytes into wasm memory with `alloc`, then passes
  a pointer and a length.
- **Out:** Text and JSON come back in one buffer, `Sim.out`. A call returns
  the length, and `outPtr` gives the start. Three calls use other buffers:
  `editorContents` and `editorContentsPtr` give the editor's own bytes,
  and `nodeStatuses` gives a fixed status buffer.

## Interface

All functions are in `main.zig`. Many of them call the `Sim` method of the
same name. The others call `sim.console` or `sim.editor`, or a `Sim`
method with another name, such as `takeConsoleOutput`, `openEditor`,
`compile` and `blocksView`.

| Area | Exports | What they do |
| --- | --- | --- |
| Memory | `main.zig:alloc`, `main.zig:free`, `main.zig:outPtr`, `main.zig:outLen` | Allocate and free buffers in wasm memory, and find the output buffer. |
| Chip | `main.zig:init`, `main.zig:setRom`, `main.zig:load`, `main.zig:reset` | Create the `Sim`, give it a ROM dump or arrayForth 3's `pFDISK.blk`, assemble a file of a `Sim.Kind`, and restore the chip to how the file started it. |
| Running | `main.zig:run`, `main.zig:stepNext`, `main.zig:stepRound`, `main.zig:stepNode`, `main.zig:stepSlot` | Run for up to `budget` rounds, or step by node, round or slot. `run` returns a `Sim.Stop`. |
| History | `main.zig:remember`, `main.zig:back`, `main.zig:backTo`, `main.zig:historyView` | Save the chip before a run, with a `Sim.Cause`, and go back to an earlier state. |
| Breakpoints | `main.zig:toggleBreakpoint`, `main.zig:toggleWatch`, `main.zig:clearBreakpoints` | Set and clear breakpoints on addresses and watches on ports. |
| Trace | `main.zig:setTracing`, `main.zig:takeTrace` | Turn tracing on or off, and take what was traced since the last call. |
| Views | `main.zig:nodeStatuses`, `main.zig:nodeView`, `main.zig:tilesView`, `main.zig:chipView` | Write the state of each node, one node, or the whole chip for the page to draw. |
| Prompt | `main.zig:interpret`, `main.zig:complete` | Interpret a line at the arrayForth 3 prompt as node `target`, and list the words that could complete a prefix. Both write JSON. |
| Console | `main.zig:give`, `main.zig:endInput`, `main.zig:wantsInput`, `main.zig:consoleOutput` | Give the console input, end it, and take its output. `give` returns how much there was room for. |
| Editor | `main.zig:editorOpen`, `main.zig:editorKey`, `main.zig:editorView`, `main.zig:editorMoveTo`, `main.zig:editorGoTo`, `main.zig:editorContents`, `main.zig:editorContentsPtr`, `main.zig:editorSaved`, `main.zig:editorUnsaved`, `main.zig:editorCompile`, `main.zig:editorBlocks` | Drive the colorForth block editor, save its file, and compile the block being edited. |

The core these functions use is described in [`src/`](../README.md).

## Invariants

These are the rules that the code relies on, and that a change must keep.

- Call `main.zig:init` before any other export except `alloc` and `free`.
  The other functions use the global `sim`, which is undefined until then.
  `init` returns false if it can't allocate the `Sim`. Then no other call
  is safe.
- Data in the output buffer is valid only until the next call that writes to
  `Sim.out`. Copy it out before the next call.
- A function that returns a length returns 0 when it ran out of memory
  (`main.zig:written`).
- Enums cross as integers. `main.zig:load`, `main.zig:toggleWatch` and
  `main.zig:editorKey` check them with `std.enums.fromInt` and fail on a
  bad value.
  `main.zig:remember` falls back to `.run`.
- Error results are small integers, not Zig errors. `run` returns `0xff`,
  `stepNext` returns -1, `toggleBreakpoint`, `toggleWatch` and `editorKey`
  return -1, and the `bool` functions return false.
- `main.zig:takeTrace` sets bit 31 of its result when older trace lines were
  dropped. The lower bits are the length.
- `main.zig:nodeStatuses` returns a fixed buffer of
  `2 * Sim.layout.count()` bytes. The first half holds each node's status.
  The second half holds the ports each node moved words through in its last
  step (`Sim.statuses`).

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- All memory comes from `std.heap.wasm_allocator`. The module keeps two
  globals: `main.zig:sim`, a pointer to the one `Sim` that `init` creates,
  and the status buffer `main.zig:statuses`.
- The only import is `jsLog` from the `env` module. `main.zig:panic` sends
  the panic message to it, then traps.
- The module does no file or network I/O. The page gives it every file as
  bytes.

## Verification

- Build the wasm module: `zig build wasm`
- Run the web version's tests, which load this module in Deno:
  `zig build test-web`
- The core's own tests: `zig build test`
