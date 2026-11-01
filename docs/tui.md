# TUI

The chip panel at the top right shows all nodes. Running nodes are green, nodes waiting on a
port yellow, and nodes waiting for code dim. Unless the panel is small, it
shows each node as a tile with what it is waiting on and its registers,
scrolling to follow the selected node when they do not all fit, with arrows
in its title for the nodes out of view; `t` chooses numbers, or tiles to
scroll through however small the panel, instead. Arrows between tiles show what the
ports between nodes are doing: green for a word that went across, yellow for
a node waiting to read or write, and dim for one waiting for code, with none
where the nodes on both sides wait to read. The node panel shows the
selected node's registers, stacks, and RAM and ROM around the word it is
executing.

| Key | |
| --- | --- |
| `space` | run or pause |
| `s` | step the next node to run, and select it |
| `S` | a round of steps, the furthest behind first |
| `n` | step the selected node |
| `z` | go back to before the last step or run, up to 64 times |
| `hjkl`, arrows | select a node on the map, or move through memory in the node panel |
| `tab`, `shift+tab` | move to the next or previous panel, from the map and node panels |
| `t` | on the map, show tiles where they fit and numbers otherwise, numbers, or tiles to scroll through |
| `alt+1`-`5` | move to the map, console, node, aforth or debug panel from any panel, showing it, as does `ctrl` in terminals that report it |
| `1` `2` `3` `4` `5` | show or hide the map, console, node, aforth and debug panels |
| `f`, `esc` | fill the screen with the panel, and go back |
| `<` `>` `-` `+` | resize the panels, as can dragging their borders |
| `pgup` `pgdn` | page through memory, or scroll the console or aforth panel |
| `b` | set or clear a breakpoint on the word in memory under the cursor |
| `w` | watch the selected node's reads from a port, with `r` `d` `l` `u`, or its writes to one, with `R` `D` `L` `U`, or stop watching it |
| `g` | follow the word the node is executing again |
| `?`, `F1` | list the keys, with `F1` where `?` would be typed |
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

The aforth panel takes lines of arrayForth 3, as `gasim aforth` does, with the
selected node as the target of the IDE's words: `x15. LIT` pushes onto its
stack, and `NODE` selects another node. `up` and `down` recall lines typed
before, `tab` completes a word or lists the words it could be, and `z`
goes back to before a line, as it does after a step.

The debug panel, hidden until `5` shows it, has three views, which `h` and
`l` move between. The trace shows a line for each step that runs code, as
`--trace` does, while `t` turns tracing on; `o` shows only the selected
node's lines, `c` clears them, `w` saves those shown as trace.txt, and
`pgup` `pgdn` scroll. The breakpoints and watches can be chosen with `up`
and `down`: `enter` shows the node, and the breakpoint in its memory, `x`
removes one, and `X` all. The history lists the steps and runs kept to go
back to, the latest first, and `enter` goes back to before the one chosen,
forgetting those after it.
