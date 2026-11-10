# arrayForth

gasim reads two kinds of arrayForth 3 files:

- `.af`: arrayForth 3 source
- `.blk`: polyFORTH blocks of arrayForth 3 source

arrayForth 3 is GreenArrays' current toolset. Its F18 assembler syntax is
described in section 4.2 of DB013, the arrayForth 3 User's Manual. See
[`src/arrayforth.zig`](../src/arrayforth.zig) for what gasim supports.

## Source files

Code between `ASM[` and `]ASM` is assembled into bins. gasim packs them into
the same object code that arrayForth 3 makes.

Each example has an arrayForth 3 version. This is `examples/echo.af`:

```
ASM[ # 0 NODE ERS  # 0 org
: main  up b!  begin @b !b again
>BIN ]ASM
```

## Block files

A `.blk` file holds blocks, like the disks arrayForth 3 keeps its source and
projects in.

- gasim loads block 0, unless `--load` names other blocks.
- You can give `--load` more than once. gasim loads the blocks in turn.
- Blocks can load other blocks with `LOAD`, `THRU` and `FH`.

For example, this assembles the Ethernet NIC from the arrayForth 3
distribution. Block 1562 first sets where its modules go:

```
$ gasim --listing --load 1562 --load 2001 sF/pFDISK.blk
```

## Boot descriptors

arrayForth 3's boot descriptors say what to load into nodes and how to start
them, with their registers and stacks set. For example:

```
107 +NODE 1614 /RAM DOWN /B
```

When a program has descriptors, gasim sets up the nodes as they say,
instead of loading each bin into its own node. It does this directly, or
with a boot stream if you give `--boot` (see [Boot streams](boot.md)).

This loads the SRAM cluster with its descriptors, which are in the block
after its load block:

```
$ gasim --load 2331 --load 2332 sF/pFDISK.blk
```

## arrayForth 3 prompt

`gasim aforth`, and the aforth panel in the [TUI](tui.md), work like
arrayForth 3's interactive prompt (its outer interpreter). You can assemble
code into bins, and use the words of arrayForth 3's IDE on the simulated
chip:

| Word | What it does |
| --- | --- |
| `NODE` | picks a node |
| `UPD` | shows its stacks |
| `LIT` | pushes a number onto its stack |
| `BOOT` | loads a bin into its RAM |
| `CALL` | runs code there |
| `?RAM`, `-ASM`, `R@`, `R!` | look at and change its RAM |
| `WORDS` | lists the words |

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

If you give a program after `aforth`, gasim loads it first. The bins and
labels of an arrayForth 3 program stay available at the prompt.

### Host words

Outside `ASM[`, `: name … ;` defines a word that runs on the host. Host
words can use `IF`, and `BEGIN`, `FOR` and `DO` loops. For example:

```
: dump ( a n) 0 DO DUP I + R@ D. LOOP DROP ;
```

### Scripts

`aforth` reads lines from stdin, or from `-e`. Except at a terminal, errors
go to stderr, and gasim exits 1 if a line failed. See [Scripting with the
CLI](cli.md) for `--from` and `--to`.
