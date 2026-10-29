// The app: the chip's view, with the map, the node and the console, in
// regions whose borders can be dragged, or as tabs on a narrow screen.

import { state, start, toggleRun, stepNext, stepRound, stepNode, back, move, openFile, openExample, examples } from './state.js';
import { Toolbar, StatusBar, RomDialog, HelpDialog, dialogs, applyTheme } from './views/toolbar.js';
import { ChipMap } from './views/map.js';
import { NodePanel } from './views/node.js';
import { Dock, showDock } from './views/dock.js';
import { EditorView } from './views/editor.js';

const { m } = window;

// ---------- layout ----------

/** the sizes of the node column and the dock, kept for next time */
const layout = loadLayout();

function loadLayout() {
  const defaults = { node: 26, dock: 30, tab: 'node' };
  try {
    return { ...defaults, ...JSON.parse(localStorage.getItem('layout') ?? '{}') };
  } catch {
    return defaults;
  }
}

function saveLayout() {
  try {
    localStorage.setItem('layout', JSON.stringify(layout));
  } catch {
    // the layout lasts for this visit only
  }
}

/**
 * A border to drag, setting `layout[name]` as a percentage of the chip
 * view's width or height, measured from its right or bottom edge.
 */
function gutter(name, vertical, min, max) {
  const drag = (e) => {
    const box = e.currentTarget.parentElement.getBoundingClientRect();
    const percent = vertical ? ((box.right - e.clientX) / box.width) * 100 : ((box.bottom - e.clientY) / box.height) * 100;
    layout[name] = Math.round(Math.max(min, Math.min(max, percent)));
  };
  return m(`.gutter.${vertical ? 'columns' : 'rows'}`, {
    role: 'separator',
    'aria-orientation': vertical ? 'vertical' : 'horizontal',
    'aria-valuenow': layout[name],
    'aria-valuemin': min,
    'aria-valuemax': max,
    tabindex: 0,
    onpointerdown: (e) => e.currentTarget.setPointerCapture(e.pointerId),
    onpointermove: (e) => {
      if (e.currentTarget.hasPointerCapture(e.pointerId)) drag(e);
      else e.redraw = false;
    },
    onpointerup: saveLayout,
    onkeydown: (e) => {
      const step = { ArrowLeft: 2, ArrowUp: 2, ArrowRight: -2, ArrowDown: -2 }[e.key];
      // Mithril prevents the default when a handler returns false, so this
      // one never does
      if (step === undefined) {
        e.redraw = false;
        return;
      }
      e.preventDefault();
      layout[name] = Math.max(min, Math.min(max, layout[name] + step));
      saveLayout();
    },
  });
}

/** the tabs below the map on a narrow screen: the node, or a dock's tab */
function tabs() {
  const tab = (name, dock, label) => {
    const selected = layout.tab === name && (dock === null || state.dock === dock);
    return m('button', {
      role: 'tab',
      class: selected ? '' : 'secondary outline',
      'aria-selected': selected ? 'true' : 'false',
      onclick: () => {
        layout.tab = name;
        if (dock) showDock(dock);
        saveLayout();
      },
    }, label, dock === 'console' && state.unseenOutput ? m('span.unseen', { 'aria-label': ', new output' }) : null);
  };
  return m('nav.tabs', { role: 'tablist' }, [tab('node', null, 'Node'), tab('dock', 'forth', 'Forth'), tab('dock', 'console', 'Console')]);
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
      style: { '--node-width': `${layout.node}%`, '--dock-height': `${layout.dock}%` },
    }, [
      m(ChipMap),
      gutter('dock', false, 10, 70),
      m(Dock),
      gutter('node', true, 18, 50),
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
  Escape: () => (dialogs.open = null),
};

document.addEventListener('keydown', (e) => {
  if (!state.chip || e.ctrlKey || e.metaKey || e.altKey) return;
  if (typing(e) && e.key !== 'Escape') return;
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
  await openFile(file);
  m.redraw();
});

// a warning before leaving with blocks not saved
window.addEventListener('beforeunload', (e) => {
  if (state.editor?.unsaved) e.preventDefault();
});

applyTheme();
m.route.prefix = '#';
m.route(document.getElementById('app'), '/chip', routes);
start().then(async () => {
  // ?example=hello.ga opens an example, so a link can show one
  const example = new URLSearchParams(location.search).get('example');
  if (example && examples.some((e) => e.name === example)) await openExample(example);
  m.redraw();
}, (error) => {
  document.getElementById('app').textContent = `gasim could not start: ${error.message}`;
});
