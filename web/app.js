// The app: the chip's view, with the map, the node and the console, in
// regions whose borders can be dragged, or on a narrow screen, the map
// above tabs, with the border between them dragged.

import {
  state, start, toggleRun, stepNext, stepRound, stepNode, stepSlot, back, move, openFile, openExample, flushWorkspace, workspaceKept,
} from './state.js';
import { Toolbar, StatusBar, RomDialog, HelpDialog, dialogs, applyTheme } from './views/toolbar.js';
import { ChipMap } from './views/map.js';
import { NodePanel } from './views/node.js';
import { Dock, showDock, panels, unseen } from './views/dock.js';
import { EditorView } from './views/editor.js';
import { layout, saveLayout, gutter } from './layout.js';

const { m } = window;

/** the tabs below the map on a narrow screen: the node, or a dock's tab */
function tabs() {
  const tab = (name, dock, label) => {
    const selected = layout.tab === name && (dock === null || state.dock === dock);
    return m('button', {
      role: 'tab',
      'aria-selected': selected ? 'true' : 'false',
      onclick: () => {
        layout.tab = name;
        if (dock) showDock(dock);
        saveLayout();
      },
    }, label, dock ? unseen(dock) : null);
  };
  return m('nav.tabs', { role: 'tablist' }, [
    tab('node', null, 'Node'),
    Object.entries(panels).map(([dock, panel]) => tab('dock', dock, panel.label)),
  ]);
}

/** Shows a dock's tab, on a narrow screen too, and types into it. */
function typeInto(dock) {
  layout.tab = 'dock';
  showDock(dock);
  m.redraw.sync();
  document.getElementById(dock === 'forth' ? 'forth-input' : 'console-input')?.focus();
}

const ChipView = {
  view() {
    return m('main.chip-view', {
      class: `tab-${layout.tab}`,
      style: { '--node-width': `${layout.node}%`, '--dock-height': `${layout.dock}%`, '--stack-height': `${layout.stack}%` },
    }, [
      m(ChipMap),
      gutter('dock', false, 10, 70),
      m(Dock),
      gutter('node', true, 18, 50),
      gutter('stack', false, 20, 80),
      tabs(),
      m(NodePanel),
    ]);
  },
};

/** the page around a view: the toolbar, the status bar and the dialogs */
const Page = {
  view(vnode) {
    if (!state.chip) return m('p.loading', 'Loading gasim…');
    return [m(Toolbar), vnode.children, m(StatusBar), m(RomDialog), m(HelpDialog)];
  },
};

const routes = {
  '/chip': { render: () => m(Page, m(ChipView)) },
  '/editor': { render: () => m(Page, m(EditorView)) },
};

// ---------- keys and files ----------

/** whether a key is being typed into something, rather than for the app */
const typing = (e) => e.target.closest('input, textarea, select, [contenteditable]') !== null;

/** keys for the chip's view */
const keys = {
  ' ': toggleRun,
  s: stepNext,
  S: stepRound,
  n: stepNode,
  N: stepSlot,
  z: back,
  ArrowLeft: () => move(-1, 0),
  ArrowRight: () => move(1, 0),
  ArrowUp: () => move(0, 1),
  ArrowDown: () => move(0, -1),
  h: () => move(-1, 0),
  l: () => move(1, 0),
  k: () => move(0, 1),
  j: () => move(0, -1),
  f: () => typeInto('forth'),
  c: () => typeInto('console'),
  e: () => m.route.set('/editor'),
};

/** keys for any view */
const anywhere = {
  '?': () => (dialogs.open = 'help'),
  F1: () => (dialogs.open = 'help'),
  Escape: () => (dialogs.open = null),
};

document.addEventListener('keydown', (e) => {
  if (!state.chip || e.ctrlKey || e.metaKey || e.altKey) return;
  if (typing(e) && e.key !== 'Escape' && e.key !== 'F1') return;
  // keys act on the chip only where nothing else takes them
  if (e.target.closest('button, a, summary, [role=separator]') && (e.key === ' ' || e.key.startsWith('Arrow'))) return;
  if (dialogs.open && e.key !== 'Escape') return;
  const action = anywhere[e.key] ?? (m.route.get() === '/chip' ? keys[e.key] : undefined);
  if (!action) return;
  e.preventDefault();
  action();
  m.redraw();
});

document.addEventListener('dragover', (e) => {
  if (e.dataTransfer.types.includes('Files')) e.preventDefault();
});

document.addEventListener('drop', async (e) => {
  const file = e.dataTransfer.files[0];
  if (!file || !state.chip) return;
  e.preventDefault();
  // a handle to save to, where the browser gives one, asked for before the
  // event ends
  const handle = e.dataTransfer.items[0]?.getAsFileSystemHandle?.();
  const h = await handle?.catch(() => null);
  await openFile(file, h?.kind === 'file' ? h : null);
  m.redraw();
});

// a warning before leaving with blocks not saved, unless the browser keeps
// them for the next visit
window.addEventListener('beforeunload', (e) => {
  flushWorkspace();
  if (state.editor?.unsaved && !workspaceKept()) e.preventDefault();
});

window.addEventListener('pagehide', flushWorkspace);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') flushWorkspace();
});

applyTheme();
m.route.prefix = '#';
m.route(document.getElementById('app'), '/chip', routes);
start().then(async () => {
  // A link with ?example=hello.ga opens that example. It also opens
  // versions that the menu hides.
  const example = new URLSearchParams(location.search).get('example');
  if (example && /^[\w.-]+\.(ga|af|cf)$/.test(example)) await openExample(example);
  m.redraw();
}, (error) => {
  document.getElementById('app').textContent = `gasim could not start: ${error.message}`;
});
