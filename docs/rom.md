# GA144 ROM

The ROM of a GreenArrays G144A12 chip is copyright © GreenArrays, Inc., and
is not part of gasim. It is documented in the [G144A12 Chip
Reference](https://www.greenarraychips.com/home/documents/index.php#GA144)
(DB002). Its source is in `sF/pFDISK.blk` of GreenArrays' [arrayForth
3](https://www.greenarraychips.com/home/support/download-03d.php)
distribution. gasim assembles the ROM from that source, as arrayForth 3
does (see [`src/rom.zig`](../src/rom.zig)).

## What the ROM does

With ROM:

- each node gets the ROM of the GA144 node with the same number
- the boot nodes start in their boot code after reset, as on the real chip
- programs can call ROM words, such as `*.17` and `warm`, by name

Without ROM:

- nodes without a program wait for code on their ports
- programs cannot call ROM words
- `--boot` does not work

## Where gasim finds it

Without `--rom`, gasim looks for arrayForth 3 where its installer puts it:

- `C:\GreenArrays` on Windows
- Wine's C: drive on Linux and macOS, in `$WINEPREFIX` or `~/.wine`, such as
  `~/.wine/drive_c/GreenArrays/EVB002`

gasim assembles the ROM once, and saves it as `gasim/ga144.txt` in
`$XDG_DATA_HOME` (`~/.local/share` by default), or in `%LOCALAPPDATA%` on
Windows. After that, gasim loads the saved ROM and no longer needs
arrayForth 3. To assemble the ROM again, delete the saved file.

`--rom <path>` gives the ROM directly. The path can be:

- a ROM dump, in the format below
- arrayForth 3's disk, `sF/pFDISK.blk`
- the directory arrayForth 3 is installed in

## Format

gasim saves the ROM as a text dump, which `--rom` also reads. For each node,
the dump has:

1. the node's number, on its own line
2. its 64 ROM words, for addresses x080 to x0bf, in decimal, one per line

Words are as stored in memory, so instruction words are XORed with x15555.

## Checking the arrayForth 3 assembler

Copy arrayForth 3's disk to `rom/pFDISK.blk`, which git ignores. Then
`zig build test` assembles every node's ROM from it, and checks it matches
a real G144A12's ROM by its SHA-256.

The real ROM was read from a chip by Michael Schuldt. It is
`raw-rom-dump.txt` from
[mschuldt/ga144-sim](https://github.com/mschuldt/ga144-sim) at commit
`de5974a`.

Without the disk, the tests that need the ROM are skipped. The disk's
blocks also seed the fuzz test of polyFORTH blocks.
