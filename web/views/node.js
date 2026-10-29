// The selected node: what it is doing, its registers and stacks, and its
// RAM and ROM disassembled, with a gutter to set breakpoints in.

import { state, toggleBreakpoint } from '../state.js';

const { m } = window;

export const hex = (value, digits) => value.toString(16).padStart(digits, '0');
const word = (value) => hex(value, 5);

function doing(node) {
  switch (node.status) {
    case 'running': return 'Running';
    case 'code': return `Waiting for code from ${node.waiting_on}`;
    case 'reading': return `Waiting to read ${node.waiting_on}`;
    case 'writing': return `Waiting to write ${node.waiting_on}`;
  }
}

const field = (name, value, title, wide = false) => [m('dt', { title, class: wide ? 'wide' : '' }, name), m('dd', { class: wide ? 'wide' : '' }, value)];

function registers(node) {
  return m('dl.registers', [
    field('P', hex(node.p, 3), 'Program counter'),
    field('slot', node.slot, 'The slot of I being executed'),
    field('carry', node.carry, node.extended ? 'Extended arithmetic is on' : 'Carry, for extended arithmetic'),
    field('A', word(node.a)),
    field('B', hex(node.b, 3)),
    field('io', word(node.io), 'The I/O register'),
    field('time', `${node.time.toFixed(1)} ns`, 'Time spent executing'),
    field('I', node.i === null ? `next word from ${node.fetch_from}` : m('span', m('code', word(node.i)), ' ', node.i_code), 'The instruction word', true),
  ]);
}

function stack(name, values, named) {
  return m('.stack', [
    m('h3', name),
    m('ol', values.map((v, k) => m('li', { class: k < named.length ? 'named' : 'below' }, k < named.length ? m('span.reg', named[k]) : null, m('code', word(v))))),
  ]);
}

function memory(node) {
  const rows = [];
  node.memory.forEach((line, k) => {
    if (k === 0 || k === 64) rows.push(m('tr.heading', { key: `h${k}` }, m('th[colspan=4]', k === 0 ? 'RAM' : 'ROM')));
    // RAM and ROM repeat at x040 and x0c0
    const here = node.here !== null && (node.here & 0x1bf) === line.address;
    rows.push(
      m('tr', { key: line.address, class: [here ? 'here' : '', line.value === 0 ? 'zero' : ''].join(' ') }, [
        m(
          'td.gutter',
          m('button.breakpoint', {
            class: line.breakpoint ? 'set' : '',
            'aria-pressed': line.breakpoint ? 'true' : 'false',
            'aria-label': `${line.breakpoint ? 'Remove' : 'Set'} a breakpoint at ${hex(line.address, 3)}`,
            onclick: () => toggleBreakpoint(line.address),
          }),
        ),
        m('td.address', hex(line.address, 3)),
        m('td.value', word(line.value)),
        m('td.code', { class: line.literal ? 'literal' : '' }, line.code),
      ]),
    );
  });
  return m('table.memory', m('tbody', rows));
}

export const NodePanel = {
  onupdate(vnode) {
    // keep the word being run in view when it moves, unless running, and
    // start a node newly selected at its word, or at the top
    const { here, number } = state.node;
    const selected = number !== vnode.state.number;
    if ((state.running && !selected) || (here === vnode.state.here && !selected)) return;
    vnode.state.here = here;
    vnode.state.number = number;
    const listing = vnode.dom.querySelector('.listing');
    const row = listing.querySelector('tr.here');
    if (!row) {
      if (selected) listing.scrollTop = 0;
      return;
    }
    const top = row.offsetTop;
    const bottom = top + row.offsetHeight;
    if (selected || top < listing.scrollTop || bottom > listing.scrollTop + listing.clientHeight) {
      listing.scrollTop = top - listing.clientHeight / 3;
    }
  },
  view() {
    const node = state.node;
    return m('section.panel.node', { 'aria-label': 'Node' }, [
      m('header.panel-head', [m('h2', `Node ${String(node.number).padStart(3, '0')}`), m('span.doing', { class: node.status }, doing(node))]),
      m('.panel-body.node-body', [
        registers(node),
        m('.stacks', [stack('Data stack', node.data_stack, ['T', 'S']), stack('Return stack', node.return_stack, ['R'])]),
        m('.listing', { tabindex: 0, 'aria-label': 'RAM and ROM' }, memory(node)),
      ]),
    ]);
  },
};
