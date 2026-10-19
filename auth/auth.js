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
    return r.data ? Object.assign(r.data, { user: s.user }) : { status: 'pending', user: s.user, missing: true };
  };
  A.isApproved = function (p) { return !!p && p.status === 'approved'; };
  A.isAdmin = function (p) { return A.isApproved(p) && p.role === 'admin'; };

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
  // 228th callsign: CT-1234 "Nickname". Returns the tidied name, or null if it doesn't fit.
  A.callsign = function (v) {
    v = String(v || '').replace(/[\u201c\u201d\u201e\u201f\u2033]/g, '"').replace(/\s+/g, ' ').trim();
    var m = v.match(/^([A-Za-z]{2,4})\s*-\s*(\d{4})\s*"\s*([A-Za-z0-9][A-Za-z0-9 .'-]{0,23}?)\s*"$/);
    return m ? m[1].toUpperCase() + '-' + m[2] + ' "' + m[3] + '"' : null;
  };
  A.callsignHelp = 'Use your 228th name, like CT-1234 "Nickname": your letters, a dash, your four numbers, then your nickname in quotes.';
  A.numberTaken = async function (name) {
    var r = await A.sb.rpc('number_taken', { num: name.match(/-(\d{4}) /)[1] });
    return !r.error && r.data === true;
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
      if (A.isAdmin(p)) link('dashboard/', 'Dashboard', 'dashboard');
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
