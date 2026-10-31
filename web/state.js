// The app's state and what changes it: loading files and the ROM, running
// and stepping the chip. Views read `state` and call these; each change
// ends in a redraw.

import { loadEngine, Kind, Status } from './engine.js';
import * as store from './store.js';

const { m } = window;

/** The examples in zig-out/web/examples, with what each shows. */
export const examples = [
  { name: 'hello.ga', about: 'Print a greeting' },
  { name: 'hello.af', about: 'Print a greeting, in arrayForth 3' },
  { name: 'hello.cf', about: 'Print a greeting, in colorForth' },
  { name: 'echo.ga', about: 'Copy console input to the console' },
  { name: 'echo.af', about: 'Copy console input, in arrayForth 3' },
  { name: 'echo.cf', about: 'Copy console input, in colorForth' },
  { name: 'upcase.ga', about: 'Upper-case console input' },
  { name: 'upcase.af', about: 'Upper-case console input, in arrayForth 3' },
  { name: 'upcase.cf', about: 'Upper-case console input, in colorForth' },
  { name: 'alphabet.cf', about: 'Print the alphabet' },
  { name: 'variables.cf', about: 'Count with a variable' },
  { name: 'multiply.cf', about: 'Multiply with +*' },
];

/** console output kept, in characters */
const consoleCapacity = 64 * 1024;
/** lines typed at the prompt kept, and the prompt's answers shown */
const historyCapacity = 200;
const entriesCapacity = 500;
/** how long a frame spends running the chip, in milliseconds */
const frameBudget = 8;
/** lines of the trace kept */
const traceCapacity = 5000;
/** files kept to open again */
const recentCapacity = 8;

export const state = {
  gasim: null,
  /** the selected node's index, which is also the prompt's target */
  selected: 0,
  running: false,
  /** waiting on the console for input, with nothing else to do */
  waitingForInput: false,
  /** a line about what just happened, for the status bar */
  message: 'Open a file, or pick an example',
  /**
   * the file loaded: { name, kind, bytes, loads, handle }, the handle where
   * the browser gave one to read it again
   */
  file: null,
  /** files opened before, the latest first, as `file` */
  recent: [],
  /** where the ROM came from: 'served', 'saved', 'given', or null */
  rom: null,
  console: '',
  chip: null,
  node: null,
  /** each node's Status name, and the ports it moved words through */
  statuses: [],
  transfers: new Uint8Array(0),
  /** each node's registers and ports, while the map shows them, or null */
  tiles: null,
  /** the dock's tab: 'forth', 'console', 'trace', 'breakpoints' or 'history' */
  dock: 'forth',
  /**
   * the trace: whether tracing, the lines kept, whether older ones were
   * dropped, and whether only the selected node's are shown
   */
  trace: { on: false, lines: [], dropped: false, onlySelected: false },
  /** the steps and runs to go back through, oldest first: { steps, cause } */
  moments: [],
  /** console output arrived while the console's tab was not shown */
  unseenOutput: false,
  /** the prompt's answers: { target, line, answer } */
  entries: [],
  /** lines typed at the prompt, the latest last */
  history: [],
  /** console input that did not fit yet, given as the node reads */
  pendingInput: new Uint8Array(0),
  inputEnded: false,
  /** the block being edited, as Sim.editorView has it */
  editor: null,
  /** the editor's file: { name, handle }, or null for a new one */
  editorFile: null,
  /** the blocks of the editor's file, as text */
  blocks: [],
  blockQuery: '',
  /** whether blue words show, and the marks where colors change */
  showFormat: true,
  showMarks: false,
  /** on a narrow screen, what the editor's view shows */
  editorTab: 'editing',
};

let rounds = 20000;
const decoder = new TextDecoder();
const encoder = new TextEncoder();

/** Loads the engine and the ROM, and comes back to where the last visit was. */
export async function start() {
  state.gasim = await loadEngine();
  await findRom();
  state.history = (await store.get('history')) ?? [];
  state.recent = (await store.get('recent')) ?? [];
  refresh();
  refreshEditor();
  await restore();
}

/** Reads what the views show from the engine. */
export function refresh() {
  const g = state.gasim;
  state.chip = g.chip();
  state.node = g.node(state.selected);
  const { status, transfers } = g.statuses();
  state.statuses = Array.from(status, (s) => Status[s]);
  state.transfers = transfers.slice();
  if (state.tiles) state.tiles = g.tiles();
  state.moments = g.history();
  if (state.trace.on) takeTrace();
  givePending();
  const output = g.consoleOutput();
  if (output.length > 0) {
    if (state.dock !== 'console') state.unseenOutput = true;
    state.console += decoder.decode(output, { stream: true });
    if (state.console.length > consoleCapacity) state.console = state.console.slice(-consoleCapacity / 2);
  }
}

// ---------- nodes ----------

/** a node's number, such as 717, from its index */
export function nodeNumber(i) {
  const columns = state.chip.columns;
  return Math.floor(i / columns) * 100 + (i % columns);
}

/** a node's index from its number, or null if it is not on the chip */
export function nodeIndex(number) {
  const { rows, columns } = state.chip;
  const y = Math.floor(number / 100);
  const x = number % 100;
  return y < rows && x < columns ? y * columns + x : null;
}

export function select(i) {
  state.selected = i;
  state.node = state.gasim.node(i);
  keepWorkspace();
}

/** Reads each node's registers as the chip changes, for the map, or stops. */
export function showRegisters(on) {
  if (on === (state.tiles !== null)) return;
  state.tiles = on ? state.gasim.tiles() : null;
}

/** Moves the selection a node east, west, north or south, if there is one. */
export function move(dx, dy) {
  const { rows, columns } = state.chip;
  const x = (state.selected % columns) + dx;
  const y = Math.floor(state.selected / columns) + dy;
  if (x >= 0 && x < columns && y >= 0 && y < rows) select(y * columns + x);
}

// ---------- files ----------

/** the kind of a file by its extension, or null */
export function kindOf(name) {
  const extension = name.split('.').pop().toLowerCase();
  return extension in Kind ? extension : null;
}

/** whether a file of this kind has blocks to choose to load */
export const hasBlocks = (kind) => kind === 'blk' || kind === 'cf';

/**
 * Loads a program, or a ROM if it is a dump or arrayForth 3's disk. With a
 * handle, from the File System Access API, it can be read again and a .cf
 * saved in place.
 */
export async function openFile(file, handle = null) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (/\.txt$/i.test(file.name) || /^pFDISK\.blk$/i.test(file.name)) return giveRom(bytes, file.name);
  const kind = kindOf(file.name);
  if (!kind) {
    state.message = `${file.name} is not a .ga, .af, .blk or .cf file`;
    return;
  }
  const loads = state.recent.find((r) => r.name === file.name)?.loads ?? [0];
  load({ name: file.name, kind, bytes, loads, handle });
}

/** whether the browser can open and save files in place */
export const canPick = 'showOpenFilePicker' in window;

const pickerTypes = [{ description: 'gasim files', accept: { 'application/octet-stream': ['.ga', '.af', '.blk', '.cf', '.txt'] } }];

/** Opens a file through the browser's picker, keeping its handle. */
export async function pickFile() {
  let handle;
  try {
    [handle] = await window.showOpenFilePicker({ types: pickerTypes });
  } catch {
    // not chosen
    return;
  }
  await openFile(await handle.getFile(), handle);
}

/** Opens a file opened before, read again where it can be. */
export async function openRecent(name) {
  const file = state.recent.find((r) => r.name === name);
  if (file) load(await readAgain(file));
}

/** The file as it is now, if its handle can read it, or as it was kept. */
async function readAgain(file) {
  if (!file.handle) return file;
  try {
    if ((await file.handle.queryPermission()) !== 'granted' && (await file.handle.requestPermission()) !== 'granted') return file;
    const bytes = new Uint8Array(await (await file.handle.getFile()).arrayBuffer());
    return { ...file, bytes };
  } catch {
    return file;
  }
}

/** Keeps a file to open again, the latest first. */
function keepRecent(file) {
  state.recent = [file, ...state.recent.filter((r) => r.name !== file.name)].slice(0, recentCapacity);
  store.put('recent', state.recent);
}

export function forgetRecent() {
  state.recent = [];
  store.remove('recent');
}

export async function openExample(name) {
  const response = await fetch(`examples/${name}`);
  if (!response.ok) {
    state.message = `Cannot fetch ${name}`;
    return m.redraw();
  }
  load({ name, kind: kindOf(name), bytes: new Uint8Array(await response.arrayBuffer()), loads: [0], example: true });
  m.redraw();
}

/** Assembles a file onto a new chip, keeping it to load again. */
export function load(file) {
  pause();
  state.file = file;
  if (!file.example) keepRecent(file);
  forgetInput();
  const error = state.gasim.load(Kind[file.kind], file.bytes, hasBlocks(file.kind) ? file.loads : []);
  state.message = error ? `${file.name}: ${error}` : `Loaded ${file.name}`;
  // the engine opens colorForth in the editor too
  if (file.kind === 'cf') {
    state.editorFile = { name: file.name, handle: file.handle ?? null };
    refreshEditor();
  }
  refresh();
  keepWorkspace();
}

/**
 * Loads the file again, such as with other blocks or a new ROM, as it is
 * now if it can be read again.
 */
export async function reload() {
  if (state.file) load(await readAgain(state.file));
}

// ---------- the ROM ----------

/** The ROM served beside the page, or else the one saved in the browser. */
async function findRom() {
  const served = await fetch('ga144.txt').then((r) => (r.ok ? r.arrayBuffer() : null), () => null);
  if (served && state.gasim.setRom(new Uint8Array(served))) {
    state.rom = 'served';
    return;
  }
  const saved = await store.get('rom');
  if (saved && state.gasim.setRom(saved)) state.rom = 'saved';
}

/** Takes a ROM given by the user, keeping it for next time. */
export async function giveRom(bytes, name) {
  if (!state.gasim.setRom(bytes)) {
    state.message = `${name} is neither a ROM dump nor arrayForth 3's disk`;
    return m.redraw();
  }
  state.rom = (await store.put('rom', bytes)) ? 'saved' : 'given';
  await reload();
  state.message = `ROM read from ${name}${state.file ? `, and ${state.file.name} loaded again` : ''}`;
  m.redraw();
}

export async function forgetRom() {
  await store.remove('rom');
  state.message = 'The saved ROM is forgotten, from the next visit';
  m.redraw();
}

// ---------- running ----------

export function toggleRun() {
  if (state.running) pause();
  else run();
}

export function run() {
  if (state.running) return;
  state.gasim.remember();
  state.running = true;
  state.waitingForInput = false;
  state.message = 'Running';
  requestAnimationFrame(frame);
}

export function pause() {
  if (!state.running) return;
  state.running = false;
  state.waitingForInput = false;
  state.message = 'Paused';
}

/** Runs the chip for about a frame's budget, keeping the budget to time. */
function frame() {
  if (!state.running) return;
  if (state.waitingForInput && !state.gasim.wantsInput()) state.waitingForInput = false;
  if (!state.waitingForInput) {
    const began = performance.now();
    const { stop, hit } = state.gasim.run(rounds);
    const took = performance.now() - began;
    if (stop === 'budget') rounds = Math.max(1000, Math.min(2_000_000, Math.round(rounds * Math.min(2, frameBudget / Math.max(took, 0.1)))));
    stopped(stop, hit);
  }
  refresh();
  m.redraw();
  if (state.running) requestAnimationFrame(frame);
}

function stopped(stop, hit) {
  if (stop === 'hit') {
    state.running = false;
    state.message = sentence(hit);
    const number = /node (\d+)/.exec(hit);
    if (number) select(nodeIndex(Number(number[1])));
  } else if (stop === 'settled') {
    state.running = false;
    state.message = 'Every node is waiting';
  } else if (stop === 'input') {
    state.waitingForInput = true;
    state.message = 'Waiting for console input';
  }
}

const sentence = (text) => text.charAt(0).toUpperCase() + text.slice(1);

/** Steps the next node to run, and selects it. */
export function stepNext() {
  if (state.running) return;
  const i = state.gasim.stepNext();
  if (i === null) state.message = 'Every node is waiting';
  else select(i);
  refresh();
}

/** Steps each runnable node once. */
export function stepRound() {
  if (state.running) return;
  if (!state.gasim.stepRound()) state.message = 'Every node is waiting';
  refresh();
}

/** Steps the selected node, even if it is waiting. */
export function stepNode() {
  if (state.running) return;
  if (!state.gasim.stepNode(state.selected)) state.message = 'The node is waiting';
  refresh();
}

export function back() {
  if (state.running) return;
  state.message = state.gasim.back() ? `Back to ${state.gasim.chip().steps.toLocaleString()} steps` : 'Nothing to go back to';
  refresh();
}

/** Goes back before the `n`th step or run kept, forgetting those after it. */
export function backTo(n) {
  if (state.running) return;
  if (state.gasim.backTo(n)) state.message = `Back to ${state.gasim.chip().steps.toLocaleString()} steps`;
  refresh();
}

export function reset() {
  pause();
  state.gasim.reset();
  forgetInput();
  state.message = 'Back to the start';
  refresh();
}

export function toggleBreakpoint(address, i = state.selected) {
  const set = state.gasim.toggleBreakpoint(i, address);
  if (set === null) state.message = 'There are too many breakpoints';
  refresh();
  keepWorkspace();
}

/** Watches a node's reads or writes through a port, or stops watching. */
export function toggleWatch(i, port, write) {
  const set = state.gasim.toggleWatch(i, port, write);
  if (set === null) state.message = 'There are too many watches';
  refresh();
  keepWorkspace();
}

export function clearBreakpoints() {
  state.gasim.clearBreakpoints();
  state.message = 'The breakpoints and watches are removed';
  refresh();
  keepWorkspace();
}

// ---------- the trace ----------

export function toggleTracing() {
  const on = !state.trace.on;
  if (!state.gasim.setTracing(on)) {
    state.message = 'There is not the memory to trace';
    return;
  }
  state.trace.on = on;
  state.message = on ? 'Tracing each step that runs code' : 'Not tracing';
  keepWorkspace();
}

/** Takes what was traced, keeping the last lines. */
function takeTrace() {
  const { text, dropped } = state.gasim.takeTrace();
  if (!text) return;
  const t = state.trace;
  const lines = text.split('\n');
  // the text ends a line
  lines.pop();
  t.lines = t.lines.concat(lines);
  if (dropped || t.lines.length > traceCapacity) t.dropped = true;
  if (t.lines.length > traceCapacity) t.lines = t.lines.slice(-traceCapacity);
}

export function clearTrace() {
  state.trace.lines = [];
  state.trace.dropped = false;
}

/** The lines of the trace shown: all, or the selected node's. */
export function traceShown() {
  const { lines, onlySelected } = state.trace;
  if (!onlySelected) return lines;
  const prefix = `${String(nodeNumber(state.selected)).padStart(3, '0')} `;
  return lines.filter((line) => line.startsWith(prefix));
}

export function saveTrace() {
  const lines = traceShown();
  download(new TextEncoder().encode(lines.map((line) => `${line}\n`).join('')), 'trace.txt', 'text/plain');
  state.message = `Saved ${lines.length.toLocaleString()} lines as trace.txt`;
}

/** Gives the user bytes as a file to save, wherever downloads go. */
function download(bytes, name, type = 'application/octet-stream') {
  const link = document.createElement('a');
  link.href = URL.createObjectURL(new Blob([bytes], { type }));
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}

// ---------- the workspace ----------

let workspaceTimer = null;
/** not until the last visit's workspace is back, so as not to lose it */
let restored = false;
/** whether the workspace is kept as it is now, and which keeping was last */
let kept = true;
let keepings = 0;

/** Keeps where the page is for the next visit, soon after it changes. */
function keepWorkspace() {
  if (!restored) return;
  kept = false;
  clearTimeout(workspaceTimer);
  workspaceTimer = setTimeout(flushWorkspace, 500);
}

/** Keeps the workspace now, such as as the page is left. */
export function flushWorkspace() {
  if (!restored || kept) return;
  clearTimeout(workspaceTimer);
  const keeping = ++keepings;
  const { file, chip, editor, editorFile } = state;
  store.put('workspace', {
    file,
    selected: state.selected,
    breakpoints: chip.breakpoints,
    watches: chip.watches,
    tracing: state.trace.on,
    editor: { name: editorFile?.name ?? null, handle: editorFile?.handle ?? null, bytes: state.gasim.editorContents(), unsaved: editor.unsaved, block: editor.block },
  }).then((ok) => {
    if (ok && keeping === keepings) kept = true;
  });
}

/** whether the blocks not saved are at least kept in the browser */
export const workspaceKept = () => kept;

/** Comes back to where the last visit was: its file, editor and breakpoints. */
async function restore() {
  const w = await store.get('workspace');
  if (!w) {
    restored = true;
    return;
  }
  const g = state.gasim;
  if (w.tracing && g.setTracing(true)) state.trace.on = true;
  if (w.file) load(w.file);
  for (const b of w.breakpoints ?? []) {
    const i = nodeIndex(b.node);
    if (i !== null && !state.chip.breakpoints.some((k) => k.node === b.node && k.address === b.address)) g.toggleBreakpoint(i, b.address);
  }
  for (const watch of w.watches ?? []) {
    const i = nodeIndex(watch.node);
    if (i !== null && !state.chip.watches.some((k) => k.node === watch.node && k.port === watch.port && k.write === watch.write)) g.toggleWatch(i, watch.port, watch.write);
  }
  if (w.editor?.bytes?.length > 0 && !g.editorOpen(w.editor.bytes)) {
    if (w.editor.unsaved) g.editorUnsaved();
    g.editorGoTo(w.editor.block);
    state.editorFile = w.editor.name ? { name: w.editor.name, handle: w.editor.handle } : null;
  }
  if (w.selected < state.chip.rows * state.chip.columns) select(w.selected);
  if (w.file) state.message = `Back to ${w.file.name}`;
  restored = true;
  refresh();
  refreshEditor();
}

// ---------- the prompt ----------

/**
 * Interprets a line of arrayForth 3 with the selected node as the IDE's
 * target, keeping it in the history, and selects the node the line made
 * the target, such as with 708 NODE.
 */
export function interpret(line) {
  const target = nodeNumber(state.selected);
  const answer = state.gasim.interpret(line, target);
  state.entries.push({ target, line, answer });
  if (state.entries.length > entriesCapacity) state.entries.splice(0, state.entries.length - entriesCapacity);
  if (line.trim() !== '' && state.history.at(-1) !== line) {
    state.history.push(line);
    if (state.history.length > historyCapacity) state.history.splice(0, state.history.length - historyCapacity);
    store.put('history', state.history);
  }
  if (answer.target !== null && answer.target !== target) {
    const i = nodeIndex(answer.target);
    if (i !== null) state.selected = i;
  }
  refresh();
}

/** The words that could complete the last word of `text`. */
export function completions(text) {
  const start = text.search(/\S*$/);
  const partial = text.slice(start);
  return { start, partial, words: partial === '' ? [] : state.gasim.complete(partial) };
}

// ---------- the console ----------

/** Gives the console input, keeping what does not fit for when it does. */
export function sendInput(text) {
  if (state.inputEnded) {
    state.message = "The console's input has ended";
    return;
  }
  const bytes = encoder.encode(text);
  const pending = new Uint8Array(state.pendingInput.length + bytes.length);
  pending.set(state.pendingInput);
  pending.set(bytes, state.pendingInput.length);
  state.pendingInput = pending;
  givePending();
  if (state.pendingInput.length > 0) state.message = `${state.pendingInput.length} bytes wait for the node to read`;
}

function givePending() {
  if (state.pendingInput.length === 0) return;
  const given = state.gasim.give(state.pendingInput);
  state.pendingInput = state.pendingInput.slice(given);
}

/** Ends the console's input, once what is pending has been given. */
export function endInput() {
  givePending();
  if (state.pendingInput.length > 0) {
    state.message = 'Input can end once the node has read what is pending';
    return;
  }
  state.gasim.endInput();
  state.inputEnded = true;
  state.message = "The console's input has ended";
}

/** Forgets the console's output and input, as the chip starts again. */
function forgetInput() {
  state.console = '';
  state.unseenOutput = false;
  state.pendingInput = new Uint8Array(0);
  state.inputEnded = false;
}

// ---------- the editor ----------

let blocksTimer = null;

/** Reads the block being edited, and soon after, the blocks as text. */
export function refreshEditor() {
  state.editor = state.gasim.editor();
  keepWorkspace();
  clearTimeout(blocksTimer);
  blocksTimer = setTimeout(() => {
    state.blocks = state.gasim.editorBlocks();
    m.redraw();
  }, 250);
}

/** Gives the editor a key, and does what it asks, as the TUI does. */
export function editorKey(key, ctrl) {
  const action = state.gasim.editorKey(key, ctrl);
  if (action.error) {
    state.message = sentence(action.error);
  } else if (action === 'save') {
    saveEditor();
  } else if (action === 'compile') {
    compileEditor();
  } else if (action === 'toggle_format') {
    toggleFormat();
  } else if (action === 'quit') {
    m.route.set('/chip');
  }
  refreshEditor();
}

export function editorGoTo(block) {
  if (!state.gasim.editorGoTo(block)) state.message = 'There is no such block';
  refreshEditor();
}

export function editorMoveTo(i) {
  state.gasim.editorMoveTo(i);
  refreshEditor();
}

export function toggleFormat() {
  state.showFormat = !state.showFormat;
}

export function toggleMarks() {
  state.showMarks = !state.showMarks;
}

/**
 * Saves the editor's blocks: in place, to the file they were opened from or
 * last saved to, where the browser can, or else as a download. `as` asks
 * where to save them first.
 */
export async function saveEditor(as = false) {
  const bytes = state.gasim.editorContents();
  const name = state.editorFile?.name ?? 'blocks.cf';
  let handle = as ? null : state.editorFile?.handle ?? null;
  if (!handle && 'showSaveFilePicker' in window) {
    try {
      handle = await window.showSaveFilePicker({ suggestedName: name, types: [{ description: 'colorForth blocks', accept: { 'application/octet-stream': ['.cf'] } }] });
    } catch (error) {
      if (error.name === 'AbortError') return;
      handle = null;
    }
  }
  const compressed = state.editor.compressed ? ', uncompressed' : '';
  const count = bytes.length / 1024;
  const blocks = `${count} block${count === 1 ? '' : 's'}`;
  if (handle) {
    try {
      const mode = { mode: 'readwrite' };
      if ((await handle.queryPermission(mode)) !== 'granted' && (await handle.requestPermission(mode)) !== 'granted') {
        throw new Error('the browser was not allowed to');
      }
      const writable = await handle.createWritable();
      await writable.write(bytes);
      await writable.close();
    } catch (error) {
      state.message = `Cannot save ${handle.name}: ${error.message}`;
      return m.redraw();
    }
    state.editorFile = { name: handle.name, handle };
    state.message = `Saved ${blocks} to ${handle.name}${compressed}`;
  } else {
    download(bytes, name);
    state.editorFile = { name, handle: null };
    state.message = `Saved ${blocks} as ${name}${compressed}, wherever downloads go`;
  }
  state.gasim.editorSaved();
  refreshEditor();
  m.redraw();
}

/** Compiles the block, and starts the chip again with its code. */
export function compileEditor() {
  pause();
  const { message } = state.gasim.editorCompile();
  state.message = sentence(message);
  refresh();
  refreshEditor();
}

/** Starts a new file of blocks, once unsaved changes are let go. */
export function newEditorFile() {
  if (state.editor.unsaved && !confirm('The blocks are not saved. Start a new file anyway?')) return;
  state.gasim.editorOpen(new Uint8Array(0));
  state.editorFile = null;
  state.message = 'A new file of blocks';
  refreshEditor();
}
