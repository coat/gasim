import { engine, example } from './harness.test.js';
import * as app from './state.js';
import { assert, assertEquals } from '@std/assert';

const { state } = app;

/** Loads an example as the page does, on a new engine. */
async function load(name) {
  state.gasim = await engine();
  app.load({ name, kind: app.kindOf(name), bytes: await example(name), loads: [0], example: true });
}

/** Runs the chip as a frame does, until it stops. */
function run() {
  state.gasim.run(1_000_000);
  app.refresh();
}

Deno.test('kindOf goes by the extension', () => {
  assertEquals(app.kindOf('hello.ga'), 'ga');
  assertEquals(app.kindOf('BLOCKS.CF'), 'cf');
  assertEquals(app.kindOf('notes.txt'), null);
});

Deno.test('nodes are numbered by row and column', async () => {
  await load('hello.ga');
  assertEquals(app.nodeNumber(0), 0);
  assertEquals(app.nodeNumber(143), 717);
  assertEquals(app.nodeIndex(717), 143);
  assertEquals(app.nodeIndex(718), null);
  assertEquals(app.nodeIndex(800), null);
});

Deno.test('move stays on the chip', async () => {
  await load('hello.ga');
  app.select(0);
  app.move(-1, 0);
  assertEquals(state.selected, 0);
  app.move(1, 1);
  assertEquals(app.nodeNumber(state.selected), 101);
});

Deno.test('a loaded example runs to the console', async () => {
  await load('hello.ga');
  assertEquals(state.message, 'Loaded hello.ga');
  run();
  assertEquals(state.console, 'Hello, world!\n');
});

Deno.test('input the console has no room for waits for the node to read', async () => {
  await load('echo.ga');
  // more than the console holds
  const line = `${'x'.repeat(599)}\n`;
  app.sendInput(line);
  assert(state.pendingInput.length > 0);
  run();
  run();
  assertEquals(state.pendingInput.length, 0);
  assertEquals(state.console, line);
});

Deno.test('input after it ends is refused', async () => {
  await load('echo.ga');
  app.endInput();
  assert(state.inputEnded);
  app.sendInput('more');
  assertEquals(state.message, "The console's input has ended");
});

Deno.test('reset forgets the console', async () => {
  await load('hello.ga');
  run();
  app.reset();
  assertEquals(state.console, '');
  assertEquals(state.chip.steps, 0);
});

Deno.test('the trace can show only the selected node', async () => {
  await load('hello.ga');
  state.trace.lines = ['000 one', '717 two', '000 three'];
  state.trace.onlySelected = true;
  app.select(0);
  assertEquals(app.traceShown(), ['000 one', '000 three']);
  state.trace.onlySelected = false;
  assertEquals(app.traceShown().length, 3);
});

Deno.test('steps say what they stepped', async () => {
  await load('hello.ga');
  app.stepNext();
  assertEquals(state.message, `Stepped node ${app.pad(app.nodeNumber(state.selected))}`);
  app.stepRound();
  assertEquals(state.message, 'Stepped each node that could run');
  app.select(app.nodeIndex(717));
  app.stepNode();
  assertEquals(state.message, 'Node 717 is still waiting');
});
