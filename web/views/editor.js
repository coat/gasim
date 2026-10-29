// The colorForth editor: the blocks of the file, the block being edited as
// colored words, the selected node beside it, and a bar of colors and what
// the editor is doing. Keys go to Editor.key through a hidden input, which
// on-screen keyboards and input methods type into too.

import { state, editorKey, editorGoTo, editorMoveTo, saveEditor, compileEditor, newEditorFile, toggleFormat, toggleMarks } from '../state.js';
import { NodePanel } from './node.js';

const { m } = window;

/** the colors, the letter that sets each with ctrl, and with shift */
export const colors = [
  { color: 'red', ctrl: 'r', shift: 'R', does: 'defines a word' },
  { color: 'yellow', ctrl: 'y', shift: 'Y', does: 'runs as it compiles' },
  { color: 'green', ctrl: 'g', shift: 'G', does: 'compiles' },
  { color: 'white', ctrl: 'w', shift: 'W', does: 'is a comment' },
  { color: 'cyan', ctrl: 't', shift: 'C', does: 'compiles a macro' },
  { color: 'magenta', ctrl: 'v', shift: 'M', does: 'is a variable' },
  { color: 'blue', ctrl: 'b', shift: 'B', does: 'lays out the block' },
];

/** the marks `gasim blocks` writes before a word whose color changes */
const marks = { red: ':', yellow: '[', green: ']', cyan: '\\', white: '(', magenta: '@', gray: '^', blue: '~' };

const named = {
  ArrowLeft: 'left',
  ArrowRight: 'right',
  ArrowUp: 'up',
  ArrowDown: 'down',
  Home: 'home',
  End: 'end',
  PageUp: 'page_up',
  PageDown: 'page_down',
  Escape: 'escape',
  Enter: 'enter',
  Backspace: 'backspace',
};

/** letters of the colors with ctrl, and ctrl+s to save */
const ctrlLetters = 'rygwtvbs';

/**
 * The editor's key for a key event, as [key, ctrl], or null for keys that
 * are not the editor's. Alt with a color's letter does what ctrl does, as
 * browsers keep ctrl+w and ctrl+t for themselves.
 */
function keyOf(e) {
  if (e.isComposing || e.metaKey) return null;
  if (e.key in named) return e.ctrlKey || e.altKey ? null : [named[e.key], false];
  const letter = /^Key([A-Z])$/.exec(e.code)?.[1].toLowerCase();
  if (e.altKey && !e.ctrlKey) return letter && ctrlLetters.includes(letter) ? [letter, true] : null;
  if (e.ctrlKey) return letter && ctrlLetters.includes(letter) ? [letter, true] : null;
  return e.key.length === 1 ? [e.key, false] : null;
}

function token(t, i, view, previous) {
  const typing = view.mode === 'insert' && i === view.cursor;
  const here = i === view.cursor;
  if (t.color === 'blue' && !state.showFormat && !here) return null;
  const mark = state.showMarks && (t.color !== previous || t.color === 'red' || t.color === 'magenta') ? marks[t.color] : null;
  return m('span.cf', {
    key: i,
    class: [`cf-${t.color}`, here ? (typing ? 'typing' : 'cursor') : ''].join(' '),
    'data-i': i,
  }, mark ? m('span.mark', mark) : null, t.text, t.value !== null ? m('span.cf-green.value', ` ${t.value}`) : null);
}

/** the block's words in lines, as colorForth shows a block */
function lines(view) {
  const rows = [];
  let previous = null;
  view.tokens.forEach((t, i) => {
    while (rows.length <= t.line) rows.push([]);
    rows[t.line].push(token(t, i, view, previous));
    previous = t.color;
  });
  if (rows.length === 0) rows.push([]);
  return rows.map((row, n) => m('.cf-line', { key: n }, row.length > 0 ? row : m('span.cf-empty', ' ')));
}

const Block = {
  view() {
    const view = state.editor;
    const focus = (dom) => dom.closest('.cf-block').querySelector('input').focus({ preventScroll: true });
    return m('.cf-block', {
      class: [view.read_only ? 'read-only' : '', view.mode].join(' '),
      onclick: (e) => {
        const word = e.target.closest('.cf');
        if (word) editorMoveTo(Number(word.dataset.i));
        else e.redraw = false;
        focus(e.target);
      },
    }, [
      m('input.keys[autocomplete=off][autocapitalize=off][spellcheck=false]', {
        'aria-label': `Block ${view.block}, ${view.mode === 'insert' ? 'typing' : 'moving'}`,
        oncreate: (vnode) => vnode.dom.focus({ preventScroll: true }),
        onkeydown: (e) => {
          const key = keyOf(e);
          if (!key) {
            e.redraw = false;
            return;
          }
          e.preventDefault();
          editorKey(key[0], key[1]);
        },
        // what came without a key the editor knows, such as from an
        // on-screen keyboard
        oninput: (e) => {
          for (const c of e.target.value) editorKey(c, false);
          e.target.value = '';
        },
      }),
      lines(view),
    ]);
  },
};

function blocksList() {
  const query = state.blockQuery.trim().toLowerCase();
  const shown = state.blocks.filter((b) => !query || b.text.toLowerCase().includes(query) || String(b.block) === query);
  return m('section.panel.block-index', { 'aria-label': 'Blocks' }, [
    m('header.panel-head', m('h2', 'Blocks')),
    m('.panel-body', [
      m('input[type=search][placeholder=Search]', {
        value: state.blockQuery,
        'aria-label': 'Search the blocks',
        oninput: (e) => (state.blockQuery = e.target.value),
      }),
      m('ol.block-list', shown.map((b) => m('li', { key: b.block }, m('button', {
        class: [b.block === state.editor.block ? 'current' : '', b.empty || b.read_only ? 'muted' : ''].join(' '),
        'aria-current': b.block === state.editor.block ? 'true' : undefined,
        onclick: () => {
          editorGoTo(b.block);
          // on a narrow screen, back to the block
          state.editorTab = 'editing';
        },
      }, [
        m('span.number', b.block),
        m('span.first-line', b.read_only ? 'not source' : b.empty ? 'empty' : b.text.split('\n')[0]),
      ])))),
      shown.length === 0 ? m('p.muted', 'No block has that') : null,
    ]),
  ]);
}

function colorBar() {
  const view = state.editor;
  const set = (c) => editorKey(c.ctrl, true);
  return m('footer.color-bar', [
    m('.colors', { role: 'toolbar', 'aria-label': 'Colors' }, colors.map((c) => m('button.swatch', {
      class: `cf-${c.color}`,
      title: `${c.color}: ${c.does} (shift+${c.shift}, or ctrl or alt+${c.ctrl})`,
      disabled: view.read_only,
      onclick: () => set(c),
    }, c.color))),
    m('span.mode', { class: view.mode }, view.mode === 'insert' ? 'typing' : 'moving'),
    m('span.muted', `${view.cells}/255 cells`),
    view.prefix !== null ? m('span.prefix', view.prefix) : null,
    m('span.hints.muted', view.mode === 'insert'
      ? 'space: next word · enter: new line · esc: done'
      : 'i a o: type · x y p: cut copy put · u U: undo redo · [ ]: blocks · L: compile · ctrl+s: save'),
  ]);
}

export const EditorView = {
  view() {
    const view = state.editor;
    const file = state.editorFile;
    return m('main.editor-view', { class: `tab-${state.editorTab}` }, [
      blocksList(),
      m('section.panel.editing', { 'aria-label': 'Editor' }, [
        m('header.panel-head', [
          m('h2', `Block ${view.block}`),
          m('span.muted.file', file ? `${file.name}${view.unsaved ? ' (not saved)' : ''}` : 'a new file'),
          view.read_only ? m('span.badge', 'not source') : null,
          m('.actions', [
            m('button.secondary.outline', { onclick: () => editorGoTo(view.block - 1), disabled: view.block === 0, title: 'The block before ([)' }, 'Before'),
            m('button.secondary.outline', { onclick: () => editorGoTo(view.block + 1), disabled: view.block + 1 >= view.capacity, title: 'The block after (])' }, 'After'),
            m('label.toggle', { title: 'Show blue words, which lay out the block (f)' }, [
              m('input[type=checkbox][role=switch]', { checked: state.showFormat, onchange: toggleFormat }), 'Blue',
            ]),
            m('label.toggle', { title: 'Mark where colors change, as gasim blocks does' }, [
              m('input[type=checkbox][role=switch]', { checked: state.showMarks, onchange: toggleMarks }), 'Marks',
            ]),
            m('button.secondary.outline', { onclick: newEditorFile, title: 'Start a new file of blocks' }, 'New'),
            m('button.secondary', { onclick: compileEditor, title: 'Compile the block and start the chip again with it (L)' }, 'Compile'),
            m('button', { onclick: saveEditor, title: 'Save the blocks (ctrl+s)' }, 'Save'),
          ]),
        ]),
        m('.panel-body', m(Block)),
        colorBar(),
      ]),
      m('nav.tabs', { role: 'tablist' }, ['editing', 'blocks', 'node'].map((tab) => m('button', {
        role: 'tab',
        class: state.editorTab === tab ? '' : 'secondary outline',
        'aria-selected': state.editorTab === tab ? 'true' : 'false',
        onclick: () => (state.editorTab = tab),
      }, { editing: 'Block', blocks: 'Blocks', node: 'Node' }[tab]))),
      m(NodePanel),
    ]);
  },
};
