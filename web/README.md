# web

## Overview

This folder is gasim's web version: a page that runs the GA144 simulator
in the browser. The simulator's core runs as a WebAssembly (wasm) module,
built from [`src/web/main.zig`](../src/web/main.zig). The page is plain
JavaScript modules drawn with [Mithril](https://mithril.js.org/). It needs
no package manager and no build step of its own.

The code has three layers:

1. `engine.js` loads `gasim.wasm` and wraps its exports in a small
   JavaScript API.
2. `state.js` holds the app's state and every action that changes it,
   such as loading a file or stepping the chip.
3. `app.js` and [`views/`](./views/README.md) draw the page from `state`
   and call `state.js` when the user acts.

`store.js` keeps files and settings in the browser between visits.

To build and serve the page, see [Building](../docs/building.md#the-web-version).

## Interface

### Files

| File | What it does |
| --- | --- |
| `index.html` | The page. It loads `vendor/mithril.min.js` as a script, then `app.js` as a module. |
| `app.js` | The entry point. It applies the theme and sets up the routes `#/chip` and `#/editor`. It sets up the draggable layout, the keys and file drops. Then it calls `state.js:start`, and opens the example that `?example=<name>` names, if there is one. |
| `state.js` | The app's state, `state`, and the functions that change it. |
| `engine.js` | The wasm module behind a JavaScript API. |
| `store.js` | A small key-value store in IndexedDB. |
| `style.css` | The page's styles. |

### `engine.js`

- `loadEngine(url = 'gasim.wasm')` fetches and starts the wasm module. It
  returns an object with `nodes`, the number of nodes, and methods that
  mirror the module's exports. These include `setRom`, `load`, `run`,
  `stepNext`, `stepRound`, `stepNode`, `stepSlot`, `reset`, `remember`,
  `back`, `backTo`, `history`, `toggleBreakpoint`, `toggleWatch`,
  `clearBreakpoints`, `setTracing`, `takeTrace`, `statuses`, `node`,
  `tiles`, `chip`, `interpret`, `complete`, `give`, `endInput`,
  `wantsInput`, `consoleOutput` and the `editor*` methods.
- `Stop`, `Status`, `Cause` and `Action` are arrays that turn the
  module's numbers into names. `Kind` and `Direction` are objects that go
  the other way: they turn names into the numbers that calls take, such
  as `Kind[file.kind]`.

### `state.js`

- `state` is the one object the views read. It holds the engine
  (`state.gasim`), the selected node, the chip, the console, the trace,
  the prompt's history and the editor.
- `start()` loads the engine, the ROM and the list of examples. Then it
  brings back the last visit's workspace.
- `refresh()` reads what the views show from the engine. `refreshEditor()`
  does the same for the editor.

`state.js` also exports these functions, by what they act on:

| Area | Functions |
| --- | --- |
| Files | `openFile`, `pickFile`, `openRecent`, `forgetRecent`, `openExample`, `load`, `reload`, `kindOf`, `hasBlocks`, `canPick`, and the list `examples` |
| The ROM | `giveRom`, `forgetRom` |
| Running and stepping | `toggleRun`, `run`, `pause`, `stepNext`, `stepRound`, `stepNode`, `stepSlot`, `back`, `backTo`, `reset` |
| Nodes | `select`, `move`, `nodeNumber`, `nodeIndex`, `pad`, `showRegisters` |
| Debugging | `toggleBreakpoint`, `toggleWatch`, `clearBreakpoints`, `toggleTracing`, `clearTrace`, `traceShown`, `saveTrace` |
| The prompt and the console | `interpret`, `completions`, `sendInput`, `endInput` |
| The editor | `editorKey`, `editorGoTo`, `editorMoveTo`, `toggleFormat`, `toggleMarks`, `saveEditor`, `compileEditor`, `newEditorFile` |
| The workspace | `flushWorkspace`, `workspaceKept` |

### `store.js`

- `get(key)` returns the value kept under `key`, or null.
- `put(key, value)` keeps a value and returns whether it could.
- `remove(key)` forgets a key.

### Folders

- [`views/`](./views/README.md) holds the Mithril components for the map,
  the node, the dock, the editor and the toolbar.
- [`vendor/`](./vendor/README.md) holds Mithril, copied as published. Don't
  edit it.
- `icons/` holds the toolbar's SVG icons. The desktop GUI draws them too,
  so `build.zig` lists the ones it needs in `gui_icons`.

## Invariants

These are the rules that the code relies on, and that a change must keep.

- The name lists in `engine.js` must match the numbers the core uses.
  `Kind`, `Stop`, `Status` and `Cause` follow `Sim.Kind`, `Sim.Stop`,
  `Sim.Status` and `Sim.Cause`. `Action` and the editor's key names follow
  `Editor.Action` and `Editor.Key.Code`. `Direction` follows gasim's
  `Direction`. If you change one side, change the other.
- `engine.js` copies bytes into wasm memory with `withBytes` and frees
  them after the call. Text and JSON come back through one shared output
  buffer, so read each result before the next call.
- `statuses()` returns views into wasm memory that are valid only until
  the next call. `state.js:refresh` copies them.
- An empty answer from a JSON call means the module ran out of memory.
  `engine.js` throws an error then.
- Views read `state` and change it through `state.js`. Only `state.js`
  calls the engine.
- `state.js` runs the chip in `requestAnimationFrame` frames. It tunes the
  number of rounds per frame so a frame spends about `frameBudget`
  (8 ms) running.
- `state.js` caps what it keeps: 5,000 trace lines, 200 prompt lines, 500
  prompt answers and 8 recent files. When the console's text grows past
  `consoleCapacity` (64 Ki characters), `state.js` keeps only the last
  half of it.
- `?example=<name>` opens only names that match `/^[\w.-]+\.(ga|af|cf)$/`.
  It also opens examples that the menu hides.
- The private `state.js:keepWorkspace` saves the workspace 500 ms after a
  change, by calling `flushWorkspace`. It does nothing until `restore` has
  run. This keeps the last visit's workspace from being written over
  before it is read.
- The modules get Mithril from `window.m`, which the vendored script sets.
  Tests set up the same global in `harness.test.js`.

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- `engine.js:loadEngine` fetches `gasim.wasm` next to the page. The wasm
  module logs through `console.error`.
- `state.js` fetches `ga144.txt` (a ROM dump, served only if the build
  was given `-Drom`), `examples/index.json` and the examples.
- `store.js` keeps values in the IndexedDB database `gasim`, store
  `files`. `state.js` uses the keys `rom`, `history`, `recent` and
  `workspace`. Each call fails quietly where storage is blocked.
- `state.js:flushWorkspace` saves the workspace at once. `app.js` calls it
  on `beforeunload`, `pagehide` and when the page is hidden.
- `app.js` keeps the layout in `localStorage` under `layout`. It listens
  for `keydown`, `dragover` and `drop` on the document.
- `app.js` warns before leaving the page if the editor has changes that
  are neither saved nor kept in the browser.
- `state.js` reads and writes the user's files through the File System
  Access API, where the browser has it. Otherwise `saveEditor` saves the
  blocks as a download, named after the editor's file, or `blocks.cf` if
  it has no name yet.
- `state.js:saveTrace` always saves the trace as a download, `trace.txt`.
- `state.js:newEditorFile` asks the user with `confirm` before it drops
  unsaved blocks.

## Verification

- Run: `zig build test-web`

This builds the wasm module and runs the Deno tests in this folder
(`*.test.js`), with the repository's `deno.json`. It needs
[Deno](https://deno.com/). The tests load the real wasm module through
`harness.test.js`, so they test `engine.js`, `state.js` and
`views/map.js:fit` against the core. After `zig build web`, you can also
run `deno test --allow-read web/` by hand.

To try the page by hand, run `zig build serve`. It builds the page into
`zig-out/web` and serves it on http://localhost:8080. Add `-- PORT` for
another port. `zig build web` only builds it, and leaves out the
`*.test.js` files.
