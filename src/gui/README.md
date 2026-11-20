# gui

## Overview

This folder is `gasim-gui`, gasim's desktop app. It draws the core's `Sim`
in a window with [dvui](https://github.com/david-vanderson/dvui) and SDL3.
The build adds it only with `-Dgui`, because that option fetches dvui and
SDL3.

The GUI shows the same things as the web version: a toolbar, a map of the
chip's nodes, a panel for the selected node, and a dock of tabs below the
map. It also has a colorForth block editor. Each module keeps its state in
module-level variables. `ui.zig` starts and stops `files`, `dock` and
`editor`, and `dock.zig` starts and stops `debug`.

| File | What it does |
| --- | --- |
| `main.zig` | Starts the dvui app, finds the folders it uses, reads the command line and opens the first file. |
| `ui.zig` | Owns the one `Sim`, and draws each frame: the toolbar, the map, the node panel and the status line. Handles the keys. |
| `dock.zig` | Draws the tabs below the map: the arrayForth 3 prompt, the console, and the debug tabs. |
| `debug.zig` | Draws the trace, breakpoints and history tabs for `dock.zig`. |
| `editor.zig` | Draws the colorForth block editor: the block list, the block, and the color bar. |
| `files.zig` | Opens files, examples and the ROM, and saves the workspace between runs. |
| `config.zig` | Reads the settings in `gui.json`: fonts, colors and the Examples menu. |
| `style.zig` | Turns the fonts and base16 colors from `gui.json` into a dvui theme. |
| `help.zig` | Draws the keys dialog, and switches the theme between Auto, Light and Dark. |

## Interface

The GUI is an app, not a library. These are the entry points that the
modules use to call each other.

- `main.zig:dvui_app` describes the app to dvui. It passes `start`, `init`
  and `deinit`, and sets `ui.frame` as the frame function.
- `main.zig:init` finds the data, state, config and examples folders,
  starts `ui`, and reads `gui.json` from gasim's config folder. It reads
  `--rom <path>` and a file from the command line. Then it opens the ROM
  and the file, restores the last workspace, and applies the theme.
- `ui.zig:sim` is the one `gasim.Sim` that the whole GUI drives.
- `ui.zig:start` and `ui.zig:stop` start and stop `files`, `dock` and
  `editor`, and set up or free the `Sim`.
- `ui.zig:frame` draws one frame and runs the chip for part of it.
- `ui.zig:open` loads a file into the `Sim` by its extension
  (`Sim.Kind.ofPath`). It opens the editor for a `.cf` file.
- `ui.zig:say` shows a message in the status line.
- `ui.zig:running` says whether the chip runs, `ui.zig:selected` which
  node is selected, and `ui.zig:view` whether the chip or the editor
  shows.
- `dock.zig:draw` draws the dock. `dock.zig:service` passes console input
  and output between the dock and the `Sim`. `dock.zig:interpret` runs a
  line at the arrayForth 3 prompt on the selected node.
- `debug.zig:service` takes the trace from the `Sim` each frame, and
  `debug.zig:setTracing` turns tracing on or off.
- `editor.zig:draw` draws the editor, and `editor.zig:key` gives it a key.
  `editor.zig:opened` notes the file to save back to.
- `files.zig:open` opens a file, and `files.zig:openExample` opens an
  example. `files.zig:reload` reads the current file again.
- `files.zig:drop` notes a file dropped on the window.
  `files.zig:openDropped` opens it, and `ui.zig:frame` calls it first in
  each frame.
- `files.zig:savedAs` makes the file that the editor saved to the open
  file. `editor.zig:save` calls it.
- `files.zig:findRom` loads the ROM from `--rom` or from the data folder.
  `files.zig:romDialog` shows the ROM dialog.
- `files.zig:restoreWorkspace` reads the workspace, and
  `files.zig:keepWorkspace` writes it.
- `config.zig:load` reads the settings file and applies it.
- `style.zig:theme` builds the dvui theme, and `help.zig:apply` sets it.

The core that the GUI drives is described in [`src/`](../README.md). The
GUI's keys match the web version's. See [docs/](../../docs/README.md) for
how to use gasim.

## Invariants

These are the rules that the code relies on, and that a change must keep.

- `ui.zig:sim` must not move. Its doc comment says that it keeps pointers to
  its own fields, so it lives in a global.
- `ui.zig:stop` stops `files`, `dock` and `editor` first, then calls
  `sim.deinit` last.
- `main.zig:init` opens things in a fixed order: `ui.start`, then
  `files.examples_dir`, then `config.load`, then `files.findRom`, then
  `files.open`, then `files.restoreWorkspace`, then `help.apply`. A file
  given on the command line wins over the one the last run had open.
- `ui.zig:frame` handles the keys last, so they see only the events that no
  widget took.
- `ui.zig:runFrame` changes how many rounds it runs per frame to keep the
  chip near an 8 ms budget (`frame_budget_ns`). The count stays between
  1,000 and 2,000,000.
- Chip keys act only when the chip view shows, the help dialog is closed
  (`ui.zig:keys`), and no text entry has focus. `dock.zig:typing` covers
  the prompt, the console and the watch entry. `files.zig:typing` covers
  the entry for which blocks to load.
- The dock keeps at most 500 prompt entries and 200 history lines, and the
  last 64 KiB of console output (`dock.zig:interpret`,
  `dock.zig:service`).
- The trace keeps at most 5,000 lines (`debug.zig:service`).
- The recent files list keeps at most 8 files (`files.zig:keepRecent`).
  `files.zig:open` doesn't add examples to it. `keepRecent` itself doesn't
  check, so a new caller must.
- `files.zig:isRom` treats a file as a ROM when its name ends in `.txt` or
  is `pFDISK.blk`. Both checks ignore case.
- `files.zig:readExample` refuses names that `gasim.examples.isExample`
  rejects, and names that contain `/`, `\` or `:`.
- Every setting in the settings file is optional. The GUI ignores fields it
  does not know (`config.zig:load`).

## Side effects

This is what the code does outside its own memory, such as reading a
file.

In this section, `<data>`, `<state>` and `<config>` are gasim's own
folders. On Linux they are `~/.local/share/gasim`, `~/.local/state/gasim`
and `~/.config/gasim`, unless the `XDG_*_HOME` variables say otherwise.

The GUI uses two files named `gui.json`, in two different folders:

| File | Who uses it | What it holds |
| --- | --- | --- |
| `<config>/gui.json` | `config.zig:load` reads it. The GUI never writes it. | Fonts, colors, and whether to show the Examples menu. |
| `<state>/gui.json` | `files.zig:restoreWorkspace` reads it. `files.zig:keepWorkspace` writes it when the GUI stops. | The workspace (`files.zig:Workspace`): the open file and recent files, the selected node, the view, the map's tile mode, breakpoints, watches, whether tracing is on, the dock's tab, the prompt's history, the theme, the panes, and the editor's format and marks settings. |

The settings file may be a read-only link, such as one that Home Manager
makes into the Nix store. That is why the GUI never writes it.

Other side effects:

- `main.zig:dataDir`, `main.zig:stateDir` and `main.zig:configDir` read
  `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CONFIG_HOME` and `HOME`. On
  Windows they read `LOCALAPPDATA` and `APPDATA`.
- `main.zig:examplesDir` looks for the examples in several folders. It
  tries `<exe>/examples`, then `<exe>/../share/gasim/examples`, then
  `<data>/examples`, then each folder in `XDG_DATA_DIRS`.
- `files.zig:keepRom` writes the ROM to `<data>/ga144.txt`.
  `files.zig:forgetRom` deletes it.
- `files.zig:pick`, `files.zig:romDialog` and `debug.zig:saveTrace` open
  native file dialogs. `editor.zig:save` opens one only for "save as", or
  when the blocks have no file yet. `editor.zig:save` writes the blocks,
  and `debug.zig:saveTrace` writes the trace.
- `main.zig:init` adds an SDL event watch for files dropped on the window.
  `main.zig:deinit` removes it.
- `style.zig:set` reads the font files named in the settings file.

## Verification

- Run the GUI's tests: `zig build test-gui -Dgui`. They open a hidden
  window, so they need a display. `zig build test` does not run them.
- Save what the tests draw as PNG files: `zig build test-gui -Dgui
  -Dgui-images=<dir>`
- Run the GUI: `zig build run-gui -Dgui`
