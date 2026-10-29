// The bar along the top: files, running and stepping, and the ROM; the
// status line along the bottom; and the dialogs they open.

import {
  state, examples, openFile, openExample, reload, hasBlocks, toggleRun, stepNext, stepRound, stepNode, back, reset,
  giveRom, forgetRom,
} from '../state.js';

const { m } = window;

/** which dialog is open: 'rom', 'help' or null */
export const dialogs = { open: null };

function fileInput(accept, onfile, label, attrs = {}) {
  return m('label.button', { role: 'button', ...attrs }, [
    label,
    m('input[type=file][hidden]', {
      accept,
      onchange: async (e) => {
        const file = e.target.files[0];
        e.target.value = '';
        if (file) {
          await onfile(file);
          m.redraw();
        }
      },
    }),
  ]);
}

function examplesMenu() {
  return m('details.dropdown.examples', [
    m('summary', { role: 'button', class: 'secondary outline' }, 'Examples'),
    m('ul', examples.map((example) => m('li', m('a[href=#]', {
      onclick: (e) => {
        e.preventDefault();
        e.target.closest('details').open = false;
        openExample(example.name);
      },
    }, [m('strong', example.name), m('small', example.about)])))),
  ]);
}

function blocksField() {
  const file = state.file;
  if (!file || !hasBlocks(file.kind)) return null;
  return m('form.blocks', {
    onsubmit: (e) => {
      e.preventDefault();
      const loads = new FormData(e.target).get('loads').split(/[\s,]+/).filter(Boolean).map(Number);
      if (loads.some((n) => !Number.isInteger(n) || n < 0)) {
        state.message = 'Blocks are numbers, such as 0 or 18 20';
        return;
      }
      file.loads = loads;
      reload();
    },
  }, [
    m('label', { for: 'loads' }, 'Blocks'),
    m('input#loads[name=loads][inputmode=numeric]', { value: file.loads.join(' '), title: 'The blocks to load, as --load loads them' }),
    m('button.secondary.outline[type=submit]', 'Load'),
  ]);
}

const tool = (label, onclick, attrs = {}) => m('button.tool', { onclick, ...attrs }, label);

export const Toolbar = {
  view() {
    const stopped = !state.running;
    return m('header.toolbar', [
      m('.group.files', [
        m('strong.brand', 'gasim'),
        fileInput('.ga,.af,.blk,.cf,.txt', openFile, 'Open…', { class: 'secondary' }),
        examplesMenu(),
        state.file ? m('span.file', { title: state.file.name }, state.file.name) : null,
        blocksField(),
      ]),
      m('.group.run', { role: 'toolbar', 'aria-label': 'Run and step' }, [
        tool(state.running ? 'Pause' : 'Run', toggleRun, { class: state.running ? 'secondary' : '', title: 'Run or pause (space)' }),
        tool('Step', stepNext, { disabled: !stopped, class: 'secondary outline', title: 'Step the next node to run (s)' }),
        tool('Round', stepRound, { disabled: !stopped, class: 'secondary outline', title: 'Step each node that can run once (shift+s)' }),
        tool('Node', stepNode, { disabled: !stopped, class: 'secondary outline', title: 'Step the selected node (n)' }),
        tool('Back', back, { disabled: !stopped || state.chip.history === 0, class: 'secondary outline', title: 'Go back before the last step or run (z)' }),
        tool('Reset', reset, { class: 'secondary outline', title: 'Start the chip again as it was loaded' }),
      ]),
      m('.group.info', [
        m('span.steps', { title: 'Steps taken by all the nodes' }, `${state.chip.steps.toLocaleString()} steps`),
        m('button.secondary.outline', { onclick: () => (dialogs.open = 'rom'), title: 'The ROM' }, state.rom ? 'ROM' : 'No ROM'),
        m('button.secondary.outline', { onclick: () => (dialogs.open = 'help'), title: 'Keys (?)', 'aria-label': 'Help' }, '?'),
        m(ThemeToggle),
      ]),
    ]);
  },
};

const themes = ['auto', 'light', 'dark'];

/** the theme chosen, kept for next time, where storage allows */
function chosenTheme() {
  try {
    return localStorage.getItem('theme') ?? 'auto';
  } catch {
    return 'auto';
  }
}

export function applyTheme(theme = chosenTheme()) {
  if (theme === 'auto') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', theme);
}

const ThemeToggle = {
  view() {
    const theme = chosenTheme();
    return m('button.secondary.outline', {
      title: `Theme: ${theme}`,
      onclick: () => {
        const next = themes[(themes.indexOf(theme) + 1) % themes.length];
        try {
          localStorage.setItem('theme', next);
        } catch {
          // the theme lasts for this visit only
        }
        applyTheme(next);
      },
    }, theme === 'dark' ? 'Dark' : theme === 'light' ? 'Light' : 'Auto');
  },
};

export const StatusBar = {
  view() {
    return m('footer.status-bar', { role: 'status' }, [
      m('span.message', state.message),
      state.waitingForInput ? m('span.muted', 'The console has no input to give') : null,
    ]);
  },
};

function dialog(name, title, body) {
  return m('dialog', {
    open: dialogs.open === name,
    onclick: (e) => {
      if (e.target.tagName === 'DIALOG') dialogs.open = null;
    },
  }, m('article', [
    m('header', [m('button[rel=prev]', { 'aria-label': 'Close', onclick: () => (dialogs.open = null) }), m('h3', title)]),
    body,
  ]));
}

const romSource = {
  served: 'The ROM is the one served with this page, ga144.txt.',
  saved: 'The ROM is the one you gave, saved in this browser.',
  given: 'The ROM is the one you gave. This browser cannot keep it for next time.',
};

export const RomDialog = {
  view() {
    return dialog('rom', 'The ROM', [
      m('p', state.rom ? romSource[state.rom] : 'There is no ROM, so code that calls into it, or starts in it, does not load.'),
      m('p', 'The ROM is GreenArrays\'. Give a dump of it in the format of gasim\'s --rom, or arrayForth 3\'s pFDISK.blk to assemble it from.'),
      m('.actions', [
        fileInput('.txt,.blk', async (file) => {
          await giveRom(new Uint8Array(await file.arrayBuffer()), file.name);
          dialogs.open = null;
        }, 'Give a ROM…'),
        state.rom === 'saved' ? m('button.secondary.outline', { onclick: forgetRom }, 'Forget the saved ROM') : null,
      ]),
    ]);
  },
};

const keys = [
  ['space', 'Run or pause'],
  ['s', 'Step the next node to run'],
  ['shift+s', 'Step each node that can run once'],
  ['n', 'Step the selected node'],
  ['z', 'Go back before the last step or run'],
  ['arrows or h j k l', 'Select a node'],
  ['f', 'Type at the Forth prompt'],
  ['c', 'Type into the console'],
  ['esc', 'Stop typing'],
  ['tab', 'Complete a word at the prompt'],
  ['up and down', 'Lines typed before, at the prompt'],
  ['?', 'Show these keys'],
];

export const HelpDialog = {
  view() {
    return dialog('help', 'Keys', [
      m('table', m('tbody', keys.map(([key, what]) => m('tr', [m('td', m('kbd', key)), m('td', what)])))),
      m('p.muted', 'Drop a file anywhere on the page to open it. A .txt file, or pFDISK.blk, is taken as the ROM.'),
    ]);
  },
};
