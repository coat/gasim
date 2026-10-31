import { engine, example, runToStop } from './harness.test.js';
import { Kind } from './engine.js';
import { assert, assertEquals } from '@std/assert';

Deno.test('the chip is a GA144', async () => {
  const g = await engine();
  assertEquals(g.nodes, 144);
  const chip = g.chip();
  assertEquals([chip.rows, chip.columns], [8, 18]);
});

Deno.test('hello.ga prints a greeting', async () => {
  const g = await engine();
  assertEquals(g.load(Kind.ga, await example('hello.ga')), null);
  assertEquals(runToStop(g), { stop: 'settled', output: 'Hello, world!\n' });
});

Deno.test('echo.ga copies console input', async () => {
  const g = await engine();
  assertEquals(g.load(Kind.ga, await example('echo.ga')), null);
  assertEquals(runToStop(g).stop, 'input');
  assert(g.wantsInput());
  assertEquals(g.give('echo me\n'), 8);
  assertEquals(runToStop(g).output, 'echo me\n');
});

Deno.test('load gives the error, with where it was', async () => {
  const g = await engine();
  assertEquals(g.load(Kind.ga, 'node 717\nnonsense\n'), "line 2: UndefinedLabel at 'nonsense'");
});

Deno.test('back undoes a step', async () => {
  const g = await engine();
  g.load(Kind.ga, await example('hello.ga'));
  assertEquals(g.back(), false);
  assert(g.stepRound());
  const after = g.chip().steps;
  assert(after > 0);
  assert(g.back());
  assertEquals(g.chip().steps, 0);
});

Deno.test('a breakpoint is set, then cleared', async () => {
  const g = await engine();
  g.load(Kind.ga, await example('hello.ga'));
  assertEquals(g.toggleBreakpoint(0, 0), true);
  assertEquals(g.chip().breakpoints.length, 1);
  assertEquals(g.toggleBreakpoint(0, 0), false);
  assertEquals(g.chip().breakpoints.length, 0);
});

Deno.test('tiles show what each node waits on', async () => {
  const g = await engine();
  g.load(Kind.ga, await example('hello.ga'));
  const tiles = g.tiles();
  assertEquals(tiles.length, 144);
  assertEquals(tiles[0].doing, 'run');
});
