// Hooks that keep a scrolled element at its end as it grows, unless it was
// scrolled back, which the element itself remembers.

export const follow = {
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
