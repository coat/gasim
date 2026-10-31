// The app: the chip's view, with the map, the node and the console, in
// regions whose borders can be dragged, or on a narrow screen, the map
// above tabs, with the border between them dragged.

import {
  state, start, toggleRun, stepNext, stepRound, stepNode, back, move, openFile, openExample, examples, flushWorkspace, workspaceKept,
} from './state.js';
import { Toolbar, StatusBar, RomDialog, HelpDialog, dialogs, applyTheme } from './views/toolbar.js';
import { ChipMap } from './views/map.js';
import { NodePanel } from './views/node.js';
import { Dock, showDock, panels, unseen } from './views/dock.js';
import { EditorView } from './views/editor.js';

const { m } = window;

// ---------- layout ----------

/**
 * the sizes of the node column and the dock, and on a narrow screen, of
 * the tabs under the map, kept for next time
 */
const layout = loadLayout();

function loadLayout() {
  const defaults = { node: 26, dock: 30, stack: 50, tab: 'node' };
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

/** where a border's drag started: the pointer, and the size then */
let dragFrom = null;

/**
 * A border to drag, setting `layout[name]` as a percentage of the chip
 * view's width or height, measured from its right or bottom edge. It moves
 * as far as the pointer has from where the drag started, in the view's
 * content box, the percentages' box, so it stays under the pointer.
 */
function gutter(name, vertical, min, max) {
  const at = (e) => (vertical ? e.clientX : e.clientY);
  const drag = (e) => {
    const view = e.currentTarget.parentElement;
    const style = getComputedStyle(view);
    const size = vertical
      ? view.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)
      : view.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
    const percent = dragFrom.size + ((dragFrom.at - at(e)) / size) * 100;
    layout[name] = Math.round(Math.max(min, Math.min(max, percent)) * 10) / 10;
  };
  return m(`.gutter.${name}-gutter`, {
    role: 'separator',
    'aria-orientation': vertical ? 'vertical' : 'horizontal',
    'aria-valuenow': Math.round(layout[name]),
    'aria-valuemin': min,
    'aria-valuemax': max,
    tabindex: 0,
    onpointerdown: (e) => {
      e.currentTarget.setPointerCapture(e.pointerId);
      dragFrom = { at: at(e), size: layout[name] };
    },
    onpointermove: (e) => {
      if (dragFrom && e.currentTarget.hasPointerCapture(e.pointerId)) drag(e);
      else e.redraw = false;
    },
    onpointerup: () => {
      dragFrom = null;
      saveLayout();
    },
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
  // ?example=hello.ga opens an example, so a link can show one
  const example = new URLSearchParams(location.search).get('example');
  if (example && examples.some((e) => e.name === example)) await openExample(example);
  m.redraw();
}, (error) => {
  document.getElementById('app').textContent = `gasim could not start: ${error.message}`;
});
