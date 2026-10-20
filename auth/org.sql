-- 228th Black Skulls Corps: org structure add-on.
-- Units (Corps > HICOM > divisions > battalions > companies > platoons > squads > teams), positions you fill with members,
-- qualifications / MOS / medals, delegated access for members who aren't Admin, and a change log.
-- Admin and High-Com can change everything. Nothing posts to Discord. The "_as" functions are kept so a bot can be added later.
--
-- Run auth/setup.sql first. Then paste this whole file into Supabase > SQL Editor > New query and press Run.
-- Safe to run again after updates: it never deletes your units, positions or assignments.

-- ---------------------------------------------------------------------------------------------------------------
-- Ranks vs. other roles. The roles table already holds Admin, High-Com and the rank ladder.
-- is_rank marks the ladder so Promote / Demote know which one to swap. abbr is the short form (CPT, CS, CT...).
alter table public.roles add column if not exists is_rank boolean not null default true;
alter table public.roles add column if not exists abbr text;
update public.roles set is_rank = false where name in ('admin', 'high-com');
update public.roles r set abbr = v.abbr from (values
  ('marshal-commander',''),('senior-commander','CC'),('battalion-commander','CC'),('commander','CC'),('major','CM'),
  ('captain','CPT'),('first-lieutenant','C1L'),('second-lieutenant','C2L'),('command-sergeant-major','CCM'),
  ('sergeant-major','CSM'),('master-sergeant','CMS'),('sergeant-first-class','CFC'),('staff-sergeant','CSS'),
  ('sergeant','CS'),('senior-corporal','SCP'),('corporal','CP'),('lance-corporal','CLC'),('specialist','SPC'),
  ('trooper-1st-class','T1C'),('trooper-2nd-class','T2C'),('trooper-3rd-class','T3C'),('shiny','CT'),('cadet','CR-C')
) as v(name, abbr) where r.name = v.name and r.abbr is null;

-- Discord account link, set by the bot's /link command.
alter table public.profiles add column if not exists discord_id text;
create unique index if not exists profiles_discord_id_key on public.profiles (discord_id) where discord_id is not null;

-- ---------------------------------------------------------------------------------------------------------------
-- Tables
create table if not exists public.org_units (
  id         bigint generated always as identity primary key,
  parent_id  bigint references public.org_units on delete restrict,
  name       text not null check (length(btrim(name)) between 1 and 60),
  kind       text not null default 'unit',      -- corps, command, division, smu, socom, battalion, company, platoon, troop, squad, team, section
  callsign   text,                              -- Skull, Revenant, Demon Alpha...
  tier       text,                              -- Tier 1, Tier 2, Entry...
  badge      text,                              -- image path on the site, like images/mos/commando.webp
  about      text,
  sort       int  not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists org_units_parent on public.org_units (parent_id);

create table if not exists public.org_positions (
  id        bigint generated always as identity primary key,
  unit_id   bigint not null references public.org_units on delete cascade,
  title     text not null check (length(btrim(title)) between 1 and 60),
  callsign  text,                               -- Demon 1, Alpha 1-1...
  min_rank  text references public.roles(name) on update cascade on delete set null,  -- shown as a warning, not enforced
  grants    text[] not null default '{}',       -- access the holder gets inside this unit (only Admin can set these)
  sort      int  not null default 0,
  holder    uuid references public.profiles on delete set null,
  since     timestamptz
);
create index if not exists org_positions_unit on public.org_positions (unit_id);
create index if not exists org_positions_holder on public.org_positions (holder);

-- Qualifications, MOS and medals members can hold.
create table if not exists public.quals (
  id     bigint generated always as identity primary key,
  name   text not null unique,
  kind   text not null default 'qual' check (kind in ('mos', 'qual', 'medal')),
  grp    text,
  about  text,
  sort   int not null default 0
);
create table if not exists public.member_quals (
  member   uuid   not null references public.profiles on delete cascade,
  qual     bigint not null references public.quals on delete cascade,
  given_at timestamptz not null default now(),
  given_by uuid,
  primary key (member, qual)
);

-- Access for people who aren't Admin. Give a permission to one member or to everyone with a role,
-- everywhere (unit_id null) or only inside one unit and everything under it.
create table if not exists public.org_grants (
  id      bigint generated always as identity primary key,
  member  uuid references public.profiles on delete cascade,
  role    text references public.roles(name) on update cascade on delete cascade,
  perm    text not null check (perm in ('members.approve', 'ranks.set', 'quals.set', 'positions.assign', 'org.edit')),
  unit_id bigint references public.org_units on delete cascade,
  check ((member is null) <> (role is null))
);

-- Every change, newest first.
create table if not exists public.org_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      uuid,
  actor_name text,
  via        text not null default 'site',
  action     text not null,
  summary    text not null,
  color      int
);

create table if not exists public.discord_links (
  code       text primary key,
  member     uuid not null references public.profiles on delete cascade,
  expires_at timestamptz not null
);

alter table public.org_units     enable row level security;
alter table public.org_positions enable row level security;
alter table public.quals         enable row level security;
alter table public.member_quals  enable row level security;
alter table public.org_grants    enable row level security;
alter table public.org_log       enable row level security;
alter table public.discord_links enable row level security;
-- Everything below goes through the functions, which check access. Nothing is readable or writable directly.
revoke all on public.org_units, public.org_positions, public.quals, public.member_quals, public.org_grants,
  public.org_log, public.discord_links from anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- Helpers. Every "_as" function takes the acting member as its first argument; the website calls the short
-- wrappers further down (which pass auth.uid()), and the Discord bot calls the "_as" versions with the server key.

create or replace function public.org_is_admin(actor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = actor and status = 'approved' and role = 'admin');
$$;

-- Admin and High-Com: full access to the org.
create or replace function public.org_is_command(actor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = actor and status = 'approved' and all_roles && array['admin', 'high-com']);
$$;

create or replace function public.org_rank_of(m uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select max(r.rank) from profiles p join roles r on r.name = any(p.all_roles) and r.is_rank where p.id = m), 0);
$$;

create or replace function public.org_rank_name(m uuid) returns text
language sql stable security definer set search_path = public as $$
  select r.name from profiles p join roles r on r.name = any(p.all_roles) and r.is_rank where p.id = m order by r.rank desc limit 1;
$$;

create or replace function public.org_ancestors(u bigint) returns bigint[]
language sql stable security definer set search_path = public as $$
  with recursive up(id, parent_id, depth) as (
    select id, parent_id, 0 from org_units where id = u
    union all
    select x.id, x.parent_id, up.depth + 1 from org_units x join up on x.id = up.parent_id where up.depth < 50
  )
  select coalesce(array_agg(id), '{}') from up;
$$;

-- Can this member use a permission on this unit (null = everywhere)?
-- Yes if they're Admin, have a grant (for them or one of their roles) that covers the unit,
-- or hold a position whose built-in access covers it.
create or replace function public.org_can(actor uuid, p_perm text, p_unit bigint) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare mine text[]; path bigint[];
begin
  if actor is null then return false; end if;
  if org_is_command(actor) then return true; end if;
  select all_roles into mine from profiles where id = actor and status = 'approved';
  if mine is null then return false; end if;
  path := case when p_unit is null then '{}'::bigint[] else org_ancestors(p_unit) end;
  return exists (
    select 1 from org_grants g
    where g.perm = p_perm and (g.member = actor or g.role = any(mine))
      and (g.unit_id is null or g.unit_id = any(path))
  ) or (p_unit is not null and exists (
    select 1 from org_positions p where p.holder = actor and p_perm = any(p.grants) and p.unit_id = any(path)
  ));
end $$;

-- Member-level permissions (ranks, qualifications) are allowed everywhere, or for anyone who holds a
-- position inside a unit the actor's access covers.
create or replace function public.org_can_member(actor uuid, p_perm text, target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select org_can(actor, p_perm, null)
      or exists (select 1 from org_positions p where p.holder = target and org_can(actor, p_perm, p.unit_id));
$$;

create or replace function public.org_need(ok boolean, what text) returns void
language plpgsql immutable as $$
begin
  if not coalesce(ok, false) then raise exception 'You don''t have access to %', what using errcode = '42501'; end if;
end $$;

create or replace function public.org_name(m uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select display_name from profiles where id = m), 'Unknown member');
$$;
-- "Demon 1 · Unit Commander"
create or replace function public.org_pos_label(pid bigint) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(callsign, '') || ' · ', '') || title from org_positions where id = pid;
$$;
create or replace function public.org_who(m uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(display_name, 'Unknown member') from profiles where id = m;
$$;

create or replace function public.org_note(actor uuid, p_via text, p_action text, p_summary text, p_color int) returns void
language sql security definer set search_path = public as $$
  insert into org_log (actor, actor_name, via, action, summary, color)
  values (actor, org_name(actor), coalesce(p_via, 'site'), p_action, p_summary, p_color);
$$;


-- ---------------------------------------------------------------------------------------------------------------
-- Structure: units
create or replace function public.org_unit_save_as(actor uuid, p_via text, p_id bigint, p_parent bigint, p_name text,
  p_kind text, p_callsign text, p_tier text, p_badge text, p_about text)
returns bigint language plpgsql security definer set search_path = public as $$
declare old org_units; new_id bigint; parent_name text;
begin
  p_name := btrim(coalesce(p_name, ''));
  if p_name = '' then raise exception 'Give the unit a name'; end if;
  if p_id is null then
    perform org_need(case when p_parent is null then org_is_command(actor) else org_can(actor, 'org.edit', p_parent) end, 'add units here');
    insert into org_units (parent_id, name, kind, callsign, tier, badge, about, sort)
    values (p_parent, p_name, coalesce(nullif(btrim(p_kind), ''), 'unit'), nullif(btrim(p_callsign), ''), nullif(btrim(p_tier), ''),
            nullif(btrim(p_badge), ''), nullif(btrim(p_about), ''),
            coalesce((select max(sort) + 1 from org_units where parent_id is not distinct from p_parent), 0))
    returning id into new_id;
    select name into parent_name from org_units where id = p_parent;
    perform org_note(actor, p_via, 'Unit added', '**' || p_name || '**' || coalesce(' under ' || parent_name, ''), 14262315);
    return new_id;
  end if;

  select * into old from org_units where id = p_id;
  if not found then raise exception 'That unit no longer exists'; end if;
  perform org_need(org_can(actor, 'org.edit', p_id), 'edit ' || old.name);
  if p_parent is distinct from old.parent_id then
    -- Moving: needs access where it was and where it's going, and can't go inside itself.
    perform org_need(case when old.parent_id is null then org_is_command(actor) else org_can(actor, 'org.edit', old.parent_id) end, 'move ' || old.name);
    perform org_need(case when p_parent is null then org_is_command(actor) else org_can(actor, 'org.edit', p_parent) end, 'move units there');
    if p_parent is not null and p_id = any(org_ancestors(p_parent)) then raise exception 'A unit can''t go inside itself'; end if;
  end if;
  update org_units set parent_id = p_parent, name = p_name, kind = coalesce(nullif(btrim(p_kind), ''), 'unit'),
    callsign = nullif(btrim(p_callsign), ''), tier = nullif(btrim(p_tier), ''), badge = nullif(btrim(p_badge), ''),
    about = nullif(btrim(p_about), ''),
    sort = case when p_parent is distinct from old.parent_id then coalesce((select max(sort) + 1 from org_units where parent_id is not distinct from p_parent), 0) else sort end
  where id = p_id;
  if p_parent is distinct from old.parent_id then
    select name into parent_name from org_units where id = p_parent;
    perform org_note(actor, p_via, 'Unit moved', '**' || p_name || '** now sits under ' || coalesce('**' || parent_name || '**', 'the top level'), 14262315);
  elsif p_name <> old.name then
    perform org_note(actor, p_via, 'Unit renamed', '**' || old.name || '** is now **' || p_name || '**', 14262315);
  end if;
  return p_id;
end $$;

create or replace function public.org_unit_delete_as(actor uuid, p_via text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare u org_units; filled int;
begin
  select * into u from org_units where id = p_id;
  if not found then return; end if;
  perform org_need(case when u.parent_id is null then org_is_command(actor) else org_can(actor, 'org.edit', u.parent_id) end, 'remove ' || u.name);
  if exists (select 1 from org_units where parent_id = p_id) then
    raise exception '% still has units under it. Move or remove those first.', u.name;
  end if;
  select count(*) into filled from org_positions where unit_id = p_id and holder is not null;
  delete from org_units where id = p_id;
  perform org_note(actor, p_via, 'Unit removed', '**' || u.name || '** was removed' ||
    case when filled > 0 then ' (' || filled || ' member' || case when filled = 1 then '' else 's' end || ' unassigned)' else '' end, 14824251);
end $$;

-- Reorder the units that share a parent, or the positions in a unit. Not logged.
create or replace function public.org_order_as(actor uuid, p_what text, p_ids bigint[]) returns void
language plpgsql security definer set search_path = public as $$
declare scope bigint;
begin
  if p_what = 'units' then
    select parent_id into scope from org_units where id = p_ids[1];
    perform org_need(case when scope is null then org_is_command(actor) else org_can(actor, 'org.edit', scope) end, 'reorder these units');
    update org_units u set sort = x.i from unnest(p_ids) with ordinality as x(id, i) where u.id = x.id and u.parent_id is not distinct from scope;
  else
    select unit_id into scope from org_positions where id = p_ids[1];
    perform org_need(org_can(actor, 'org.edit', scope), 'reorder these positions');
    update org_positions p set sort = x.i from unnest(p_ids) with ordinality as x(id, i) where p.id = x.id and p.unit_id = scope;
  end if;
end $$;

-- Structure: positions
create or replace function public.org_position_save_as(actor uuid, p_via text, p_id bigint, p_unit bigint, p_title text,
  p_callsign text, p_min_rank text, p_grants text[])
returns bigint language plpgsql security definer set search_path = public as $$
declare old org_positions; new_id bigint; uname text;
begin
  p_title := btrim(coalesce(p_title, ''));
  if p_title = '' then raise exception 'Give the position a title'; end if;
  p_grants := coalesce(p_grants, '{}');
  if exists (select 1 from unnest(p_grants) g where g not in ('members.approve', 'ranks.set', 'quals.set', 'positions.assign', 'org.edit')) then
    raise exception 'Unknown access type';
  end if;
  select name into uname from org_units where id = p_unit;
  if uname is null then raise exception 'That unit no longer exists'; end if;
  perform org_need(org_can(actor, 'org.edit', p_unit), 'edit positions in ' || uname);
  if p_id is null then
    if cardinality(p_grants) > 0 and not org_is_command(actor) then raise exception 'Only Admin or High-Com can give a position built-in access'; end if;
    insert into org_positions (unit_id, title, callsign, min_rank, grants, sort)
    values (p_unit, p_title, nullif(btrim(p_callsign), ''), nullif(p_min_rank, ''), p_grants,
            coalesce((select max(sort) + 1 from org_positions where unit_id = p_unit), 0))
    returning id into new_id;
    perform org_note(actor, p_via, 'Position added', '**' || coalesce(nullif(btrim(p_callsign), '') || ' · ', '') || p_title || '** in ' || uname, 14262315);
    return new_id;
  end if;
  select * into old from org_positions where id = p_id;
  if not found then raise exception 'That position no longer exists'; end if;
  perform org_need(org_can(actor, 'org.edit', old.unit_id), 'edit this position');
  if p_grants is distinct from old.grants and not org_is_command(actor) then raise exception 'Only Admin or High-Com can change a position''s built-in access'; end if;
  update org_positions set unit_id = p_unit, title = p_title, callsign = nullif(btrim(p_callsign), ''),
    min_rank = nullif(p_min_rank, ''), grants = p_grants,
    sort = case when p_unit <> old.unit_id then coalesce((select max(sort) + 1 from org_positions where unit_id = p_unit), 0) else sort end
  where id = p_id;
  if p_unit <> old.unit_id then
    perform org_note(actor, p_via, 'Position moved', '**' || org_pos_label(p_id) || '** moved to ' || uname, 14262315);
  end if;
  return p_id;
end $$;

create or replace function public.org_position_delete_as(actor uuid, p_via text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare p org_positions; label text; uname text;
begin
  select * into p from org_positions where id = p_id;
  if not found then return; end if;
  perform org_need(org_can(actor, 'org.edit', p.unit_id), 'remove this position');
  label := org_pos_label(p_id);
  select name into uname from org_units where id = p.unit_id;
  delete from org_positions where id = p_id;
  perform org_note(actor, p_via, 'Position removed', '**' || label || '** in ' || uname || ' was removed' ||
    coalesce(' (' || org_who(p.holder) || ' unassigned)', ''), 14824251);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- People: fill a position, set rank, qualifications, approve sign-ups.

-- p_member null empties the position.
create or replace function public.org_assign_as(actor uuid, p_via text, p_position bigint, p_member uuid) returns text
language plpgsql security definer set search_path = public as $$
declare p org_positions; uname text; g text; warn text := '';
begin
  select * into p from org_positions where id = p_position;
  if not found then raise exception 'That position no longer exists'; end if;
  select name into uname from org_units where id = p.unit_id;
  perform org_need(org_can(actor, 'positions.assign', p.unit_id), 'fill positions in ' || uname);
  if p.holder is not distinct from p_member then return ''; end if;
  if p_member is not null then
    if not exists (select 1 from profiles where id = p_member and status = 'approved') then raise exception 'Only approved members can hold a position'; end if;
    -- A position with built-in access can only be filled by someone who already has that access here.
    foreach g in array p.grants loop
      if not org_can(actor, g, p.unit_id) then raise exception 'This position comes with access you don''t have, so only Admin or someone with that access can fill it'; end if;
    end loop;
  end if;
  update org_positions set holder = p_member, since = case when p_member is null then null else now() end where id = p_position;
  if p_member is null then
    perform org_note(actor, p_via, 'Position vacated', org_who(p.holder) || ' is no longer **' || org_pos_label(p_position) || '** in ' || uname, 9343635);
  else
    if p.min_rank is not null and org_rank_of(p_member) < (select rank from roles where name = p.min_rank) then
      warn := (select label from roles where name = p.min_rank);
    end if;
    perform org_note(actor, p_via, 'Position filled', org_who(p_member) || ' is now **' || org_pos_label(p_position) || '** in ' || uname ||
      coalesce(' (replacing ' || org_who(p.holder) || ')', '') || case when warn <> '' then E'\n-# Below the ' || warn || ' this position calls for' else '' end, 4177770);
  end if;
  return warn;  -- non-empty: the member is below the position's rank (allowed, but worth knowing)
end $$;

create or replace function public.org_set_rank_as(actor uuid, p_via text, p_member uuid, p_rank text) returns void
language plpgsql security definer set search_path = public as $$
declare t profiles; old_name text; old_rank int; new_rank int; new_label text; old_label text; mine int;
begin
  select * into t from profiles where id = p_member;
  if not found or t.status <> 'approved' then raise exception 'That member isn''t approved'; end if;
  select rank, label into new_rank, new_label from roles where name = p_rank and is_rank;
  if new_rank is null then raise exception 'That isn''t a rank'; end if;
  perform org_need(org_can_member(actor, 'ranks.set', p_member), 'change ' || coalesce(t.display_name, 'this member') || '''s rank');
  old_name := org_rank_name(p_member);
  old_rank := org_rank_of(p_member);
  if old_name = p_rank then return; end if;
  if org_is_admin(p_member) and not org_is_admin(actor) then raise exception 'Only Admin can change an Admin''s rank'; end if;
  if actor = p_member and not org_is_admin(actor) then raise exception 'You can''t change your own rank'; end if;
  if not org_is_command(actor) then
    mine := org_rank_of(actor);
    if old_rank >= mine then raise exception 'You can only change the rank of members below you'; end if;
    if new_rank >= mine then raise exception 'You can only give ranks below your own'; end if;
  end if;
  update profiles set all_roles = array(select x from unnest(all_roles) x join roles r on r.name = x where not r.is_rank) || p_rank
  where id = p_member;
  select label into old_label from roles where name = old_name;
  perform org_note(actor, p_via, case when new_rank > old_rank then 'Promotion' else 'Demotion' end,
    org_who(p_member) || ': ' || coalesce(old_label, 'no rank') || ' → **' || new_label || '**',
    case when new_rank > old_rank then 4177770 else 14824251 end);
end $$;

-- Move one step up (+1) or down (-1) the rank ladder.
create or replace function public.org_step_rank_as(actor uuid, p_via text, p_member uuid, p_dir int) returns text
language plpgsql security definer set search_path = public as $$
declare cur int; nxt text;
begin
  cur := org_rank_of(p_member);
  if p_dir > 0 then select name into nxt from roles where is_rank and rank > cur order by rank asc limit 1;
  else select name into nxt from roles where is_rank and rank < cur order by rank desc limit 1; end if;
  if nxt is null then raise exception '% is already at the % rank', org_name(p_member), case when p_dir > 0 then 'top' else 'bottom' end; end if;
  perform org_set_rank_as(actor, p_via, p_member, nxt);
  return (select label from roles where name = nxt);
end $$;

create or replace function public.org_qual_as(actor uuid, p_via text, p_member uuid, p_qual bigint, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare q quals; had boolean;
begin
  select * into q from quals where id = p_qual;
  if not found then raise exception 'That qualification no longer exists'; end if;
  if not exists (select 1 from profiles where id = p_member and status = 'approved') then raise exception 'That member isn''t approved'; end if;
  perform org_need(org_can_member(actor, 'quals.set', p_member), 'give or remove qualifications for ' || org_name(p_member));
  if actor = p_member and not org_is_admin(actor) then raise exception 'You can''t give or remove your own qualifications and medals'; end if;
  had := exists (select 1 from member_quals where member = p_member and qual = p_qual);
  if p_on = had then return; end if;
  if p_on then
    insert into member_quals (member, qual, given_by) values (p_member, p_qual, actor);
    perform org_note(actor, p_via, case q.kind when 'medal' then 'Medal awarded' when 'mos' then 'MOS added' else 'Qualification earned' end,
      org_who(p_member) || ' — **' || q.name || '**', case q.kind when 'medal' then 14262315 else 4177770 end);
  else
    delete from member_quals where member = p_member and qual = p_qual;
    perform org_note(actor, p_via, case q.kind when 'medal' then 'Medal removed' when 'mos' then 'MOS removed' else 'Qualification removed' end,
      org_who(p_member) || ' — ' || q.name, 9343635);
  end if;
end $$;

-- Qualification list (needs org.edit everywhere).
create or replace function public.org_qual_save_as(actor uuid, p_via text, p_id bigint, p_name text, p_kind text, p_grp text, p_about text)
returns bigint language plpgsql security definer set search_path = public as $$
declare new_id bigint;
begin
  perform org_need(org_can(actor, 'org.edit', null), 'edit the qualification list');
  p_name := btrim(coalesce(p_name, ''));
  if p_name = '' then raise exception 'Give it a name'; end if;
  if p_id is null then
    insert into quals (name, kind, grp, about, sort) values (p_name, coalesce(p_kind, 'qual'), nullif(btrim(p_grp), ''), nullif(btrim(p_about), ''),
      coalesce((select max(sort) + 1 from quals), 0)) returning id into new_id;
    return new_id;
  end if;
  update quals set name = p_name, kind = coalesce(p_kind, kind), grp = nullif(btrim(p_grp), ''), about = nullif(btrim(p_about), '') where id = p_id;
  return p_id;
end $$;
create or replace function public.org_qual_delete_as(actor uuid, p_via text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform org_need(org_can(actor, 'org.edit', null), 'edit the qualification list');
  delete from quals where id = p_id;
end $$;

-- Discord link: the website makes a code, the member types /link <code> in Discord.
create or replace function public.org_link_as(p_discord_id text, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  delete from discord_links where expires_at < now();
  select member into m from discord_links where code = upper(btrim(p_code));
  if m is null then raise exception 'That code didn''t work. Codes last 15 minutes; get a new one on the Org page.'; end if;
  update profiles set discord_id = null where discord_id = p_discord_id and id <> m;
  update profiles set discord_id = p_discord_id where id = m;
  delete from discord_links where member = m;
  return org_name(m);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Website wrappers (use the signed-in member).
create or replace function public.org_unit_save(p_id bigint, p_parent bigint, p_name text, p_kind text, p_callsign text, p_tier text, p_badge text, p_about text)
returns bigint language sql security definer set search_path = public as $$ select org_unit_save_as(auth.uid(), 'site', p_id, p_parent, p_name, p_kind, p_callsign, p_tier, p_badge, p_about) $$;
create or replace function public.org_unit_delete(p_id bigint) returns void
language sql security definer set search_path = public as $$ select org_unit_delete_as(auth.uid(), 'site', p_id) $$;
create or replace function public.org_order(p_what text, p_ids bigint[]) returns void
language sql security definer set search_path = public as $$ select org_order_as(auth.uid(), p_what, p_ids) $$;
create or replace function public.org_position_save(p_id bigint, p_unit bigint, p_title text, p_callsign text, p_min_rank text, p_grants text[])
returns bigint language sql security definer set search_path = public as $$ select org_position_save_as(auth.uid(), 'site', p_id, p_unit, p_title, p_callsign, p_min_rank, p_grants) $$;
create or replace function public.org_position_delete(p_id bigint) returns void
language sql security definer set search_path = public as $$ select org_position_delete_as(auth.uid(), 'site', p_id) $$;
create or replace function public.org_assign(p_position bigint, p_member uuid) returns text
language sql security definer set search_path = public as $$ select org_assign_as(auth.uid(), 'site', p_position, p_member) $$;
create or replace function public.org_set_rank(p_member uuid, p_rank text) returns void
language sql security definer set search_path = public as $$ select org_set_rank_as(auth.uid(), 'site', p_member, p_rank) $$;
create or replace function public.org_qual(p_member uuid, p_qual bigint, p_on boolean) returns void
language sql security definer set search_path = public as $$ select org_qual_as(auth.uid(), 'site', p_member, p_qual, p_on) $$;
create or replace function public.org_qual_save(p_id bigint, p_name text, p_kind text, p_grp text, p_about text) returns bigint
language sql security definer set search_path = public as $$ select org_qual_save_as(auth.uid(), 'site', p_id, p_name, p_kind, p_grp, p_about) $$;
create or replace function public.org_qual_delete(p_id bigint) returns void
language sql security definer set search_path = public as $$ select org_qual_delete_as(auth.uid(), 'site', p_id) $$;

create or replace function public.org_link_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if not exists (select 1 from profiles where id = auth.uid() and status = 'approved') then raise exception 'Only approved members can link Discord'; end if;
  delete from discord_links where member = auth.uid() or expires_at < now();
  c := upper(substr(md5(gen_random_uuid()::text), 1, 6));
  insert into discord_links (code, member, expires_at) values (c, auth.uid(), now() + interval '15 minutes');
  return c;
end $$;
create or replace function public.org_unlink() returns void
language sql security definer set search_path = public as $$ update profiles set discord_id = null where id = auth.uid() $$;

-- Access (Admin only).
create or replace function public.org_grant_add(p_member uuid, p_role text, p_perm text, p_unit bigint) returns void
language plpgsql security definer set search_path = public as $$
declare who text; uname text;
begin
  if not org_is_command(auth.uid()) then raise exception 'Only Admin and High-Com can change access'; end if;
  insert into org_grants (member, role, perm, unit_id) values (p_member, nullif(p_role, ''), p_perm, p_unit);
  who := coalesce(org_who(p_member), (select 'Everyone with ' || label from roles where name = p_role));
  select name into uname from org_units where id = p_unit;
  perform org_note(auth.uid(), 'site', 'Access given', who || ' can now **' || case p_perm
    when 'members.approve' then 'approve sign-ups' when 'ranks.set' then 'promote and demote'
    when 'quals.set' then 'give qualifications and medals' when 'positions.assign' then 'fill positions'
    else 'edit the structure' end || '** ' || coalesce('in ' || uname, 'everywhere'), 5793266);
end $$;
create or replace function public.org_grant_remove(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not org_is_command(auth.uid()) then raise exception 'Only Admin and High-Com can change access'; end if;
  delete from org_grants where id = p_id;
end $$;


-- ---------------------------------------------------------------------------------------------------------------
-- Reading

-- The whole chart. Anyone can see the structure; names of who fills each position are for approved members only.
create or replace function public.org_chart() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare is_member boolean := exists (select 1 from profiles where id = auth.uid() and status = 'approved');
begin
  return jsonb_build_object(
    'member', is_member,
    'units', coalesce((select jsonb_agg(to_jsonb(u) order by u.parent_id nulls first, u.sort, u.id) from org_units u), '[]'),
    'positions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'unit_id', p.unit_id, 'title', p.title, 'callsign', p.callsign, 'min_rank', p.min_rank,
        'grants', p.grants, 'sort', p.sort, 'filled', p.holder is not null,
        'holder', case when is_member then p.holder end,
        'since', case when is_member then p.since end) order by p.unit_id, p.sort, p.id) from org_positions p), '[]'),
    'ranks', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'label', label, 'abbr', abbr, 'rank', rank, 'is_rank', is_rank) order by rank desc) from roles), '[]'),
    'quals', coalesce((select jsonb_agg(to_jsonb(q) order by q.kind, q.sort, q.id) from quals q), '[]')
  );
end $$;

-- Approved members with rank, qualifications and whether Discord is linked. Approved members only. No emails.
create or replace function public.org_people() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from profiles where id = auth.uid() and status = 'approved') then
    coalesce((select jsonb_agg(jsonb_build_object(
      'id', p.id, 'display_name', p.display_name, 'avatar_url', p.avatar_url, 'all_roles', p.all_roles,
      'rank', org_rank_name(p.id), 'linked', p.discord_id is not null, 'joined', p.approved_at,
      'quals', coalesce((select jsonb_agg(m.qual) from member_quals m where m.member = p.id), '[]')
    ) order by org_rank_of(p.id) desc, p.display_name) from profiles p where p.status = 'approved'), '[]')
  else '[]'::jsonb end;
$$;

-- What the signed-in member can do. units_for lists the unit ids each permission covers (null = everywhere).
create or replace function public.org_my_access() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me profiles; admin boolean;
begin
  select * into me from profiles where id = auth.uid();
  if me.id is null then return jsonb_build_object('signed_in', false); end if;
  admin := org_is_command(me.id);  -- "admin" here means full org access (Admin or High-Com)
  return jsonb_build_object(
    'signed_in', true, 'approved', me.status = 'approved', 'admin', admin, 'owner', org_is_admin(me.id), 'id', me.id,
    'linked', me.discord_id is not null, 'rank', org_rank_of(me.id),
    'grants', case when me.status <> 'approved' then '[]'::jsonb else coalesce((
      select jsonb_agg(distinct jsonb_build_object('perm', perm, 'unit_id', unit_id)) from (
        select g.perm, g.unit_id from org_grants g where g.member = me.id or g.role = any(me.all_roles)
        union
        select unnest(p.grants), p.unit_id from org_positions p where p.holder = me.id
      ) x), '[]') end
  );
end $$;

create or replace function public.org_log_list(p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (org_is_command(auth.uid()) or exists (select 1 from org_grants g join profiles p on p.id = auth.uid() and p.status = 'approved'
            where g.member = p.id or g.role = any(p.all_roles))
          or exists (select 1 from org_positions where holder = auth.uid() and cardinality(grants) > 0)) then
    return '[]'::jsonb;
  end if;
  return coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (select * from org_log order by id desc limit least(p_limit, 500)) l), '[]');
end $$;

create or replace function public.org_grants_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not org_is_command(auth.uid()) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'member', g.member, 'member_name', p.display_name,
    'role', g.role, 'role_label', r.label, 'perm', g.perm, 'unit_id', g.unit_id) order by g.id)
    from org_grants g left join profiles p on p.id = g.member left join roles r on r.name = g.role), '[]');
end $$;

-- Removed from Terminator's version: Discord posting and a second sign-up approval screen (approvals stay on the Dashboard).
drop trigger if exists org_log_discord on public.org_log;
drop function if exists public.org_log_to_discord();
drop function if exists public.org_settings_set(text, text);
drop function if exists public.org_settings_get();
drop function if exists public.org_webhook_test();
drop function if exists public.org_approve(uuid, boolean, text);
drop function if exists public.org_approve_as(uuid, text, uuid, boolean, text);
drop function if exists public.org_requests();
drop table if exists public.org_settings;

-- ---------------------------------------------------------------------------------------------------------------
-- Who can call what. Website functions: signed-in members (each checks access itself). "_as" functions: server key only.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'org\_%' or p.proname = 'org_need') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname like '%\_as' or f.proname in ('org_is_admin', 'org_rank_of', 'org_rank_name', 'org_ancestors', 'org_can', 'org_can_member',
                                               'org_name', 'org_pos_label', 'org_who', 'org_note', 'org_need', 'org_is_command') then
      execute format('grant execute on function %s to service_role', f.sig);
    else
      execute format('grant execute on function %s to authenticated, service_role', f.sig);
    end if;
  end loop;
end $$;
grant execute on function public.org_chart() to anon;  -- the public can see the structure (not names)

-- ---------------------------------------------------------------------------------------------------------------
-- Starting structure. Only runs on an empty org; edit everything afterwards from org/manage/.
do $$
declare corps bigint; hicom bigint; demons bigint; troop bigint; echelon bigint; arma bigint; vrc bigint;
        socom bigint; bn bigint; co bigint; plt bigint; t text; i int; j int; k int;
        co_plts text[][];
begin
  if exists (select 1 from org_units) then return; end if;

  insert into org_units (name, kind, about, badge, sort) values ('228th Black Skulls Corps', 'corps',
    'Every platform, every game, every division and every trooper operating under the banner.', 'images/corps-emblem.webp', 0) returning id into corps;
  insert into org_positions (unit_id, title, min_rank, sort) values (corps, 'Marshal Commander', 'marshal-commander', 0);

  insert into org_units (parent_id, name, kind, callsign, about, sort) values (corps, 'High Command', 'command', 'HICOM',
    'Oversees every branch: vision, standards, long-term direction and stability.', 0) returning id into hicom;
  insert into org_positions (unit_id, title, min_rank, grants, sort) values
    (hicom, 'Senior Commander', 'senior-commander', '{}', 0), (hicom, 'Senior Commander', 'senior-commander', '{}', 1), (hicom, 'Senior Commander', 'senior-commander', '{}', 2);

  -- Units that answer only to HICOM.
  insert into org_units (parent_id, name, kind, callsign, tier, badge, about, sort) values (hicom, '228th Demon Commandos', 'smu', 'Demon', 'Tier 1',
    'images/mos/commando.webp', 'The Clone Commandos. Answer only to HICOM, separate from SOCOM.', 0) returning id into demons;
  insert into org_positions (unit_id, title, callsign, grants, sort) values
    (demons, 'Unit Commander', 'Demon 1', '{positions.assign,quals.set,ranks.set,org.edit}', 0),
    (demons, 'Executive Officer', 'Demon 2', '{positions.assign,quals.set}', 1),
    (demons, 'Command Sergeant Major', 'Demon 3', '{positions.assign,quals.set}', 2),
    (demons, 'Operations Officer', 'Demon 4', '{}', 3),
    (demons, 'Communications Chief', 'Demon 5', '{}', 4);
  i := 0;
  foreach t in array array['Alpha', 'Bravo', 'Charlie'] loop
    insert into org_units (parent_id, name, kind, callsign, sort) values (demons, 'Demon ' || t, 'troop', 'Demon ' || t, i) returning id into troop;
    insert into org_positions (unit_id, title, sort) values (troop, 'Troop Commander', 0), (troop, 'Troop Sergeant', 1);
    for j in 1..2 loop
      insert into org_units (parent_id, name, kind, callsign, sort) values (troop, t || ' ' || j, 'team', t || ' ' || j, j) returning id into plt;
      insert into org_positions (unit_id, title, callsign, sort) values (plt, 'Team Leader', t || ' ' || j || '-1', 0);
      for k in 2..5 loop
        insert into org_positions (unit_id, title, callsign, sort) values (plt, 'Operator', t || ' ' || j || '-' || k, k);
      end loop;
    end loop;
    i := i + 1;
  end loop;

  insert into org_units (parent_id, name, kind, callsign, badge, about, sort) values (hicom, 'Echelon', 'smu', 'Night-Stalker',
    'images/mos/echelon.webp', 'Elite two-trooper teams, hand-picked by tryout. Answer only to HICOM.', 1) returning id into echelon;
  insert into org_positions (unit_id, title, callsign, sort) values (echelon, 'Echelon Lead', 'Night-Stalker 1', 0), (echelon, 'Echelon', 'Night-Stalker 2', 1);

  -- Divisions (one per game).
  insert into org_units (parent_id, name, kind, about, sort) values (hicom, 'VRChat Division', 'division', 'The 228th on VRChat.', 2) returning id into vrc;
  insert into org_positions (unit_id, title, sort) values (vrc, 'Division Lead', 0);
  insert into org_units (parent_id, name, kind, about, sort) values (hicom, 'Arma 3 Division', 'division', 'The 228th on Arma 3.', 3) returning id into arma;
  insert into org_positions (unit_id, title, sort) values (arma, 'Division Lead', 0);

  insert into org_units (parent_id, name, kind, about, sort) values (arma, 'SOCOM', 'socom', 'Special Operations Command.', 0) returning id into socom;
  insert into org_positions (unit_id, title, sort) values (socom, 'SOCOM Commander', 0);
  insert into org_units (parent_id, name, kind, callsign, tier, badge, about, sort) values
    (socom, 'ARF', 'smu', 'Hellhound', 'Tier 3', 'images/mos/arf.webp', 'Advanced Recon Force.', 0),
    (socom, 'ARC', 'smu', 'Revenant', 'Tier 2', 'images/mos/arc-2.webp', 'Advanced Recon Commandos.', 1),
    (socom, 'Spec Ops', 'smu', 'Phantom', 'Entry', 'images/mos/spec-ops-2.webp', 'Where troopers start before Assessment and Selection.', 2);
  insert into org_positions (unit_id, title, sort) select id, 'Lead', 0 from org_units where parent_id = socom;

  insert into org_units (parent_id, name, kind, about, sort) values (arma, '228th Battalion', 'battalion', 'Conventional forces.', 1) returning id into bn;
  insert into org_positions (unit_id, title, min_rank, sort) values (bn, 'Battalion Commander', 'battalion-commander', 0), (bn, 'Battalion Sergeant Major', 'sergeant-major', 1);
  -- Starting layout: two big companies, one platoon per conventional MOS. Rearrange freely.
  co_plts := array[
    array['Skull|Conventional|images/mos/conventional.webp', 'Death Angel|Airborne|images/mos/airborne.webp', 'Drowned|Scuba|images/mos/scuba-2.webp', 'Marine|Marine|images/mos/marine.webp'],
    array['Dreadnaught|Armored|images/mos/armored-2.webp', 'Hellrider|BARC|images/mos/barc-3.webp', 'Banshee|Pilot|images/mos/pilot.webp', 'Shatterfield|Combat Engineer|images/mos/engineer.webp']];
  for i in 1..2 loop
    insert into org_units (parent_id, name, kind, sort) values (bn, case i when 1 then '1st Company' else '2nd Company' end, 'company', i) returning id into co;
    insert into org_positions (unit_id, title, min_rank, sort) values (co, 'Company Commander', 'captain', 0), (co, 'First Sergeant', 'master-sergeant', 1);
    for j in 1..4 loop
      insert into org_units (parent_id, name, kind, callsign, badge, sort) values (co,
        (array['1st', '2nd', '3rd', '4th'])[j] || ' Platoon (' || split_part(co_plts[i][j], '|', 2) || ')', 'platoon',
        split_part(co_plts[i][j], '|', 1), nullif(split_part(co_plts[i][j], '|', 3), ''), j) returning id into plt;
      insert into org_positions (unit_id, title, min_rank, sort) values (plt, 'Platoon Leader', 'second-lieutenant', 0), (plt, 'Platoon Sergeant', 'sergeant-first-class', 1);
    end loop;
  end loop;
  insert into org_units (parent_id, name, kind, callsign, badge, about, sort) values (bn, 'Medical Section', 'section', 'Death Surgeon', 'images/mos/medic.webp',
    'Combat medics attached across the battalion.', 3) returning id into plt;
  insert into org_positions (unit_id, title, sort) values (plt, 'Chief Medic', 0);
end $$;

-- Qualifications, MOS and medals (from the site). Adds any that are missing.
insert into public.quals (name, kind, grp, sort)
select v.name, v.kind, v.grp, v.sort from (values
  ('Conventional','mos','Skull',1),('ARC','mos','Revenant',2),('ARF','mos','Hellhound',3),('Airborne','mos','Death Angel',4),
  ('Armored','mos','Dreadnaught',5),('BARC','mos','Hellrider',6),('Commando','mos','Demon',7),('Combat Engineer','mos','Shatterfield',8),
  ('Marine','mos',null,9),('Combat Medic (MOS)','mos','Death Surgeon',10),('Pilot','mos','Banshee',11),('Scuba','mos','Drowned',12),
  ('Spec Ops','mos','Phantom',13),('Echelon','mos','Night-Stalker',14),
  ('Anti-Tank','qual',null,1),('Breacher','qual',null,2),('Combat Medic','qual',null,3),('Stealth','qual',null,4),('EOD','qual',null,5),
  ('RTO','qual',null,6),('Light Weaponry','qual',null,7),('Heavy Weaponry','qual',null,8),('Jetpack','qual',null,9),('Marksman','qual',null,10),
  ('Piloting / Flight','qual',null,11),('Riot','qual',null,12),('SAR','qual',null,13),('SERE','qual',null,14),
  ('Black Skull Star','medal','Valor & Honor',1),('Order of the Crimson Skull','medal','Valor & Honor',2),('Medal of the Fallen Fang','medal','Valor & Honor',3),
  ('Iron Skull Medal','medal','Valor & Honor',4),('Shadow Saber Cross','medal','Valor & Honor',5),('Medal of Bravery','medal','Valor & Honor',6),
  ('28th Campaign Medal','medal','Campaigns & Operations',7),('Siege of Umbara Service Medal','medal','Campaigns & Operations',8),
  ('Outer Rim Expedition Medal','medal','Campaigns & Operations',9),('Black Skulls Defense Medal','medal','Campaigns & Operations',10),
  ('Operation Vanguard Medal','medal','Campaigns & Operations',11),('228th–238th Joint Campaign Medal','medal','Campaigns & Operations',12),
  ('Raid Defense Ribbon','medal','Campaigns & Operations',13),('SpecOps Gateway Medal','medal','MOS & Specialty',14),('ARF Recon Badge','medal','MOS & Specialty',15),
  ('ARC Trooper Cross','medal','MOS & Specialty',16),('Commando Dagger','medal','MOS & Specialty',17),('Echelon Phantom Medal','medal','MOS & Specialty',18),
  ('Combat Medic Skull','medal','MOS & Specialty',19),('Pilot''s Talon','medal','MOS & Specialty',20),('Flame Trooper''s Brand','medal','MOS & Specialty',21),
  ('Galactic Marine Frost Star','medal','MOS & Specialty',22),('Skull Commander''s Medal','medal','Leadership & Service',23),('Iron Mentor Medal','medal','Leadership & Service',24),
  ('Black Skull Instructor Ribbon','medal','Leadership & Service',25),('HICOM Service Medal','medal','Leadership & Service',26),('S-Staff Achievement Medal','medal','Leadership & Service',27),
  ('Loyalty of the 228th Medal','medal','Leadership & Service',28),('Brotherhood of the Skull Ribbon','medal','Leadership & Service',29),('Black Skull Conduct Medal','medal','Leadership & Service',30),
  ('228th Honorable Service','medal','Leadership & Service',31),('Medal of Dedicated Service','medal','Leadership & Service',32),('228th Veteran','medal','Leadership & Service',33),
  ('Builder of the Corps Medal','medal','Community & Creative',34),('Recruiter''s Fang','medal','Community & Creative',35),('Event Guardian Medal','medal','Community & Creative',36),
  ('Discord Sentinel Ribbon','medal','Community & Creative',37),('Ceremonial Honor Guard Medal','medal','Community & Creative',38),('Lorekeeper''s Medal','medal','Community & Creative',39),
  ('Avatar Artisan Medal','medal','Community & Creative',40),('Worldsmith Medal','medal','Community & Creative',41),('Diplomatic Envoy Medal','medal','Community & Creative',42),
  ('Medal of Trade','medal','Community & Creative',43)
) as v(name, kind, grp, sort)
where not exists (select 1 from public.quals);

