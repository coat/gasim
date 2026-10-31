// The chip's nodes in a grid, north at the top, each colored by what it is
// doing: as numbers, with the edges it moved words through in its last step
// lit, or with room, as the TUI's and the GUI's do, as tiles of their
// registers, with arrows between them showing which way words go.

import { state, select, nodeNumber, showRegisters } from '../state.js';

const { m } = window;

const directions = ['right', 'down', 'left', 'up'];

/**
 * The side of a node's tile a port faces, as Chip names ports: on even
 * columns right faces east, on even rows down faces north, and odd ones
 * the reverse.
 */
function side(direction, x, y) {
  switch (direction) {
    case 'right': return x % 2 === 0 ? 'e' : 'w';
    case 'left': return x % 2 === 0 ? 'w' : 'e';
    case 'down': return y % 2 === 0 ? 'n' : 's';
    case 'up': return y % 2 === 0 ? 's' : 'n';
  }
}

const statusText = {
  running: 'running',
  code: 'waiting for code',
  reading: 'waiting to read',
  writing: 'waiting to write',
};

// ---------- the tiles' size ----------

/**
 * Tiles of registers, in characters and lines of the tiles' font, as the
 * GUI's: the least for every node to fit, the least to scroll through, and
 * the largest, with gaps between them for arrows
 */
const smallest = { width: 8, height: 2.5, gapX: 2, gapY: 1 };
const comfortable = { width: 11, height: 4, gapX: 2, gapY: 1 };
const largest = { width: 16, height: 6 };

/**
 * which tiles the map chooses: registers if every node fits in them,
 * otherwise numbers; numbers; or registers, scrolling if every node does
 * not fit
 */
export const modes = ['auto', 'numbers', 'registers'];

const modeTitles = {
  auto: 'Registers where every node fits, otherwise numbers',
  numbers: 'Numbers, filling the map',
  registers: 'Registers, scrolling where every node does not fit',
};

/**
 * Tiles of registers for a map `columns` characters wide and `lines` high:
 * as large as fit with every node in view, up to the largest, and with too
 * little room, for registers, comfortable ones to scroll through. Null for
 * numbers.
 */
export function fit(mode, columns, lines, chip) {
  const perColumn = columns / chip.columns;
  const perRow = lines / chip.rows;
  const least = mode === 'registers' ? comfortable : smallest;
  if (mode !== 'numbers' && perColumn >= least.width + smallest.gapX && perRow >= least.height + smallest.gapY) {
    return {
      width: Math.min(Math.floor(perColumn - smallest.gapX), largest.width),
      height: Math.min(Math.floor(perRow - smallest.gapY), largest.height),
      gapX: smallest.gapX,
      gapY: smallest.gapY,
    };
  }
  return mode === 'registers' ? comfortable : null;
}

/** the mode chosen, kept for next time, where storage allows */
function chosenMode() {
  try {
    const mode = localStorage.getItem('tiles');
    return modes.includes(mode) ? mode : 'auto';
  } catch {
    return 'auto';
  }
}

let mode = chosenMode();

function choose(next) {
  mode = next;
  try {
    localStorage.setItem('tiles', next);
  } catch {
    // the mode lasts for this visit only
  }
}

// ---------- the tiles ----------

/** a triangle pointing north, east, south or west, as 'n', 'e', 's' or 'w' */
const arrow = (selector, way, attrs) => m(`span.${selector}.${way}`, attrs);

const cardinal = (name) => name[0];

const word = (value) => value.toString(16);

function registers(i) {
  const t = state.tiles[i];
  const items = [['P', word(t.p)], ['s', t.slot], ['T', word(t.t)], ['S', word(t.s)], ['A', word(t.a)], ['B', word(t.b)], ['io', word(t.io)]];
  return [
    m('span.head', [
      m('span.number', String(nodeNumber(i)).padStart(3, '0')),
      m('span.faint', t.doing),
      // the ports it waits on, as arrows, or the I/O register
      t.waiting_on ? m('span.faint', t.waiting_on) : m('span.faint', t.ports.map((p) => arrow('arrow', cardinal(p)))),
    ]),
    m('span.regs', items.map(([name, value]) => m('span', [m('span.faint', name), value]))),
  ];
}

/** what the ports to the east and north are doing, in the gaps there */
function flows(i) {
  const { east, north } = state.tiles[i];
  return [
    east ? arrow('flow.across', east.outward ? 'e' : 'w', { class: east.kind }) : null,
    north ? arrow('flow.upward', north.outward ? 'n' : 's', { class: north.kind }) : null,
  ];
}

function tile(i, large) {
  const { columns, console_node: consoleNode, console_port: consolePort, breakpoints } = state.chip;
  const x = i % columns;
  const y = Math.floor(i / columns);
  const number = nodeNumber(i);
  const status = state.statuses[i];
  const moved = state.transfers[i];
  const edges = [];
  // small tiles light the edges words went through; large ones have arrows
  if (!large) {
    directions.forEach((direction, d) => {
      if (moved & (0x11 << d)) edges.push(m(`span.edge.${side(direction, x, y)}`));
    });
  }
  const label = String(number).padStart(3, '0');
  return m(
    'button.tile',
    {
      key: i,
      class: [
        status,
        i === state.selected ? 'selected' : '',
        breakpoints.some((b) => b.node === number) ? 'has-breakpoint' : '',
      ].join(' '),
      'aria-pressed': i === state.selected ? 'true' : 'false',
      'aria-label': `Node ${label}, ${statusText[status]}${number === consoleNode ? ', console' : ''}`,
      title: `${label}: ${statusText[status]}`,
      onclick: () => select(i),
    },
    large ? registers(i) : m('span.number', label),
    number === consoleNode ? m(`span.edge.console.${side(consolePort, x, y)}`, { title: `The console, on the ${consolePort} port` }) : null,
    edges,
    large ? flows(i) : null,
  );
}

/**
 * Sizes the tiles for the map's room, in the tiles' font, reading the
 * nodes' registers while they show.
 */
function measure(vnode) {
  const body = vnode.dom.querySelector('.panel-body');
  const probe = body.querySelector('.measure').getBoundingClientRect();
  const char = probe.width / 10;
  const line = probe.height;
  const style = getComputedStyle(body);
  const width = body.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
  const height = body.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
  const t = fit(mode, width / char, height / line, state.chip);
  const size = t && { ...t, char, line };
  if (JSON.stringify(size) === JSON.stringify(vnode.state.size)) return;
  vnode.state.size = size;
  showRegisters(size !== null);
  m.redraw();
}

/** the tiles' size, and the gaps', for CSS, in pixels */
function sizes({ width, height, gapX, gapY, char, line }) {
  return {
    '--char': `${char}px`,
    '--line': `${line}px`,
    '--tile-w': `${width * char}px`,
    '--tile-h': `${height * line}px`,
    '--gap-x': `${gapX * char}px`,
    '--gap-y': `${gapY * line}px`,
    // the lines of registers under the first, from a quarter line down
    '--register-lines': Math.floor(height - 0.25) - 1,
  };
}

export const ChipMap = {
  oncreate(vnode) {
    vnode.state.observer = new ResizeObserver(() => measure(vnode));
    vnode.state.observer.observe(vnode.dom.querySelector('.panel-body'));
  },
  onremove(vnode) {
    vnode.state.observer.disconnect();
    showRegisters(false);
  },
  view(vnode) {
    const { rows, columns } = state.chip;
    const size = vnode.state.size;
    // until the registers are read, after the tiles are measured
    const large = size != null && state.tiles !== null;
    const tiles = [];
    for (let y = rows - 1; y >= 0; y--) for (let x = 0; x < columns; x++) tiles.push(tile(y * columns + x, large));
    return m('section.panel.map', { 'aria-label': 'Chip', class: large ? 'large' : '' }, [
      m('header.panel-head', [
        m('h2', 'Chip'),
        m('.modes[role=group]', { 'aria-label': 'Tiles' }, modes.map((name) => m('button.small', {
          class: name === mode ? '' : 'secondary outline',
          'aria-pressed': name === mode ? 'true' : 'false',
          title: modeTitles[name],
          onclick: () => {
            choose(name);
            measure(vnode);
          },
        }, name))),
        m('ul.legend', { 'aria-label': 'Legend' }, [
          m('li.running', 'running'),
          m('li.reading', 'reading'),
          m('li.writing', 'writing'),
          m('li.code', 'waiting for code'),
          m('li.moved', 'moved'),
        ]),
      ]),
      m('.panel-body', [
        m('span.measure[aria-hidden=true]', '0000000000'),
        m('.tiles', { class: large ? 'large' : '', style: { '--columns': columns, '--rows': rows, ...(large ? sizes(size) : {}) } }, tiles),
      ]),
    ]);
  },
};
