// The bar along the top: files, running and stepping, and the ROM; the
// status line along the bottom; and the dialogs they open.

import {
  state, pad, examples, openFile, openExample, reload, hasBlocks, toggleRun, stepNext, stepRound, stepNode, back, reset,
  giveRom, forgetRom, canPick, pickFile, openRecent, forgetRecent,
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

/** an icon, with its label beside it where the toolbar has room */
const labelled = (icon, label) => [
  m('span.icon', { style: `--icon: url(icons/${icon}.svg)` }),
  m('span.label', label),
];

/** a menu item that closes its menu and does something */
const item = (does, children) => m('li', m('a[href=#]', {
  onclick: (e) => {
    e.preventDefault();
    e.target.closest('details').open = false;
    does();
  },
}, children));

function examplesMenu() {
  return m('details.dropdown.examples', [
    m('summary', { role: 'button', class: 'secondary outline', title: 'Examples to open', 'aria-label': 'Examples' }, labelled('book-open', 'Examples')),
    m('ul', examples.map((example) => item(() => openExample(example.name), [m('strong', example.name), m('small', example.about)]))),
  ]);
}

function recentMenu() {
  if (state.recent.length === 0) return null;
  return m('details.dropdown.examples', [
    m('summary', { role: 'button', class: 'secondary outline', title: 'The files opened before', 'aria-label': 'Recent' }, labelled('clock', 'Recent')),
    m('ul', [
      state.recent.map((file) => item(async () => {
        await openRecent(file.name);
        m.redraw();
      }, [
        m('strong', file.name),
        m('small', file.handle ? 'read again from where it was opened' : 'as it was opened'),
      ])),
      item(forgetRecent, m('small', 'Forget these files')),
    ]),
  ]);
}

/** Open, through the browser's picker where it can save in place too */
function openButton() {
  const accept = '.ga,.af,.blk,.cf,.txt';
  const attrs = { class: 'secondary', title: 'Open a file', 'aria-label': 'Open…' };
  if (!canPick) return fileInput(accept, openFile, labelled('folder-open', 'Open…'), attrs);
  return m('button', {
    ...attrs,
    onclick: async () => {
      await pickFile();
      m.redraw();
    },
  }, labelled('folder-open', 'Open…'));
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
      reload().then(m.redraw);
    },
  }, [
    m('label', { for: 'loads' }, 'Blocks'),
    m('input#loads[name=loads][inputmode=numeric]', { value: file.loads.join(' '), title: 'The blocks to load, as --load loads them' }),
    m('button.secondary.outline[type=submit]', { title: 'Open the file again with these blocks' }, 'Load'),
  ]);
}

const tool = (label, onclick, attrs = {}, icon = null) => m('button.tool', { onclick, 'aria-label': label, ...attrs }, icon ? labelled(icon, label) : label);

export const Toolbar = {
  view() {
    const stopped = !state.running;
    return m('header.toolbar', [
      m('.group.files', [
        m('strong.brand', 'gasim'),
        m('nav.views', { role: 'tablist', 'aria-label': 'Views' }, [['/chip', 'Chip', 'cpu-chip'], ['/editor', 'Editor', 'code-bracket']].map(([route, label, icon]) => {
          const current = m.route.get() === route;
          return m(m.route.Link, {
            href: route,
            role: 'tab',
            class: current ? 'current' : '',
            'aria-selected': current ? 'true' : 'false',
            title: route === '/editor' ? 'The colorForth editor (e)' : 'The chip (q in the editor)',
            'aria-label': label,
          }, labelled(icon, label));
        })),
        openButton(),
        recentMenu(),
        examplesMenu(),
        state.file ? m('span.file', { title: state.file.name }, state.file.name) : null,
        blocksField(),
      ]),
      m('.group.run', { role: 'toolbar', 'aria-label': 'Run and step' }, [
        tool(state.running ? 'Pause' : 'Run', toggleRun, { class: state.running ? 'secondary' : '', title: 'Run or pause (space)' }, state.running ? 'pause' : 'play'),
        tool('Step', stepNext, { disabled: !stopped, class: 'secondary outline', title: 'Step the next node to run (s)' }),
        tool('Round', stepRound, { disabled: !stopped, class: 'secondary outline', title: 'Step each node that can run once (shift+s)' }),
        tool('Node', stepNode, { disabled: !stopped, class: 'secondary outline', title: 'Step the selected node (n)' }),
        tool('Back', back, { disabled: !stopped || state.chip.history === 0, class: 'secondary outline', title: 'Go back before the last step or run (z)' }, 'arrow-uturn-left'),
        tool('Reset', reset, { class: 'secondary outline', title: 'Start the chip again as it was loaded' }, 'arrow-path'),
      ]),
      m('.group.info', [
        m('span.steps', { title: 'Steps taken by all the nodes' }, `${state.chip.steps.toLocaleString()} steps`),
        m('button.secondary.outline', { onclick: () => (dialogs.open = 'rom'), title: 'The ROM' }, state.rom ? 'ROM' : 'No ROM'),
        m('button.secondary.outline', { onclick: () => (dialogs.open = 'help'), title: 'Keys (?)', 'aria-label': 'Help' }, labelled('question-mark-circle', 'Help')),
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
    const label = theme === 'dark' ? 'Dark' : theme === 'light' ? 'Light' : 'Auto';
    return m('button.secondary.outline', {
      title: `Theme: ${theme}`,
      'aria-label': `Theme: ${theme}`,
      onclick: () => {
        const next = themes[(themes.indexOf(theme) + 1) % themes.length];
        try {
          localStorage.setItem('theme', next);
        } catch {
          // the theme lasts for this visit only
        }
        applyTheme(next);
      },
    }, labelled({ dark: 'moon', light: 'sun' }[theme] ?? 'computer-desktop', label));
  },
};

const statusText = {
  running: 'running',
  code: 'waiting for code',
  reading: 'waiting to read',
  writing: 'waiting to write',
};

export const StatusBar = {
  view() {
    return m('footer.status-bar', { role: 'status' }, [
      m('span.message', state.message),
      state.waitingForInput ? m('span.muted', 'The console has no input to give') : null,
      m('span.selected', `node ${pad(state.node.number)}, ${statusText[state.node.status]}`),
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
  ['e', 'The colorForth editor, and q in it to come back'],
  ['f', 'Type at the Forth prompt'],
  ['c', 'Type into the console'],
  ['esc', 'Stop typing'],
  ['tab', 'Complete a word at the prompt'],
  ['up and down', 'Lines typed before, at the prompt'],
  ['? or F1', 'Show these keys'],
];

const editorKeys = [
  ['h l, or left right', 'The word before or after'],
  ['j k, or down up', 'The next or last red word'],
  ['0 $, or home end', 'The first or last word'],
  ['[ ], or page up down', 'The block before or after'],
  ['a number, then g', 'Go to that block'],
  ['i a', 'Type a word before or after this one'],
  ['o O', 'Type a red word on a line after or before'],
  ['space, enter, esc', 'The next word, a new line, done typing'],
  ['x X', 'Cut this word, or the one before'],
  ['y p P', 'Copy, and put after or before'],
  ['u U', 'Undo and redo'],
  ['R Y G W C M B', 'Color this word'],
  ['ctrl or alt + r y g w t v b', 'Color the word, as it is typed too'],
  ['L', 'Compile the block and start the chip again'],
  ['ctrl+s, or s', 'Save'],
  ['f', 'Show or hide blue words'],
  ['q', 'Back to the chip'],
];

const table = (rows) => m('table', m('tbody', rows.map(([key, what]) => m('tr', [m('td', m('kbd', key)), m('td', what)]))));

export const HelpDialog = {
  view() {
    const editing = m.route.get() === '/editor';
    return dialog('help', editing ? 'The editor\'s keys' : 'Keys', [
      table(editing ? editorKeys : keys),
      editing ? m('p.muted', 'Browsers keep ctrl+w and ctrl+t, so alt+w and alt+t color white and cyan, as do the buttons below the block.') : null,
      editing ? null : m('p.muted', 'Drop a file anywhere on the page to open it. A .txt file, or pFDISK.blk, is taken as the ROM.'),
    ]);
  },
};
