# Chip files

A chip file describes a chip in [ZON](https://ziglang.org/documentation/master/#toc-ZON).
It gives:

- the size of the chip's array of nodes
- each node that is not a basic node with no pins, with:
  - its ROM type
  - its GPIO pins
  - the word of its ROM it starts at after reset (`.cold` or `.warm`)
  - a data register, for SERDES boot nodes

gasim has the GA144's chip file built in:
[`src/chips/ga144.zon`](../src/chips/ga144.zon).

Use `--chip` to run a program on another chip.
[`examples/chips/2x2.zon`](../examples/chips/2x2.zon) is a chip of four
nodes. One of them, node 100, is wired like the GA144's node 708:

```
$ gasim run --chip examples/chips/2x2.zon --uart 100 examples/chips/hello-2x2.ga
Hello, world!
```

For a chip of basic nodes only, you do not need a file. Use
`--layout <rows>x<columns>` instead.

## ROM

A node gets the ROM of the GA144 node with the same number, if that node has
the same ROM type. Otherwise it borrows the ROM of a GA144 node that does:

- Basic nodes borrow node 404's ROM.
- Special nodes, whose ROMs all differ, can only use their own.

A ROM names ports, and its `warm` jumps to its GA144 node's neighbours. So a
node with a borrowed ROM should sit where its GA144 node sits:

- in a row and column with the same parity (odd or even)
- off the same edges of the array

On the top and bottom rows, pin 17 wakes a node through its `up` port. On the
other rows, it wakes the node through `left`. In both cases, that port faces
off the array.

## Programs

`.ga` programs are assembled for the chip's ROMs.

arrayForth 3 and colorForth programs are always assembled for the GA144's
ROMs. gasim refuses one for a node whose ROM type differs from the GA144
node with the same number.
