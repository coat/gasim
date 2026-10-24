# gasim

A cross-platform simulator for the [GreenArrays,
Inc.](https://www.greenarraychips.com) [GA144 multi-computer
chip](https://www.greenarraychips.com/home/documents/index.php#GA144).

## Usage

```bash
gasim examples/hello.ga
```

This assembles the program into the RAM of a single F18A node and runs it
until the node is waiting on something that cannot happen. A console is
attached to the node's `up` port. Each word written to it is printed as a
byte, and each read from it takes a byte from stdin:

```bash
echo "hello" | gasim examples/echo.ga
```

See [`src/assembler.zig`](src/assembler.zig) for the assembler syntax.

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
- [ ] Multi-node chip
- [ ] ROM implementations
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
