# colorForth Support

`gasim blocks` writes the colorForth source in a file of blocks as text. Each
word is marked with its color where the color changes: `:` red, `[` yellow, `]`
green, `\` cyan, `(` white, `@` magenta, `^` gray and `~` blue, with hex
numbers after a `$`.

`gasim source.cf` opens the blocks in an editor. Hit alt+1 to get back to the
chip view and alt+6 to get back to the colorForth editor. It's inspired by
AshleyF's [Color](https://github.com/AshleyF/Color) editor. The cursor is on a
word, and as in vim. Keys move between words and blocks - hit `i`, `a` or `o`
to start typing. Typing a space starts the next word in green after a red name
and otherwise in the same color, and a color key changes the color of the word
being typed or the one under the cursor. Words typed in yellow, green or white
that read as numbers, such as `-5` or `$1f`, become numbers. `s` saves the
file, which a compressed arrayForth 2 image is saved as uncompressed, and a
file that does not exist is created. Blocks that are not colorForth source,
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
`here` leaves where that is, `n ,` lays down a number, `n load` and
`n m loads` load a block, or m blocks of code from n, skipping the blocks
of comments between them, `exit` ends a block, and `n bin` saves the code
as a bin of another number. Arithmetic is colorForth's, with `-` inverting
and `or` exclusive. A yellow label leaves its address, for green `lit`. A
red word labels the next instruction word. Green words assemble: opcodes,
by arrayForth 2's names `-` `or` `push` `pop` or arrayForth 3's, `begin`
`if` `then` `next` and the other control words, calls to labels and the
ROM, and port names such as `right`. Green numbers are literals. Gray
numbers, which arrayForth 2 wrote as it compiled, are checked against where
gasim has got to, with a warning if they differ. Between `host` and
`target`, a red word defines a word for the host, which runs its green
words as yellow ones and pushes its numbers, such as `:r-l- ]$1f5 lit ;`,
a macro for a literal, until `empty` forgets the words defined since
`mark`. `--listing` shows the line of colorForth each word came from, as
`gasim blocks` writes it. Compiled this way, the F18 code of `OkadWork.cf` agrees with the gray
numbers arrayForth 2 wrote, but for a few lines that were changed after it
was compiled. This opens the PWM demo running in node 600, and lists the
SHA-256 scheduler in node 101:

```
$ gasim --load 842 OkadWork.cf
$ gasim --listing --load 900 OkadWork.cf
```
