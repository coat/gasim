// The wasm module (src/web/main.zig) behind a small JS API. Bytes go in
// copied into wasm memory; text and JSON come back from one buffer.

/** File kinds, as Sim.Kind numbers them, by extension. */
export const Kind = { ga: 0, af: 1, blk: 2, cf: 3 };

/** Why run() stopped, as Sim.Stop numbers them. */
export const Stop = ['budget', 'settled', 'input', 'hit'];

/** A node's status in statuses(), as Sim.Status numbers them. */
export const Status = ['running', 'code', 'reading', 'writing'];

/** What the chip was saved before, as Sim.Cause numbers them. */
export const Cause = ['step', 'round', 'node', 'run', 'line', 'reset', 'compile'];

/** Port directions, as gasim's Direction numbers them. */
export const Direction = { right: 0, down: 1, left: 2, up: 3 };

/** What an editor key asks for, as Editor.Action numbers them. */
export const Action = ['none', 'save', 'compile', 'toggle_format', 'quit'];

/** Editor keys with names, as Editor.Key.Code numbers them. */
const editorKeys = ['char', 'left', 'right', 'up', 'down', 'home', 'end', 'page_up', 'page_down', 'escape', 'enter', 'backspace'];

export async function loadEngine(url = 'gasim.wasm') {
  const dec = new TextDecoder();
  const enc = new TextEncoder();
  let x;
  const view = (p, n) => new Uint8Array(x.memory.buffer, p, n);
  const text = (p, n) => dec.decode(view(p, n));
  const env = { jsLog: (p, n) => console.error('[gasim]', text(p, n)) };
  const { instance } = await WebAssembly.instantiateStreaming(fetch(url), { env });
  x = instance.exports;
  if (!x.init()) throw new Error('gasim: out of memory');

  const out = (n = x.outLen()) => text(x.outPtr(), n);
  // a view of nothing is out of memory, as JSON is never empty
  const json = (n) => {
    if (!n) throw new Error('gasim: out of memory');
    return JSON.parse(out(n));
  };
  // why a call failed, which only running out of memory leaves unsaid
  const why = () => out() || 'gasim: out of memory';

  /** Calls f with bytes (a Uint8Array or a string) copied into wasm memory. */
  function withBytes(bytes, f) {
    if (typeof bytes === 'string') bytes = enc.encode(bytes);
    const size = Math.max(1, bytes.length);
    const p = x.alloc(size);
    if (!p) throw new Error('gasim: out of memory');
    try {
      view(p, bytes.length).set(bytes);
      return f(p, bytes.length);
    } finally {
      x.free(p, size);
    }
  }

  const count = () => {
    const chip = json(x.chipView());
    return chip.rows * chip.columns;
  };
  const nodes = count();

  return {
    nodes,

    // ---------- the chip ----------

    /** A ROM dump, or arrayForth 3's pFDISK.blk. Returns whether it was read. */
    setRom: (bytes) => withBytes(bytes, (p, n) => !!x.setRom(p, n)),
    /**
     * Assembles a file and sets up the chip with it. `kind` is a Kind;
     * `loads` the blocks to load from a .blk or .cf. Returns null, or the
     * error, with where it was.
     */
    load(kind, bytes, loads = []) {
      const l = new Uint32Array(loads);
      return withBytes(bytes, (p, n) =>
        withBytes(new Uint8Array(l.buffer), (lp) => (x.load(kind, p, n, lp, l.length) ? null : why())),
      );
    },
    /**
     * Runs for up to `budget` rounds. Returns why it stopped, a Stop, with
     * the breakpoint or watch hit described.
     */
    run(budget) {
      const stop = Stop[x.run(budget >>> 0)];
      if (stop === undefined) throw new Error('gasim: out of memory');
      return { stop, hit: stop === 'hit' ? out() : null };
    },
    /** Steps the next node to run; returns its index, or null when all wait. */
    stepNext() {
      const i = x.stepNext();
      return i < 0 ? null : i;
    },
    /** Steps each runnable node once; false when every node waits. */
    stepRound: () => !!x.stepRound(),
    /** Steps one node; false if it is still waiting. */
    stepNode: (i) => !!x.stepNode(i),
    reset: () => x.reset(),
    /** Saves the chip to go back to, before running it. */
    remember: () => x.remember(Cause.indexOf('run')),
    /** Goes back before the last step or run; false with nothing to go back to. */
    back: () => !!x.back(),
    /** Goes back before the `n`th step or run kept, the oldest 0. */
    backTo: (n) => !!x.backTo(n),
    /** The steps and runs to go back through, oldest first: { steps, cause }. */
    history: () => json(x.historyView()),
    /** Returns whether it is set now, or null with too many. */
    toggleBreakpoint(i, address) {
      const r = x.toggleBreakpoint(i, address);
      return r < 0 ? null : !!r;
    },
    toggleWatch(i, direction, write) {
      const r = x.toggleWatch(i, Direction[direction], write ? 1 : 0);
      return r < 0 ? null : !!r;
    },
    clearBreakpoints: () => x.clearBreakpoints(),
    /** Starts or stops tracing; false out of memory. */
    setTracing: (on) => !!x.setTracing(on ? 1 : 0),
    /** The lines traced since last called, and whether older ones were dropped. */
    takeTrace() {
      const r = x.takeTrace() >>> 0;
      const n = r & 0x7fffffff;
      return { text: n ? out(n) : '', dropped: r >= 0x80000000 };
    },
    /**
     * Each node's status, a Status index, and the ports it moved words
     * through in its last step: bits 0-3 written, 4-7 read, by Direction.
     * Views into wasm memory, valid until the next call.
     */
    statuses() {
      const p = x.nodeStatuses();
      return { status: view(p, nodes), transfers: view(p + nodes, nodes) };
    },
    node: (i) => json(x.nodeView(i)),
    chip: () => json(x.chipView()),

    // ---------- the prompt ----------

    /** Interprets a line with node `target` as the IDE's. */
    interpret: (line, target) => withBytes(line, (p, n) => json(x.interpret(p, n, target))),
    complete: (prefix) => withBytes(prefix, (p, n) => json(x.complete(p, n))),

    // ---------- the console ----------

    /** Gives the console input; returns how many bytes there was room for. */
    give: (bytes) => withBytes(bytes, (p, n) => x.give(p, n)),
    endInput: () => x.endInput(),
    wantsInput: () => !!x.wantsInput(),
    /** What the console wrote since this was last called, as bytes. */
    consoleOutput() {
      const n = x.consoleOutput();
      return view(x.outPtr(), n).slice();
    },

    // ---------- the editor ----------

    /** Opens colorForth blocks; returns null, or why it could not. */
    editorOpen: (bytes) => withBytes(bytes, (p, n) => (x.editorOpen(p, n) ? null : why())),
    /**
     * Gives the editor a key: a character, or a name such as 'enter'.
     * Returns the Action, or { error } with its message.
     */
    editorKey(key, ctrl = false) {
      const named = editorKeys.indexOf(key);
      const code = named > 0 ? named : 0;
      const char = named > 0 ? 0 : key.charCodeAt(0);
      // colorForth has no characters beyond ASCII, and the editor takes a byte
      if (char >= 0x80) return 'none';
      const r = x.editorKey(code, char, ctrl ? 1 : 0);
      return r < 0 ? { error: why() } : Action[r];
    },
    editor: () => json(x.editorView()),
    editorMoveTo: (i) => x.editorMoveTo(i),
    editorGoTo: (block) => !!x.editorGoTo(block),
    /** The editor's file to save, as a copy. */
    editorContents() {
      const n = x.editorContents();
      return view(x.editorContentsPtr(), n).slice();
    },
    editorSaved: () => x.editorSaved(),
    editorUnsaved: () => x.editorUnsaved(),
    /** Compiles the block and starts the chip again: { ok, message }. */
    editorCompile() {
      const ok = !!x.editorCompile();
      return { ok, message: ok ? out() : why() };
    },
    /** Each block of the file: { block, read_only, empty, text }. */
    editorBlocks: () => json(x.editorBlocks()),
  };
}
