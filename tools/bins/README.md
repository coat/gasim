# bins

## Overview

`bins` writes the SHA-256 of each bin of code in arrayForth 3's object
file, `sF/OBJ-AF3`. A bin is the code for one node. The output is the ZON
list in `src/af3-bins.zon`. gasim's tests assemble GreenArrays' stock code
and check each bin against these digests. See
[The ROM](../../docs/rom.md) for where to find `OBJ-AF3`.

```bash
zig build bin-digests -- <OBJ-AF3> > src/af3-bins.zon
```

## Interface

- `main.zig:main` reads the file named by its one argument and prints the
  ZON list on stdout. Each entry has the form
  `.{ .bin = <number>, .sha256 = "<hex>" }`.
- `src/rom.zig:af3_bins` imports the list it writes.

## Invariants

These are the rules that the code relies on, and that a change must keep.

- The file must hold at least `main.zig:bins` (4 chips of 144 nodes, so
  576) blocks of `main.zig:block_size` (1024) bytes.
- Only the first `main.zig:ram_size` (256) bytes of each block are hashed.
  They are the node's 64 words of RAM, 4 bytes each, highest byte first.
- A bin whose RAM is all `main.zig:empty` (`call warm`) has no code, and
  is left out.
- Bins count the nodes of a chip row by row, and the chips one after
  another.
- `src/af3-bins.zon` is generated. Change it by running this tool, not by
  hand.

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- It reads the object file, and writes only to stdout.
- It exits with status 2 on wrong usage, and 1 if the file is too short.

## Verification

- Run: `zig build bin-digests -- <OBJ-AF3>`
- Run: `zig build test` to check the digests against the stock code. The
  test needs `rom/pFDISK.blk`, and is skipped without it.
