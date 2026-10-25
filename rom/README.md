# GA144 ROM

`ga144.txt` holds the ROM of every node of a GreenArrays G144A12 chip.

The ROM is copyright © GreenArrays, Inc. It is documented in the [G144A12 Chip
Reference](https://www.greenarraychips.com/home/documents/index.php#GA144)
(DB002), and its source is part of GreenArrays'
[arrayForth](https://www.greenarraychips.com/home/support/download-03d.php)
distribution.

The contents were read from a chip by Michael Schuldt, and this file is
`raw-rom-dump.txt` from [mschuldt/ga144-sim](https://github.com/mschuldt/ga144-sim)
at commit `de5974a`.

## Format

For each node, its number on a line, followed by its 64 ROM words, for
addresses x080 to x0bf, in decimal, one per line. Words are as stored in
memory, so instruction words are XORed with x15555.
