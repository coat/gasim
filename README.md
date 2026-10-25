# gasim

A cross-platform simulator for the [GreenArrays,
Inc.](https://www.greenarraychips.com) [GA144 multi-computer
chip](https://www.greenarraychips.com/home/documents/index.php#GA144).

## Usage

```bash
gasim examples/hello.ga
```

This assembles the program onto a simulated 8x18 array of F18A nodes, like
the GA144, and opens it in a terminal user interface. Nodes without a
program wait for code on all of their ports.

A console is attached to the `up` port of node 000, which faces off the
south edge of the chip. Each word written to it is printed as a byte, and
each read from it takes a byte of input.

With `run`, or when stdin or stdout is not a terminal, gasim runs the program
until every node is waiting on something that cannot happen, with the
console on stdin and stdout instead:

```bash
gasim run examples/hello.ga
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
- `--break <node>:<address>`: stop when the node is about to fetch the word at
  the address, given in hex, and print its stacks and registers. Literals
  are never fetched as instructions, so a breakpoint on one never stops. Can
  be given more than once.
- `--watch <node>:<port>[:read|:write]`: stop when the node reads from or
  writes to the port, or only one of those, and print the value. Reads include
  instruction words the node fetches from the port, such as a boot stream. Can
  be given more than once.
- `--trace`: with `run`, write a line to stderr for each word a node executes:
  the node, the word's address, the raw word, its opcodes, and T, S and R
  after it.

```
$ gasim run --trace --break 000:004 examples/hello.ga
000 000 04b12 @p b! @p .  T 00007 S 00000 R 00000
...
000 003 2bcba a! @+ >r .  T 00000 S 00000 R 0000d
info: node 000 reached 004
info: P 004  T 00000  S 00000  R 0000d  A 00008  B 145
```

- `--why`: with `run`, once every node is waiting, say what each one is
  waiting on. Nodes waiting on several ports, as they do after reset, are
  only counted.

```
$ echo hi | gasim run --why examples/upcase.ga
HI
info: node 000 waiting to read up
info: node 001 waiting to read right
info: 142 nodes waiting on several ports, as after reset
```

- `--listing`: instead of running, write each node's words: the address, the
  raw word, its opcodes or literal value, and the source line it came from.

```
$ gasim --listing examples/hello.ga
node 000
000 04b12  @p b! @p .                 7      up b!                  \ B addresses the console
001 00145  literal up
002 00007  literal 7                  8      'message a!            \ A walks through the message
...
```

See [`src/assembler.zig`](src/assembler.zig) for the assembler syntax.

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

### arrayForth 3 prompt

`gasim repl` is basically an  arrayForth 3 outer interpreter. Code can be
assembled into bins, and the words of arrayForth 3's IDE act on the simulated
chip: `NODE` picks a node, `UPD` shows its stacks, `LIT` pushes onto them,
`BOOT` loads a bin into its RAM, `CALL` runs code there, and `?RAM`, `-ASM`,
`R@` and `R!` look at and change it. A program given after `repl` is loaded
first, and the bins and labels of an arrayForth 3 program stay available.
Outside `ASM[`, `: name … ;` defines a host word, with `IF`, `BEGIN`, `FOR`
and `DO` loops, such as `: dump ( a n) 0 DO DUP I + R@ D. LOOP DROP ;`.

```
$ gasim repl
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

On a terminal, lines are edited with
[isocline](https://github.com/daanx/isocline), with history and Tab
completion of words and labels. isocline links libc into the `gasim`
executable, which `zig build -Disocline=false` leaves out, along with
line editing.

### Terminal user interface

A map panel shows all nodes. Running nodes are green, nodes waiting on a port
yellow, and nodes waiting for code dim. Given room, such as by filling the
screen with `f`, it shows each node as a tile with what it is waiting on and
its registers, and arrows between tiles show what the ports between nodes
are doing: green for a word that went across, yellow for a node waiting to
read or write, and dim for one waiting for code. The node panel shows the selected
node's registers, stacks, and RAM and ROM around the word it is executing.

| Key | |
| --- | --- |
| `space` | run or pause |
| `s` | step the next node to run, and select it |
| `S` | step every node once |
| `n` | step the selected node |
| `z` | go back to before the last step or run, up to 64 times |
| `hjkl`, arrows | select a node on the map, or move through memory in the node panel |
| `tab`, `shift+tab` | move to the next or previous panel, from the map and node panels |
| `alt+1`-`4` | move to the map, console, node or forth panel from any panel, showing it, as does `ctrl` in terminals that report it |
| `1` `2` `3` `4` | show or hide the map, console, node and forth panels |
| `f`, `esc` | fill the screen with the panel, and go back |
| `<` `>` `-` `+` | resize the panels, as can dragging their borders |
| `pgup` `pgdn` | page through memory, or scroll the console or forth panel |
| `b` | set or clear a breakpoint on the word in memory under the cursor |
| `w` | watch the selected node's reads from a port, with `r` `d` `l` `u`, or its writes to one, with `R` `D` `L` `U`, or stop watching it |
| `g` | follow the word the node is executing again |
| `q`, `ctrl+c` | quit |

Clicking a node on the map to select it.
Clicking a word in memory moves the cursor to it, and clicking to its left
sets or clears a breakpoint, shown as a red dot. Running pauses when a node
is about to fetch a word with a breakpoint, or makes a watched transfer,
and selects that node. Going back leaves the console as it is: its output
stays, and input that nodes have read is not read again.
Borders between panels can be dragged, or on touch screens, which turn drags
into scrolling, tapped and then tapped again where they should go. In
the console, typed text is sent as input with `enter`, `ctrl+d` ends the
input as the end of a pipe would, and `esc` goes back to the map. Long lines
of output wrap.

The forth panel takes lines of arrayForth 3, as `gasim repl` does, with the
selected node as the target of the IDE's words: `x15. LIT` pushes onto its
stack, and `NODE` selects another node. `up` and `down` recall lines typed
before, `tab` completes a word or lists the words it could be, and `z`
goes back to before a line, as it does after a step.

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
