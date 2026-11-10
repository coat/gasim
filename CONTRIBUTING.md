# Contributing to gasim

Thank you for helping. This page explains how to write for gasim: the
docs, code comments, commit messages and pull requests. For how to build
gasim and run its tests, see [Building](docs/building.md).

## Write in plain language

gasim's writing follows [ISO 24495-1](https://www.iso.org/standard/78907.html),
the international standard for plain language. Writing is plain when
readers can:

1. **find** what they need
2. **understand** it the first time they read it
3. **use** it to do what they came to do

This applies to everything you write for gasim:

- the docs in `docs/` and the README
- code comments, including doc comments (`///` and `//!`)
- comments in the examples, including colorForth comments in `.cf` files
- help text and messages that gasim prints
- commit messages and pull request descriptions

## How to write plainly

**Know your reader.** Think about who will read it and what they need to
do. A doc page is for someone using gasim. A doc comment is for someone
about to call or change the code.

**Put the most important thing first.** Start with what the thing does or
what the reader should know. Give details and exceptions after that.

**Use short sentences.** Aim for one idea per sentence. If a sentence has
several commas or semicolons, split it.

**Use full sentences.** Write "Returns the examples in `dir`", not "the
examples in `dir`, by name". Fragments make the reader guess the verb.

**Use the active voice.** Write "the GUI shows the error", not "the error
is said".

**Use common words.** Write "folder" or "file", "next to" and "use". When
you need a technical term, explain it the first time you use it, or link
to where the docs explain it.

**Use lists and tables.** Use a list for steps or options. Use a table to
compare things. Use headings so readers can find their place.

**Show an example.** A short example, such as a command and its output,
is often clearer than a description.

**Cut what the reader doesn't need.** Leave out history, thinking aloud,
and anything the code already makes obvious.

## Code comments

- Start each doc comment with a full sentence that says what the code does.
  For example: "Returns the first folder that has examples in it."
- Explain *why* the code does something when it isn't obvious. Don't repeat
  what the code says.
- Keep comments short. If a comment needs several paragraphs, the docs may
  be a better place for it.

## Examples

Each example in `examples/` starts with a comment in the form
`name - what it does`. The Examples menus in the GUI and the web version
show this text as the example's description, so keep it short:

```
\ hello.ga - print a greeting
```

In a `.cf` file, this is the first comment line of block 0. To change it,
write the block as text, edit it, and pack it again:

```bash
gasim cf text examples/hello.cf > hello.txt
gasim cf pack hello.txt -o examples/hello.cf
```

colorForth has no apostrophe, so `.cf` comments use `:` for one, as in
`ashleyf:s`.

## Commit messages

- Write a short subject line that says what changed. Prefix it with the
  area when that helps, such as `docs:` or `examples:`.
- After a blank line, write a few short lines or a list on what changed and
  why.

## Pull requests

A pull request description has a title and two sections:

- **Summary:** what changed and why, and any trade-offs a reviewer should
  weigh.
- **Test plan:** a checklist of what you ran, and what you didn't check.

Make each claim one the code supports.
