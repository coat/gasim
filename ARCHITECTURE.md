# gasim's architecture

This page is for people and agents who change gasim's code. To use gasim,
see the [README](README.md) and the [docs](docs/README.md).

gasim has one core and three front ends. The core in `src/` simulates the
chip and does no I/O of its own. The `gasim` command, the desktop GUI and
the web version each give it files, a terminal or a window. The tools in
`tools/` help build, check and measure gasim, but they are not part of it.

Each code folder has its own README. It lists the folder's interface, its
invariants and its side effects. An invariant is a rule that the code
relies on, and that a change must keep. A side effect is anything the code
does outside its own memory, such as reading a file.

## What the build defines

`build.zig` is the only code at the top level. It builds these from
`src/`:

- The `gasim` module comes from `src/root.zig`. The command, the GUI and
  the tests import it.
- The `gasim` command comes from `src/cli/main.zig`.
- `gasim-gui` comes from `src/gui/main.zig`. The build adds it only with
  `-Dgui`.
- The wasm core comes from `src/web/main.zig`. In a Debug build, it is
  built ReleaseSmall, because Debug wasm is slow.

The wasm core and `ga-tools-check` don't import the `gasim` module. Each
makes its own module from `src/root.zig`, for its own target and optimize
mode.

These are the build's steps:

| Step | What it does |
| --- | --- |
| `zig build` | Installs `gasim`, the examples in `share/gasim/examples`, and `gasim-gui` with `-Dgui`. |
| `run` | Runs `gasim`, with the arguments after `--`. |
| `test` | Runs the core's tests and the command's tests, `gasim test examples/test.zon` and `examples/test.zig`. |
| `wasm` | Builds the wasm core. |
| `web` | Installs `web/` without its `*.test.js` files, the wasm core, the examples and their `index.json` (from `tools/examples`) into `zig-out/web`. With `-Drom=<dump>`, it adds the dump as `ga144.txt`. |
| `test-web` | Runs the web version's tests, with Deno. |
| `serve` | Builds `web` and serves it on localhost. |
| `run-gui`, `test-gui` | Run the GUI, and its tests. Both need `-Dgui`. |
| `bench`, `bin-digests`, `ga-tools` | Run the tools in `tools/`. |

These are the build's options:

| Option | What it does |
| --- | --- |
| `-Dcoverage` | `test` runs the core's and the command's tests under `kcov`, and installs the merged report in `zig-out/coverage`. |
| `-Dfuzz` | Builds the tests with LLVM, which `--fuzz` needs. |
| `-Disocline` | Edits lines at the prompt with isocline, which links libc. On by default. |
| `-Dstrip` | Leaves out debug info, as the releases do. |
| `-Dgui`, `-Dgui-images` | Build the GUI, and save what `test-gui` draws as PNG files. |
| `-Drom`, `-Dga`, `-Dga-rom`, `-Dbench-base` | Give the `web`, `ga-tools` and `bench` steps what they need. |
| `-fsys=sdl3`, `-fno-sys=sdl3` | Link the system's SDL3, or build it from source. Linking is the default on Linux, because SDL3 built from source finds no display on NixOS. |

The install steps leave out the files in `examples/` that end in `.zig` or
`test.zon` (`build.zig:examples_excluded`).

## Folders

- [`src`](src/README.md) is the core module. It has the assemblers for
  `.ga`, `.af`, `.blk` and `.cf`, boot streams, the chip and its F18A
  nodes, devices, boards and snapshots. It also has `Sim`, which the GUI
  and the web version use.
  - [`src/cli`](src/cli/README.md) is the `gasim` command: its options,
    `run`, `step`, `start`, `show`, `test`, the TUI and the arrayForth 3
    prompt. It owns the exit codes.
  - [`src/gui`](src/gui/README.md) is `gasim-gui`, built with dvui and
    SDL3.
  - [`src/web`](src/web/README.md) holds the functions that the wasm core
    exports for the web version.
  - `src/boards` and `src/chips` hold only `.zon` files, which
    `Board.zig:evb002` and `Spec.zig:ga144` import.
- [`web`](web/README.md) is the web version: JavaScript modules with
  Mithril, around the wasm core.
  - [`web/views`](web/views/README.md) holds the page's Mithril
    components.
  - [`web/vendor`](web/vendor/README.md) holds Mithril, which is not
    gasim's code.
- [`tools`](tools/README.md) holds the developer tools `bench`, `bins`,
  `examples`, `ga-tools` and `serve`. Each has its own build step, except
  `examples`, which the `web` step runs.
- `examples`, `tests`, `docs`, `nix` and `rom` hold programs, test data,
  docs, the Home Manager module and the arrayForth 3 disk. They have no
  README of this kind.

## Rules across folders

- Outside its tests, the core does no file I/O. The only exception is
  `examples.zig:list`, which reads the folder it is given. The front ends
  do all other I/O. The core's tests read `rom/pFDISK.blk`, fuzz seeds and
  `examples/`.
- Only `web/state.js` calls the wasm engine. The views read the state and
  call `state.js`.
- The enums in `web/engine.js` must match `Sim.zig`, `Editor.zig` and
  `port.zig`. Change both sides together.
- A snapshot starts with `gasimsnp` and a hash of its types
  (`snapshot.zig:typeHash`) and of `snapshot.zig:format_version`. When the
  types or the version change, older snapshots give `error.OtherVersion`.
  Raise `format_version` when you change what `snapshot.zig:write` writes
  by hand.
- `zig build bin-digests` makes `src/af3-bins.zon`. Don't edit it by hand.
- arrayForth 3's interpreter keeps its state on the stack while it
  assembles, so assembling the ROM needs more than 1 MiB of stack. This is
  why `build.zig` gives the wasm core 8 MiB (`wasm.stack_size`).
- Without `rom/pFDISK.blk`, the ROM tests are skipped. CI has no copy of
  it.

## What gasim changes outside itself

- The command, the GUI and `ga-tools` read the ROM that gasim saved in
  `$XDG_DATA_HOME/gasim/ga144.txt`, or `~/.local/share/gasim/ga144.txt`.
  The command and the GUI also write it there. On Windows, without
  `XDG_DATA_HOME`, the command and the GUI use `%LOCALAPPDATA%\gasim`
  instead.
- The command keeps the prompt's history in `$XDG_STATE_HOME/gasim`, or
  `~/.local/state/gasim`. The
  GUI keeps its settings and its workspace in two `gui.json` files, one in
  its config folder and one in its state folder.
- The web version keeps its files in the browser's IndexedDB database
  `gasim`, and a few settings in `localStorage`.
- `zig build bench` writes to `.zig-cache/bench`. `zig build serve`
  listens on `127.0.0.1`, port 8080 by default.

## How to check a change

- Run the core's and the command's tests: `zig build test`
- Run the GUI's tests: `zig build test-gui -Dgui`
- Run the web version's tests: `zig build test-web`
