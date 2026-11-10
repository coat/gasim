# colorForth

gasim can edit, compile and run colorForth blocks (`.cf` files), including
arrayForth 2 images such as `OkadWork.cf`.

## The editor

`gasim source.cf` opens the blocks in an editor. Press `alt+1` to go to the
chip's panels, and `alt+6` to come back to the editor. Without a `.cf` file,
the editor starts a new file of blocks.

The editor is inspired by AshleyF's [Color](https://github.com/AshleyF/Color)
editor, and works like vim. The cursor is always on a word. Keys move
between words and blocks. Press `i`, `a` or `o` to start typing.

While you type:

- A space starts the next word. After a red name, the next word is green.
  Otherwise it keeps the same color.
- A color key changes the color of the word you are typing.
- A word typed in yellow, green or white that reads as a number, such as
  `-5` or `$1f`, becomes a number.

When you are not typing, a color key changes the color of the word under the cursor.

You cannot edit blocks that are not colorForth source, such as the kernel of
an arrayForth 2 image.

### Keys

| Key | What it does |
| --- | --- |
| `h` `l`, `b` `w` | move to the word before or after |
| `j` `k` | move to the next or previous red name |
| `0` `$` | move to the first or last word |
| `[` `]` | move to the block before or after |
| `256g` | move to block 256 |
| `i` `a` | type a word before or after the cursor |
| `o` `O` | type a new red name on a line below or above |
| `x` `X` | delete the word, or the one before it |
| `y` | copy the word |
| `p` `P` | put the last deleted or copied word after or before |
| `u` `U` | undo, redo |
| `ctrl+r` `y` `g` `w` `t` `v` `b` | red, yellow, green, white, cyan, magenta or blue, while typing or not |
| `R` `Y` `G` `W` `C` `M` `B` | the same colors, while not typing |
| `space`, `enter`, `esc` | while typing: the next word, a new line, done |
| `f` | show or hide blue words, which lay out the block |
| `L` | compile the block and restart the chip with its code |
| `s`, `ctrl+s` | save |
| `:` | type a command |

### Compiling with `L`

`L` compiles the block, and the blocks it loads. Then it restarts the chip
with all the code compiled so far. The block's code replaces what it
compiled before. If compiling fails, the cursor moves to the word that
failed.

### Saving

`s` saves the file. If the file does not exist, saving creates it. A new
file is named first. A compressed arrayForth 2 image is saved uncompressed.

### Commands

Commands open and save files, as in vim:

| Command | What it does |
| --- | --- |
| `:w` | saves |
| `:w file` | saves as the file, and saves to it from then on, as vim's `:saveas` does |
| `:w! file` | saves over a file that is already there |
| `:e file` | opens a file of blocks, or starts a new one there, which saving creates |
| `:new` | starts a new file, which `:w` names |
| `:q` | quits |
| `:q!` | quits without saving |
| `:wq` | saves and quits |
| `:x` | saves if the blocks changed, and quits |
| `:messages` | lists the latest errors, and what stopped a run |

`:e` and `:new` ask for `!`, as `:e! file`, if the blocks have changes you
have not saved. They also forget the code compiled from the file before.

- `tab` completes a command's name, or the name of a `.cf` file or a
  directory.
- `esc` cancels the command.
- A file name that is not absolute is relative to the directory gasim
  started in.

The [TUI](tui.md#commands) lists the commands that act on the chip.

## As text

`gasim cf text` (or `gasim blocks`) prints the colorForth source in a file of
blocks as text. `gasim cf pack` turns text back into blocks.

```
$ gasim cf text app.cf > app.txt
$ gasim cf pack app.txt -o app.cf
$ gasim cf pack block5.txt --into OkadWork.cf -o mine.cf
$ gasim cf expand OkadWork.cf -o expanded.cf
```

- `--into` keeps the file's other blocks, and replaces only the blocks the
  text names.
- A compressed arrayForth 2 image comes out uncompressed, as `cf expand`
  writes it.

### The text format

Each block starts with a line `block <n>`. Text before the first such line
is block 0.

A mark before a word gives its color, where the color changes:

| Mark | Color |
| --- | --- |
| `:` | red |
| `[` | yellow |
| `]` | green |
| `\` | cyan |
| `(` | white |
| `@` | magenta |
| `^` | gray |
| `~` | blue |

- Red and magenta words are marked every time.
- A word after a red or magenta word is green, unless it is marked.
- Hex numbers start with `$`.
- A variable's value follows its name.

So that the text reads back as the same bytes:

- A word that would read as a mark, such as a green `@+`, keeps its own mark
  (`]@+`), even when the color has not changed. So does a word `block`.
- A word that would read as a number has `'` before it, such as `('1`.
- A number stored in a cell of its own, though it is small enough not to
  need one, has `#` before it.

## Compiling F18 code

gasim compiles F18 code in colorForth as arrayForth 2 does, into the same
object code as arrayForth 3 source. `gasim run` compiles from block 0, or
from the blocks `--load` names.

Each example has a colorForth version. This is `gasim cf text
examples/echo.cf`:

```
block 0
(echo - copy console input to the console ~cr
[0 node 0 org
:main ]up b! begin ]@b !b end
```

Three more examples follow AshleyF's [Chuck Moore's
Creations](https://github.com/AshleyF/Color/blob/master/Docs/chuck_moores_creations.md)
posts on the F18:

- `alphabet.cf` prints the alphabet with a `for` loop.
- `variables.cf` counts with a variable. Its store word, just before it,
  stores into the variable's literal in place.
- `multiply.cf` multiplies with the multiply-step instruction `+*`, and
  prints the product in hex:

```
[0 node 0 org
:* (ab-p ]a! 0 17 for +* unext drop drop a ;
:digit (n ]$f and -10 . + -if 58 . + !b ; then 97 . + !b ;
:.hex (n print the digits above this one first ]dup 2/ 2/ 2/ 2/ if .hex digit ; then drop digit ;
:main ]up b! $3d $31 * .hex 10 !b $ff $ff * .hex 10 !b left b! @b
```

### Yellow words

Yellow words run while the block loads:

| Word | What it does |
| --- | --- |
| `n node` | starts the code of node n, and saves the code of the node before |
| `a org` | sets where code goes |
| `here` | leaves where code goes |
| `n ,` | lays down a number |
| `n load` | loads block n |
| `n m loads` | loads m blocks of code from block n |
| `n m thru` | loads the blocks of code from n to m |
| `n fh` | leaves the number of the block n after the one being loaded |
| `exit` | ends the block |
| `n bin` | saves the code as a bin with another number |
| `spispeed`, `spicmd`, `spiadr` | assemble the literals that arrayForth 2's F18 compiler gives the SPI boot |

`loads` and `thru` skip the blocks of comments between blocks of code.

gasim's directives, labels, and the F18 compiler's words take priority over
names from the image. For example, block 202 also names blocks `host` and
`target`, but `[host load`, in the IDE's blocks, still begins host words.

In an arrayForth 2 image, a yellow word that is none of these leaves the
number that the image's system gives it as it starts. The system names them
in block 18 and the blocks it loads. For example, block 202's `:sram [264 ];`
names block 264, the SRAM cluster's, so `[sram load` loads it.

Arithmetic is colorForth's, both before a node's code and in host words.
`-` inverts, and `or` is exclusive.

#### Yellow words in a node's code

Once a node's code has begun, other yellow words assemble code as green
words do, as arrayForth 2 compiles them. For example, this lays down the
instruction words a node sends a neighbour to run, after `@p`:

```
]@p !b ; [.. dup or a! ..
```

These yellow words still work out numbers: `swap`, `nip`, `negate`, `*`,
`/`, `mod`, `/mod` and `*/`.

A yellow `:` before a label or a port leaves its address, for a green
`lit`, as in `[: message ]lit`.

### Boot descriptors

Boot descriptors say what to load into nodes and how to start them. They
work like arrayForth 3's, but with single numbers:

| Words | What they do |
| --- | --- |
| `n +node` | picks node n, and leaves F18 code |
| `bin /ram` | loads all of the node's RAM from the bin |
| `a n bin /part` | loads n words at address a, instead of the loads before |
| `x /a`, `x /b`, `x /io` | set the A, B and io registers |
| `a /p` | sets P |
| `v1 … vn n /stack` | sets the data stack |
| `v1 … vn n /rstack` | sets the return stack |

For example, block 266 describes the SRAM cluster's nodes with
`[107 +node 1614 /ram down /b`.

`gasim run` and `L` set up a program with descriptors as they say. `L` sets
up the code compiled so far first. It leaves out a node whose bin was not
saved.

### Red words

A red word labels the next instruction word. The code of nodes compiled
after it can call the label, as nodes call the words they send each other.
`reclaim` or `empty` forgets it.

### Green words

Green words assemble:

- opcodes, by arrayForth 2's names (`-`, `or`, `push`, `pop`) or arrayForth
  3's
- `begin`, `if`, `then`, `next` and the other control words
- calls to labels and to the ROM
- port names, such as `right`

Green numbers are literals.

### Gray numbers

arrayForth 2 wrote gray numbers as it compiled. gasim checks each one
against where it has got to, and warns if they differ.

A `then` with nothing to resolve only aligns, as arrayForth 2 did, with a
warning. For example, block 792 has an `if` in a comment. If a structure has
one `then` too many, the warning falls on its last `then`.

### Host words

A red word defines a word for the host:

- between `host` and `target`
- outside F18 code, such as before a node's code in a load, or after
  `+node`

A host word runs its green words as yellow ones, and pushes its numbers. For
example, `:r-l- ]$1f5 lit ;` is a macro for a literal.

A red word with no words before the next red word falls through into it, as
in `:head :pipe [1112 ]load ;`. `empty` forgets the words defined since
`mark`.

A word defined outside `host` is there for the blocks loaded after it, until
`reclaim` or `empty`. A loader's block defines its words like this in x86
code, such as block 228's `+wire`. F18 code's words, and colorForth's own
words such as `dup`, take priority over it.

Each load you give the compiler starts outside F18 code. A block loaded from
F18 code goes on in its node.

#### Control flow in host words

Host words branch and loop as x86 colorForth compiles them, as block 230's
`?rl` and `+dx` do:

- `for`, `next` and `i`
- `push` and `pop`
- `if` and `-if`
- `begin` with `end`, `until`, `-until`, `while` and `-while`. These test
  the flags of the last `+`, `and`, `or`, `negate`, `2*` or `2/`.
- `;` returns. The green words after it, such as `then`, go on in the word.

A word defined outside `host` may have control words that don't match, as
F18 code can, such as a ROM source's `begin … unext`. It fails only when it
runs.

#### Yellow words in a definition

Yellow words in a definition run while it is defined. The next green word
compiles the number they leave, as in colorForth:

```
:seven [3 4 + ]lit ;
```

There, and in host words, `@` and `!` fetch and store. For example, an
image's system variables leave their address in yellow. Block 444's
`:resume [@res2 ]@ …` reads the value that block 202 keeps for `@res2`.

### Listings

`--listing` shows the line of colorForth that each word came from, as
`gasim cf text` writes it.

### OkadWork.cf

Compiled this way, the F18 code of `OkadWork.cf` matches the gray numbers
arrayForth 2 wrote. The exceptions are a few lines that were changed after
arrayForth 2 compiled them.

This opens the PWM demo running in node 600:

```
$ gasim --load 842 OkadWork.cf
```

This lists the SHA-256 scheduler in node 101:

```
$ gasim --listing --load 900 OkadWork.cf
```
