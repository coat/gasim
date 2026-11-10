# TUI

The terminal UI (TUI) shows the whole chip on one page, in panels:

| Panel | Key | What it shows |
| --- | --- | --- |
| map | `alt+1` | every node on the chip |
| console | `alt+2` | what nodes write to the console, and a prompt to type input |
| node | `alt+3` | the selected node's registers, stacks and memory |
| aforth | `alt+4` | an arrayForth 3 prompt |
| debug | `alt+5` | the trace, breakpoints and watches, and history |
| colorForth editor | `alt+6` | the [colorForth editor](colorForth.md#the-editor) |

Open it with `gasim <program>` or `gasim tui <program>`. To open a chip as a
[snapshot](cli.md) left it, use `gasim tui --from <snapshot>`. The chip
opens paused, with the steps it had taken.

## The map

The map shows every node. Its colors show what each node is doing:

- **green**: running
- **yellow**: waiting on a port
- **dim**: waiting for code

If the panel is big enough, each node is a tile that shows what it is
waiting on, and its registers. When the tiles don't all fit, the map
scrolls to follow the selected node. Arrows in the panel's title point to
the nodes out of view. Press `t` to switch between tiles, node numbers, or
tiles that scroll however small the panel is.

Arrows between tiles show what the ports between nodes are doing:

- **green**: a word went across
- **yellow**: a node is waiting to read or write
- **dim**: a node is waiting for code
- **no arrow**: the nodes on both sides are waiting to read

Click a node to select it.

## The node panel

The node panel shows the selected node's registers, stacks, and the RAM and
ROM around the word it is running.

For a program gasim assembled, the panel also shows:

- the label at each word, and the names of ROM words, such as `warm`, once
  the ROM is loaded
- jumps and calls by name, such as `call emit` instead of `call 0a9`
- where the word at the cursor came from, under the node's status, such as
  `hello.ga:9  @+ for @+ !b unext`. For colorForth blocks it shows the
  block and word, without the text.

A word is described only while memory still holds what was assembled there.
Code a node loads or changes as it runs is shown without labels.

When a node is part way through a word, the panel shows its opcodes in the
`I` row and in the word's row of memory. Opcodes the node has run are dim,
and the one it runs next is in reverse. A node is part way through a word
after `N` steps one opcode, or while it waits on a port.

- Click a word to move the cursor to it.
- Click to the left of a word to set or clear a breakpoint. A breakpoint
  shows as a red dot.

## Keys

| Key | What it does |
| --- | --- |
| `space` | run or pause |
| `s` | step the next node to run, and select it |
| `S` | take a round of steps, the node furthest behind first |
| `n` | step the selected node |
| `N` | step one opcode of the selected node. If the node is between words, this only fetches the next one. |
| `z` | undo the last step or run, up to 64 times |
| `hjkl`, arrows | select a node on the map, or move through memory in the node panel |
| `tab`, `shift+tab` | move to the next or previous panel, except while typing |
| `alt+1` to `alt+5` | move to a panel, and show it if it is hidden. This works even while typing. `ctrl` works too, in terminals that report it. |
| `alt+h` `j` `k` `l` | move to the nearest panel to the left, below, above or to the right. If several are nearest, it picks the one you last left. This works even while typing. |
| `1` to `5` | show or hide the map, console, node, aforth or debug panel |
| `f`, `esc` | make the panel fill the screen, and go back |
| `<` `>` | narrow or widen the left column |
| `-` `+` | shorten or lengthen the focused panel, or the map from the node panel |
| `pgup` `pgdn` | page through memory, or scroll the console or aforth panel |
| `b` | set or clear a breakpoint on the word under the cursor |
| `w` | watch the selected node's port (see below) |
| `g` | follow the word the node is running again |
| `t` | on the map, choose tiles or numbers |
| `:` | type a [command](#commands) |
| `?`, `F1` | list the keys |
| `q`, `ctrl+c` | quit |

`alt+2` and `alt+4` also start typing in the console or aforth panel. So
does `alt+h` `j` `k` `l` when it moves to one of them.

`w` waits for a second key:

- `r` `d` `l` `u` watch the node's reads from the right, down, left or up
  port
- `R` `D` `L` `U` watch its writes to that port
- if the node is already watched, `w` stops watching it

You can also drag the border between two panels to resize them. On a touch
screen, which turns drags into scrolling, tap the border and then tap where
it should go.

### Listing keys

`?` lists the keys of the panel or mode you are in. Where `?` would be typed
as text, use `F1`. In the list:

- `/` filters the list by what you type
- `enter` keeps the filter
- `esc` shows all the keys again

## Breakpoints and watches

A run pauses when a node is about to fetch a word with a breakpoint, or
makes a watched transfer. The TUI then selects that node.

When you undo with `z`, the console stays as it is. Its output stays, and
nodes do not read again the input they already read.

## The status bar

The status bar shows the keys you can use. When a key waits for another,
such as `w` for a port, the bar shows only the keys it takes.

A message stays in the status bar until you press the next key. Errors, and
what stopped a run, are red. The TUI keeps the last 32. `:messages` lists as
many of the latest as fit.

## Commands

Press `:` to type a command. Commands do things that have no key, or that
would take a key many times. They take the same names and arguments as the
[CLI](options.md).

| Command | What it does |
| --- | --- |
| `:node 105` | selects a node |
| `:break 105:003` | sets or clears a breakpoint |
| `:watch 105:right` | watches a port's reads and writes, or stops. Add `:read` or `:write` to watch only one of them. |
| `:step` | takes a step. See below. |
| `:run` | runs. `--max-steps 1000` stops after about that many steps. |
| `:help text` | lists only the keys that mention the text |
| `:messages` | lists the latest errors and stops |
| `:w` `:e` `:new` `:q` | save, open and start files of blocks, and quit, as in [the editor](colorForth.md#commands) |

`:step` takes these options:

- `--count 4`: take that many steps
- `--node 105`: step that node
- `--rounds 4`: take that many rounds of steps
- `--slot`: step one opcode of a node, the selected one unless `--node`
  says another

It stops at a breakpoint or watch, and takes at most a million steps. One
`z` undoes all of them.

While you type a command:

- `tab` completes a command's name, or the `.cf` file it takes. Otherwise
  it shows what the command takes, on the row above the status bar.
- `esc` cancels the command.

## The console and aforth panels

The console and aforth panels have two modes, like the colorForth editor.

Until you start typing, they take the same keys as the other panels. So you
can zoom, hide, resize and leave them, and run and step the chip. These keys
also scroll their output:

| Key | What it does |
| --- | --- |
| `j` `k`, `up` `down` | scroll |
| `pgup` `pgdn` | page |
| `g` `G`, `home` `end` | go to the start or end |

To start typing, press `i`, `a` or `enter`, press `alt+2` or `alt+4`, or
click the prompt. The status bar shows `typing`. Press `esc` to stop.

In the console:

- `enter` sends what you typed as input
- `ctrl+d` ends the input, as the end of a pipe would
- long lines of output wrap

The aforth panel takes lines of arrayForth 3, as [`gasim
aforth`](arrayForth.md#arrayforth-3-prompt) does. The IDE's words act on the
selected node. For example, `x15. LIT` pushes onto its stack, and `NODE`
selects another node.

- `up` and `down` recall lines you typed before
- `tab` completes a word, or lists the words it could be
- `z` undoes a line, as it undoes a step

## The debug panel

The debug panel is hidden until you press `5`. It has three views. Use `h`
and `l` to move between them.

**Trace.** A line for each step that runs code, as `--trace` prints.

| Key | What it does |
| --- | --- |
| `t` | turn tracing on or off |
| `o` | show only the selected node's lines |
| `c` | clear the lines |
| `w` | save the lines shown as `trace.txt` |
| `pgup` `pgdn` | scroll |

**Breakpoints and watches.** Choose one with `up` and `down`.

| Key | What it does |
| --- | --- |
| `enter` | show its node, and the breakpoint in its memory |
| `x` | remove it |
| `X` | remove them all |

**History.** The steps and runs you can undo, the latest first. Press
`enter` to go back to before the one chosen. This forgets the ones after it.
