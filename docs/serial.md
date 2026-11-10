# Serial ports

gasim can connect the simulated chip to other programs in three ways:

- **The console**, attached to a node's port. This is the default.
- **A UART** on a node's pins, with `--uart`.
- **A board's serial ports**, with `--board`, on stdin and stdout or on
  pseudo-terminals (ptys).

## The console

By default, the console is attached to the `up` port of node 000. `run`
connects it to stdin and stdout. Use `--console <node>:<port>` to attach it
elsewhere. The port must face off the edge of the array.

## UARTs

`--uart <node>[:<baud>]` puts stdin and stdout on a UART on the node's pins,
instead of the console:

- the node reads on pin 17
- the node writes on pin 1
- both lines are inverted
- the default rate is 921600 baud

This is how a USB serial port is wired to node 708 on GreenArrays'
evaluation boards.

```
$ gasim run --uart 708 examples/uart.ga
Hello, world!
```

Bytes from the host boot node 708 from its ROM. So `gasim run --uart 708`
without a program boots whatever stdin sends, such as a boot stream from
[ga-tools](https://github.com/mschuldt/ga-tools). With `--boot`, gasim sends
the program as a boot stream itself. See [Boot streams](boot.md).

## A board's serial ports

With `--board`, `run` puts one of the board's serial ports on stdin and
stdout. Choose it with `--usb <port>`. See [Board files](boards.md#serial-ports).

## Ptys

`--pty <port>[=<link>]` puts a board's serial port on a pseudo-terminal. A
program can open it as it would open a USB serial port's device. For
example, arrayForth 3 running under Wine can talk to the simulated EVB002.

```
$ gasim run --board evb002 --pty A=$HOME/.wine/dosdevices/com3 --pty C
info: port A: /dev/pts/4
info: port C: /dev/pts/5
```

gasim prints the path of each pty. If you give a link, gasim also makes a
symbolic link to the pty at that path.

How a run with ptys works:

- You can give `--pty` more than once. Programs can use all the ptys at the
  same time as each other, and as stdin and stdout.
- stdin and stdout carry the port that `--usb` names. Without `--usb`,
  they carry no port, and gasim does not read stdin.
- Each port runs at the baud rate in its board file.
- The run goes on until you press Ctrl+C, as a real board would, even after
  stdin ends. Then gasim removes the links it made.
- gasim replaces a link that points to another pty, such as one left by an
  earlier run, or to nothing. It refuses to replace a link to anything
  else, such as a serial port that Wine found.
- A pty keeps what the port sends before a program opens it, up to its
  buffer size (about 19 KB on Linux). After that, or whenever nothing reads
  the pty, gasim drops bytes rather than holding up the chip. It says how
  many it dropped.
- `--to` cannot save a snapshot of a run with ptys, because it cannot save
  the program on the other end.

Ptys work on Linux, macOS and the BSDs, in builds with libc.

### No RTS or DTR

A pty has no RTS or DTR lines. Hosts such as arrayForth 3 and ga-tools set
these lines to reset the chip, and their serial libraries may refuse the
port without them. For example, pyserial's `rts` raises "Inappropriate
ioctl for device".
