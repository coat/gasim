# examples

## Overview

`examples` writes the examples in a folder, with their descriptions, as
JSON. The web version's Examples menu reads this file, because a web page
can't list a folder. `zig build web` runs it on `examples/` and installs
the result as `zig-out/web/examples/index.json`. See
[Building](../../docs/building.md) for the web version.

```bash
zig build web
```

The build names the executable `examples-index`, and runs it as
`examples-index <dir> <index.json>`.

## Interface

- `main.zig:main` lists the examples in `<dir>` and writes them to
  `<index.json>`, indented by 2 spaces.
- It uses `src/examples.zig:list`. The GUI calls `list` too, and the web
  version reads the file this tool writes, so both show the same
  examples.

## Invariants

These are the rules that the code relies on, and that a change must keep.

- `list` keeps only `.cf`, `.ga` and `.af` files, and skips folders. It
  sorts them by name. When a program has several versions, it keeps one:
  the `.cf`, or else the `.ga`, or else the `.af`. If it can't read the
  folder, the list is empty.
- Each example's description comes from its first comment, in the form
  `name - what it does`. For a `.cf` file, that is the first comment in
  block 0. [Contributing](../../CONTRIBUTING.md) describes that comment.
- The build runs this tool every time (`has_side_effects`), because Zig
  doesn't hash the files in the folder.

## Side effects

This is what the code does outside its own memory, such as reading a
file.

- It reads the folder and creates or replaces the output file.
- It exits with status 2 on wrong usage.

## Verification

- Run: `zig build web`
- Run: `zig build test-web` to run the web version's tests, with Deno.
