// Shared form pieces for the Forms page (forms/) and the public Alliance page (alliance/). Needs auth/auth.js first.
// FormKit.question(q, value, locked, opts) draws one question; FormKit.collect(form, el) reads the answers back.
// opts.free: the signature takes any name instead of a 228th callsign (for people outside the unit).
(function () {
  var A = window.Auth, K = window.FormKit = {};

  K.question = function (q, val, locked, opts) {
    opts = opts || {};
    var box = A.el('div', 'q' + (q.type === 'info' ? ' info' : '')); box.dataset.q = q.id;
    if (q.type === 'info') {
      if (q.label) box.appendChild(A.el('h3', null, q.label));
      if (q.help) box.appendChild(A.richText(q.help));
      return box;
    }
    var name = 'q_' + q.id;
    if (q.type === 'agree') {
      var l = A.el('label', 'agree'), c = A.el('input'); c.type = 'checkbox'; c.name = name; c.checked = val === true; c.disabled = locked;
      var tx = A.el('span', null, q.label || 'I agree'); if (q.required) tx.appendChild(A.el('span', 'req', ' *'));
      l.appendChild(c); l.appendChild(tx);
      box.appendChild(l);
      if (q.help) box.appendChild(A.el('p', 'qh', q.help));
      return box;
    }
    var lab = A.el('label', 'ql', q.label || 'Question'); lab.htmlFor = name;
    if (q.required) lab.appendChild(A.el('span', 'req', '*'));
    box.appendChild(lab);
    if (q.help) box.appendChild(A.el('p', 'qh', q.help));
    if (q.type === 'signature') { box.appendChild(signature(q, val, locked, opts.free)); return box; }
    if (q.type === 'text' || q.type === 'long') {
      var i = A.el(q.type === 'long' ? 'textarea' : 'input'); i.id = i.name = name; i.maxLength = q.type === 'long' ? 4000 : 300;
      i.value = typeof val === 'string' ? val : ''; i.disabled = locked; box.appendChild(i);
    } else {
      var opts2 = A.el('div', 'opts'), have = Array.isArray(val) ? val : val != null ? [val] : [];
      (q.options || []).forEach(function (o) {
        var l2 = A.el('label'), c2 = A.el('input'); c2.type = q.type === 'choice' ? 'radio' : 'checkbox'; c2.name = name; c2.value = o;
        c2.checked = have.indexOf(o) >= 0; c2.disabled = locked; l2.appendChild(c2); l2.appendChild(document.createTextNode(o)); opts2.appendChild(l2);
      });
      box.appendChild(opts2);
    }
    return box;
  };

  // Signature: a name (a member's callsign, checked the same way as on sign-up) and a drawn signature.
  function signature(q, val, locked, free) {
    val = val && typeof val === 'object' ? val : {};
    var w = A.el('div', 'sig'), name = 'q_' + q.id;
    var lab = A.el('label', 'f'), inp = A.el('input'), hint = A.el('span', 'hint', free ? 'Your name, callsign or handle, as you want it on the agreement.' : A.callsignHelp);
    lab.appendChild(document.createTextNode(free ? 'Your name' : 'Callsign')); inp.name = name; inp.maxLength = 60; inp.autocapitalize = 'off'; inp.spellcheck = false;
    inp.placeholder = free ? 'Name / callsign' : 'CT-1234 "Nickname"'; inp.value = val.name || ''; inp.disabled = locked;
    lab.appendChild(inp); lab.appendChild(hint); w.appendChild(lab);
    if (locked) hint.hidden = true; else if (!free) A.watchCallsign(inp, hint);
    var pad = A.el('div', 'pad'), cv = A.el('canvas'); pad.appendChild(cv); pad.appendChild(A.el('div', 'line')); pad.appendChild(A.el('span', 'ph', 'Sign here with your finger or mouse'));
    var bar = A.el('div', 'padbar'); bar.appendChild(A.el('span', 'label', 'Drawn signature'));
    var clr = A.el('button', 'btn ghost small', 'Clear'); clr.type = 'button'; clr.onclick = function () { clear(); };
    if (!locked) bar.appendChild(clr);
    w.appendChild(bar); w.appendChild(pad);
    var ctx = cv.getContext('2d'), drawing = false, last = null, inked = false;
    function size() {
      var r = pad.getBoundingClientRect(), d = Math.min(window.devicePixelRatio || 1, 2), keep = inked ? cv.toDataURL() : null;
      cv.width = Math.max(1, Math.round(r.width * d)); cv.height = Math.max(1, Math.round(r.height * d));
      ctx.setTransform(d, 0, 0, d, 0, 0); ctx.lineWidth = 2.4; ctx.lineCap = ctx.lineJoin = 'round'; ctx.strokeStyle = '#111';
      if (keep) paint(keep);
    }
    function paint(src) { var im = new Image(); im.onload = function () { var r = pad.getBoundingClientRect(); ctx.drawImage(im, 0, 0, r.width, r.height); }; im.src = src; }
    function clear() { ctx.clearRect(0, 0, cv.width, cv.height); inked = false; pad.classList.remove('done'); }
    function pt(e) { var r = cv.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
    if (!locked) {
      cv.addEventListener('pointerdown', function (e) { drawing = true; last = pt(e); cv.setPointerCapture(e.pointerId); ctx.beginPath(); ctx.arc(last.x, last.y, 1.1, 0, 7); ctx.fillStyle = '#111'; ctx.fill(); inked = true; pad.classList.add('done'); e.preventDefault(); });
      cv.addEventListener('pointermove', function (e) { if (!drawing) return; var p = pt(e); ctx.beginPath(); ctx.moveTo(last.x, last.y); ctx.lineTo(p.x, p.y); ctx.stroke(); last = p; e.preventDefault(); });
      ['pointerup', 'pointercancel', 'pointerleave'].forEach(function (t) { cv.addEventListener(t, function () { drawing = false; }); });
    }
    requestAnimationFrame(function () { size(); if (val.drawing) { inked = true; pad.classList.add('done'); paint(val.drawing); } });
    var rt; addEventListener('resize', function () { clearTimeout(rt); rt = setTimeout(size, 150); });
    w._value = function () {
      var nm = free ? inp.value.trim() : A.callsign(inp.value) || '';
      if (nm) inp.value = nm;
      // Shrink the drawing to a small image so answers stay light.
      var out = '';
      if (inked) {
        var c2 = document.createElement('canvas'), r = pad.getBoundingClientRect(); c2.width = 600; c2.height = Math.round(600 * r.height / r.width);
        var x = c2.getContext('2d'); x.fillStyle = '#fff'; x.fillRect(0, 0, c2.width, c2.height); x.drawImage(cv, 0, 0, c2.width, c2.height); out = c2.toDataURL('image/jpeg', 0.7);
      }
      return { name: nm, drawing: out };
    };
    w._free = !!free;
    return w;
  }

  // Read the answers from a drawn form. missing is the first required question left empty, or null.
  K.collect = function (f, form) {
    var ans = {}, missing = null;
    form.querySelectorAll('.q.bad').forEach(function (x) { x.classList.remove('bad'); });
    (f.questions || []).forEach(function (q) {
      if (q.type === 'info') return;
      var name = 'q_' + q.id, v, box = form.querySelector('[data-q="' + q.id + '"]');
      if (q.type === 'agree') v = form.querySelector('[name="' + name + '"]').checked;
      else if (q.type === 'text' || q.type === 'long') v = form.querySelector('[name="' + name + '"]').value.trim();
      else if (q.type === 'signature') {
        var sig = box.querySelector('.sig'), sv = sig._value(); v = sv;
        if (q.required && (!sv.name || !sv.drawing)) {
          box.classList.add('bad');
          if (!missing) missing = { id: q.id, label: !sv.name ? (sig._free ? 'Signature: your name' : 'Signature: your callsign, like CT-1234 "Nickname"') : 'Signature: draw your signature in the box' };
        }
        ans[q.id] = v; return;
      }
      else if (q.type === 'choice') { var c = form.querySelector('[name="' + name + '"]:checked'); v = c ? c.value : ''; }
      else v = Array.prototype.map.call(form.querySelectorAll('[name="' + name + '"]:checked'), function (x) { return x.value; });
      var empty = v === false || v === '' || (Array.isArray(v) && !v.length);
      if (q.required && empty) { box.classList.add('bad'); if (!missing) missing = q; }
      ans[q.id] = v;
    });
    return { answers: ans, missing: missing };
  };
})();
