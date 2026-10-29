// The dock's panels for debugging: the trace, the breakpoints and watches,
// and the history of steps and runs to go back to.

import {
  state, nodeNumber, nodeIndex, select, toggleBreakpoint, toggleWatch, clearBreakpoints, toggleTracing, clearTrace,
  traceShown, saveTrace, backTo,
} from '../state.js';
import { hex } from './node.js';
import { follow } from './follow.js';

const { m } = window;

const pad = (n) => String(n).padStart(3, '0');

// ---------- the trace ----------

export const traceHead = () => [
  m('label.toggle', { title: 'Write a line for each step that runs code, as --trace does. Running is slower.' }, [
    m('input[type=checkbox][role=switch]', { checked: state.trace.on, onchange: toggleTracing }), 'Tracing',
  ]),
  m('label.toggle', { title: 'Show only the lines of the selected node' }, [
    m('input[type=checkbox][role=switch]', { checked: state.trace.onlySelected, onchange: () => (state.trace.onlySelected = !state.trace.onlySelected) }),
    `Only ${pad(nodeNumber(state.selected))}`,
  ]),
  m('button.secondary.outline.small', { onclick: saveTrace, disabled: state.trace.lines.length === 0, title: 'Save the lines shown as trace.txt' }, 'Save'),
  m('button.secondary.outline.small', { onclick: clearTrace, disabled: state.trace.lines.length === 0 }, 'Clear'),
];

export const Trace = {
  view() {
    const lines = traceShown();
    if (lines.length === 0) {
      return m('.trace', m('p.muted.hint', state.trace.on
        ? state.trace.onlySelected && state.trace.lines.length > 0 ? 'The selected node has run no code since the trace began.' : 'Step or run the chip, and each step that runs code is written here.'
        : 'Turn tracing on to see each step that runs code: the node, the address, the word and its instructions, and T, S and R after it.'));
    }
    return m('.trace', [
      state.trace.dropped ? m('p.muted.note', `Only the last ${lines.length.toLocaleString()} lines are kept.`) : null,
      m('pre.output', { tabindex: 0, 'aria-label': 'Trace', ...follow }, lines.join('\n')),
    ]);
  },
};

// ---------- breakpoints and watches ----------

export const breakpointsHead = () => {
  const { breakpoints, watches } = state.chip;
  return m('button.secondary.outline.small', { onclick: clearBreakpoints, disabled: breakpoints.length + watches.length === 0 }, 'Remove all');
};

const ports = ['right', 'down', 'left', 'up'];

/** a row for a breakpoint or a watch, to show its node or remove it */
function row(key, label, node, remove) {
  return m('li', { key }, [
    m('button.link', { onclick: () => select(nodeIndex(node)), title: `Select node ${pad(node)}` }, label),
    m('button.secondary.outline.small', { onclick: remove, 'aria-label': `Remove ${label}` }, 'Remove'),
  ]);
}

const WatchForm = {
  oninit(vnode) {
    /** the node typed, or null for the selected node */
    vnode.state.node = null;
    vnode.state.port = 'right';
    vnode.state.write = false;
  },
  view(vnode) {
    const s = vnode.state;
    const typed = s.node ?? pad(nodeNumber(state.selected));
    return m('form.watch-form', {
      onsubmit: (e) => {
        e.preventDefault();
        const number = /^\d+$/.test(typed.trim()) ? Number(typed) : NaN;
        const i = Number.isInteger(number) ? nodeIndex(number) : null;
        if (i === null) {
          state.message = `There is no node ${typed}`;
          return;
        }
        s.node = null;
        if (state.chip.watches.some((w) => w.node === number && w.port === s.port && w.write === s.write)) {
          state.message = 'That is watched already';
          return;
        }
        toggleWatch(i, s.port, s.write);
      },
    }, [
      m('label', { for: 'watch-node' }, 'Watch node'),
      m('input#watch-node[inputmode=numeric][autocomplete=off]', { value: typed, oninput: (e) => (s.node = e.target.value) }),
      m('select', { 'aria-label': 'Reads or writes', value: s.write ? 'write' : 'read', onchange: (e) => (s.write = e.target.value === 'write') }, [
        m('option[value=read]', 'reading'),
        m('option[value=write]', 'writing'),
      ]),
      m('select', { 'aria-label': 'Port', value: s.port, onchange: (e) => (s.port = e.target.value) }, ports.map((p) => m('option', { value: p }, p))),
      m('button.secondary[type=submit]', 'Watch'),
    ]);
  },
};

export const Breakpoints = {
  view() {
    const { breakpoints, watches } = state.chip;
    return m('.breakpoints', [
      m('h3', 'Breakpoints'),
      breakpoints.length === 0
        ? m('p.muted', 'Set one in the gutter beside a node\'s RAM and ROM. Running stops as the node reaches it.')
        : m('ul.stops', breakpoints.map((b) => row(`b${b.node}-${b.address}`, `node ${pad(b.node)} at ${hex(b.address, 3)}`, b.node,
          () => toggleBreakpoint(b.address, nodeIndex(b.node))))),
      m('h3', 'Watches'),
      watches.length === 0
        ? m('p.muted', 'Running stops as a node watched reads or writes a word through the port.')
        : m('ul.stops', watches.map((w) => row(`w${w.node}-${w.port}-${w.write}`, `node ${pad(w.node)} ${w.write ? 'writing' : 'reading'} ${w.port}`, w.node,
          () => toggleWatch(nodeIndex(w.node), w.port, w.write)))),
      m(WatchForm),
    ]);
  },
};

// ---------- the history ----------

const causes = {
  step: 'a step',
  round: 'a round of steps',
  node: 'a step of one node',
  run: 'a run',
  line: 'a line at the prompt',
  reset: 'starting again',
  compile: 'compiling a block',
};

export const History = {
  view() {
    const moments = state.moments;
    return m('.history', [
      m('p.muted.note', moments.length === 0
        ? 'Each step and run is kept here, up to 64, to go back to.'
        : 'Going back forgets what came after.'),
      m('ol.moments', [
        m('li.now', { key: 'now' }, [m('span', 'Now'), m('span.steps', `${state.chip.steps.toLocaleString()} steps`)]),
        ...moments.map((moment, n) => ({ moment, n })).reverse().map(({ moment, n }) => m('li', { key: `${n}-${moment.steps}` }, [
          m('span', `Before ${causes[moment.cause]}`),
          m('span.steps', `${moment.steps.toLocaleString()} steps`),
          m('button.secondary.outline.small', { onclick: () => backTo(n), disabled: state.running }, 'Go back'),
        ])),
      ]),
    ]);
  },
};
