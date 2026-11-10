# Boot streams

By default, gasim writes each program straight into its nodes' RAM. With
`--boot`, gasim loads the program the way a real chip is loaded: it sends a
boot stream, and the nodes' ROM reads it. So `--boot` needs the
[ROM](rom.md).

Where the stream goes depends on the other options:

| Options | Where the stream goes |
| --- | --- |
| `--boot` | through the SERDES port of node 001, as one GA144 boots another |
| `--uart 708 --boot` | through the UART to node 708's ROM, before anything from stdin |
| `--board ... --boot` | through the board's serial port to the chip it is wired to |

```
$ gasim run --uart 708 examples/uart.ga
Hello, world!
$ gasim run --uart 708 --boot examples/uart.ga
Hello, world!
```

## arrayForth 3 streams

An arrayForth 3 program can describe its own boot stream between
`STREAM[` and `]STREAM`. gasim lays the stream out as arrayForth 3's
STREAMER does. Where it goes depends on the node the stream starts from:

| Starts from | How gasim sends it |
| --- | --- |
| 708 | through the UART |
| 705 | packed into the board's SPI flash, for node 705's ROM to read. Use `--board evb002 --jumper J26=off --boot`. |
| 300 | clocked into node 300's pins 17 and 1, as the disk's synchronous master (bin 1901) clocks out a word. Use `run` with no `--board`. |
| 207 | not sent. This stream is for pF/144's snorkel to send, so `--boot` refuses it. Without `--boot`, a stream of one frame sets up its nodes, as boot descriptors do. |

Some blocks send streams, and pF/144's nucleus, with `!STREAM`, `!stream`
and `!NUCLEUS`, as `1665 LOAD` does. gasim sends these from node 708 one
after another, as arrayForth 3 does.

## Paths across two chips

A stream's path can go on from a node to the same node on the other chip.
On the EVB002, the synchronous bridge between the two chips' node 300
carries what host node 400 writes to its `up` port to target node 400
(block 1668).

The stream does not build the bridge. An earlier frame must build it, as
block 1670's does.

On a board, `--boot` through a serial port boots the chip the port is wired
to. If the stream's path goes through a bridge, it boots the other chip too.
