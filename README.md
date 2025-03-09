# gasim

A cross-platform simulator for the [GreenArrays,
Inc.](https://www.greenarraychips.com) [GA144 multi-computer
chip](https://www.greenarraychips.com/home/documents/index.php#GA144) or a
virtual multi-computer with any number of [F18 18-bit
computers](https://www.greenarraychips.com/home/documents/index.php#F18A).

## Building

To build gasim, zig 0.14.0 is required.

```bash
zig build install
```

`gasim` executable will be available in `./zig-out/bin/gasim`.

## Usage

```bash
gasim file.ga
```

## Configuration

By default `gasim` will simulate a GA144 chip with 144 F18 computers. To
specify custom number of F18 computers, use the `-n` flag.

```bash
gasim -n 4 examples/file.ga
```

This will attempt to simulate a multi-computer with a square geometry of 4 F18
computers, with a numbering scheme that follows the GA144 chip.

### Profiles

You can further customize your own multi-computer by creating an INI file. For
example, here's the profile for the GA144 chip:

```ini
computers = 144
rows = 8
columns = 18
```

To simulate the above profile saved as `ga144.ini`, use the `-p` flag:

```bash
gasim -p ga144.ini file.ga
```

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
