// The panels under the map: the arrayForth 3 prompt, and the console.

import { state, nodeNumber, interpret, completions, sendInput, endInput } from '../state.js';

const { m } = window;

const pad = (n) => String(n).padStart(3, '0');

/** an error's name as words, such as `undefined label` for UndefinedLabel */
const words = (name) => name.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase();

/**
 * Hooks that keep a scrolled element at its end as it grows, unless it was
 * scrolled back, which the element itself remembers.
 */
const follow = {
  oncreate: (vnode) => (vnode.dom.scrollTop = vnode.dom.scrollHeight),
  onupdate(vnode) {
    if (vnode.dom.atEnd !== false) vnode.dom.scrollTop = vnode.dom.scrollHeight;
  },
  onscroll(e) {
    const el = e.target;
    el.atEnd = el.scrollTop + el.clientHeight >= el.scrollHeight - 4;
    e.redraw = false;
  },
};

// ---------- the prompt ----------

function entry({ target, line, answer }, recall) {
  return m('li.entry', [
    m('button.line', { title: 'Type this line again', onclick: () => recall(line) }, [m('span.target', `${pad(target)}>`), ' ', line]),
    answer.output ? m('pre.printed', answer.output) : null,
    answer.ok
      ? m('.answer', [
        m('span.ok', 'ok'),
        answer.stack.length > 0
          ? m('ol.stack-row', { 'aria-label': 'Stack, the top last' }, answer.stack.map((v) => m('li', { title: `x${(v & 0x3ffff).toString(16)}` }, v)))
          : null,
      ])
      : m('.answer.error', { role: 'alert' }, [words(answer.error), answer.token ? [' at ', m('code', answer.token)] : null]),
  ]);
}

const Forth = {
  oninit(vnode) {
    vnode.state.text = '';
    /** how far back in the history the line typed is, 0 for a new one */
    vnode.state.back = 0;
    vnode.state.choices = null;
  },
  view(vnode) {
    const s = vnode.state;
    const recall = (line) => {
      s.text = line;
      s.choices = null;
      vnode.dom.querySelector('input').focus();
    };
    const fromHistory = (back) => {
      s.back = back;
      s.text = back === 0 ? '' : state.history[state.history.length - back];
    };
    const choose = (start, word) => {
      s.text = s.text.slice(0, start) + word + ' ';
      s.choices = null;
      vnode.dom.querySelector('input').focus();
    };
    const complete = () => {
      const { start, partial, words: found } = completions(s.text);
      if (found.length === 0) {
        s.choices = { start, words: [], none: partial !== '' };
        return;
      }
      if (found.length === 1) return choose(start, found[0]);
      // as much as they all share
      let common = found[0];
      for (const word of found) while (!word.startsWith(common)) common = common.slice(0, -1);
      if (common.length > partial.length) s.text = s.text.slice(0, start) + common;
      s.choices = { start, words: found };
    };
    return m('.forth', [
      m('ol.entries', {
        oncreate: follow.oncreate,
        onupdate: follow.onupdate,
        onscroll: follow.onscroll,
        'aria-live': 'polite',
      }, state.entries.length === 0
        ? m('li.muted.hint', 'Type arrayForth 3 below. The selected node is the target of words such as UPD, R@ and CALL.')
        : state.entries.map((e) => entry(e, recall))),
      s.choices
        ? m('.choices', { role: 'listbox', 'aria-label': 'Words' }, s.choices.none
          ? m('span.muted', 'No word starts with that')
          : s.choices.words.map((word) => m('button.secondary.outline', { role: 'option', onclick: () => choose(s.choices.start, word) }, word)))
        : null,
      m('form.prompt', {
        onsubmit: (e) => {
          e.preventDefault();
          interpret(s.text);
          s.text = '';
          s.back = 0;
          s.choices = null;
        },
      }, [
        m('label.target', { for: 'forth-input' }, `${pad(nodeNumber(state.selected))}>`),
        m('input#forth-input[autocomplete=off][autocapitalize=off][spellcheck=false]', {
          value: s.text,
          'aria-label': 'arrayForth 3',
          oninput: (e) => {
            s.text = e.target.value;
            s.choices = null;
          },
          onkeydown: (e) => {
            if (e.key === 'Tab' && !e.shiftKey) {
              e.preventDefault();
              complete();
            } else if (e.key === 'ArrowUp' && s.back < state.history.length) {
              e.preventDefault();
              fromHistory(s.back + 1);
            } else if (e.key === 'ArrowDown' && s.back > 0) {
              e.preventDefault();
              fromHistory(s.back - 1);
            } else if (e.key === 'Escape') {
              if (s.choices) s.choices = null;
              else e.target.blur();
            } else e.redraw = false;
          },
        }),
        m('button.secondary.outline[type=button]', { onclick: complete, title: 'Complete the word (Tab)' }, 'Complete'),
        m('button[type=submit]', 'Enter'),
      ]),
    ]);
  },
};

// ---------- the console ----------

const Console = {
  oninit(vnode) {
    vnode.state.text = '';
    vnode.state.raw = false;
  },
  view(vnode) {
    const s = vnode.state;
    return m('.console', [
      m('pre.output', {
        tabindex: 0,
        'aria-live': 'polite',
        'aria-label': 'Console output',
        oncreate: follow.oncreate,
        onupdate: follow.onupdate,
        onscroll: follow.onscroll,
      }, state.console || m('span.muted', 'Nothing yet')),
      m('form.prompt', {
        onsubmit: (e) => {
          e.preventDefault();
          if (s.raw) return;
          sendInput(`${s.text}\n`);
          s.text = '';
        },
      }, [
        m('input#console-input[autocomplete=off][autocapitalize=off][spellcheck=false]', {
          value: s.raw ? '' : s.text,
          disabled: state.inputEnded,
          placeholder: state.inputEnded ? 'The input has ended' : s.raw ? 'Keys go to the node as they are typed' : 'A line of input',
          'aria-label': 'Console input',
          oninput: (e) => {
            if (s.raw) {
              // what the keys did not send, such as text from an input method
              sendInput(e.target.value);
              e.target.value = '';
            } else s.text = e.target.value;
          },
          onkeydown: (e) => {
            if (e.key === 'Escape') {
              e.target.blur();
            } else if (s.raw && e.key === 'Enter') {
              e.preventDefault();
              sendInput('\n');
            } else if (s.raw && e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
              e.preventDefault();
              sendInput(e.key);
            } else e.redraw = false;
          },
        }),
        m('label.raw', { title: 'Send each key as it is typed, rather than a line at a time' }, [
          m('input[type=checkbox][role=switch]', { checked: s.raw, onchange: (e) => {
            s.raw = e.target.checked;
          } }),
          'Keys',
        ]),
        m('button[type=submit]', { disabled: s.raw || state.inputEnded }, 'Send'),
        m('button.secondary.outline[type=button]', {
          onclick: endInput,
          disabled: state.inputEnded,
          title: 'End the input, as ctrl+d does in a terminal',
        }, 'End input'),
      ]),
    ]);
  },
};

// ---------- the dock ----------

export function showDock(tab) {
  state.dock = tab;
  if (tab === 'console') state.unseenOutput = false;
}

export const Dock = {
  view() {
    const { console_node: node, console_port: port } = state.chip;
    const tab = (name, label, extra) => m('button', {
      role: 'tab',
      class: state.dock === name ? '' : 'secondary outline',
      'aria-selected': state.dock === name ? 'true' : 'false',
      onclick: () => showDock(name),
    }, label, extra);
    return m('section.panel.dock', { 'aria-label': state.dock === 'forth' ? 'Forth' : 'Console' }, [
      m('header.panel-head', [
        m('nav.dock-tabs', { role: 'tablist' }, [
          tab('forth', 'Forth'),
          tab('console', 'Console', state.unseenOutput ? m('span.unseen', { 'aria-label': ', new output' }) : null),
        ]),
        state.dock === 'console'
          ? [
            m('span.muted', `node ${pad(node)}, ${port} port`),
            m('button.secondary.outline.small', { onclick: () => (state.console = ''), disabled: state.console === '' }, 'Clear'),
          ]
          : m('button.secondary.outline.small', { onclick: () => (state.entries = []), disabled: state.entries.length === 0 }, 'Clear'),
      ]),
      m('.panel-body.dock-body', state.dock === 'forth' ? m(Forth) : m(Console)),
    ]);
  },
};
