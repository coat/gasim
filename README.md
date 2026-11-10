# gasim

A cross-platform simulator for the [GreenArrays,
Inc.](https://www.greenarraychips.com) [GA144 multi-computer
chip](https://www.greenarraychips.com/home/documents/index.php#GA144).

![The chip, console, aforth and node panels](docs/screenshot-chip.png)

With gasim you can:

- run programs written in F18 assembly (`.ga`), arrayForth 3 (`.af`, `.blk`)
  or colorForth (`.cf`)
- step through them and watch every node in a terminal UI, a desktop GUI or
  a web browser
- edit colorForth blocks in a built-in editor
- script, debug and test runs from the command line
- simulate GreenArrays' EVB002 evaluation board, with its two chips, SPI
  flash, SRAM and USB serial ports

## Install

- Download `gasim` and the desktop GUI, `gasim-gui`, from the [GitHub
  Releases](https://github.com/coat/gasim/releases) page.
- Try the [web version](https://coat.github.io/gasim/) in your browser.
- With Nix, run `nix run github:coat/gasim`, or `nix run github:coat/gasim#gui`
  for the GUI.

See [Installing](docs/install.md) for where the examples are, and how to set
the GUI's fonts and colors.

## Usage

```bash
gasim examples/hello.ga
```

This loads the program onto a simulated GA144: an 8x18 array of F18A nodes.
It opens the terminal UI (TUI). Nodes without a program wait for code on all
their ports. You can also start `gasim` without a program and load code from
the aforth panel. Press `q` to quit.

To run a program without the TUI, use `run`. gasim also runs the program
when stdin or stdout is not a terminal. A console is attached to the `up`
port of node 000, and it reads stdin and writes stdout:

```
$ gasim run examples/hello.ga
Hello, world!
$ echo "hello" | gasim examples/echo.ga
hello
```

The run ends when every node is waiting for something that can no longer
happen.

A program can use several nodes. In `examples/upcase.ga`, node 000 passes
its input to node 001, which converts it to upper case:

```
$ echo "hello" | gasim examples/upcase.ga
HELLO
```

### TUI

The TUI is a work in progress. Everything is on one page, in panels that you
can resize, maximize and hide. Use Tab and Shift+Tab to move between panels.
The console and aforth panels have an input prompt, so you can also press
Alt+1 to Alt+5 to jump to a panel. Ctrl works too, in terminals that report
it. The mouse works too.

The status bar shows the keys you can use. Press `?` or F1 to see all of
them. See [TUI](docs/tui.md) for more.

### colorForth

![The colorForth block editor](docs/screenshot-colorforth.png)

gasim has a built-in colorForth editor, inspired by AshleyF's
[Color](https://github.com/AshleyF/Color) editor. Open a `.cf` file to start
in the editor (`gasim examples/hello.cf`), or press Alt+6 in the TUI to edit
a new file of blocks. Use `:w`, `:e` and `:new` to save, open and start
files.

To print a `.cf` file as text, run `gasim cf text examples/hello.cf`.

See [colorForth](docs/colorForth.md) for the keys and more.

### arrayForth

gasim reads files ending in `.af` as arrayForth 3 source. This is the F18
assembler syntax of GreenArrays' current tools.

```
$ gasim run examples/hello.af
Hello, world!
$ echo "hello" | gasim examples/echo.af
hello
```

The aforth panel in the TUI, and `gasim aforth`, work like arrayForth 3's
interactive prompt. See [arrayForth](docs/arrayForth.md) for more.

### Scripting

You can do everything the TUI does with commands. This is useful for
scripts, CI and AI agents. gasim saves the chip's state in a snapshot file.
Each command reads one snapshot and writes another. `--json` prints the
result as a JSON object.

```
$ gasim start examples/hello.ga -o 0.snap
$ gasim run --from 0.snap --to 1.snap --break 000:004 --json
{"stop":"breakpoint","node":"000","address":"004","steps":148,"time_ps":34800,"output":"","snapshot":"1.snap"}
$ gasim show 1.snap 000 --mem --count 2
$ gasim step --from 1.snap --to 2.snap --node 000 --count 3
```

`gasim test` checks what a program should output and leave in its nodes.
See [Scripting with the CLI](docs/cli.md) for snapshots, tests and exit
codes, and [Options](docs/options.md) for every option. `gasim help
<command>` also lists them.

### Debugging

`--break`, `--watch`, `--trace`, `--why` and `--stats` show what a run is
doing. `gasim listing` shows the words a program assembles to.

```
$ echo hi | gasim run --why examples/upcase.ga
HI
info: node 000 waiting to read up
info: node 001 waiting to read right
info: 142 nodes waiting on several ports, as after reset
```

See [Debugging options](docs/options.md#debugging).

### Boards and serial ports

gasim can simulate the board around the chip. `--board evb002` gives you
GreenArrays' EVB002, with stdin and stdout on its USB serial port A:

```
$ gasim run --board evb002 examples/uart.ga
Hello, world!
```

You can describe your own chips and boards in files. You can also put a
board's serial ports on pseudo-terminals, so that other programs, such as
arrayForth 3 under Wine, can talk to the simulated chip. See:

- [Chip files](docs/chips.md)
- [Board files and the EVB002](docs/boards.md)
- [Serial ports](docs/serial.md)
- [Boot streams](docs/boot.md)

### ROM

The GA144's ROM belongs to GreenArrays, so it is not part of gasim. If you
have [arrayForth
3](https://www.greenarraychips.com/home/support/download-03d.php) installed,
gasim finds it and builds the ROM from its source. Without the ROM, nodes
wait for code, and programs cannot call ROM words. See [ROM](docs/rom.md).

## Documentation

All documentation is in [docs](docs/README.md).

## Building

You need [Zig 0.17.0](https://ziglang.org/download/).

```bash
zig build -Doptimize=ReleaseFast
```

This puts `gasim` in `./zig-out/bin/`. See [Building](docs/building.md) for
the GUI, the web version, tests and fuzzing, and
[Benchmarks](docs/benchmarks.md) for measuring speed.

## Prior art

- GreenArrays' own SOFTSIM, in their free [arrayForth
  distribution](https://www.greenarraychips.com/home/support/download-03d.php).
  It works well under Wine.
- [AshleyF/Color](https://github.com/AshleyF/Color): a colorForth editor,
  assembler and F18 simulator written in F#. gasim's colorForth editor is
  closely based on its vim-like editor.
- [mschuldt/ga144-sim](https://github.com/mschuldt/ga144-sim): a GA144
  simulator from an [alternative toolchain](https://github.com/mschuldt/ga-tools).

## References

- AshleyF's [blog
  series](https://github.com/AshleyF/Color/blob/master/Docs/chuck_moores_creations.md),
  which introduces the F18 architecture and instruction set.
- GreenArrays' own
  [documentation](https://www.greenarraychips.com/home/documents/index.php) on
  the GA144 chip and F18 architecture. It is concise and very informative.
- The [colorForth instruction
  set](https://mschuldt.github.io/www.colorforth.com/inst.htm).
