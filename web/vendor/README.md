# Vendored

Copied as published, so the web version needs no package manager:

- `mithril.min.js`: [Mithril](https://mithril.js.org/) 2.2.2, from
  `https://cdn.jsdelivr.net/npm/mithril@2.2.2/mithril.min.js`. MIT, see
  `LICENSE-mithril`.
- `pico.slate.min.css`: [Pico CSS](https://picocss.com/) 2.0.6 with its
  slate theme, from
  `https://cdn.jsdelivr.net/npm/@picocss/pico@2.0.6/css/pico.slate.min.css`.
  MIT, see `LICENSE-pico`.
- `../icons/*.svg`: some of [Heroicons](https://heroicons.com/) 2.2.0's
  20 px solid icons, from `https://registry.npmjs.org/heroicons/-/heroicons-2.2.0.tgz`.
  The GUI draws them too, converted to TinyVG as it is built. MIT, see
  `LICENSE-heroicons`. Not Heroicons' own, but drawn from them: `step` and
  `step-back` are `play` squeezed, and mirrored, with a bar as `pause`'s
  are, `round` is `forward` squeezed, with a bar, and `step-node` is a small
  `step` cut out of `stop`'s tile, wound the other way so the hole shows
  where shapes fill nonzero, as dvui's do.
