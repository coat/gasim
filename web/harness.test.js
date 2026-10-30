// What the tests share: the page's globals, and the engine. Each test file
// imports this before the modules it tests. Run them with `zig build
// test-web`, or `deno test --allow-read web/` after `zig build web`. It is
// named as a test, with none, so that `zig build web` leaves it out too.

import { loadEngine } from './engine.js';
import { resolve, toFileUrl } from '@std/path';

// state.js reads Mithril and the browser's APIs from `window`, as the page
// loads Mithril with a script tag
globalThis.window = globalThis;
(0, eval)(await Deno.readTextFile(new URL('vendor/mithril.min.js', import.meta.url)));

/** gasim.wasm: given by `zig build test-web`, or else as `zig build web` installs it */
export const wasm = Deno.args[0] ? toFileUrl(resolve(Deno.args[0])) : new URL('../zig-out/web/gasim.wasm', import.meta.url);

/** A new engine, with no ROM. */
export const engine = () => loadEngine(wasm);

/** An example's bytes. */
export const example = (name) => Deno.readFile(new URL(`../examples/${name}`, import.meta.url));

const decoder = new TextDecoder();

/** Runs the chip until it stops, returning why and what the console wrote. */
export function runToStop(g, budget = 1_000_000) {
  const { stop } = g.run(budget);
  return { stop, output: decoder.decode(g.consoleOutput()) };
}
