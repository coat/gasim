# Board files

A board file describes what a board puts around its chips, in
[ZON](https://ziglang.org/documentation/master/#toc-ZON). It gives:

- the board's [chip file](chips.md), as `ga144` for the GA144 or a path
  relative to the board file, and how many of that chip there are
- serial ports wired to the chips' pins
- pull-up and pull-down resistors
- wires between pins
- SERDES links between nodes
- pins wired to the chips' RESET- pins
- named jumpers that connect some of these, and whether each is on or off
  when the board is shipped

Use a board with `--board <file>`. Use `--jumper <name>=on|off` to set a
jumper differently from how the board is shipped.

## Node numbers on several chips

The first chip's nodes have their usual numbers, such as `708`. The nodes of
each later chip start with the chip's number, such as `1.708`. Write them
this way:

- in a board file: `.chip = 1, .node = 708`
- in programs: `node 1.708`
- in options: `--break 1.708:004`

All the chips' nodes run together. gasim always runs the node that is
furthest behind in time first.

arrayForth 3 programs (`.af`, `.blk`) go to the first chip's nodes, unless a
descriptor puts them on another chip, such as `10500 +NODE`.

## The EVB002

gasim has a board file for GreenArrays' EVB002 evaluation board built in, as
`--board evb002`. It is
[`src/boards/evb002.zon`](../src/boards/evb002.zon). It follows the board's
data book (DB014) and the jumper settings it ships with (AN021).

The board has:

- **The host chip**, chip 0, with:
  - USB serial port A, on node 708's pins 17 and 1
  - USB serial port B, on 200.17 (in) and 100.17 (out)
  - jumper J26 (NO BOOT), which holds 705.17 high
  - pull-ups on the chip enables of the SPI flash and the SRAM
- **The SPI flash**, on host node 705's pins 1 (clock), 3 (chip select), 5
  (data out) and 17 (data in). Use `--flash <file>` to give its contents.
  Node 705's ROM boots from it with `--jumper J26=off`.
- **The SRAM**: 1M words of 16 bits, set to zero at the start of each run.
  - its address is on host node 009's parallel bus, and on 008.5 and 008.17
  - its data is on node 007's bus
  - CE- and WE- are on 008.1 and 008.3

  This is how arrayForth 3's SRAM cluster drives it.
- **The target chip**, chip 1, with USB serial port C on node 1.708's pins
  17 and 1, and a pull-up on 1.705.17.
- **Links between the chips**:
  - a SERDES link from host node 701 to target node 001
  - jumpers J34 and J35, which join the two chips' 300.1 and 300.17
- **The target's reset**: jumper J22 connects host 500.17 to the target's
  RESET-. The target's reset circuit holds RESET- high through J22.5-6. Host
  node 500 resets the target by driving 500.17 low.

```
$ gasim run --board evb002 examples/uart.ga
Hello, world!
$ gasim run --board evb002 --jumper J23.3-4=off examples/uart.ga
warning: port A (708.17 in, 708.1 out) never carried a byte
$ sed 's/^node 708/node 1.708/' examples/uart.ga > target.ga
$ gasim run --board evb002 --usb C --boot target.ga
Hello, world!
```

## Serial ports

`run` puts one serial port on stdin and stdout. Choose it with `--usb`. The
default is the board's first port that is not on a pty, such as `A`. Port C is the EVB002's target
chip's.

The other serial ports are not connected, unless you put them on ptys with
`--pty`. A node reads an unconnected port as an idle line, because its pin's
pull-down holds it low and the line is inverted.

A board with no serial ports uses the console instead (`--console`).

A wire cannot go to a serial port's pin yet, because the port's input would
not wake the other pin's node.

See [Serial ports](serial.md) for UARTs and ptys.

## SERDES

A SERDES node sends a word like this:

1. It writes the first word to its data register and sets bit 17 of its io
   register.
2. It writes each word after that to its `up` port. This waits until the
   word before has been sent.

The node at the other end receives each word by reading `up` (DB001 §3.6).

A word takes 40 ns: 18 bits at about 450 Mb/s. The G144A12's data book
gives no timing for SERDES yet, so this is an estimate. There is no flow
control. If a word has not been read when the next one arrives, it is lost.

## Reset

While a chip's RESET- pin is low:

- the chip is held in reset
- its nodes are as after a reset, and waiting

When RESET- rises, the chip starts again as after a reset, at that time. Its
RAM keeps what it held.

A node may have run past that time already, because a `unext` loop can take
a node far ahead. Whatever that node did stays done, such as a byte or a
SERDES word it sent.

RESET- has no pull-down. So on the EVB002:

- With J22.1-2 on and J22.5-6 off, 500.17's pull-down holds the target in
  reset until host node 500 drives it high.
- With J22.1-2 off, the target is never reset.

```
$ gasim run --board evb002 --usb C --jumper J22.5-6=off --why target.ga
info: chip 1 held in reset
...
```

gasim does not model the reset button, or port C's RTS line (J22.3-4),
because stdin has no RTS. You can still set J22.3-4 with `--jumper`.
