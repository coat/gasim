# gasim

A cross-platform simulator for the [GreenArrays,
Inc.](https://www.greenarraychips.com) [GA144 multi-computer
chip](https://www.greenarraychips.com/home/documents/index.php#GA144).

## Usage

```bash
gasim examples/hello.ga
```

This assembles the program and runs it on a simulated 8x18 array of F18A
nodes, like the GA144, until every node is waiting on something that cannot
happen. Nodes without a program wait for code on all of their ports.

A console is attached to the `up` port of node 000, which faces off the
south edge of the chip. Each word written to it is printed as a byte, and
each read from it takes a byte from stdin:

```bash
echo "hello" | gasim examples/echo.ga
```

Programs can span several nodes with the `node` directive. In
`examples/upcase.ga`, node 000 passes input to its neighbour, node 001,
which converts it to upper case:

```bash
echo "hello" | gasim examples/upcase.ga
```

Options:

- `--layout <rows>x<columns>`: size of the array of nodes, up to 100x100
  (default `8x18`)
- `--console <node>:<port>`: where the console is attached, on a port facing
  off the edge of the array (default `000:up`)
- `--rom <file>`: ROM dump to load into the nodes (default `rom/ga144.txt`,
  if it exists)
- `--boot`: load programs with a boot stream through the SERDES port of node
  001, as one GA144 boots another, instead of writing them straight into RAM.
  This needs ROM.

See [`src/assembler.zig`](src/assembler.zig) for the assembler syntax.

### ROM

The GA144's ROM, copyright GreenArrays, Inc., is in
[`rom/ga144.txt`](rom/ga144.txt) and loaded by default when gasim runs from
this directory. See [`rom/README.md`](rom/README.md) for where it came from and
its format.

With ROM, each node gets the ROM of the GA144 node with the same number, and
the boot nodes start in their boot code after reset, as on the real chip.
Programs can also call ROM words such as `*.17` and `warm` by name.

Without ROM, nodes without a program wait for code on their ports, and
programs cannot call ROM words.

## Download

[Download](https://sadbeast.com/gasim/download.html) a static binary for your operating system.

If you have Nix installed, try `nix run github:coat/gasim#`.

## Building

To build `gasim`, [zig 0.17.0](https://ziglang.org/download/) is required.

```bash
zig build -Doptimize=ReleaseFast
```

`gasim` will be available in `./zig-out/bin/gasim`.

### TODO

- [x] Comm ports and console I/O
- [x] Multi-node chip
- [x] ROM and booting
- [ ] TUI
- [ ] colorForth editor and compiler

## Prior Art

- GreenArrays' own SOFTSIM available in their free [arrayForth
distribution](https://www.greenarraychips.com/home/support/download-03d.php).
Works well under wine.
- [AshleyF/Color](https://github.com/AshleyF/Color) - A colorForth editor,
assembler and F18 simulator written in F#.
- [mschuldt/ga144-sim](https://github.com/mschuldt/ga144-sim) - GA144 simulator
from an [alternative toolchain](https://github.com/mschuldt/ga-tools).

## References

- Incredibly informative [blog
series](https://github.com/AshleyF/Color/blob/master/Docs/chuck_moores_creations.md)
by [AshleyF](https://github.com/AshleyF) that introduces the F18 architecture
and instruction set.
- GreenArrays' own concise, but very informative
[documentation](https://www.greenarraychips.com/home/documents/index.php) on
the GA144 chip and F18 architecture.
- [colorForth instruction
set](https://mschuldt.github.io/www.colorforth.com/inst.htm)
