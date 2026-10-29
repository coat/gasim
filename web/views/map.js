// The chip's nodes in a grid, north at the top, each colored by what it is
// doing, with the edges it moved words through in its last step lit.

import { state, select, nodeNumber } from '../state.js';

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

function tile(i) {
  const { columns, console_node: consoleNode, console_port: consolePort, breakpoints } = state.chip;
  const x = i % columns;
  const y = Math.floor(i / columns);
  const number = nodeNumber(i);
  const status = state.statuses[i];
  const moved = state.transfers[i];
  const edges = [];
  directions.forEach((direction, d) => {
    if (moved & (0x11 << d)) edges.push(m(`span.edge.${side(direction, x, y)}`));
  });
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
    m('span.number', label),
    number === consoleNode ? m(`span.edge.console.${side(consolePort, x, y)}`, { title: `The console, on the ${consolePort} port` }) : null,
    edges,
  );
}

export const ChipMap = {
  view() {
    const { rows, columns } = state.chip;
    const tiles = [];
    for (let y = rows - 1; y >= 0; y--) for (let x = 0; x < columns; x++) tiles.push(tile(y * columns + x));
    return m('section.panel.map', { 'aria-label': 'Chip' }, [
      m('header.panel-head', [
        m('h2', 'Chip'),
        m('ul.legend', { 'aria-label': 'Legend' }, [
          m('li.running', 'running'),
          m('li.reading', 'reading'),
          m('li.writing', 'writing'),
          m('li.code', 'waiting for code'),
        ]),
      ]),
      m('.panel-body', m('.tiles', { style: { '--columns': columns, '--rows': rows } }, tiles)),
    ]);
  },
};
