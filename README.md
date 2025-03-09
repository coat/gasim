# gasim

A cross-platform simulator for the [GreenArrays,
Inc.](https://www.greenarraychips.com) [GA144 multi-computer
chip](https://www.greenarraychips.com/home/documents/index.php#GA144).

## Building

To build `gasim`, [zig 0.14.0](https://ziglang.org/download/) is required.

```bash
zig build -Doptimize=ReleaseFast
```

`gasim` executable will be available in `./zig-out/bin/gasim`.

## Usage

```bash
gasim examples/hello.blk
```

This will launch the simulator with node 708 executing instructions streamed in
from `examples/hello.blk`.

## Prior Art

* GreenArrays own SOFTSIM available in their free [arrayForth
distribution](https://www.greenarraychips.com/home/support/download-03d.php).
Works well under wine.
* [AshleyF/Color](https://github.com/AshleyF/Color) - A colorForth editor,
assembler and F18 simulator written in F#.
* [mschuldt/ga144-sim](https://github.com/mschuldt/ga144-sim) - GA144 simulator
from the [alternative toolchain](https://github.com/mschuldt/ga-tools) written
in Python.

## References

* Incredibly informative [blog
series](https://github.com/AshleyF/Color/blob/master/Docs/chuck_moores_creations.md)
by [AshleyF](https://github.com/AshleyF) that introduces the F18 architecture
and instruction set.
* GreenArrays own concise, but very informative
[documentation](https://www.greenarraychips.com/home/documents/index.php) on
the GA144 chip and F18 architecture.
* [colorForth instruction
set](https://mschuldt.github.io/www.colorforth.com/inst.htm)
