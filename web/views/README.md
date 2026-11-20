# web/views

## Overview

This folder holds the web version's views. Each file is a set of
[Mithril](https://mithril.js.org/) components that draw one part of the
page. The views read `state` from [`../state.js`](../state.js) and call its
functions to change it. They never call the wasm engine directly.

[`../app.js`](../app.js) puts the views together into two routes:
`/chip`, the chip's view, and `/editor`, the colorForth editor.

## Interface

| File | Exports | What it draws |
| --- | --- | --- |
| `map.js` | `ChipMap`, `fit`, `modes` | The chip's nodes as a grid of tiles, north at the top. |
| `node.js` | `NodePanel`, `hex` | The selected node: its registers, stacks, RAM and ROM, with a gutter to set breakpoints. |
| `dock.js` | `Dock`, `panels`, `showDock`, `unseen` | The tabbed panels under the map: the arrayForth 3 prompt, the console, and the debug panels. |
| `debug.js` | `Trace`, `traceHead`, `Breakpoints`, `breakpointsHead`, `History` | The dock's debug panels: the trace, the breakpoints and watches, and the history to go back to. |
| `editor.js` | `EditorView`, `colors` | The colorForth editor: the list of blocks, the block being edited, and a bar of colors. |
| `toolbar.js` | `Toolbar`, `StatusBar`, `RomDialog`, `HelpDialog`, `dialogs`, `applyTheme` | The toolbar at the top, the status bar at the bottom, and the ROM and help dialogs. |
| `follow.js` | `follow` | Hooks that keep a scrolling element at its end as it grows. |

Some details:

- `map.js:fit(mode, columns, lines, chip)` is a pure function. It returns
  the size of a tile of registers for a map of a given size, or null to
  show node numbers. `map.js:modes` lists the modes it takes: `auto`,
  `numbers` and `registers`.
- `dock.js:panels` maps each dock tab to its `label`, a `head` for the
  tab bar and a `body` component. `app.js` uses it to build the tabs on a
  narrow screen.
- `toolbar.js:dialogs.open` says which dialog is open: `'rom'`, `'help'`
  or null. `app.js` sets it from the `?`, `F1` and `Escape` keys.
- `node.js:hex(value, digits)` writes a number in hex, padded with zeros.
  `debug.js` uses it too.

## Invariants

These are the rules that the code relies on, and that a change must keep.

- Each file except `follow.js` gets Mithril from the global the vendored
  script sets, with `const { m } = window;`. The page must load
  [`../vendor/mithril.min.js`](../vendor/README.md) before these modules.
  `follow.js` uses no Mithril.
- To change the chip, the files or the engine, views call the functions
  that `../state.js` exports, such as `select`, `toggleBreakpoint` and
  `editorKey`. Views may set fields that only the page uses directly.
  Some are top level, such as `state.message`, `state.dock`, `state.editorTab`,
  `state.blockQuery` and `state.unseenOutput`. Others are nested, such as
  `state.trace.onlySelected` and `state.file.loads`. Views also clear
  `state.entries` and `state.console`.
- `map.js:ChipMap` calls `state.js:showRegisters` with true only while its
  tiles have room for registers. It calls it with false when it is
  removed. This keeps `state.tiles` null, and saves reading every node's
  registers, while the map shows only numbers.
- `editor.js:keyOf` sends alt with a letter in `ctrlLetters`
  (`'rygwtvbs'`) as ctrl with that letter. These are the color letters and
  `s`, to save. Browsers keep ctrl+w and ctrl+t for themselves.
- The History tab's head shows "of 64 kept" (`dock.js`). The 64 is typed
  in, and copies the core's `Sim.history_capacity`. If that changes,
  change this too.
- `editor.js` hides blue words with `token` returning null, and leaves
  them out of the row. Mithril throws on a hole among keyed children.
- `map.js:side` follows the chip's port names. On even columns, right
  faces east. On even rows, down faces north. Odd ones are the reverse.

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- `map.js` keeps the chosen tile mode in `localStorage` under `tiles`.
- `toolbar.js` keeps the theme in `localStorage` under `theme`, and
  `toolbar.js:applyTheme` sets or removes `data-theme` on the root
  element.
- Both fall back to the default for this visit when storage is blocked.
- `map.js:ChipMap` watches its body with a `ResizeObserver` and
  disconnects it when removed.
- `toolbar.js:Toolbar` adds a `resize` listener on `window` and removes it
  when removed. It measures the toolbar to choose whether to show labels.
- `node.js:NodePanel` and `follow.js:follow` scroll their elements.
- `toolbar.js:RomDialog` reads a file the user picks and passes it to
  `state.js:giveRom`, which saves it in the browser.

## Verification

- Run: `zig build test-web`

This runs the Deno tests in `web/`. Of the views, only `map.js:fit` has
tests, in `web/map.test.js`. Check other changes by hand with
`zig build serve`, which serves the page on http://localhost:8080.
