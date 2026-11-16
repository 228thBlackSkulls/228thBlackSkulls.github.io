/* Role reader for Trooper Profiles (Command Center). Reads Discord role names, and the trooper's callsign if it shows,
   out of screenshots, right in the browser with Tesseract (free, nothing leaves the computer until it's filed).
   RoleReader.read(fileOrBlob, onProgress) -> { roles: [...], trooper: 'CT-1234', nickname: 'Minxy', discord: '1234...', text } */
window.RoleReader = (function () {
  var TESS = 'https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js';
  var worker = null, loading = null, progress = null;

  function loadScript(src) {
    return new Promise(function (ok, bad) {
      if (window.Tesseract) return ok();
      var s = document.createElement('script'); s.src = src; s.onload = ok; s.onerror = function () { bad(new Error('Couldn\'t load the text reader. Check the connection and try again.')); };
      document.head.appendChild(s);
    });
  }
  function getWorker() {
    if (worker) return Promise.resolve(worker);
    if (!loading) loading = loadScript(TESS).then(function () {
      return Tesseract.createWorker('eng', 1, { logger: function (m) { if (progress) progress(m); } });
    }).then(function (w) {
      worker = w;
      // Sparse text: role chips are short words scattered across rows, not paragraphs.
      return w.setParameters({ tessedit_pageseg_mode: '11', preserve_interword_spaces: '1' }).then(function () { return w; });
    }).catch(function (e) { loading = null; throw e; });
    return loading;
  }

  // Draw the screenshot bigger, in grey, dark text on light, with the contrast stretched (Discord is light text on dark).
  function prepare(file) {
    return new Promise(function (ok, bad) {
      var url = URL.createObjectURL(file), img = new Image();
      img.onload = function () {
        URL.revokeObjectURL(url);
        var w = img.naturalWidth, h = img.naturalHeight, big = Math.max(w, h);
        var k = w < 1400 ? Math.min(3, 1400 / w) : big > 2400 ? 2400 / big : 1;
        var c = document.createElement('canvas'); c.width = Math.round(w * k); c.height = Math.round(h * k);
        var x = c.getContext('2d', { willReadFrequently: true }); x.imageSmoothingQuality = 'high'; x.drawImage(img, 0, 0, c.width, c.height);
        var d = x.getImageData(0, 0, c.width, c.height), p = d.data, i, sum = 0, n = p.length / 4, g = new Uint8ClampedArray(n);
        for (i = 0; i < n; i++) { g[i] = 0.299 * p[i * 4] + 0.587 * p[i * 4 + 1] + 0.114 * p[i * 4 + 2]; sum += g[i]; }
        var dark = sum / n < 128, lo = 255, hi = 0, hist = new Uint32Array(256);
        for (i = 0; i < n; i++) { if (dark) g[i] = 255 - g[i]; hist[g[i]]++; }
        // Stretch between the 2nd and 98th percentile.
        var acc = 0; for (i = 0; i < 256; i++) { acc += hist[i]; if (acc > n * 0.02) { lo = i; break; } }
        acc = 0; for (i = 255; i >= 0; i--) { acc += hist[i]; if (acc > n * 0.02) { hi = i; break; } }
        var span = Math.max(1, hi - lo);
        for (i = 0; i < n; i++) { var v = (g[i] - lo) * 255 / span; p[i * 4] = p[i * 4 + 1] = p[i * 4 + 2] = v; p[i * 4 + 3] = 255; }
        x.putImageData(d, 0, 0);
        ok(c);
      };
      img.onerror = function () { URL.revokeObjectURL(url); bad(new Error('That file isn\'t a picture the browser can open.')); };
      img.src = url;
    });
  }

  // Words Discord shows around the roles that aren't roles.
  var SKIP = /^(roles?|no roles|about me|member since|note|click to add a note|add note|message|send message|add role|add roles|edit roles?|view full (profile|bio)|mutual (servers?|friends?)|activity|playing|listening to|watching|online|idle|do not disturb|offline|bio|connections|server profile|joined|discord member since|pronouns|block|report|edit profile|copy user id|\+)$/i;
  var CALLSIGN = /\b([A-Z]{1,4}(?:-[A-Z])?)\s*[-–—]\s*(\d{4})\b\s*["“”'‘’]?\s*([A-Za-z][A-Za-z0-9 .'’-]{0,30}?)\s*["“”'‘’]?\s*$/;

  // Just the role's own words: no ==== dividers, no "..." where Discord cut a long name off, and none of the stray
  // marks the coloured dot or a role's little icon read as (@ © # ¢ & 4) and so on).
  function clean(t) {
    t = t.replace(/[=_|~`^]+/g, ' ').replace(/(\.\.\.|…)+/g, ' ').replace(/[—–]{2,}/g, ' ').replace(/\s+/g, ' ').trim();
    var w = t.split(' ');
    function junk(x, edge) { return !/[A-Za-z]/.test(x) || (x.length <= 2 && !/^(?:[A-Z]{2}|[A-Za-z]\d?|\d[A-Za-z])$/.test(x) && edge) || /^[eoOcCa]$/.test(x) && edge === 'start'; }
    while (w.length && junk(w[0], 'start')) w.shift();
    while (w.length && junk(w[w.length - 1], 'end')) w.pop();
    t = w.join(' ').replace(/^[^A-Za-z0-9(\[]+/, '').replace(/[\s.,;:·•'’"“”*#&%¢©®°@$£¥€\-]+$/, '').trim();
    // Close a bracket the cut-off left open: "EOD [Explosive Ordnance Dispos" -> "EOD [Explosive Ordnance Dispos]".
    if ((t.match(/\[/g) || []).length > (t.match(/\]/g) || []).length) t += ']';
    return t;
  }
  // A chip worth keeping: at least 3 characters with 2 letters, or a 2-letter all-caps short name like "QM".
  function realRole(t) { return /[A-Za-z].*[A-Za-z]/.test(t) && (t.length >= 3 || /^[A-Z]{2}$/.test(t)); }

  // Split each line into chips where the gap between words is wider than a normal space.
  function chipsFrom(data) {
    var out = [];
    (data.lines || []).forEach(function (ln) {
      var ws = (ln.words || []).filter(function (w) { return w.text && w.text.trim(); });
      if (!ws.length) { if (ln.text) out.push({ text: ln.text, conf: ln.confidence }); return; }
      ws.sort(function (a, b) { return a.bbox.x0 - b.bbox.x0; });
      var hgt = Math.max(1, ln.bbox.y1 - ln.bbox.y0), cur = [ws[0]];
      for (var i = 1; i < ws.length; i++) {
        var gap = ws[i].bbox.x0 - ws[i - 1].bbox.x1;
        if (gap > hgt * 0.95) { out.push(group(cur)); cur = []; }
        cur.push(ws[i]);
      }
      out.push(group(cur));
    });
    return out;
    function group(ws) { return { text: ws.map(function (w) { return w.text; }).join(' '), conf: ws.reduce(function (s, w) { return s + w.confidence; }, 0) / ws.length }; }
  }

  async function read(file, onProgress) {
    progress = onProgress || null;
    var w = await getWorker(), canvas = await prepare(file);
    var r = await w.recognize(canvas), data = r.data, res = { roles: [], trooper: '', nickname: '', discord: '', text: data.text || '' };
    var id = (data.text || '').match(/\b\d{17,20}\b/); if (id) res.discord = id[0];
    var seen = {}, chips = chipsFrom(data);
    // Anything above Discord's ROLES heading is the name card: look there only for the callsign.
    var at = chips.findIndex(function (c) { return /^roles?$/i.test(clean(c.text)); });
    chips.forEach(function (c, i) {
      var raw = c.text.trim(), t = clean(raw);
      if (/^@?[a-z0-9_.]{2,32}$/.test(raw) && /[_.\d]/.test(raw)) return; // their username
      if (!t || !realRole(t) || c.conf < 30 || SKIP.test(t) || /^\d+ online$/i.test(t)) return;
      var cs = t.match(CALLSIGN);
      if (cs && !res.trooper) { res.trooper = cs[1] + '-' + cs[2]; res.nickname = (cs[3] || '').trim(); return; }
      if (at >= 0 && i <= at) return;
      // Their Discord ID and dates aren't roles.
      if (/^\d{15,21}$/.test(t) || /^[A-Z][a-z]{2} \d{1,2}, \d{4}/.test(t)) return;
      if (!/[A-Za-z0-9]/.test(t)) return;
      var k = t.toLowerCase(); if (seen[k]) return; seen[k] = 1;
      res.roles.push(t);
    });
    return res;
  }

  return { read: read, warm: function () { return getWorker().catch(function () {}); } };
})();
