// The panels under the map. For now only the console's output; the forth
// prompt, console input and the trace come next (docs/WEB.md, phase 3).

import { state } from '../state.js';

const { m } = window;

export const Dock = {
  onupdate(vnode) {
    // follow the output, unless scrolled back
    const body = vnode.dom.querySelector('.output');
    if (vnode.state.atEnd !== false) body.scrollTop = body.scrollHeight;
  },
  view(vnode) {
    const { console_node: node, console_port: port } = state.chip;
    return m('section.panel.dock', { 'aria-label': 'Console' }, [
      m('header.panel-head', [
        m('h2', 'Console'),
        m('span.muted', `node ${String(node).padStart(3, '0')}, ${port} port`),
        m('button.secondary.outline.small', { onclick: () => (state.console = ''), disabled: state.console === '' }, 'Clear'),
      ]),
      m(
        'pre.output.panel-body',
        {
          tabindex: 0,
          'aria-live': 'polite',
          onscroll: (e) => {
            const el = e.target;
            vnode.state.atEnd = el.scrollTop + el.clientHeight >= el.scrollHeight - 4;
            e.redraw = false;
          },
        },
        state.console || m('span.muted', 'Nothing yet'),
      ),
    ]);
  },
};
