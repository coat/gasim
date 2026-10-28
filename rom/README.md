# GA144 ROM

The ROM of the nodes of a GreenArrays G144A12 chip is copyright ©
GreenArrays, Inc., and not part of gasim. It is documented in the [G144A12
Chip Reference](https://www.greenarraychips.com/home/documents/index.php#GA144)
(DB002), and its source is in `sF/pFDISK.blk` of GreenArrays'
[arrayForth 3](https://www.greenarraychips.com/home/support/download-03d.php)
distribution, which gasim assembles it from (see `src/rom.zig`).

## Format

gasim saves the ROM it assembles as a dump in text, which `--rom` also
reads: for each node, its number on a line, followed by its 64 ROM words,
for addresses x080 to x0bf, in decimal, one per line. Words are as stored in
memory, so instruction words are XORed with x15555.

## Checking the arrayForth 3 assembler

With arrayForth 3's disk copied here as `rom/pFDISK.blk`, which git ignores,
`zig build test` assembles every node's ROM from it and checks it is the
same as a G144A12's, by its SHA-256. That is of the ROM as read from a chip
by Michael Schuldt, `raw-rom-dump.txt` from
[mschuldt/ga144-sim](https://github.com/mschuldt/ga144-sim) at commit
`de5974a`. The tests that need the ROM are skipped without the disk.
