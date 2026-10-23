/* Page effects for the login and member pages, matched to the main site:
   - going to another page of the site plays the red pixel wipe with the page name decoding,
     and the next page dissolves in from it;
   - buttons scramble their label when tapped, drop-down titles decode as they open;
   - sections slide up as they appear (first load and tab switches) and their titles decode.
   The main site loads this with data-nav-only, so it only gets the page-to-page wipe (it has its own button effects).
   Everything is skipped for reduced motion and in the edit page's preview. */
(function () {
  var me = document.currentScript;
  if (/[?&]preview\b/.test(location.search) || (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches)) return;
  var NAV_ONLY = me && me.hasAttribute('data-nav-only');
  var ROOT = new URL('../', me ? me.src : location.href);
  var KEY = '228th-fx-arrive', arrive = null;
  try { arrive = JSON.parse(sessionStorage.getItem(KEY) || 'null'); sessionStorage.removeItem(KEY); } catch (e) {}
  if (arrive && !(Date.now() - arrive.t < 10000)) arrive = null;

  var css = '#fxpx{position:fixed;inset:0;z-index:9999;pointer-events:none;display:none}' +
    '#fxpx.on{display:block;pointer-events:auto}#fxpx canvas{position:absolute;inset:0;width:100%;height:100%}' +
    '#fxpx .l{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);text-align:center;opacity:0;transition:opacity .15s;width:min(90vw,640px)}' +
    '#fxpx .l.on{opacity:1}' +
    '#fxpx .t{font:800 clamp(1.6rem,5vw,2.6rem)/1.1 "Big Shoulders Stencil Display",Impact,"Arial Narrow",sans-serif;text-transform:uppercase;letter-spacing:.03em;color:#efefed;white-space:nowrap;overflow:hidden}' +
    '#fxpx .b{height:2px;background:#29292d;margin:12px auto 10px;width:min(60%,260px);position:relative;overflow:hidden}' +
    '#fxpx .b i{position:absolute;inset:0;background:#e2333b;transform-origin:left;transform:scaleX(0)}' +
    '#fxpx .p{font:500 .72rem "IBM Plex Mono",ui-monospace,Menlo,monospace;letter-spacing:.14em;color:#e2333b}' +
    'html.fx-arr{background:#0a0a0b}html.fx-arr body{visibility:hidden}' +
    '@keyframes fxUp{from{opacity:0;transform:translateY(22px)}to{opacity:1;transform:none}}' +
    '.fx-up{animation:fxUp .75s cubic-bezier(.2,.7,.2,1) both}';
  var st = document.createElement('style'); st.textContent = css; (document.head || document.documentElement).appendChild(st);
  if (arrive) document.documentElement.classList.add('fx-arr');

  var GLYPHS = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789#/+-';
  function rnd(n) { return Math.floor(Math.random() * n); }
  // Decode text into place. Stops on its own if something else changes the text meanwhile.
  function scramble(el, text, dur, done) {
    var start = performance.now(), len = text.length, last = null;
    if (el._scr) cancelAnimationFrame(el._scr);
    (function step(now) {
      if (last !== null && el.textContent !== last) { el._scr = 0; done && done(); return; }
      var p = Math.min(1, (now - start) / dur), out = '';
      for (var i = 0; i < len; i++) { var c = text[i]; out += (c === ' ' || i < p * len * 1.05 - 1) ? c : GLYPHS[rnd(GLYPHS.length)]; }
      el.textContent = last = out;
      if (p < 1) el._scr = requestAnimationFrame(step); else { el.textContent = text; el._scr = 0; done && done(); }
    })(start);
  }
  window.FX = { scramble: scramble };

  // ---- Pixel wipe overlay ----
  var box, cv, ctx, lab, bar, pct, busy = false;
  function build() {
    if (box) return;
    box = document.createElement('div'); box.id = 'fxpx'; box.setAttribute('aria-hidden', 'true');
    box.innerHTML = '<canvas></canvas><div class="l"><div class="t"></div><div class="b"><i></i></div><div class="p">000%</div></div>';
    document.body.appendChild(box);
    cv = box.querySelector('canvas'); ctx = cv.getContext('2d');
    lab = box.querySelector('.t'); bar = box.querySelector('.b i'); pct = box.querySelector('.p');
  }
  function mix(a, b, t) { return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]; }
  var SLOW = 1; // >1 plays the wipe slower; 1 matches the main page
  var RED = [226, 51, 59], DEEP = [150, 18, 24], DARK = [10, 10, 11];
  function grid(x, y) {
    var W = innerWidth, H = innerHeight, dpr = Math.min(2, devicePixelRatio || 1);
    cv.width = W * dpr; cv.height = H * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    var cs = Math.max(34, Math.min(64, Math.round(W / 11))), cols = Math.ceil(W / cs), rows = Math.ceil(H / cs), cells = [], maxD = 0;
    for (var r = 0; r < rows; r++) for (var c = 0; c < cols; c++) { var dx = c * cs + cs / 2 - x, dy = r * cs + cs / 2 - y, dd = Math.sqrt(dx * dx + dy * dy); maxD = Math.max(maxD, dd); cells.push({ x: c * cs, y: r * cs, d: dd, j: Math.random() }); }
    cells.forEach(function (k) { k.t = (k.d / maxD) * 420 + k.j * 110; k.o = (1 - k.d / maxD) * 300 + k.j * 160; });
    return { W: W, H: H, cs: cs, cells: cells };
  }
  // Cover the screen from the tap point, then decode the next page's name while it loads.
  function wipeIn(x, y, label, then) {
    build(); busy = true;
    var g = grid(x, y), IN = 830, LOAD = 900, t0 = performance.now(), fired = false, gone = false;
    box.classList.add('on'); lab.textContent = ''; bar.style.transform = 'scaleX(0)'; pct.textContent = '000%';
    (function frame(now) {
      var t = (now - t0) / SLOW; ctx.clearRect(0, 0, g.W, g.H);
      if (t < IN) {
        g.cells.forEach(function (k) { var a = t - k.t; if (a < 0) return; var c = a < 90 ? RED : mix(a < 200 ? RED : DEEP, DARK, Math.min(1, (a - (a < 200 ? 90 : 200)) / (a < 200 ? 110 : 180))); ctx.fillStyle = 'rgb(' + c.map(Math.round) + ')'; ctx.fillRect(k.x, k.y, g.cs + .5, g.cs + .5); });
      } else {
        ctx.fillStyle = 'rgb(10,10,11)'; ctx.fillRect(0, 0, g.W, g.H);
        if (!fired) { fired = true; box.querySelector('.l').classList.add('on'); scramble(lab, label, LOAD * .4); }
        // One steady fill, the same pace as the main page; the next page opens once it's full.
        var p = Math.min(1, (t - IN) / (LOAD * .85)); bar.style.transform = 'scaleX(' + p + ')'; pct.textContent = ('00' + Math.round(p * 100)).slice(-3) + '%';
        if (t >= IN + LOAD && !gone) { gone = true; lab.textContent = label; then(); }
      }
      requestAnimationFrame(frame);
    })(t0);
  }
  // On the new page: the bar stays full for a moment, then the dark screen dissolves away.
  function wipeOut(a) {
    build();
    var x = (a.x || .5) * innerWidth, y = (a.y || .5) * innerHeight, g = grid(x, y);
    box.classList.add('on'); var l = box.querySelector('.l'); l.classList.add('on');
    lab.textContent = a.label || ''; document.documentElement.classList.remove('fx-arr');
    var LOAD = 150, OUT = 580, t0 = performance.now();
    bar.style.transform = 'scaleX(1)'; pct.textContent = '100%';
    (function frame(now) {
      var t = (now - t0) / SLOW; ctx.clearRect(0, 0, g.W, g.H);
      if (t < LOAD) {
        ctx.fillStyle = 'rgb(10,10,11)'; ctx.fillRect(0, 0, g.W, g.H);
      } else if (t < LOAD + OUT) {
        l.classList.remove('on'); var u = t - LOAD;
        g.cells.forEach(function (k) { var b = u - k.o; if (b > 120) return; ctx.fillStyle = b > 0 ? 'rgba(10,10,11,' + (1 - b / 120) + ')' : 'rgb(10,10,11)'; if (b > 0 && b < 50) ctx.fillStyle = 'rgb(150,18,24)'; ctx.fillRect(k.x, k.y, g.cs + .5, g.cs + .5); });
      } else { ctx.clearRect(0, 0, g.W, g.H); box.classList.remove('on'); return; }
      requestAnimationFrame(frame);
    })(t0);
  }
  // Go to another page of the site behind the wipe. opts.replace swaps the history entry (used after logging in).
  FX.go = function (url, label, opts) {
    opts = opts || {};
    if (busy) return;
    var x = opts.x != null ? opts.x : innerWidth / 2, y = opts.y != null ? opts.y : innerHeight / 2;
    wipeIn(x, y, (label || '228th Black Skulls Corps').toUpperCase(), function () {
      try { sessionStorage.setItem(KEY, JSON.stringify({ t: Date.now(), label: (label || '').toUpperCase(), x: x / innerWidth, y: y / innerHeight })); } catch (e) {}
      if (opts.replace) location.replace(url); else location.href = url;
    });
  };
  // Coming back with the Back button can show the page as it was left, still covered; uncover it.
  addEventListener('pageshow', function (e) {
    if (e.persisted && box) { box.classList.remove('on'); busy = false; }
  });

  var NAMES = { '': '228th Black Skulls Corps', 'login/': 'Log in', 'members/': 'Dashboard', 'account/': 'My account', 'org/': 'Unit Organization', 'org/manage/': 'Org manager', 'docs/': 'Documents', 'dashboard/': 'Command Center' };
  function pageOf(u) { var p = u.pathname.slice(ROOT.pathname.length); return p.replace(/index\.html$/, ''); }
  FX.nameOf = function (url) { try { return NAMES[pageOf(new URL(url, location.href))] || ''; } catch (e) { return ''; } };
  function labelFor(a, u) {
    var t = (a._orig || a.innerText || a.textContent || '').replace(/\s+/g, ' ').trim();
    if (a.classList.contains('brand') || !t || t.length > 40) t = NAMES[pageOf(u)] || '228th Black Skulls Corps';
    return t;
  }
  // Same-site page links (not files, the edit page, the op planner or in-page jumps).
  function sitePage(a) {
    if (a.target && a.target !== '_self') return null;
    if (a.hasAttribute('download')) return null;
    var href = a.getAttribute('href') || '';
    if (!href || href.charAt(0) === '#' || /^(mailto|tel|javascript):/i.test(href)) return null;
    var u; try { u = new URL(a.href, location.href); } catch (e) { return null; }
    if (u.origin !== location.origin || u.pathname.indexOf(ROOT.pathname) !== 0) return null;
    var p = pageOf(u);
    if (/^(admin|planner|archive)\//.test(p) || /\.(?!html?$)\w+$/.test(p)) return null;
    if (u.pathname === location.pathname && u.search === location.search) return null;
    return u;
  }

  function buttonText(b) {
    if (b.children.length || b.disabled || b.closest('#fxpx')) return null;
    var t = b.textContent; return t && t.trim() ? t : null;
  }
  document.addEventListener('click', function (e) {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    var a = e.target.closest && e.target.closest('a');
    var u = a && sitePage(a), label = u ? labelFor(a, u) : '';
    if (!NAV_ONLY) {
      var b = e.target.closest && e.target.closest('button,.btn');
      var txt = b && buttonText(b);
      if (txt && !b._busy) {
        b._busy = true; b._orig = txt; var w = b.style.width;
        b.style.width = b.getBoundingClientRect().width + 'px';
        scramble(b, txt, 480, function () { b._busy = false; b.style.width = w; });
      }
    }
    if (!u) return;
    e.preventDefault();
    var x = e.clientX || innerWidth / 2, y = e.clientY || innerHeight / 2;
    setTimeout(function () { FX.go(u.href, label, { x: x, y: y }); }, a.classList.contains('btn') ? 140 : 0);
  });

  function arrived() { if (arrive) wipeOut(arrive); }
  if (NAV_ONLY) {
    if (document.body) arrived(); else document.addEventListener('DOMContentLoaded', arrived);
    return;
  }

  // ---- Member pages: sections slide up and their titles decode as they appear ----
  var started = performance.now();
  function title(el) {
    var h = el.matches('h1,h2') ? el : el.querySelector('h1,h2');
    if (h && !h.children.length && h.offsetParent) scramble(h, h._txt || (h._txt = h.textContent), 650);
  }
  function show(el, i) {
    if (!el || el.nodeType !== 1 || el.hidden || el.closest('[hidden]')) return;
    el.classList.remove('fx-up'); void el.offsetWidth;
    el.style.animationDelay = (i || 0) * 110 + 'ms'; el.classList.add('fx-up');
    el.addEventListener('animationend', function h() { el.removeEventListener('animationend', h); el.classList.remove('fx-up'); el.style.animationDelay = ''; });
    setTimeout(function () { title(el); }, (i || 0) * 110);
  }
  // A section's own blocks come in one after another.
  function showSection(el) {
    var kids = [].filter.call(el.children, function (k) { return !k.hidden && k.tagName !== 'SCRIPT' && k.tagName !== 'TEMPLATE'; }).slice(0, 10);
    if (kids.length > 1) kids.forEach(function (k, i) { show(k, i); }); else show(el, 0);
  }
  function enter() {
    var main = document.querySelector('main'); if (!main) return;
    [].forEach.call(main.children, function (k) { if (!k.hidden && k.id !== 'msg') showSection(k); });
    // Sections that open later (after the login check, or when a tab is picked).
    new MutationObserver(function (list) {
      list.forEach(function (m) {
        var el = m.target;
        if (el.hidden || m.oldValue === null) return;
        if (el.parentNode === main || el.hasAttribute('data-pane') || (el.parentNode && el.parentNode.parentNode === main && performance.now() - started < 4000)) showSection(el);
      });
    }).observe(main, { subtree: true, attributes: true, attributeFilter: ['hidden'], attributeOldValue: true });
    // Drop-down titles decode as they open.
    document.addEventListener('toggle', function (e) {
      var d = e.target; if (!d.open || d.tagName !== 'DETAILS') return;
      var s = d.querySelector(':scope>summary'); if (s && !s.children.length) scramble(s, s._txt || (s._txt = s.textContent), 450);
    }, true);
  }
  function ready() { arrived(); enter(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready); else ready();
})();
