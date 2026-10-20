// Shared account helpers for the login, members and dashboard pages (and the main site's menu links).
(function () {
  var C = window.SB_CONFIG || {};
  var A = window.Auth = { configured: !!(C.url && C.anonKey), providers: C.providers || ['discord', 'email'] };
  if (A.configured && window.supabase) {
    A.sb = window.supabase.createClient(C.url, C.anonKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce' } });
  }

  // Absolute URL of a site page, relative to the site root (this file lives in /auth/).
  var root = new URL('../', document.currentScript ? document.currentScript.src : location.href).href;
  A.url = function (path) { return root + (path || ''); };

  A.session = async function () {
    if (!A.sb) return null;
    var r = await A.sb.auth.getSession();
    return r.data && r.data.session;
  };

  // The signed-in person's profile with their role's label and rank, or null.
  A.me = async function () {
    var s = await A.session();
    if (!s) return null;
    var r = await A.sb.from('profiles').select('*, roles(*)').eq('id', s.user.id).maybeSingle();
    if (r.error) throw r.error;
    if (!r.data) return { status: 'pending', user: s.user, missing: true, perms: [] };
    var me = Object.assign(r.data, { user: s.user, perms: [] });
    // What this person's roles let them do (set per role on the Dashboard). Admin can do everything.
    if (me.status === 'approved') { var pr = await A.sb.rpc('my_perms'); me.perms = (!pr.error && pr.data) || (me.role === 'admin' ? ['events', 'briefings', 'bios', 'members', 'roles'] : []); }
    return me;
  };
  A.isApproved = function (p) { return !!p && p.status === 'approved'; };
  A.isAdmin = function (p) { return A.isApproved(p) && p.role === 'admin'; };
  A.can = function (p, perm) { return A.isApproved(p) && (p.perms || []).indexOf(perm) >= 0; };
  A.canDash = function (p) { return A.isApproved(p) && (p.perms || []).length > 0; };
  // The permissions a role can be given, in the order the Dashboard lists them.
  A.PERMS = [['events', 'Create, edit and delete events and timers'], ['briefings', 'Post and delete briefings'], ['bios', 'Edit anyone\'s bio'], ['members', 'Approve sign-ups and change members\' roles']];

  A.signOut = async function () {
    if (A.sb) await A.sb.auth.signOut();
    location.href = A.url('');
  };

  // Tiny DOM helpers.
  A.el = function (tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  };
  A.avatar = function (p) {
    if (p && p.avatar_url) { var i = A.el('img', 'av'); i.src = p.avatar_url; i.alt = ''; i.referrerPolicy = 'no-referrer'; return i; }
    return A.el('span', 'av', ((p && p.display_name) || '?').trim().charAt(0).toUpperCase());
  };
  // 228th callsign: the rank designation from the site's rank list, a dash, four numbers, then "Nickname".
  // The designations come from content.json (ranks[].abbr) so they follow the rank list; these are the fallback.
  A.prefixes = ['CC', 'CM', 'CPT', 'C1L', 'C2L', 'CCM', 'CSM', 'CMS', 'CFC', 'CSS', 'CS', 'SCP', 'CP', 'CLC', 'SPC', 'T1C', 'T2C', 'T3C', 'CT', 'CR-C'];
  A.loadPrefixes = function () {
    if (!A._prefixes) A._prefixes = fetch(A.url('content.json'), { cache: 'no-cache' }).then(function (r) { return r.json(); }).then(function (c) {
      var list = (c.ranks || []).map(function (r) { return String(r.abbr || '').trim().toUpperCase(); }).filter(Boolean);
      if (list.length) A.prefixes = list.filter(function (x, i) { return list.indexOf(x) === i; });
      A.ranks = (c.ranks || []).filter(function (r) { return r.name; });
    }).catch(function () {});
    return A._prefixes;
  };
  // Fills a <select> with every rank on the rank list, grouped, keeping `current` selected.
  A.fillRanks = function (sel, current) {
    return A.loadPrefixes().then(function () {
      var ranks = A.ranks || [], groups = {}, order = [];
      sel.innerHTML = '<option value="">Pick your rank</option>';
      ranks.forEach(function (r) { var g = r.group || 'Ranks'; if (!groups[g]) { groups[g] = []; order.push(g); } groups[g].push(r); });
      order.forEach(function (g) {
        var og = document.createElement('optgroup'); og.label = g;
        groups[g].forEach(function (r) { var o = document.createElement('option'); o.value = o.textContent = (r.abbr ? r.abbr + ' ' : '') + r.name; og.appendChild(o); });
        sel.appendChild(og);
      });
      if (current) {
        if (![].some.call(sel.options, function (o) { return o.value === current; })) { var o = document.createElement('option'); o.value = o.textContent = current; sel.appendChild(o); }
        sel.value = current;
      }
    });
  };
  // Splits what someone typed into designation, number and nickname, however loosely they typed it.
  function parts(v) {
    v = String(v || '').replace(/[“”„‟″]/g, '"').replace(/\s+/g, ' ').trim();
    var m = v.match(/^([A-Za-z](?:[A-Za-z0-9]{0,2}[A-Za-z])?(?:\s*-\s*[A-Za-z](?![A-Za-z0-9]))?)(\s*-?\s*)(\d+)(.*)$/);
    if (!m) return { raw: v };
    var nick = m[4].trim(), quoted = /^".*"$/.test(nick) && nick.length > 1;
    return { raw: v, prefix: m[1].replace(/\s+/g, ''), sep: m[2], num: m[3], nickRaw: nick, quoted: quoted, nick: nick.replace(/^"+|"+$/g, '').trim() };
  }
  function titleCase(n) { return n.split(' ').filter(Boolean).map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase(); }).join(' '); }
  // Checks a name against the rules and lists what's wrong, in plain words.
  A.checkCallsign = function (v) {
    var p = parts(v), probs = [], list = A.prefixes;
    if (!p.raw) return { ok: false, problems: ['Type your 228th name, like CT-1234 "Nickname".'] };
    if (!p.prefix) return { ok: false, problems: ['Start with your rank designation letters, then a dash and your 4-digit number, like CT-1234.'] };
    var up = p.prefix.toUpperCase();
    if (list.indexOf(up) < 0) probs.push(up + ' isn\'t a rank designation. Use one from the rank list: ' + list.join(', ') + '.');
    else if (p.prefix !== up) probs.push('Rank designation letters must be capital: ' + up + ', not ' + p.prefix + '.');
    if (p.sep !== '-') probs.push(p.sep.indexOf('-') < 0 ? 'Missing the dash between ' + up + ' and your number.' : 'No spaces around the dash.');
    if (p.num.length !== 4) probs.push('Your designation number must be exactly 4 digits.');
    if (!p.nick) probs.push('Missing your nickname in quotes after the number, like "Flanker".');
    else {
      if (!p.quoted) probs.push('Missing quotation marks around your nickname, i.e. "' + titleCase(p.nick) + '".');
      if (!/^[A-Za-z0-9][A-Za-z0-9 .'-]{0,23}$/.test(p.nick)) probs.push('Nicknames can only use letters, numbers, spaces, dots, dashes and apostrophes (24 at most).');
      else if (p.nick !== titleCase(p.nick)) probs.push('Each word of your nickname starts with a capital letter and the rest is lowercase: "' + titleCase(p.nick) + '".');
    }
    if (p.raw !== up + '-' + p.num + ' "' + p.nick + '"' && !probs.length) probs.push('Use exactly one space between your number and the nickname.');
    return { ok: !probs.length, problems: probs, name: probs.length ? null : p.raw };
  };
  // Best-effort tidy-up when someone taps off the box: T2c-1234 minxy -> T2C-1234 "Minxy". Only fixes what's safe to guess.
  A.fixCallsign = function (v) {
    var p = parts(v);
    if (!p.prefix || !p.nick || p.num.length !== 4 || A.prefixes.indexOf(p.prefix.toUpperCase()) < 0) return p.raw;
    return p.prefix.toUpperCase() + '-' + p.num + ' "' + titleCase(p.nick) + '"';
  };
  // Live check on a name input: green when right, red with what's missing when wrong, auto-fixed on blur.
  A.watchCallsign = function (input, hint) {
    var help = hint.textContent;
    function show() {
      if (!input.value.trim()) { input.classList.remove('good', 'bad'); hint.className = 'hint'; hint.textContent = help; return; }
      var c = A.checkCallsign(input.value);
      input.classList.toggle('good', c.ok); input.classList.toggle('bad', !c.ok);
      hint.className = 'hint ' + (c.ok ? 'good' : 'bad');
      // Lead with the tap-off fix while they're typing, so they try that before reading the list.
      var typing = document.activeElement === input;
      hint.textContent = c.ok ? 'Looks good.' : (typing ? 'Tap off this box and the website will try to format it for you. If it stays red:\n' : '') + c.problems.join('\n');
    }
    input.addEventListener('input', show);
    input.addEventListener('blur', function () { if (input.value.trim()) input.value = A.fixCallsign(input.value); show(); });
    A.loadPrefixes().then(show);
    return show;
  };
  // Returns the tidied name, or null if it doesn't fit.
  A.callsign = function (v) { var c = A.checkCallsign(A.fixCallsign(v)); return c.ok ? c.name : null; };
  A.callsignHelp = 'Use your 228th name, like CT-1234 "Nickname": your rank designation, a dash, your four numbers, then your nickname in quotes.';
  A.numberTaken = async function (name) {
    var r = await A.sb.rpc('number_taken', { num: name.match(/-(\d{4}) /)[1] });
    return !r.error && r.data === true;
  };
  // Events: where each one shows, a readable start time, and live countdowns.
  A.VIS = { public: 'Public site', private: 'Members only', both: 'Public + members' };
  A.EVENT_LIVE_MS = 4 * 3600e3; // an event stays up, marked live, for 4 hours after it starts
  // When an event next starts. A weekly one rolls forward 7 days at a time once it has finished.
  A.nextStart = function (ev) {
    var t = Date.parse(ev.starts_at || ev.start), wk = 7 * 864e5, now = Date.now();
    if (ev.repeats_weekly && t + A.EVENT_LIVE_MS <= now) t += Math.ceil((now - A.EVENT_LIVE_MS - t) / wk) * wk;
    if (ev.repeats_weekly && t + A.EVENT_LIVE_MS <= now) t += wk;
    return t;
  };
  A.when = function (t) {
    var d = new Date(t);
    try { return d.toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' }); } catch (e) { return d.toString(); }
  };
  A.countdown = function (ms) {
    if (ms <= 0) return 'LIVE NOW';
    var s = Math.floor(ms / 1000), p = function (n) { return String(n).padStart(2, '0'); };
    return (s >= 86400 ? Math.floor(s / 86400) + 'd ' : '') + p(Math.floor(s % 86400 / 3600)) + ':' + p(Math.floor(s % 3600 / 60)) + ':' + p(s % 60);
  };
  // Any element with data-until (a start time in ms) keeps its text counting down.
  A.tickCountdowns = function () {
    function run() { document.querySelectorAll('[data-until]').forEach(function (n) { var ms = +n.dataset.until - Date.now(); n.textContent = A.countdown(ms); n.classList.toggle('live', ms <= 0); }); }
    run(); if (!A._ticking) A._ticking = setInterval(run, 1000);
  };
  A.date = function (d) { return d ? new Date(d).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : ''; };

  // Fill the page header's nav for this person. `current` is 'members' | 'dashboard' | 'login' | 'account' | 'org'.
  A.header = function (p, current) {
    var nav = document.getElementById('acct-nav');
    if (!nav) return;
    nav.textContent = '';
    function link(href, text, key) {
      var a = A.el('a', null, text); a.href = A.url(href);
      if (key === current) a.setAttribute('aria-current', 'page');
      nav.appendChild(a);
    }
    link('', 'Home');
    if (p) {
      if (A.canDash(p)) link('dashboard/', 'Dashboard', 'dashboard');
      link('members/', 'Members', 'members');
      link('org/', 'Org', 'org');
      var out = A.el('button', null, 'Log out'); out.type = 'button'; out.onclick = A.signOut; nav.appendChild(out);
    } else {
      link('org/', 'Org', 'org');
      link('login/', 'Log in', 'login');
    }
  };

  A.fail = function (box, err) {
    console.error(err);
    if (box) { box.className = 'msg'; box.textContent = (err && (err.message || err.error_description)) || 'Something went wrong. Try again.'; }
  };
})();
