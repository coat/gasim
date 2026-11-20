# Notes for coding agents

gasim is a simulator for GreenArrays' GA144 chip, written in Zig. It has
one core and three front ends: a command with a terminal UI, a desktop
GUI and a web version. This page tells an agent where to look and what
to keep in mind. It applies to every agent and tool, whatever model runs
it.

## Read first

- [ARCHITECTURE.md](ARCHITECTURE.md) explains how the code fits together:
  what `build.zig` builds, the folders, and the rules that cross them.
- Each code folder has a README with its interface, its invariants and
  its side effects. Read the one for the folder you change, such as
  [src/README.md](src/README.md) or [web/README.md](web/README.md).
- [CONTRIBUTING.md](CONTRIBUTING.md) says how to write docs, comments,
  commit messages and pull requests.
- [docs/ROADMAP.md](docs/ROADMAP.md) says what is done and what comes
  next.
- [docs/README.md](docs/README.md) lists the docs for users.

## Build and check

The Nix dev shell (`nix develop`, or direnv with `.envrc`) has Zig, Deno,
SDL3 and the benchmark tools. [Building](docs/building.md) has the
details.

| Command | What it checks |
| --- | --- |
| `zig build test` | The core's and the command's tests, and the examples |
| `zig build test-web` | The web version's tests, with Deno |
| `zig build test-gui -Dgui` | The GUI's tests, in a hidden window. They need a display. |
| `zig fmt --check build.zig build.zig.zon src tests tools examples` | The formatting that CI checks |

Without `rom/pFDISK.blk`, the tests that need the ROM are skipped. The
ROM belongs to GreenArrays, so never commit `rom/*.blk`. See
[ROM](docs/rom.md).

## Rules to keep

- Write in plain language, as CONTRIBUTING.md describes. This covers
  docs, comments, help text, commit messages and pull requests.
- When you change what a folder's README describes, update that README
  in the same change. Update ARCHITECTURE.md when you change the build or
  a rule that crosses folders.
- Make each claim in a doc, commit message or pull request one that the
  code supports.
- Don't add lines that credit an AI tool or model to commits or pull
  requests.
