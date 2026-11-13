// The sizes of the app's regions, kept for next time, and the borders
// between them to drag.

const { m } = window;

/**
 * the sizes of the node column and the dock, on a narrow screen of the
 * tabs under the map, and of the editor's odd block, kept for next time
 */
export const layout = loadLayout();

function loadLayout() {
  const defaults = { node: 26, dock: 30, stack: 50, pair: 50, tab: 'node' };
  try {
    return { ...defaults, ...JSON.parse(localStorage.getItem('layout') ?? '{}') };
  } catch {
    return defaults;
  }
}

export function saveLayout() {
  try {
    localStorage.setItem('layout', JSON.stringify(layout));
  } catch {
    // the layout lasts for this visit only
  }
}

/** where a border's drag started: the pointer, and the size then */
let dragFrom = null;

/**
 * A border to drag, setting `layout[name]` as a percentage of its parent's
 * width or height, such as the chip view's, measured from the right or
 * bottom edge. It moves as far as the pointer has from where the drag
 * started, in the parent's content box, the percentages' box, so it stays
 * under the pointer.
 */
export function gutter(name, vertical, min, max) {
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
