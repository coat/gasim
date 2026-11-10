# Installing

## Downloads

Each [GitHub release](https://github.com/coat/gasim/releases) has two
programs:

- `gasim`, which runs in a terminal
- `gasim-gui`, a desktop GUI like the [web version](https://coat.github.io/gasim/)

On Linux, `gasim-gui` needs glibc, and X11 or Wayland.

## Nix

```bash
nix run github:coat/gasim         # the terminal version
nix run github:coat/gasim#gui     # the GUI
```

To build from source instead, see [Building](building.md).

## Examples

The example programs are in:

- `examples`, beside the programs in a release
- `share/gasim/examples` in the Nix package, and in `zig-out` after
  `zig build`

The GUI's Examples menu reads them from there. It also looks in
`gasim/examples` under `XDG_DATA_HOME` (`~/.local/share` by default, or
`LOCALAPPDATA` on Windows) and under each directory in `XDG_DATA_DIRS`, and
uses the first of these folders that has examples in it. If it finds no
examples, the menu is hidden. To hide it anyway, see
[GUI settings](#gui-settings).

The menu lists the `.ga`, `.af` and `.cf` files in the folder, but not the
ones in folders inside it. When a program has more than one version, such
as `hello.cf`, `hello.ga` and `hello.af`, the menu lists only one: the
`.cf` version, because that's the one you can edit in the GUI, or else the
`.ga` one. All versions turn into the same code on the chip. To add your
own example, put it in one of these folders and restart `gasim-gui`.
The menu describes each one with the comment the file starts with, after
the ` - `:

```
\ hello.ga - print a greeting
```

In a `.cf` file, the description is the comment at the start of block 0. If
the description says which other version it matches, such as `, as hello.ga
does`, the menu leaves that part out. The web version lists the examples
that were in `examples/` when it was built.

## GUI settings

`gasim-gui` reads its settings from `gasim/gui.json` under
`XDG_CONFIG_HOME` (`~/.config` by default, or `APPDATA` on Windows). Every
setting is optional.

```json
{
  "fonts": {
    "sans": { "regular": "/path/to/Inter-Regular.ttf", "bold": "/path/to/Inter-Bold.ttf" },
    "mono": { "regular": "/path/to/JetBrainsMono-Regular.otf" },
    "size": 11
  },
  "colors": { "base00": "#1d2021", "base01": "#3c3836", "...": "...", "base0F": "#d65d0e" },
  "examples": { "menu": false }
}
```

- **Fonts** are paths to TrueType or OpenType files. The GUI draws only the
  files you give it. If you leave out a face, such as bold, the GUI makes it
  from the regular one.
- **size** is in points.
- **colors** is a [base16](https://github.com/tinted-theming/home) scheme.
  The Auto theme uses it. The Light and Dark themes keep their own colors,
  but use your fonts.
- **examples.menu** set to `false` hides the Examples menu. It is `true` by
  default.

### Home Manager

The flake has a Home Manager module that writes this file. If you use
[Stylix](https://github.com/nix-community/stylix), the module takes its fonts
and colors from Stylix.

```nix
{
  imports = [gasim.homeModules.default];
  programs.gasim.enable = true;
  # without Stylix, or to override it
  programs.gasim.fonts.mono = { package = pkgs.jetbrains-mono; name = "JetBrains Mono"; };
  programs.gasim.examples.menu = false;
}
```
