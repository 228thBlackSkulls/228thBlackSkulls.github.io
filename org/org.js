// Shared helpers for the Org chart (org/) and the Org manager (org/manage/). Needs auth/auth.js first.
(function () {
  var A = window.Auth, O = window.Org = {};

  O.PERMS = [
    { perm: 'positions.assign', label: 'Fill positions', scoped: true },
    { perm: 'ranks.set', label: 'Promote and demote', scoped: true },
    { perm: 'quals.set', label: 'Give qualifications and medals', scoped: true },
    { perm: 'org.edit', label: 'Edit the structure', scoped: true }
  ];
  O.permLabel = function (p) { var x = O.PERMS.find(function (y) { return y.perm === p; }); return x ? x.label : p; };
  O.KINDS = ['corps', 'command', 'division', 'smu', 'socom', 'battalion', 'company', 'platoon', 'troop', 'squad', 'team', 'section', 'unit'];
  O.KIND_LABEL = { corps: 'Corps', command: 'Command', division: 'Division', smu: 'Special unit', socom: 'SOCOM', battalion: 'Battalion',
    company: 'Company', platoon: 'Platoon', troop: 'Troop', squad: 'Squad', team: 'Team', section: 'Section', unit: 'Unit' };
  O.QUAL_KIND = { mos: 'MOS', qual: 'Qualification', medal: 'Medal' };

  async function rpc(name, args) {
    var r = await A.sb.rpc(name, args || {});
    if (r.error) throw r.error;
    return r.data;
  }
  O.rpc = rpc;

  // Load everything a page needs and index it.
  O.load = async function (opts) {
    opts = opts || {};
    var jobs = [rpc('org_chart'), A.session().then(function (s) { return s ? rpc('org_my_access') : { signed_in: false }; })];
    var res = await Promise.all(jobs), chart = res[0], access = res[1] || {};
    var d = { units: chart.units || [], positions: chart.positions || [], ranks: chart.ranks || [], quals: chart.quals || [],
              member: !!chart.member, access: access, people: [] };
    if (d.member) d.people = await rpc('org_people');
    O.index(d);
    return d;
  };

  O.index = function (d) {
    d.unit = {}; d.kids = {}; d.posOf = {}; d.person = {}; d.rank = {}; d.qual = {}; d.heldBy = {};
    d.units.forEach(function (u) { d.unit[u.id] = u; d.kids[u.id] = []; d.posOf[u.id] = []; });
    d.roots = [];
    d.units.forEach(function (u) { (u.parent_id && d.kids[u.parent_id] ? d.kids[u.parent_id] : d.roots).push(u); });
    function bySort(a, b) { return (a.sort - b.sort) || (a.id - b.id); }
    d.roots.sort(bySort); Object.keys(d.kids).forEach(function (k) { d.kids[k].sort(bySort); });
    d.positions.forEach(function (p) {
      if (d.posOf[p.unit_id]) d.posOf[p.unit_id].push(p);
      if (p.holder) (d.heldBy[p.holder] = d.heldBy[p.holder] || []).push(p);
    });
    Object.keys(d.posOf).forEach(function (k) { d.posOf[k].sort(bySort); });
    d.people.forEach(function (p) { d.person[p.id] = p; });
    d.ranks.forEach(function (r) { d.rank[r.name] = r; });
    d.quals.forEach(function (q) { d.qual[q.id] = q; });
    d.ladder = d.ranks.filter(function (r) { return r.is_rank; });
  };

  O.path = function (d, unitId) {
    var out = [], u = d.unit[unitId], guard = 0;
    while (u && guard++ < 50) { out.unshift(u); u = d.unit[u.parent_id]; }
    return out;
  };
  // Every unit under this one (not including it).
  O.descendants = function (d, unitId) {
    var out = [];
    (function walk(id) { (d.kids[id] || []).forEach(function (k) { out.push(k); walk(k.id); }); })(unitId);
    return out;
  };

  // Access, mirroring the database rules (the database has the final say).
  O.can = function (d, perm, unitId) {
    var a = d.access;
    if (!a || !a.approved) return false;
    if (a.admin) return true;
    var path = unitId == null ? [] : O.path(d, unitId).map(function (u) { return u.id; });
    return (a.grants || []).some(function (g) { return g.perm === perm && (g.unit_id == null || path.indexOf(g.unit_id) >= 0); });
  };
  O.canMember = function (d, perm, memberId) {
    if (O.can(d, perm, null)) return true;
    return (d.heldBy[memberId] || []).some(function (p) { return O.can(d, perm, p.unit_id); });
  };
  O.canAnything = function (d) {
    var a = d.access;
    return !!(a && a.approved && (a.admin || (a.grants || []).length));
  };
  O.myRank = function (d) { return (d.access && d.access.rank) || 0; };

  // Labels
  O.posLabel = function (p) { return (p.callsign ? p.callsign + ' · ' : '') + p.title; };
  O.rankOf = function (d, person) { return person && person.rank ? d.rank[person.rank] : null; };
  O.nameOf = function (d, id) { var p = d.person[id]; return p ? (p.display_name || 'Unnamed') : 'Member'; };
  // Other roles a member holds that aren't ranks (Admin, High-Com, Recruiter...).
  O.otherRoles = function (d, person) {
    return (person.all_roles || []).map(function (n) { return d.rank[n]; }).filter(function (r) { return r && !r.is_rank; });
  };

  // Avatar with the nickname's first letter (CT-1234 "Rook" -> R) when there's no picture.
  O.avatar = function (p) {
    if (p && p.avatar_url) return A.avatar(p);
    var n = (p && p.display_name) || '?', m = n.match(/"\s*([^"\s])/);
    return A.el('span', 'av', (m ? m[1] : n.trim().charAt(0) || '?').toUpperCase());
  };

  // A person chip: avatar, name, rank.
  O.personChip = function (d, id, opts) {
    opts = opts || {};
    var p = d.person[id], b = A.el(opts.button ? 'button' : 'span', 'who-chip');
    if (opts.button) { b.type = 'button'; b.dataset.person = id; }
    b.appendChild(O.avatar(p || { display_name: '?' }));
    var t = A.el('span', 'who-text');
    var r = O.rankOf(d, p);
    t.appendChild(A.el('b', null, p ? (p.display_name || 'Unnamed') : 'Member'));
    if (r) t.appendChild(A.el('small', null, r.label));
    b.appendChild(t);
    return b;
  };

  O.badge = function (u) {
    if (u.badge) {
      var i = A.el('img', 'badge'); i.alt = ''; i.loading = 'lazy';
      i.src = /^https?:/.test(u.badge) ? u.badge : A.url(u.badge);
      i.onerror = function () { i.replaceWith(O.badgeMark(u)); };
      return i;
    }
    return O.badgeMark(u);
  };
  O.badgeMark = function (u) {
    var s = A.el('span', 'badge mark', (u.callsign || u.name || '?').replace(/^228th\s+/i, '').trim().charAt(0).toUpperCase());
    s.setAttribute('aria-hidden', 'true');
    return s;
  };

  O.filled = function (d, unitId, deep) {
    var list = [unitId].concat(deep ? O.descendants(d, unitId).map(function (u) { return u.id; }) : []);
    var all = 0, full = 0;
    list.forEach(function (id) { (d.posOf[id] || []).forEach(function (p) { all++; if (p.filled) full++; }); });
    return { all: all, full: full };
  };

  // Status line helper with auto-clear for success.
  O.say = function (box, text, good) {
    box.className = good ? 'msg ok' : 'msg';
    box.textContent = text;
    if (good) setTimeout(function () { if (box.textContent === text) box.textContent = ''; }, 4000);
  };

  })();
