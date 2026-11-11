# Options

This page lists gasim's commands and options. `gasim help <command>` prints
the options each command takes. Each command refuses options it cannot use.

For how the commands work together, see [Scripting with the CLI](cli.md).

## Commands

| Command | What it does |
| --- | --- |
| `gasim [program]` | opens the TUI on a terminal, or runs the program if stdin or stdout is not a terminal |
| `gasim tui [program]` | opens the TUI |
| `gasim run <program>` | runs the program, with the console on stdin and stdout |
| `gasim start <program> -o <snapshot>` | loads the program and saves a snapshot, without running it |
| `gasim step --from <snapshot> --to <snapshot>` | takes one or more steps |
| `gasim show <snapshot> [node]...` | shows what is in a snapshot |
| `gasim aforth [program]` | the arrayForth 3 prompt (see [arrayForth](arrayForth.md#arrayforth-3-prompt)) |
| `gasim listing <program>` | prints each node's words, with their disassembly and source lines |
| `gasim cf text <file.cf>` | prints colorForth blocks as text |
| `gasim cf pack <text> -o <file.cf>` | writes text as colorForth blocks |
| `gasim cf expand <image> -o <file.cf>` | decompresses an arrayForth 2 image |
| `gasim test <spec.zon>...` | checks that programs do what they should |
| `gasim help [command]` | prints help |
| `gasim version` | prints the version |

A program is one of:

- `.ga`: gasim's F18 assembly. See [`src/assembler.zig`](../src/assembler.zig)
  for the syntax.
- `.af`: arrayForth 3 source
- `.blk`: polyFORTH blocks of arrayForth 3 source
- `.cf`: colorForth blocks, such as an arrayForth 2 image

`gasim --listing <program>` is the same as `gasim listing <program>`.

## The chip

These options set up the machine. Give them to `start`, `run`, `tui`,
`aforth` or `listing`. A snapshot remembers them, so you do not give them
again with `--from`.

| Option | What it does |
| --- | --- |
| `--chip <file>` | uses the chip described in a [chip file](chips.md). The default is the GA144. |
| `--layout <rows>x<columns>` | uses a chip of that size, up to 100x100, made of basic nodes with no pins |
| `--rom <path>` | loads [ROM](rom.md) into the nodes, from a ROM dump, from arrayForth 3's disk (`sF/pFDISK.blk`), or from the directory arrayForth 3 is installed in |
| `--console <node>:<port>` | attaches the console to a port that faces off the edge of the array. The default is `000:up`. |
| `--load <block>` | with a `.blk` or `.cf` file, loads this block. The default is block 0. You can give it more than once, for example to load a configuration block first. |
| `--boot` | loads programs with a boot stream instead of writing them into RAM. See [Boot streams](boot.md). |

## Boards and serial ports

| Option | What it does |
| --- | --- |
| `--board <file>` | puts the chips on a board, described in a [board file](boards.md). Use `evb002` for GreenArrays' EVB002. With `run`, stdin and stdout go to one of its serial ports. |
| `--jumper <name>=on\|off` | sets one of the board's jumpers, such as `J26=off`. You can give it more than once. |
| `--usb <port>` | puts this serial port of the board on stdin and stdout. The default is the board's first port that is not on a pty, such as `A`. |
| `--pty <port>[=<link>]` | puts a serial port on a pseudo-terminal, and links to it at `<link>` if you give one. Only with `run`. You can give it more than once. See [Serial ports](serial.md#ptys). |
| `--flash <file>` | the contents of the board's SPI flash, up to 16 MB. The rest is erased. |
| `--uart <node>[:<baud>]` | puts stdin and stdout on a UART on the node's pins, instead of the console. The default rate is 921600 baud. See [Serial ports](serial.md#uarts). |

## Running

These options are for `run`, and most are for `step` too.

| Option | What it does |
| --- | --- |
| `--from <snapshot>` | starts from a snapshot instead of a program |
| `--to <snapshot>` | saves a snapshot when the run stops |
| `--input <file\|-\|none>` | what the console or UART reads: a file, stdin (`-`), or nothing. The default is stdin, but with `--from` or `--to` it is `none`. With `none`, the run ends once nodes wait for input. |
| `--max-steps <n>` | stops after about this many more steps. gasim checks after each round of steps. |
| `--max-time <ps>` | stops once every running node has reached this time on the chip, in picoseconds |
| `--json` | prints one JSON object that says how the run ended. The output that nodes wrote is in the object, instead of on stdout. |

For `step`:

| Option | What it does |
| --- | --- |
| `--node <node>` | steps this node |
| `--count <n>` | takes this many steps. The default is 1. |
| `--rounds <n>` | takes this many rounds of steps instead. Each round steps the node furthest behind in time first. |
| `--slot` | with `--node`, makes each step run one opcode of the node instead of the rest of its instruction word. One pass of a `unext` loop is one step. If the node is between words, the step only fetches the next one. |

## Debugging

These options are for `run` and `step`.

| Option | What it does |
| --- | --- |
| `--break <node>:<address>` | stops when the node is about to fetch the word at the address, in hex, such as `105:003`. You can give it more than once. |
| `--watch <node>:<port>[:read\|:write]` | stops when the node reads from or writes to the port, such as `105:right:write`. You can give it more than once. |
| `--hits <n>` | stops at the nth stop, going past the ones before it. The default is 1. |
| `--show <nodes>` | when the run stops, prints the registers and stacks of these nodes, such as `105,708`, or `all` |
| `--why` | when the run stops, says what each node is waiting for |
| `--strict` | stops when a node does something a real chip may not do as gasim does. See [Hazards](#hazards). |
| `--stats` | says how many steps the nodes took, how fast, and how much time passed on the chip |
| `--trace` | prints a line to stderr for each word a node runs. With `--json`, each line is a JSON object. |
| `--trace-node <node>` | traces only this node |
| `--trace-file <file>` | writes the trace to this file instead of stderr |

### Breakpoints

A breakpoint stops the run before the node fetches the word, and prints the
node's stacks and registers. A literal is never fetched as an instruction,
so a breakpoint on a literal never stops.

### Watches

A watch prints the value that was read or written. Reads include
instruction words that a node fetches from a port, such as a boot stream.

### Trace

Each line of the trace shows the node, the word's address, the raw word, its
opcodes, and the T, S and R registers after it runs:

```
$ gasim run --trace --break 000:004 examples/hello.ga
000 000 04b12 @p b! @p .  T 00007 S 00000 R 00000
...
000 003 2bcba a! @+ >r .  T 00000 S 00000 R 0000d
info: node 000 reached 004
info: P 004  T 00000  S 00000  R 0000d  A 00008  B 145
```

### Why

`--why` lists what each node is waiting for. After a reset, nodes wait on
several ports at once. gasim counts those nodes instead of listing them.

```
$ echo hi | gasim run --why examples/upcase.ga
HI
info: node 000 waiting to read up
info: node 001 waiting to read right
info: 142 nodes waiting on several ports, as after reset
```

### Hazards

A hazard is something a program does that GreenArrays' documentation says
not to do. gasim does it anyway, in one fixed way, but a real chip may not
do the same. gasim knows three:

| Hazard | What the node did | Why it is a hazard |
| --- | --- | --- |
| `unsettled_add` | ran `+` or `+*` in slot 0, 1 or 2 straight after an opcode that changed S, T or P9 | the carry needs time to settle, so the sum may be wrong. Put a `.` before the add (DB001 2.3.3). |
| `rom_write` | wrote to ROM | gasim ignores the write. A real node may hang (DB001 2.4.3). |
| `lost_word` | read several ports at once after two neighbours had written to it | gasim takes one word and drops the other. Only one neighbour may write at a time (DB001 3.3.1). |

When a run ends, gasim warns of each place a hazard happened, once, and says
how many times they happened in all. It keeps the first 16 places. A step
runs a whole instruction word, and when one step has several hazards, gasim
counts them all but keeps only the place of the first.

For example, line 2 of `add.ga` is `48 1 + up b! !b`:

```
$ gasim run add.ga
warning: add.ga:2: '+' runs straight after an opcode that changes S or T, which on a real chip needs a . between (DB001 2.3.3)
1
warning: node 000 at 000, slot 2, added straight after an opcode that changed S, T or P9, which needs a . between (DB001 2.3.3)
```

The first warning is from the assembler. It finds adds that follow such an
opcode in the source, without running the program. It does not follow
jumps, so it can miss some. The second is from the run.

With `--strict`, the run stops at the first hazard, as at a breakpoint, and
exits with 7. Use it in scripts and tests to make sure a program has none.
With `--json`, the object has a `hazards` list and a `hazard_count` when
there are any.

gasim does not check an add in slot 3, which DB001 allows, or an add in
ROM, which is GreenArrays' own code. It still checks code in ROM for the
other two hazards.

### Stats

A step runs one instruction word, including its `unext` loops, or tries to
run one while the node waits on a port. With `--slot`, a step runs one
opcode. Steps per second includes any time
spent waiting for input. The chip's time is the furthest any node's clock
reached.

```
$ gasim run --stats tools/bench/ring.ga > /dev/null
info: 7300937 steps in 0.670 s, 10.9M steps/s, and 44.882 ms of the chip's time
```

### Listing

`gasim listing` prints each node's words instead of running them. Each line
shows the address, the raw word, its opcodes or literal value, and the
source line it came from.

```
$ gasim listing examples/hello.ga
node 000
000 04b12  @p b! @p .                 7      up b!                  \ B addresses the console
001 00145  literal up
002 00007  literal 7                  8      'message a!            \ A walks through the message
...
```

## Looking at snapshots

`gasim show <snapshot>` lists every node, with its status, P register, and
what it is waiting for. Name nodes to see their registers, stacks, time,
slot and carry.

| Option | What it does |
| --- | --- |
| `--mem` | shows the words in the nodes' RAM, with their disassembly |
| `--rom-words` | with `--mem`, shows the ROM's words too |
| `--at <address>` | starts at this address, in hex |
| `--count <n>` | shows this many words. The default is 64. |
| `--ports` | shows what the ports between nodes are doing |
| `--json` | prints a JSON object |

## aforth

| Option | What it does |
| --- | --- |
| `-e <line>` | interprets this line instead of reading stdin. You can give it more than once. |
| `--from <snapshot>`, `--to <snapshot>` | starts from a snapshot, and saves one at the end |
| `--json` | prints a JSON object at the end |

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | every node is waiting, with nothing more to come, or `step` took its steps |
| 1 | an error |
| 2 | wrong usage |
| 3 | a breakpoint |
| 4 | a watch |
| 5 | a limit: `--max-steps` or `--max-time` |
| 6 | `gasim test` found a difference |
| 7 | a hazard, with `--strict` |
| 128 + the signal | a signal stopped the run, such as 130 for SIGINT |
