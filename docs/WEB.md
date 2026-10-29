# gasim on the web

A client-side version of gasim: the same core compiled to wasm, with a front
end built for the browser rather than a copy of the TUI. It runs entirely in
the page. There is no backend, so it can be served as static files, for
example from GitHub Pages.

The TUI is the reference for what the web version shows, not for how it
looks.

## Goals

- The core, unchanged, as a `wasm32-freestanding` module.
- No Node, no npm, no bundler, no big framework. Mithril for views, Pico
  for base styles, native ES modules, everything vendored in `web/vendor/`.
- Files opened, saved and remembered in the browser.
- Usable on a tablet, with or without a hardware keyboard, as well as on a
  desktop.
- A plain, neutral look: Pico's default type, a slate or azure theme,
  sentence-case headings, light and dark. The only strong colors are the
  ones that mean something: colorForth's token colors and node states.

## Where things stand

Phases 0 to 2 are done:

- The core builds for wasm with no changes to how it works: the console
  takes input without a queue (`Console.give`), the editor's key map is
  `Editor.key`, which the TUI uses too, and CI builds the module with
  `zig build wasm`.
- `src/web/Sim.zig` is what the web runs: the chip with a console on node
  000's up port, an arrayForth 3 session, the editor, and the chip's
  history. It loads `.ga`, `.af`, `.blk` and `.cf` files as the CLI does,
  and is tested natively with the rest.
- `src/web/main.zig` exports it, `web/engine.js` wraps the exports, and
  `zig build web` builds the module, 140 KB at ReleaseSmall, with `web/`
  and the examples into `zig-out/web`. `zig build serve` serves it.
- The app shell, in `web/`: Mithril and Pico, vendored in `web/vendor/`,
  with the map, the node panel, the console's output, run and step,
  breakpoints, the ROM, the examples, and opening files from a button or by
  dropping them. Borders can be dragged, and below 900 px the node and the
  console are tabs under the map. `?example=hello.ga` opens an example.
- The module has an 8 MiB stack, as arrayForth 3's interpreter is kept on
  the stack as it assembles, and assembling the ROM from `pFDISK.blk`
  overflows wasm's default of 1 MiB.

## Architecture

```
  web/  (index.html, app.js, views, style.css, vendor/)
     │  ES modules, Mithril views
  engine.js   loads gasim.wasm, copies bytes in and out, decodes views
     │  exported functions, typed arrays over wasm memory
  src/web/main.zig   the C ABI over the core, one chip and one session
     │
  gasim module (src/root.zig)   unchanged, no I/O, no libc
```

This is the same shape as drgnwrrr's web build: `src/web/main.zig` exports
functions, strings and files cross as a pointer and a length into the
module's memory, and the only import is a log function for panics.

### The exports

- Memory: `alloc`, `free`.
- The chip: `setRom(bytes)`, `load(kind, bytes, loads)` for `.ga`, `.af`,
  `.blk` and `.cf`, `reset`, and `run(budget)`, which steps until the
  budget is spent, a breakpoint or watch is hit, a node waits on the
  console for input, or every node is waiting, and says which.
- Stepping: `stepNext`, `stepRound`, `stepNode(i)`, `remember` before a
  run, and `back`, with snapshots kept as `Chip.Snapshot`s, as the TUI
  keeps them.
- The debugger: breakpoints, port watches, the trace log, and why a node
  is waiting (`--why`).
- The session: `interpret(line)`, its output, `stack`, `complete(prefix)`,
  `setTarget(node)`.
- The console: `give(bytes)`, `endInput`, `wantsInput`, and its output
  since it was last read.
- The editor: `editorOpen(blocks)`, `editorKey(k)`, `editorMoveTo(i)`,
  `editorGoTo(block)`, and `editorContents` to save.

State comes back two ways. What the map needs every frame, a status byte
per node and the port activity between them, is a flat buffer read in place
through a `Uint8Array`, so the frame loop does no parsing. Everything else,
such as the selected node's stacks, registers and disassembly, or the
editor's tokens, is JSON written into a buffer, as drgnwrrr's `view()` does,
and read only when it changes.

### Running

A `requestAnimationFrame` loop calls `run(budget)` and redraws. The core is
deterministic and already runs in budgets, so the main thread is enough to
start with, and keeps pausing and stepping simple. The budget adapts to keep
each frame short. If that is ever not enough, the module can move to a Web
Worker with the same exports, posting views back.

### The build

- `zig build web` builds `gasim.wasm` and copies `web/` into `zig-out/web`.
  Debug builds will be slow, so like drgnwrrr it builds ReleaseSmall unless
  asked for another release mode.
- `zig build serve` serves `zig-out/web` on localhost, with a small static
  server in Zig as drgnwrrr's `tools/serve`. `fetch` and wasm streaming do
  not work from `file://`.
- CI builds the wasm module on every push, so that the core staying free of
  I/O and libc is checked, not only a rule.
- The release workflow publishes `zig-out/web` to GitHub Pages.

## The ROM

The ROM is GreenArrays' copyright, and `rom/README.md` says it is not part
of gasim, which is why the repository has no dump and git ignores
`rom/*.blk`. Bundling it with the web build is a change to that, and worth
deciding once for both the web and the release binaries.

So that the decision can be made either way, the page looks for the ROM in
this order:

1. `ga144.txt` next to `index.html`, with `fetch('ga144.txt')`. Whoever
   serves the page decides whether it is there. `zig build web
   -Drom=<path>` copies a dump into `zig-out/web`, and the Pages deploy
   can do the same from a secret or a release asset, without the dump being
   in the repository.
2. The ROM saved in the browser the last time one was loaded.
3. One the user gives it: a dump in the `--rom` format, or arrayForth 3's
   `pFDISK.blk`, which `rom.assemble` assembles in the page, as the CLI
   does. Either is saved for next time.

Without a ROM, the page still runs code that does not use it, as the CLI
does, and says why code that calls into ROM cannot run.

## Files

- Opening: a file button and drag and drop anywhere on the page, for `.ga`,
  `.af`, `.blk`, `.cf` and ROM dumps. The examples are bundled and listed
  in an Examples menu.
- Saving: a download made from a `Blob`, which works everywhere. Where the
  File System Access API is available (Chromium), `.cf` and source files
  opened through it can be saved in place, so ctrl+s saves the file
  opened.
- The workspace: the ROM, recent files, the prompt's history and the
  layout are kept in IndexedDB, so a reload comes back to where it was.
  `localStorage` is only for small preferences, such as the theme.
- Sharing a small program in the URL could come later.

## The panels

The TUI has the map, the node panel, the console and the forth panel, and
the editor on a screen of its own. The web version adds panels for what the
TUI only shows in passing:

- **Map:** the chip's nodes in a grid, colored by state (running, waiting
  on a port and which, suspended), with the ports between them lit when
  words cross. Tapping a node selects it, as the IDE's target too.
- **Node:** the selected node's stacks, registers, and RAM and ROM
  disassembled, with a gutter to set breakpoints.
- **Forth:** the arrayForth 3 prompt.
- **Console:** the simulated terminal.
- **Trace:** the trace log, filtered by node.
- **Breakpoints:** breakpoints and port watches, listed to turn off or
  remove.
- **History:** the snapshots kept, as a timeline to go back to.
- **Blocks:** the blocks of the open `.blk` or `.cf`, with each one's first
  line, and search.
- **Editor:** colorForth's blocks.

## Layout

There is a lot to show, so space matters more than in the TUI. The layout
is a toolbar and a few regions, each holding panels as tabs, with borders
that can be dragged and regions that can be folded away:

```
┌ toolbar: open save examples │ run pause step step-node back │ cycles ┐
├──────────────────────────────┬───────────────────────────────────────┤
│ map                          │ node                                  │
│                              │ (stacks, registers, RAM, ROM)         │
├──────────────────────────────┤                                       │
│ forth | console | trace      │                                       │
└──────────────────────────────┴───────────────────────────────────────┘
```

The editor has a view of its own, as it wants the width, with the selected
node beside it and the blocks list folded at the side:

```
┌ toolbar ─────────────────────────────────────────────────────────────┐
├────────┬───────────────────────────────────────────┬─────────────────┤
│ blocks │ editor, block 18                          │ node            │
│        │                                           │ stacks          │
│        │                                           │ forth           │
├────────┴───────────────────────────────────────────┴─────────────────┤
│ colors: red yellow green white cyan magenta blue │ mode │ unsaved    │
└──────────────────────────────────────────────────────────────────────┘
```

The widths it is designed for:

- **Desktop, 1280 and wider:** as drawn.
- **Tablet landscape, about 1024:** the same regions, with the node panel
  narrower and the dock shorter. The blocks list and the node panel in the
  editor fold by default.
- **Tablet portrait, about 768:** one column. The map is on top, and the
  node panel and the dock become tabs below it. The editor uses the full
  width, with the node panel as a sheet that slides up from the bottom.
- **Phones:** it should not break, but they are not a goal.

On a tablet:

- Controls are at least 44 px to tap. Run, pause and step stay in the
  toolbar, which does not scroll.
- A long press on a node or a line of disassembly does what a right click
  does: breakpoints and watches.
- The on-screen keyboard covers half the screen, so the prompt and the
  editor follow `visualViewport` to keep the line being typed in view.
- Everything with a key also has a button, as there may be no keyboard.

Routes are in the hash, `#/chip` and `#/editor`, so the back button works
and a view can be bookmarked.

## The prompts

Isocline is C written for terminals, so it is not used on the web. What it
gives the TUI is simple to build over an `<input>`:

### Forth

- One line of input, sent with Enter.
- History with up and down, kept in IndexedDB, and later a search like
  ctrl+r.
- Tab completion from `Session.complete`, shown as a list under the input
  that can be tapped, as tablets have no Tab key.
- Output is a list of entries rather than a terminal: each line typed, what
  it printed, and the stack after it as a row of numbers, with errors marked
  where they were found. Tapping an entry puts its line back in the input.

### Console

The console is a stream of bytes to a node, so it has two modes:

- **Line:** Enter sends the line, as the TUI does. The default.
- **Raw:** each key is sent as it is typed, for programs that echo.

An "End input" button does what ctrl+d does. The output is preformatted
text in a monospace font, scrolled to the end unless scrolled back.

## The colorForth editor

`Editor.zig` already is the model, with no I/O: moving, inserting, typing,
colors, undo, and where lines start. The TUI is a key map and a drawing over
it, and the web version is the same:

- **The key map moves into the core**, as `Editor.key(Key)` with a small
  key type of its own. `tui.zig` and the web each turn their events into
  it, so the two cannot drift apart, and the TUI's editor tests cover the
  web too.
- **Drawing:** a focusable element with each token a `<span>` of its color,
  lines broken where `startsLine` says, and the cursor a class. Tapping or
  clicking a token moves the cursor to it, with a new `Editor.moveTo`.
- **Keys the browser keeps:** a page cannot take ctrl+w, ctrl+t or ctrl+n,
  so on the web the shift+R/Y/G/W/C/M/B colors are the main ones, and a
  color bar under the editor can be tapped, which is the only way without a
  keyboard. Other ctrl keys are taken with `preventDefault`.
- **Typing:** in insert mode, characters come through a hidden `<input>`
  that has the focus, not through key events alone, so on-screen keyboards
  and input methods work. Characters colorForth cannot pack are refused
  there.
- **Colors:** colorForth's colors on black are its look, and stay in the
  dark theme. The light theme has its own set, with enough contrast on
  white. Either can show the color marks `gasim blocks` prints, for readers
  who do not tell the colors apart.

## Phases

0. **Core:** a console without `Io`, the types made public, `Editor.key`
   and `Editor.moveTo`, with the TUI moved onto `Editor.key`. CI builds the
   wasm module.
1. **The module:** `src/web/main.zig` and `engine.js`, `zig build web` and
   `zig build serve`. The export layer is tested natively in Zig, so there
   is no JavaScript test runner to need.
2. **The shell:** Mithril and Pico, the layout, the map, the node panel,
   run and step, the ROM, the examples and opening files.
3. **The prompts:** forth and console.
4. **The editor**, and the blocks list.
5. **The rest:** the workspace in IndexedDB, saving in place, breakpoints,
   watches, trace and history, and publishing to Pages.

## Open questions

- Bundling the ROM: for the web only, or the release binaries too, and does
  `rom/README.md` change with it?
- A Web Worker from the start, or only if the main thread is not enough?
- Should a program and its inputs be shareable in the URL?
