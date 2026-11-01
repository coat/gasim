# arrayForth

Files ending in `.af` are read as arrayForth 3 source, the F18 assembler
syntax of GreenArrays' current tools, described in section 4.2 of DB013,
the arrayForth 3 User's Manual. Code is assembled into bins between `ASM[`
and `]ASM`, packed into the same object code arrayForth 3 makes. See
[`src/arrayforth.zig`](src/arrayforth.zig) for what is supported. Each
example has an arrayForth 3 version, such as `examples/echo.af`:

```
ASM[ # 0 NODE ERS  # 0 org
: main  up b!  begin @b !b again
>BIN ]ASM
```

Files ending in `.blk` are read as polyFORTH blocks of arrayForth 3 source,
such as the disks arrayForth 3 keeps its source and projects in. Block 0 is
loaded unless `--load` names other blocks, which are loaded in turn, and
blocks can load others with `LOAD`, `THRU` and `FH`. For example, this
assembles the Ethernet NIC from the arrayForth 3 distribution, after the
block that configures where its modules are:

```
$ gasim --listing --load 1562 --load 2001 sF/pFDISK.blk
```

arrayForth 3's boot descriptors, such as `107 +NODE 1614 /RAM DOWN /B`, say
what to load into nodes and how to start them, with registers and stacks
set. When a program has them, gasim sets up nodes as they say, directly or
with `--boot`, instead of loading each bin into its own node. This loads
the SRAM cluster with its descriptors, which are in the block after its
load block:

```
$ gasim --load 2331 --load 2332 sF/pFDISK.blk
```

## arrayForth 3 prompt

`gasim aforth` is basically an  arrayForth 3 outer interpreter. Code can be
assembled into bins and the words of arrayForth 3's IDE act on the simulated
chip: `NODE` picks a node, `UPD` shows its stacks, `LIT` pushes onto them,
`BOOT` loads a bin into its RAM, `CALL` runs code there, and `?RAM`, `-ASM`,
`R@` and `R!` look at and change it. A program given after `aforth` is loaded
first, and the bins and labels of an arrayForth 3 program stay available.
Outside `ASM[`, `: name … ;` defines a host word, with `IF`, `BEGIN`, `FOR`
and `DO` loops, such as `: dump ( a n) 0 DO DUP I + R@ D. LOOP DROP ;`.

```
$ gasim aforth
707 NODE  x15. LIT  RDUP R+  UPD
      0      0      0      0
      0      0      0      0      0     42
R      0      0      0      0      0      0      0      0      0
 ok
ASM[ # 707 NODE  : 2x 2* ; >BIN ]ASM  0 1 707 BOOT  0 CALL  UPD
      0      0      0      0
      0      0      0      0      0     84
R      0      0      0      0      0      0      0      0      0
 ok
```

