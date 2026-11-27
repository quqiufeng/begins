/* browser-nav.js — 遥控方向键在网页里选「URL 元素」，OK 进入，返回=浏览器后退。
 *
 * 由 navinject.lua 用 CDP 的 Page.addScriptToEvaluateOnNewDocument 注入到每个新文档，
 * 所以普通跳转、SPA 路由之后都自动继续生效，不需要每次重开注入。
 *
 * 行为：
 *   方向键 → 按几何位置找当前选中元素「那个方向」上最近的链接/按钮，加一圈黄框
 *   OK/Enter → 点击选中的那个（A 标签 click 不生效时兜底 location.href）
 *   其他键一律不拦，交给 chromium 自己（返回键是 keybd 合成 KEY_BACK 走浏览器历史）
 */
(function () {
  'use strict';
  if (window.__liteNav) return;
  /* 首页（browser-home.html）自己有键盘导航（focusCard + Enter 打开），别抢它的键；
     chrome:// 内建页同理 */
  try {
    if (/browser-home\.html/.test(location.href) || /^(chrome|devtools|about):/.test(location.href)) return;
  } catch (e) {}
  window.__liteNav = 1;

  var SEL = 'a[href],[role="link"],[role="button"],button,input[type="submit"],[data-href]';
  var EDITABLE = 'input,textarea,select,[contenteditable=""],[contenteditable="true"]';
  var CLS = 'lite-nav-focus';
  var cur = null;          /* { el: Element } */

  function install_css() {
    if (document.getElementById('lite-nav-css')) return;
    var st = document.createElement('style');
    st.id = 'lite-nav-css';
    st.textContent =
      '.' + CLS + '{outline:3px solid #ffd400 !important;outline-offset:2px !important;' +
      'box-shadow:0 0 0 2px #000,0 0 22px 6px rgba(255,212,0,.6) !important;' +
      'border-radius:4px !important;transition:outline-offset .08s linear;}';
    (document.head || document.documentElement).appendChild(st);
  }

  function visible(el) {
    if (!el || !el.getBoundingClientRect) return false;
    var r = el.getBoundingClientRect();
    if (r.width < 8 || r.height < 8) return false;
    if (r.bottom < -4000 || r.top > (window.innerHeight + 4000)) return false;
    var s = null;
    try { s = window.getComputedStyle(el); } catch (e) { return false; }
    if (!s) return false;
    if (s.visibility === 'hidden' || s.display === 'none') return false;
    if (parseFloat(s.opacity || '1') < 0.1) return false;
    if (el.offsetParent === null && s.position !== 'fixed') return false;
    return true;
  }

  /* 当前方向可选的元素（每次按键重算，页面是活的） */
  function items() {
    var out = [], list;
    try { list = document.querySelectorAll(SEL); } catch (e) { return out; }
    for (var i = 0; i < list.length && out.length < 800; i++) {
      var el = list[i];
      if (el.isContentEditable) continue;
      if (el.closest && el.closest(EDITABLE)) continue;
      if (!visible(el)) continue;
      var r = el.getBoundingClientRect();
      /* 同一个框里套了好几层（缩略图 a > 图片 a）：只留面积最小的那层 */
      out.push({ el: el, r: r, area: r.width * r.height });
    }
    return out;
  }

  function center(r) { return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }

  function pick(dir, list) {
    var ref = null;
    if (cur && cur.el && document.contains(cur.el) && visible(cur.el)) {
      ref = { el: cur.el, r: cur.el.getBoundingClientRect() };
    }
    if (!ref) {
      /* 还没选过：从视口里最靠左上那个开始，别一上来就选中页头里的隐藏跳转链接 */
      var first = null, bestKey = Infinity;
      for (var i = 0; i < list.length; i++) {
        var q = list[i].r;
        if (q.bottom < 8 || q.top > window.innerHeight - 8) continue;
        var k = Math.max(0, q.top) * 10000 + q.left;
        if (k < bestKey) { bestKey = k; first = list[i]; }
      }
      return first || (list.length ? list[0] : null);
    }
    var c = center(ref.r), best = null, bestScore = Infinity;
    for (var i = 0; i < list.length; i++) {
      var it = list[i];
      if (it.el === ref.el) continue;
      if (it.el.contains(ref.el) || (ref.el.contains && ref.el.contains(it.el))) continue;
      var p = center(it.r), dx = p.x - c.x, dy = p.y - c.y;
      var primary, secondary;
      if (dir === 'right') { if (dx < 8) continue; primary = dx; secondary = Math.abs(dy); }
      else if (dir === 'left') { if (dx > -8) continue; primary = -dx; secondary = Math.abs(dy); }
      else if (dir === 'down') { if (dy < 8) continue; primary = dy; secondary = Math.abs(dx); }
      else { if (dy > -8) continue; primary = -dy; secondary = Math.abs(dx); }
      /* 主方向距离为主，垂直偏移重罚：斜着跳三行不如正前方跳一格 */
      var score = primary + 6 * secondary;
      if (score < bestScore) { bestScore = score; best = it; }
    }
    return best;
  }

  function highlight(it) {
    var prev = document.querySelectorAll('.' + CLS);
    for (var i = 0; i < prev.length; i++) prev[i].classList.remove(CLS);
    cur = it;
    it.el.classList.add(CLS);
    var r = it.r;
    if (r.top < 60 || r.bottom > window.innerHeight - 40) {
      try {
        it.el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
      } catch (e) { try { it.el.scrollIntoView(); } catch (e2) {} }
    }
  }

  function move(dir) {
    install_css();
    var list = items();
    if (!list.length) return false;
    var it = pick(dir, list);
    if (!it) return false;
    highlight(it);
    return true;
  }

  function activate() {
    var el = cur && cur.el;
    if (!el || !document.contains(el)) {
      if (!move('down')) return false;
      el = cur && cur.el;
      if (!el) return false;
    }
    var href = null;
    try { href = el.href || el.getAttribute('data-href') || null; } catch (e) {}
    /* 一律在本标签里跳：target=_blank 的卡片会开新标签页，kiosk 下新标签拿走焦点，
       遥控的方向键/OK 就"消失"了（实测：点一次新窗口后必须先用鼠标点一下页面才恢复）。 */
    if (href && /^(https?:|file:|\/)/i.test(href)) {
      try { location.assign(href); return true; } catch (e) {}
    }
    try { el.focus({ preventScroll: true }); } catch (e) { try { el.focus(); } catch (e2) {} }
    try { el.click(); return true; } catch (e) {}
    return true;
  }

  var DIRS = {
    ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down',
    Left: 'left', Right: 'right', Up: 'up', Down: 'down'
  };

  function on_key(e) {
    if (e.defaultPrevented || e.ctrlKey || e.altKey || e.metaKey) return;
    var t = e.target;
    var editing = !!(t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName || '')));
    var d = DIRS[e.key] || DIRS[e.keyCode === 37 ? 'Left' : e.keyCode === 39 ? 'Right'
      : e.keyCode === 38 ? 'Up' : e.keyCode === 40 ? 'Down' : ''];
    if (d) {
      /* 输入框里有焦点（必应首页自动聚焦搜索框）也要能用方向键选链接，
         只有 Enter 让页面自己处理（不然没法提交搜索）。 */
      if (move(d)) {
        if (editing && t && t.blur) { try { t.blur(); } catch (x) {} }
        e.preventDefault();
        e.stopPropagation();
      }
      return;
    }
    if (e.key === 'Enter' || e.keyCode === 13) {
      if (editing) return;
      if (activate()) { e.preventDefault(); e.stopPropagation(); }
    }
  }

  window.addEventListener('keydown', on_key, true);
  /* 页面换过 DOM（SPA）后原来的边框元素可能没了，清一下选中态 */
  window.addEventListener('pageshow', function () { cur = null; });
  document.addEventListener('DOMContentLoaded', function () { try { install_css(); } catch (e) {} });
})();
