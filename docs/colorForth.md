# colorForth Support

## As text

`gasim cf text`, or `gasim blocks`, writes the colorForth source in a file of
blocks as text, and `gasim cf pack` writes text as blocks:

```
$ gasim cf text app.cf > app.txt
$ gasim cf pack app.txt -o app.cf
$ gasim cf pack block5.txt --into OkadWork.cf -o mine.cf
$ gasim cf expand OkadWork.cf -o expanded.cf
```

`--into` keeps the file's other blocks, replacing the ones the text names; a
compressed arrayForth 2 image comes out uncompressed, as `cf expand` writes it.
Each block follows a line `block <n>`, or is block 0 without one. Each word is
marked with its color where the color changes: `:` red, `[` yellow, `]` green,
`\` cyan, `(` white, `@` magenta, `^` gray and `~` blue, with hex numbers after
a `$`. Red and magenta are marked each time, and a word after one is green
unless it is marked. A variable's value follows its name.

So that text reads back as the same bytes, a word that would read as a mark,
such as a green `@+`, keeps its own mark, `]@+`, though its color has not
changed, as does a word `block`. A word that reads as a number has `'` before
it, `('1`, and a number in a cell of its own that would fit in one has `#`.

## The editor

`gasim source.cf` opens the blocks in an editor. Hit alt+1 to get back to the
chip view and alt+6 to get back to the colorForth editor, which without a .cf
file starts a new file of blocks. It's inspired by
AshleyF's [Color](https://github.com/AshleyF/Color) editor. The cursor is on a
word, and as in vim. Keys move between words and blocks - hit `i`, `a` or `o`
to start typing. Typing a space starts the next word in green after a red name
and otherwise in the same color, and a color key changes the color of the word
being typed or the one under the cursor. Words typed in yellow, green or white
that read as numbers, such as `-5` or `$1f`, become numbers. `s` saves the
file, which a compressed arrayForth 2 image is saved as uncompressed, and a
file that does not exist is created; a new file is named first. Blocks that are not colorForth source,
such as the kernel of an arrayForth 2 image, cannot be edited. `L` compiles the
block, and the blocks it loads, and starts the chip again with the code
compiled so far - the block's code replacing what it compiled before, or moves
the cursor to the word that failed. Phew.

| keys | |
| --- | --- |
| `h` `l`, `b` `w` | the word before or after |
| `j` `k` | the next or previous red name |
| `0` `$` | the first or last word |
| `[` `]`, `256g` | the block before or after, or block 256 |
| `i` `a` | type a word before or after the cursor |
| `o` `O` | type a new red name on a line below or above |
| `x` `X`, `y`, `p` `P` | delete the word or the one before it, copy it, put the last back after or before |
| `u` `U` | undo, redo |
| ctrl+r y g w t v b | red, yellow, green, white, cyan, magenta or blue, as typed or after |
| `R` `Y` `G` `W` `C` `M` `B` | the same, while not typing |
| space, enter, esc | while typing: the next word, a new line, done |
| `f` | show or hide blue words, which lay out the block |
| `L` | compile the block and start the chip again with its code |
| `s`, ctrl+s | save |
| `:` | type a command, as in vim |

Commands open and save files, after vim's. `:w` saves, and `:w file` saves
as the file, which the blocks are then saved to, as vim's `:saveas` does;
`:w! file` saves over a file that is there. `:e file` opens a file of
blocks, or starts one there that saving creates, and `:new` starts a new
file, which `:w` names. Either asks for `!`, as `:e! file`, to let blocks go
that are not saved, and forgets the code compiled from the file before.
`:q` quits, `:q!` though the blocks are not saved, `:wq` after saving them,
and `:x` after saving them if they changed. `:messages` lists the latest
errors and what stopped a run, and the [TUI](tui.md) lists the commands
that act on the chip. Tab completes a command's name, or the name of a .cf
file or a directory, and esc lets the command go. A name that is not absolute
is relative to the directory gasim was started in.

F18 code in colorForth is compiled like arrayForth 2 - into the
same object code as arrayForth 3 source. Each example has a colorForth
version, such as `examples/echo.cf`, which `gasim blocks` shows:

```
[0 node 0 org
:main ]up b! begin @b !b end
```

Three more examples follow AshleyF's posts on the F18, from his
[Chuck Moore's Creations](https://github.com/AshleyF/Color/blob/master/Docs/chuck_moores_creations.md)
series: `alphabet.cf` prints the alphabet with a `for` loop,
`variables.cf` counts with a variable whose store word, just before it,
stores into its literal in place, and `multiply.cf` multiplies with the
multiply-step instruction `+*` and prints the product in hex:

```
[0 node 0 org
:* (ab-p ]a! 0 17 for +* unext drop drop a ;
:digit (n ]$f and -10 . + -if 58 . + !b ; then 97 . + !b ;
:.hex (n print the digits above this one first ]dup 2/ 2/ 2/ 2/ if .hex digit ; then drop digit ;
:main ]up b! $3d $31 * .hex 10 !b $ff $ff * .hex 10 !b left b! @b
```

Yellow words run as the block is loaded: `n node` starts the code of a
node, saving the code of the one before, `a org` sets where code goes,
`here` leaves where that is, `n ,` lays down a number, `n load`,
`n m loads` and `n m thru` load a block, or m blocks of code from n, or
the blocks of code from n to m, skipping the blocks of comments between
them, `n fh` leaves the block n after the one being loaded, `exit` ends a
block, and `n bin` saves the code as a bin of another number. In an
arrayForth 2 image, a yellow word that is nothing else leaves the number
that the image's system names as it starts, in block 18 and the blocks it
loads, such as `sram`, which block 202's `:sram [264 ];` names, the block
of the SRAM cluster: `[sram load`. Boot descriptors say what to load into
nodes and how to start them, as arrayForth 3's do but with single
numbers: `n +node` picks node n, and leaves F18 code, `bin /ram` loads all
of its RAM, `a n bin /part` n words at a, in place of the loads before,
`x /a`, `x /b`, `x /io` and `a /p` set its registers, and `v1 … vn n
/stack` its stack, as block 266 describes the SRAM cluster's nodes:
`[107 +node 1614 /ram down /b`. A program with them is set up as they
say, by `gasim run` and by `L`, which sets the code compiled up first and
leaves out a node whose bin was not saved. `spispeed`, `spicmd` and `spiadr`
assemble the literals arrayForth 2's F18 compiler gives the SPI boot. gasim's directives, labels and the F18
compiler's words come first, as block 202's `host` and `target` name
blocks too, so `[host load`, in the IDE's blocks, still begins host
words. Arithmetic
is colorForth's, with `-` inverting and `or` exclusive, before a node's
code and in host words. Once a node has begun in a load, other yellow
words assemble code as green ones do, as arrayForth 2 compiles them, such as
the instruction words a node sends a neighbour to run, laid down after
`@p`: `]@p !b ; [.. dup or a! ..`. `swap`, `nip`, `negate`, `*`, `/`,
`mod`, `/mod` and `*/` still work out numbers, and a yellow `:` before a
label or a port leaves its address, for green `lit`, as in
`[: message ]lit`. A red word labels the next instruction word, and the
code of the nodes compiled after it can call it, as nodes call the words
they send each other, until `reclaim` or `empty` forgets it. Green words
assemble: opcodes,
by arrayForth 2's names `-` `or` `push` `pop` or arrayForth 3's, `begin`
`if` `then` `next` and the other control words, calls to labels and the
ROM, and port names such as `right`. Green numbers are literals. Gray
numbers, which arrayForth 2 wrote as it compiled, are checked against where
gasim has got to, with a warning if they differ. A `then` with nothing to
resolve, as block 792's, whose `if` is in a comment, only aligns, as
arrayForth 2 went past it, with a warning, which falls on the last `then`
of a structure that has one too many. Between `host` and
`target`, and outside F18 code, before a node in a load or after
`+node`, a red word defines a word for the host, which runs its green
words as yellow ones and pushes its numbers, such as `:r-l- ]$1f5 lit ;`,
a macro for a literal, and one with no words before the next falls
through into it, as `:head :pipe [1112 ]load ;`, until `empty` forgets
the words defined since `mark`. One defined outside `host`, as a loader's
block defines its words in x86 code, such as block 228's `+wire`, is
there for the blocks loaded after it, until `reclaim` or `empty`, but F18
code's words and colorForth's own, such as `dup`, come before it. Each
load given to the compiler starts outside F18 code,
though a block loaded from F18 code goes on in its node. Yellow words in a definition run as it is
defined, and the next green word compiles the number they leave, as
colorForth does: `:seven [3 4 + ]lit ;`. There, and in host words, `@` and
`!` fetch and store, such as an image's system variables, which leave
their address in yellow, as block 444's `:resume [@res2 ]@ …` reads the
value block 202 keeps for `@res2`. `--listing` shows the line of colorForth
each word came from, as `gasim blocks` writes it. Compiled this way, the F18 code of `OkadWork.cf` agrees with the gray
numbers arrayForth 2 wrote, but for a few lines that were changed after it
was compiled. This opens the PWM demo running in node 600, and lists the
SHA-256 scheduler in node 101:

```
$ gasim --load 842 OkadWork.cf
$ gasim --listing --load 900 OkadWork.cf
```
