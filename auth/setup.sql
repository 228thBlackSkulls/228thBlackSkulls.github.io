-- 228th Black Skulls Corps: member accounts, approval and roles.
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run. Safe to run again after updates.

-- Roles: Admin, High-Com, then the 228th rank list. "rank" only keeps them in order (higher = listed first); it isn't shown.
-- Admin runs the dashboard. Every briefing picks which roles can see it.
create table if not exists public.roles (
  name  text primary key,
  label text not null,
  rank  int  not null default 10
);
insert into public.roles (name, label, rank) values
  ('admin', 'Admin', 100),
  ('high-com', 'High-Com', 90),
  ('marshal-commander', 'Marshal Commander', 80),
  ('senior-commander', 'Senior Commander', 77),
  ('battalion-commander', 'Battalion Commander', 74),
  ('commander', 'Commander', 71),
  ('major', 'Major', 68),
  ('captain', 'Captain', 65),
  ('first-lieutenant', 'First Lieutenant', 62),
  ('second-lieutenant', 'Second Lieutenant', 59),
  ('command-sergeant-major', 'Command Sergeant Major', 56),
  ('sergeant-major', 'Sergeant Major', 53),
  ('master-sergeant', 'Master Sergeant', 50),
  ('sergeant-first-class', 'Sergeant First Class', 47),
  ('staff-sergeant', 'Staff Sergeant', 44),
  ('sergeant', 'Sergeant', 41),
  ('senior-corporal', 'Senior Corporal', 38),
  ('corporal', 'Corporal', 35),
  ('lance-corporal', 'Lance Corporal', 32),
  ('specialist', 'Specialist', 29),
  ('trooper-1st-class', 'Trooper 1st Class', 26),
  ('trooper-2nd-class', 'Trooper 2nd Class', 23),
  ('trooper-3rd-class', 'Trooper 3rd Class', 20),
  ('shiny', 'Shiny', 17),
  ('cadet', 'Cadet', 14),
  ('member', 'Recruit', 10)
on conflict (name) do nothing;

-- Rank groups: the red dividers on the rank list (Commanding Officer, Senior Officers...). They're roles too, so they can be
-- given to people and carry permissions, but they're never shown as someone's rank. First run only: placed above their ranks.
alter table public.roles add column if not exists divider boolean not null default false;
do $$
declare g record; ord text[]; i int;
begin
  if exists (select 1 from public.roles where divider) then return; end if;
  select array_agg(name order by rank desc) into ord from public.roles where name <> 'admin';
  for g in select * from (values ('commanding-officer', 'Commanding Officer', 'marshal-commander'), ('senior-officers', 'Senior Officers', 'senior-commander'),
      ('junior-officers', 'Junior Officers', 'captain'), ('snco', 'SNCO', 'command-sergeant-major'), ('nco', 'NCO', 'staff-sergeant'),
      ('junior-enlisted', 'Junior Enlisted', 'lance-corporal')) v(name, label, above) loop
    if g.above = any(ord) and not exists (select 1 from public.roles where name = g.name) then
      insert into public.roles (name, label, rank, divider) values (g.name, g.label, 1, true);
      i := array_position(ord, g.above);
      ord := ord[1:i-1] || g.name || ord[i:];
    end if;
  end loop;
  -- Renumber everything in the new order (Admin stays at 100), the same way the Dashboard saves a drag.
  for i in 1..cardinality(ord) loop update public.roles set rank = 100 - i where name = ord[i]; end loop;
end $$;

-- Rank designation letters (CC, CPT, T2C, CR-C...). A member's callsign follows their rank: promote a CT to Corporal and
-- CT-1234 "Nick" becomes CP-1234 "Nick". The Dashboard keeps these in step with the rank list on the edit page.
alter table public.roles add column if not exists abbr text not null default '';
-- The org chart add-on (auth/org.sql) calls the rank ladder is_rank. Rank groups are never on the ladder.
-- Only real ranks are on it: ones with letters, plus Marshal Commander and Recruit. Custom roles (Recruiter...) aren't.
create or replace function public.role_divider_not_rank() returns trigger
language plpgsql as $$ begin
  new.is_rank := not new.divider and (coalesce(new.abbr, '') <> '' or new.name in ('marshal-commander', 'member'));
  return new;
end $$;
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'roles' and column_name = 'is_rank') then
    update public.roles set is_rank = false where is_rank and (divider or (coalesce(abbr, '') = '' and name not in ('marshal-commander', 'member')));
    drop trigger if exists roles_divider_not_rank on public.roles;
    create trigger roles_divider_not_rank before insert or update on public.roles for each row execute function public.role_divider_not_rank();
  end if;
end $$;
alter table public.roles drop constraint if exists roles_abbr_check;
alter table public.roles add constraint roles_abbr_check check (abbr = '' or abbr ~ '^[A-Z][A-Z0-9]{1,3}(-[A-Z])?$');
update public.roles r set abbr = v.abbr from (values ('senior-commander', 'CC'), ('battalion-commander', 'CC'), ('commander', 'CC'),
  ('major', 'CM'), ('captain', 'CPT'), ('first-lieutenant', 'C1L'), ('second-lieutenant', 'C2L'), ('command-sergeant-major', 'CCM'),
  ('sergeant-major', 'CSM'), ('master-sergeant', 'CMS'), ('sergeant-first-class', 'CFC'), ('staff-sergeant', 'CSS'), ('sergeant', 'CS'),
  ('senior-corporal', 'SCP'), ('corporal', 'CP'), ('lance-corporal', 'CLC'), ('specialist', 'SPC'), ('trooper-1st-class', 'T1C'),
  ('trooper-2nd-class', 'T2C'), ('trooper-3rd-class', 'T3C'), ('shiny', 'CT'), ('cadet', 'CR-C')) v(name, abbr)
  where r.name = v.name and r.abbr = '';

-- One profile per account. Everyone starts as pending until an admin approves them.
create table if not exists public.profiles (
  id           uuid primary key references auth.users on delete cascade,
  email        text,
  display_name text,
  discord_name text,
  avatar_url   text,
  note         text,
  status       text not null default 'pending' check (status in ('pending','approved','denied')),
  role         text not null default 'member' references public.roles(name) on update cascade,
  created_at   timestamptz not null default now(),
  approved_at  timestamptz,
  approved_by  uuid
);

-- Members-page posts. visible_to lists the roles that can read it; empty means every approved member.
create table if not exists public.posts (
  id         bigint generated always as identity primary key,
  title      text not null,
  body       text,
  visible_to text[] not null default '{}',
  pinned     boolean not null default false,
  author     uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.posts add column if not exists visible_to text[] not null default '{}';
-- Older installs stored a "lowest rank" instead; turn it into a role list once.
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'posts' and column_name = 'min_role') then
    update public.posts p set visible_to = coalesce((select array_agg(r.name) from public.roles r
      where r.rank >= (select x.rank from public.roles x where x.name = p.min_role)), '{}')
    where p.min_role <> 'member';
    drop policy if exists posts_read on public.posts;
    alter table public.posts drop column min_role;
  end if;
end $$;

-- Members can hold several roles, like Discord. all_roles is the full list; role is the highest one (shown as their rank).
alter table public.profiles add column if not exists all_roles text[] not null default '{}';
update public.profiles set all_roles = array[role] where cardinality(all_roles) = 0;

-- Sign-up questions Command uses to confirm who someone is: their division and the rank they hold now.
alter table public.profiles add column if not exists division text;
alter table public.profiles add column if not exists current_rank text;
-- division can list several, like 'Arma 3, VRChat'.
alter table public.profiles drop constraint if exists profiles_signup_fields_check;
alter table public.profiles add constraint profiles_signup_fields_check check (
  (division is null or division ~ '^(Arma 3|VRChat)(, (Arma 3|VRChat))?$') and coalesce(length(current_rank), 0) <= 60
  and coalesce(length(discord_name), 0) <= 60 and coalesce(length(note), 0) <= 1000);

-- Helpers (run with owner rights so policies can call them without recursion).
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and status = 'approved' and role = 'admin');
$$;

create or replace function public.my_rank() returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select r.rank from profiles p join roles r on r.name = p.role
                   where p.id = auth.uid() and p.status = 'approved'), 0);
$$;

create or replace function public.my_roles() returns text[]
language sql stable security definer set search_path = public as $$
  select all_roles from profiles where id = auth.uid() and status = 'approved';
$$;

-- Permissions per role, like Discord. Admin always has every one; any other role gets only what's ticked on the Dashboard.
--   events    = create, edit and delete events and timers
--   briefings = post and delete briefings
--   bios      = edit anyone's bio
--   members   = approve sign-ups and change members' roles (never the Admin role)
--   docs      = add, edit and delete documents and choose who can see each folder
--   forms     = build forms, choose who can fill them in, and read everyone's answers
--   selfroles = add and remove roles on their own account (never ranks, rank groups, Admin or High-Com)
-- Admin can also give any of these to one person (profiles.perms), on top of what their roles give.
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'roles' and column_name = 'perms') then
    alter table public.roles add column perms text[] not null default '{}';
    -- First time only: High-Com starts with events, briefings and bios.
    update public.roles set perms = array['events', 'briefings', 'bios'] where name = 'high-com';
  end if;
end $$;
alter table public.roles drop constraint if exists roles_perms_check;
alter table public.roles add constraint roles_perms_check check (perms <@ array['events', 'briefings', 'bios', 'members', 'docs', 'forms', 'selfroles']);
alter table public.profiles add column if not exists perms text[] not null default '{}';
alter table public.profiles drop constraint if exists profiles_perms_check;
alter table public.profiles add constraint profiles_perms_check check (perms <@ array['events', 'briefings', 'bios', 'members', 'docs', 'forms', 'selfroles']);

create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select is_admin() or exists (select 1 from roles where name = any(my_roles()) and p = any(perms))
    or exists (select 1 from profiles where id = auth.uid() and status = 'approved' and p = any(perms));
$$;
create or replace function public.my_perms() returns text[]
language sql stable security definer set search_path = public as $$
  select case when is_admin() then array['events', 'briefings', 'bios', 'members', 'docs', 'forms', 'selfroles', 'roles']
    else coalesce((select array_agg(distinct x) from (
      select unnest(r.perms) x from roles r where r.name = any(my_roles())
      union select unnest(p.perms) from profiles p where p.id = auth.uid() and p.status = 'approved') t), '{}') end;
$$;
revoke execute on function public.has_perm(text), public.my_perms() from public, anon;
grant  execute on function public.has_perm(text), public.my_perms() to authenticated;

-- Bio: the "about me" line shown on the roster. Everyone edits their own on My account; the bios permission edits anyone's.
create or replace function public.set_bio(target uuid, bio text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if target is distinct from auth.uid() and not has_perm('bios') then raise exception 'You don''t have permission to edit other members'' bios'; end if;
  if length(bio) > 1000 then raise exception 'Keep the bio under 1000 characters'; end if;
  update profiles set note = nullif(btrim(bio), '') where id = target;
end $$;
revoke execute on function public.set_bio(uuid, text) from public, anon;
grant  execute on function public.set_bio(uuid, text) to authenticated;

-- Keep role and all_roles in step. Setting role on its own (approving someone) replaces the list with that one role;
-- changing the list keeps only real roles, falls back to Recruit when empty, and makes role the highest one.
create or replace function public.sync_roles() returns trigger
language plpgsql security definer set search_path = public as $$
declare l text; cur text;
begin
  if tg_op = 'UPDATE' and new.all_roles is not distinct from old.all_roles and new.role is distinct from old.role then
    new.all_roles := array[new.role];
  elsif tg_op = 'INSERT' and cardinality(new.all_roles) = 0 then
    new.all_roles := array[new.role];
  end if;
  -- Rank groups are automatic: the member gets the group their rank sits under (a Senior Commander gets Senior Officers),
  -- and loses it when their rank moves to another group. Admin and High-Com sit above every group, so they don't count.
  new.all_roles := array(select x from unnest(new.all_roles) x where not exists (select 1 from roles d where d.name = x and d.divider))
    || coalesce((select array[d.name] from roles d, lateral (select r.rank from roles r where r.name = any(new.all_roles) and not r.divider
          and exists (select 1 from roles t where t.divider and t.rank > r.rank) order by r.rank desc limit 1) k
        where d.divider and d.rank > k.rank order by d.rank asc limit 1), '{}');
  new.all_roles := coalesce((select array_agg(r.name order by r.rank desc) from roles r where r.name = any(new.all_roles)), '{}');
  -- Rank groups (NCO, SNCO...) never count as someone's rank, so everyone also holds a real rank (Recruit if none).
  if not exists (select 1 from roles r where r.name = any(new.all_roles) and not r.divider) then new.all_roles := new.all_roles || array['member']; end if;
  new.role := (select r.name from roles r where r.name = any(new.all_roles) and not r.divider order by r.rank desc limit 1);
  -- The callsign's letters follow the highest rank that has letters. Only rank letters are swapped, so special
  -- designations (ARF, RC...) and ranks without letters (Marshal Commander, Recruit) keep the name as it is.
  l := (select r.abbr from roles r where r.name = any(new.all_roles) and not r.divider and r.abbr <> '' order by r.rank desc limit 1);
  cur := substring(new.display_name from '^([A-Z][A-Z0-9]{1,3}(?:-[A-Z])?)-[0-9]{4} "');
  if l is not null and cur is not null and cur <> l and exists (select 1 from roles where abbr = cur) then
    new.display_name := l || substr(new.display_name, length(cur) + 1);
  end if;
  return new;
end $$;
drop trigger if exists profiles_roles on public.profiles;
create trigger profiles_roles before insert or update of role, all_roles on public.profiles
  for each row execute function public.sync_roles();

-- Deleting a role takes it off everyone and every briefing first. Reordering roles re-picks everyone's highest role.
create or replace function public.role_removed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.name in ('admin', 'member') then raise exception 'The % role can''t be deleted', old.label; end if;
  update profiles set all_roles = array_remove(all_roles, old.name) where old.name = any(all_roles);
  -- A briefing only that role could see falls back to Admin only, never to everyone.
  update posts set visible_to = case when visible_to = array[old.name] then array['admin'] else array_remove(visible_to, old.name) end
  where old.name = any(visible_to);
  update doc_folders set visible_to = case when visible_to = array[old.name] then array['admin'] else array_remove(visible_to, old.name) end
  where old.name = any(visible_to);
  update forms set visible_to = case when visible_to = array[old.name] then array['admin'] else array_remove(visible_to, old.name) end
  where old.name = any(visible_to);
  return old;
end $$;
drop trigger if exists roles_removed on public.roles;
create trigger roles_removed before delete on public.roles for each row execute function public.role_removed();

create or replace function public.roles_reordered() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profiles set all_roles = all_roles;
  return null;
end $$;
drop trigger if exists roles_reordered on public.roles;
create trigger roles_reordered after update of rank, abbr on public.roles for each statement execute function public.roles_reordered();
-- When a rank's letters change (on the edit page's rank list), members whose callsign uses the old letters for that rank get the new ones.
create or replace function public.role_letters_changed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.abbr = '' or new.abbr = '' or old.abbr = new.abbr then return null; end if;
  perform set_config('app.rank_letters', 'on', true);
  update profiles p set display_name = new.abbr || substr(p.display_name, length(old.abbr) + 1)
    where p.display_name like old.abbr || '-____ "%' and p.display_name !~ ('^' || old.abbr || '-[A-Z]-')
      and (select r.name from roles r where r.name = any(p.all_roles) and not r.divider and r.abbr <> '' order by r.rank desc limit 1) = new.name;
  perform set_config('app.rank_letters', '', true);
  return null;
end $$;
drop trigger if exists roles_letters on public.roles;
create trigger roles_letters after update of abbr on public.roles for each row execute function public.role_letters_changed();
-- Bring everyone's callsign letters in line with their rank now.
update public.profiles set all_roles = all_roles;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and status = 'approved';
$$;

-- Create a profile whenever someone signs up (Discord or email).
-- Names must be the 228th callsign: the rank designation (CC, T2C, CR-C...), a dash, four numbers, then the
-- nickname in quotes, like CC-5733 "Flanker". Curly quotes from phone keyboards are straightened. Each number can only be used once.
-- The website checks the designation against the rank list and the nickname's capitals; this is the backstop.
create or replace function public.check_callsign() returns trigger
language plpgsql security definer set search_path = public as $$
declare m text[];
begin
  -- Once approved, only Admin can change someone's name.
  if tg_op = 'UPDATE' and new.display_name is distinct from old.display_name and old.status = 'approved' and not is_admin()
     and coalesce(current_setting('app.rank_letters', true), '') <> 'on' then
    raise exception 'Only Command can change your name';
  end if;
  if new.display_name is null then return new; end if;
  new.display_name := regexp_replace(btrim(translate(new.display_name, '“”„‟″', '"""""')), '\s+', ' ', 'g');
  m := regexp_match(new.display_name, '^([A-Za-z][A-Za-z0-9]{1,3}(-[A-Za-z])?) *- *([0-9]{4}) *" *(.*[^ ]) *"$');
  if m is not null then new.display_name := upper(m[1]) || '-' || m[3] || ' "' || m[4] || '"'; end if;
  if new.display_name !~ '^[A-Z][A-Z0-9]{1,3}(-[A-Z])?-[0-9]{4} "[A-Za-z0-9][A-Za-z0-9 .''-]{0,23}"$' then
    raise exception 'Name must look like CT-1234 "Nickname"' using errcode = 'check_violation';
  end if;
  if exists (select 1 from profiles p where p.id <> new.id and substring(p.display_name from '-([0-9]{4}) ') = substring(new.display_name from '-([0-9]{4}) ')) then
    raise exception 'The number % is already taken by another account', substring(new.display_name from '-([0-9]{4}) ') using errcode = 'unique_violation';
  end if;
  return new;
end $$;

drop trigger if exists profiles_callsign on public.profiles;
create trigger profiles_callsign before insert or update of display_name on public.profiles
  for each row execute function public.check_callsign();
create unique index if not exists profiles_number_key on public.profiles ((substring(display_name from '-([0-9]{4}) ')));

-- Lets the sign-up form say up front when a number is already used.
create or replace function public.number_taken(num text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where substring(display_name from '-([0-9]{4}) ') = num);
$$;
grant execute on function public.number_taken(text) to anon, authenticated;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, email, display_name, discord_name, avatar_url, division, current_rank, note)
  values (
    new.id,
    new.email,
    nullif(m->>'display_name', ''),
    case when new.raw_app_meta_data->>'provider' = 'discord' then coalesce(m->>'full_name', m->>'name')
         else left(nullif(btrim(m->>'discord_name'), ''), 60) end,
    null,
    case when m->>'division' ~ '^(Arma 3|VRChat)(, (Arma 3|VRChat))?$' then m->>'division' end,
    left(nullif(btrim(m->>'current_rank'), ''), 60),
    left(nullif(btrim(m->>'note'), ''), 1000)
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Admin action: approve, deny or change someone's role.
create or replace function public.set_member(target uuid, new_status text, new_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not has_perm('members') then raise exception 'You don''t have permission to manage members'; end if;
  if not is_admin() and (new_role = 'admin' or exists (select 1 from profiles where id = target and 'admin' = any(all_roles))) then
    raise exception 'Only an Admin can change Admin access';
  end if;
  if target = auth.uid() and is_admin() and (new_status <> 'approved' or new_role <> 'admin') then
    raise exception 'You can''t remove your own admin access';
  end if;
  update profiles set
    status      = new_status,
    role        = coalesce(new_role, role),
    approved_at = case when new_status = 'approved' then coalesce(approved_at, now()) else approved_at end,
    approved_by = case when new_status = 'approved' then coalesce(approved_by, auth.uid()) else approved_by end
  where id = target;
end $$;

-- Admin action: set the full list of roles someone holds.
create or replace function public.set_roles(target uuid, new_roles text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not has_perm('members') then raise exception 'You don''t have permission to manage members'; end if;
  if not is_admin() and ('admin' = any(new_roles) or exists (select 1 from profiles where id = target and 'admin' = any(all_roles))) then
    raise exception 'Only an Admin can change Admin access';
  end if;
  if target = auth.uid() and is_admin() and not ('admin' = any(new_roles)) then raise exception 'You can''t remove your own admin access'; end if;
  update profiles set all_roles = new_roles where id = target;
end $$;
revoke execute on function public.set_roles(uuid, text[]) from public, anon;
grant  execute on function public.set_roles(uuid, text[]) to authenticated;

-- Admin action: permissions for one person, on top of what their roles give.
create or replace function public.set_member_perms(target uuid, new_perms text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only an Admin can give permissions to one person'; end if;
  update profiles set perms = coalesce((select array_agg(distinct x) from unnest(new_perms) x), '{}') where id = target;
end $$;
revoke execute on function public.set_member_perms(uuid, text[]) from public, anon;
grant  execute on function public.set_member_perms(uuid, text[]) to authenticated;

-- Roles someone can pick for themselves: anything but ranks, rank groups, Admin and High-Com.
create or replace function public.self_role_ok(n text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from roles r where r.name = n and not r.divider and coalesce(r.abbr, '') = ''
    and r.name not in ('admin', 'high-com', 'marshal-commander', 'member'));
$$;
-- With the selfroles permission: add or remove those roles on your own account. Everything else stays as it was.
create or replace function public.set_my_roles(new_roles text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not has_perm('selfroles') then raise exception 'You don''t have permission to change your own roles'; end if;
  update profiles set all_roles = array(select x from unnest(all_roles) x where not self_role_ok(x))
    || array(select x from unnest(new_roles) x where self_role_ok(x))
  where id = auth.uid();
end $$;
revoke execute on function public.self_role_ok(text), public.set_my_roles(text[]) from public, anon;
grant  execute on function public.self_role_ok(text), public.set_my_roles(text[]) to authenticated;

-- Roster for approved members: names, roles and pictures only (no emails).
drop function if exists public.member_roster();
create or replace function public.member_roster()
returns table (display_name text, avatar_url text, role text, role_label text, rank int, approved_at timestamptz, role_labels text[], bio text)
language sql stable security definer set search_path = public as $$
  select p.display_name, p.avatar_url, p.role, r.label, r.rank, p.approved_at,
    (select array_agg(x.label order by x.rank desc) from roles x where x.name = any(p.all_roles)), p.note
  from profiles p join roles r on r.name = p.role
  where p.status = 'approved' and my_rank() > 0
  order by r.rank desc, p.display_name;
$$;

revoke execute on function public.set_member(uuid, text, text) from public, anon;
revoke execute on function public.member_roster() from public, anon;
revoke execute on function public.my_role() from public, anon;
grant  execute on function public.my_role(), public.my_roles() to authenticated;
revoke execute on function public.my_roles() from public, anon;
grant  execute on function public.set_member(uuid, text, text) to authenticated;
grant  execute on function public.member_roster() to authenticated;

-- Row level security: the database itself enforces who sees what.
alter table public.roles    enable row level security;
alter table public.profiles enable row level security;
alter table public.posts    enable row level security;

drop policy if exists roles_read  on public.roles;
drop policy if exists roles_admin on public.roles;
create policy roles_read  on public.roles for select to authenticated using (true);
create policy roles_admin on public.roles for all    to authenticated using (is_admin()) with check (is_admin());

-- Profiles: you see your own; admins see everyone. Members can only edit their own name and note.
-- Table permissions are set here explicitly, so this works whether or not "Automatically expose new tables" is on.
revoke all on public.roles, public.profiles, public.posts from anon, authenticated;
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.roles, public.posts to authenticated;
grant select, delete on public.profiles to authenticated;
grant  update (display_name, note, avatar_url, discord_name, division, current_rank) on public.profiles to authenticated;
drop policy if exists profiles_read   on public.profiles;
drop policy if exists profiles_update on public.profiles;
drop policy if exists profiles_delete on public.profiles;
create policy profiles_read   on public.profiles for select to authenticated using (id = auth.uid() or is_admin() or has_perm('members') or has_perm('bios'));
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());
create policy profiles_delete on public.profiles for delete to authenticated using (is_admin());

-- Posts: approved members read posts meant for everyone or for their role; admins see and manage all of them.
drop policy if exists posts_read  on public.posts;
drop policy if exists posts_admin on public.posts;
create policy posts_read  on public.posts for select to authenticated
  using (my_roles() is not null and (cardinality(visible_to) = 0 or visible_to && my_roles() or has_perm('briefings')));
create policy posts_admin on public.posts for all to authenticated using (has_perm('briefings')) with check (has_perm('briefings'));


-- Profile pictures must be uploaded through the site (stored in the avatars bucket below).
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_avatar_url_check') then
    update public.profiles set avatar_url = null where avatar_url !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/';
    alter table public.profiles add constraint profiles_avatar_url_check
      check (avatar_url is null or avatar_url ~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/');
  end if;
end $$;

-- Profile picture storage: anyone can view, each member can only add or remove files in their own folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/webp', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;
drop policy if exists avatars_select on storage.objects;
drop policy if exists avatars_insert on storage.objects;
drop policy if exists avatars_delete on storage.objects;
create policy avatars_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Events: ops and other times set from the Dashboard, each with its own countdown.
-- "visibility" picks where it shows: public (the main site, no login), private (the members area) or both.
create table if not exists public.events (
  id          bigint generated always as identity primary key,
  title       text not null,
  description text,
  game        text,
  starts_at   timestamptz not null,
  visibility  text not null default 'both',
  repeats_weekly boolean not null default false,
  author      uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
-- A weekly event repeats every 7 days from its start; editing its date moves this week and the ones after.
alter table public.events add column if not exists repeats_weekly boolean not null default false;
-- A cancelled event stays on the Dashboard (so it can be restored) but disappears from the site.
alter table public.events add column if not exists cancelled boolean not null default false;
alter table public.events drop constraint if exists events_fields_check;
alter table public.events add constraint events_fields_check check (
  length(trim(title)) between 1 and 120 and coalesce(length(description), 0) <= 2000
  and (game is null or game in ('Arma 3', 'VRChat', 'Arma 3 & VRChat'))
  and visibility in ('public', 'private', 'both'));
alter table public.events enable row level security;
revoke all on public.events from anon, authenticated;
grant select on public.events to anon, authenticated;
grant insert, update, delete on public.events to authenticated;
drop policy if exists events_public  on public.events;
drop policy if exists events_members on public.events;
drop policy if exists events_admin   on public.events;
-- Anyone (even logged out) sees public and both; approved members also see private; admins manage them all.
create policy events_public  on public.events for select to anon, authenticated using (visibility in ('public', 'both'));
create policy events_members on public.events for select to authenticated using (my_roles() is not null);
create policy events_admin   on public.events for all to authenticated using (has_perm('events')) with check (has_perm('events'));

-- Weekly calendar: the standing Sunday-to-Saturday schedule on the main site, set from the Dashboard's Calendar tab.
-- starts_ref is any one occurrence (it fixes the weekday and time, shown in each visitor's own time zone);
-- with no time set (TBD), "day" (0 = Sunday) says which day it goes under.
do $$ begin
  if not exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'schedule') then
    create table public.schedule (
      id         bigint generated always as identity primary key,
      title      text not null,
      details    text,
      day        int not null default 0,
      starts_ref timestamptz,
      created_at timestamptz not null default now()
    );
  end if;
end $$;
-- Which division's calendar it goes on: Arma 3, VRChat, or Both (shows on each).
alter table public.schedule add column if not exists division text not null default 'Both';
-- All day: no set time (like a day off); shows "All day" instead of a time.
alter table public.schedule add column if not exists all_day boolean not null default false;
alter table public.schedule drop constraint if exists schedule_fields_check;
alter table public.schedule add constraint schedule_fields_check check (
  length(trim(title)) between 1 and 80 and coalesce(length(details), 0) <= 300 and day between 0 and 6
  and division in ('Both', 'Arma 3', 'VRChat'));
alter table public.schedule enable row level security;
revoke all on public.schedule from anon, authenticated;
grant select on public.schedule to anon, authenticated;
grant insert, update, delete on public.schedule to authenticated;
drop policy if exists schedule_read   on public.schedule;
drop policy if exists schedule_manage on public.schedule;
create policy schedule_read   on public.schedule for select to anon, authenticated using (true);
create policy schedule_manage on public.schedule for all to authenticated using (has_perm('events')) with check (has_perm('events'));

-- Documents: the members-only Documents page. Folders nest (228th Wide > Divisions > MOS > Qualifications, and so on)
-- and each folder picks which roles can see it (empty = every approved member). A folder inside a hidden folder is hidden too.
-- The docs permission (High-Com starts with it) adds, edits and deletes folders and documents and sees all of them.
do $$ begin
  if to_regclass('public.doc_folders') is null then
    update public.roles set perms = array_append(perms, 'docs') where name = 'high-com' and not ('docs' = any(perms));
  end if;
end $$;
create table if not exists public.doc_folders (
  id         bigint generated always as identity primary key,
  parent_id  bigint references public.doc_folders on delete cascade,
  title      text not null,
  sort       int not null default 0,
  visible_to text[] not null default '{}',
  created_at timestamptz not null default now()
);
create table if not exists public.docs (
  id         bigint generated always as identity primary key,
  folder_id  bigint not null references public.doc_folders on delete cascade,
  title      text not null,
  body       text,
  sort       int not null default 0,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
alter table public.doc_folders drop constraint if exists doc_folders_fields_check;
alter table public.doc_folders add constraint doc_folders_fields_check check (length(trim(title)) between 1 and 80 and parent_id is distinct from id);
alter table public.docs drop constraint if exists docs_fields_check;
alter table public.docs add constraint docs_fields_check check (length(trim(title)) between 1 and 120 and coalesce(length(body), 0) <= 50000);

create or replace function public.doc_touch() returns trigger
language plpgsql as $$
begin new.updated_at = now(); new.updated_by = auth.uid(); return new; end $$;
drop trigger if exists docs_touch on public.docs;
create trigger docs_touch before update on public.docs for each row execute function public.doc_touch();

-- Can I see this folder? Every folder above it must allow one of my roles too.
create or replace function public.doc_folder_ok(fid bigint) returns boolean
language sql stable security definer set search_path = public as $$
  with recursive up as (
    select id, parent_id, visible_to, 1 as depth from doc_folders where id = fid
    union all
    select f.id, f.parent_id, f.visible_to, up.depth + 1 from doc_folders f join up on f.id = up.parent_id where up.depth < 20
  )
  select my_roles() is not null and (has_perm('docs')
    or not exists (select 1 from up where cardinality(visible_to) > 0 and not (visible_to && my_roles())));
$$;
revoke execute on function public.doc_folder_ok(bigint) from public, anon;
grant  execute on function public.doc_folder_ok(bigint) to authenticated;

alter table public.doc_folders enable row level security;
alter table public.docs        enable row level security;
revoke all on public.doc_folders, public.docs from anon, authenticated;
grant select, insert, update, delete on public.doc_folders, public.docs to authenticated;
drop policy if exists doc_folders_read   on public.doc_folders;
drop policy if exists doc_folders_manage on public.doc_folders;
drop policy if exists docs_read          on public.docs;
drop policy if exists docs_manage        on public.docs;
create policy doc_folders_read   on public.doc_folders for select to authenticated using (doc_folder_ok(id));
create policy doc_folders_manage on public.doc_folders for all    to authenticated using (has_perm('docs')) with check (has_perm('docs'));
create policy docs_read          on public.docs        for select to authenticated using (doc_folder_ok(folder_id));
create policy docs_manage        on public.docs        for all    to authenticated using (has_perm('docs')) with check (has_perm('docs'));

-- First run only: starter folders. Rename, move or delete any of them on the Documents page.
do $$
declare top bigint; i int := 0; t text;
begin
  if exists (select 1 from public.doc_folders) then return; end if;
  insert into public.doc_folders (title, sort) values ('228th Wide', 0);
  insert into public.doc_folders (title, sort) values ('Divisions & Branches', 1) returning id into top;
  insert into public.doc_folders (parent_id, title, sort) values (top, 'Arma 3', 0), (top, 'VRChat', 1);
  insert into public.doc_folders (title, sort) values ('MOS', 2) returning id into top;
  foreach t in array array['Conventional', 'ARC', 'ARF', 'Airborne', 'Armored', 'BARC', 'Commando', 'Combat Engineer', 'Marine',
    'Combat Medic', 'Pilot', 'Scuba', 'Spec Ops', 'Echelon'] loop
    insert into public.doc_folders (parent_id, title, sort) values (top, t, i); i := i + 1;
  end loop;
  i := 0;
  insert into public.doc_folders (title, sort) values ('Qualifications', 3) returning id into top;
  foreach t in array array['Anti-Tank', 'Breacher', 'Medic', 'Stealth', 'EOD', 'RTO', 'Light Weaponry', 'Heavy Weaponry', 'Jetpack',
    'Marksman', 'Piloting', 'Riot', 'SAR', 'SERE'] loop
    insert into public.doc_folders (parent_id, title, sort) values (top, t, i); i := i + 1;
  end loop;
end $$;

-- Raid Rules for the VRChat division (from Flanker 2026-10-23). Added once; edit it on the Documents page.
do $$
declare fid bigint;
begin
  if exists (select 1 from public.docs where title = 'Raid Rules') then return; end if;
  select f.id into fid from public.doc_folders f left join public.doc_folders p on p.id = f.parent_id
    where f.title = 'VRChat' order by (p.title = 'Divisions & Branches') desc nulls last, f.id limit 1;
  if fid is null then select id into fid from public.doc_folders where title = '228th Wide' and parent_id is null limit 1; end if;
  if fid is null then return; end if;
  insert into public.docs (folder_id, title, body, sort) values (fid, 'Raid Rules', $b$Each rule here gets one warning. If the same rule is broken again, that person will be kicked. Rules marked instant kick get no warning.

- No participating in raiding while a member of the 228th.
- No exploiting, like using OVR or shooting guns through walls. (If Raiders break this, it is an instant kick.)
- No blocking 228th Troopers' accounts. (If Raiders break this, it is an instant kick.)
- No spawn camping.
- No holstering more than 2 primary weapons. Only 1 primary and 1 secondary weapon are allowed. Exceptions may only apply to 228th Troopers.
- No abusing avatar height (minimum 1.89m and maximum 2.60m).
- No unauthorized flight abilities and avatar toggles (dashes, teleport seats, GoGo Loco, or invisibility).
- No killing unarmed civilians or unarmed troopers outside base.
- Raiders are only allowed to "spin glitch" through doors, not walls. This includes no spin glitching to seats in the offices.
- No killing anyone trying to train new recruits in the training room.
- No false recruiting. (This is an instant kick.)$b$, 0);
end $$;

-- Forms: the members-only Forms page (like Google Forms, but answers stay on the site). Each member fills a form in once
-- and can change their answers later. The forms permission (High-Com starts with it) builds forms and reads every answer.
-- questions is a list of {id, type, label, help, options, required}; type is text, long, choice, checks, agree or info.
do $$ begin
  if to_regclass('public.forms') is null then
    update public.roles set perms = array_append(perms, 'forms') where name = 'high-com' and not ('forms' = any(perms));
  end if;
end $$;
create table if not exists public.forms (
  id          bigint generated always as identity primary key,
  title       text not null,
  description text,
  questions   jsonb not null default '[]',
  visible_to  text[] not null default '{}',
  open        boolean not null default true,
  sort        int not null default 0,
  created_at  timestamptz not null default now()
);
create table if not exists public.form_responses (
  id         bigint generated always as identity primary key,
  form_id    bigint not null references public.forms on delete cascade,
  user_id    uuid not null default auth.uid() references public.profiles on delete cascade,
  name       text,
  answers    jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (form_id, user_id)
);
-- public: anyone can fill it in without logging in (the Alliance page). Their answers are filed with no account.
alter table public.forms add column if not exists public boolean not null default false;
alter table public.form_responses alter column user_id drop not null;
-- category groups forms on the page: Arma 3 first, then VRChat, then any others.
alter table public.forms add column if not exists category text not null default '';
-- multiple: members can send it again and again (a disciplinary report). Other forms stay one answer per member.
alter table public.forms add column if not exists multiple boolean not null default false;
alter table public.form_responses drop constraint if exists form_responses_form_id_user_id_key;
update public.forms set category = 'Arma 3' where category = '' and title ilike 'Arma 3%';
update public.forms set category = 'VRChat' where category = '' and title ilike 'VRChat%';
alter table public.forms drop constraint if exists forms_fields_check;
alter table public.forms add constraint forms_fields_check check (
  length(trim(title)) between 1 and 120 and coalesce(length(description), 0) <= 50000 and length(category) <= 60
  and jsonb_typeof(questions) = 'array' and length(questions::text) <= 100000);
alter table public.form_responses drop constraint if exists form_responses_fields_check;
alter table public.form_responses add constraint form_responses_fields_check check (jsonb_typeof(answers) = 'object' and length(answers::text) <= 400000);

-- Can I fill in (or see) this form?
create or replace function public.form_ok(fid bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select my_roles() is not null and (has_perm('forms') or exists (select 1 from forms f where f.id = fid
    and (cardinality(f.visible_to) = 0 or f.visible_to && my_roles())));
$$;
create or replace function public.form_open(fid bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select form_ok(fid) and exists (select 1 from forms where id = fid and open);
$$;
-- A form with a signature question is final once sent: the member can't change or withdraw it (Command can delete it).
create or replace function public.form_signed(fid bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from forms where id = fid and questions @> '[{"type":"signature"}]');
$$;
revoke execute on function public.form_ok(bigint), public.form_open(bigint), public.form_signed(bigint) from public, anon;
grant  execute on function public.form_ok(bigint), public.form_open(bigint), public.form_signed(bigint) to authenticated;

-- Answers are always filed under the member who sent them, with their callsign at the time.
create or replace function public.form_response_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.user_id = auth.uid();
  new.name = (select display_name from profiles where id = auth.uid());
  if new.user_id is null then
    -- Visitors with no account: public forms only, a modest size, and a cap per hour so the form can't be flooded.
    if tg_op <> 'INSERT' or not exists (select 1 from forms where id = new.form_id and public and open) then raise exception 'This form isn''t open to the public.'; end if;
    if length(new.answers::text) > 120000 then raise exception 'That answer is too long.'; end if;
    if (select count(*) from form_responses where user_id is null and created_at > now() - interval '1 hour') >= 15 then
      raise exception 'Too many forms sent in the last hour. Please try again later.';
    end if;
    new.name = left(coalesce(nullif(trim(new.answers->'signature'->>'name'), ''), nullif(trim(new.answers->>'unit'), ''), 'Visitor'), 80);
  elsif tg_op = 'INSERT' and not (select multiple from forms where id = new.form_id)
    and exists (select 1 from form_responses where form_id = new.form_id and user_id = new.user_id) then
    raise exception 'You''ve already filled this in.';
  end if;
  new.updated_at = now();
  if tg_op = 'INSERT' then new.created_at = now(); else new.form_id = old.form_id; new.created_at = old.created_at; end if;
  return new;
end $$;
drop trigger if exists form_responses_stamp on public.form_responses;
create trigger form_responses_stamp before insert or update on public.form_responses for each row execute function public.form_response_stamp();

alter table public.forms          enable row level security;
alter table public.form_responses enable row level security;
revoke all on public.forms, public.form_responses from anon, authenticated;
grant select, insert, update, delete on public.forms, public.form_responses to authenticated;
grant select on public.forms to anon;
grant insert on public.form_responses to anon;
drop policy if exists forms_read        on public.forms;
drop policy if exists forms_manage      on public.forms;
drop policy if exists responses_read    on public.form_responses;
drop policy if exists responses_send    on public.form_responses;
drop policy if exists responses_change  on public.form_responses;
drop policy if exists responses_delete  on public.form_responses;
create policy forms_read       on public.forms for select to authenticated using (form_ok(id));
drop policy if exists forms_public on public.forms;
create policy forms_public     on public.forms for select to anon, authenticated using (public and open);
create policy forms_manage     on public.forms for all    to authenticated using (has_perm('forms')) with check (has_perm('forms'));
create policy responses_read   on public.form_responses for select to authenticated using (user_id = auth.uid() or has_perm('forms'));
create policy responses_send   on public.form_responses for insert to authenticated with check (form_open(form_id));
drop policy if exists responses_public on public.form_responses;
create policy responses_public on public.form_responses for insert to anon with check (user_id is null);
create policy responses_change on public.form_responses for update to authenticated using (user_id = auth.uid() and form_open(form_id) and not form_signed(form_id)) with check (form_open(form_id));
create policy responses_delete on public.form_responses for delete to authenticated using (has_perm('forms') or (user_id = auth.uid() and not form_signed(form_id)));

-- High Command's private notes on an answer (shown under each answer on the Forms page). Forms permission only.
create table if not exists public.response_notes (
  response_id bigint primary key references public.form_responses on delete cascade,
  notes       text not null default '' check (length(notes) <= 20000),
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid(),
  by_name     text
);
create or replace function public.response_notes_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at = now(); new.updated_by = auth.uid();
  new.by_name = (select display_name from profiles where id = auth.uid());
  if tg_op = 'UPDATE' then new.response_id = old.response_id; end if;
  return new;
end $$;
drop trigger if exists response_notes_stamp on public.response_notes;
create trigger response_notes_stamp before insert or update on public.response_notes for each row execute function public.response_notes_stamp();
alter table public.response_notes enable row level security;
revoke all on public.response_notes from anon, authenticated;
grant select, insert, update, delete on public.response_notes to authenticated;
drop policy if exists notes_command on public.response_notes;
create policy notes_command on public.response_notes for all to authenticated using (has_perm('forms')) with check (has_perm('forms'));

-- The public 228th Dossier (Lore on the main page). Everyone approved is written in here and stays for good, even after
-- they leave, are removed or delete their account; while they're an approved member their entry follows their callsign and rank.
-- Callsigns only: no emails, pictures or anything else.
create table if not exists public.dossier (
  member_id  uuid primary key,
  name       text not null,
  command    boolean not null default false,
  rank       int not null default 0,
  added_at   timestamptz not null default now()
);
alter table public.dossier enable row level security;
revoke all on public.dossier from anon, authenticated;
create or replace function public.dossier_track() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' and new.display_name is not null then
    insert into dossier (member_id, name, command, rank)
    select new.id, new.display_name, r.rank >= coalesce((select rank from roles where name = 'second-lieutenant'), 1000), r.rank
    from roles r where r.name = new.role
    on conflict (member_id) do update set name = excluded.name, command = excluded.command, rank = excluded.rank;
  end if;
  return null;
end $$;
drop trigger if exists profiles_dossier on public.profiles;
create trigger profiles_dossier after insert or update on public.profiles for each row execute function public.dossier_track();
-- Everyone approved so far goes in now.
insert into public.dossier (member_id, name, command, rank)
select p.id, p.display_name, r.rank >= coalesce((select rank from public.roles where name = 'second-lieutenant'), 1000), r.rank
from public.profiles p join public.roles r on r.name = p.role where p.status = 'approved' and p.display_name is not null
on conflict (member_id) do update set name = excluded.name, command = excluded.command, rank = excluded.rank;

drop function if exists public.public_dossier();
create or replace function public.public_dossier()
returns table (name text, command boolean) language sql stable security definer set search_path = public as $$
  -- command: Second Lieutenant and up (listed under Command); everyone else goes under Members.
  select d.name, d.command from dossier d order by d.rank desc, d.added_at, d.name;
$$;
revoke execute on function public.public_dossier() from public;
grant  execute on function public.public_dossier() to anon, authenticated;

-- First run only: a Terms of Service agreement for each division. Edit them on the Forms page.
-- (Also swaps in the real terms if the early placeholder version is still there.)
do $$
declare q jsonb := $j$[{"id": "terms", "type": "info", "label": "Effective Immediately | Subject to Update at Any Time", "help": "By accepting a leadership, staff, or management role within any division of the 228th Black Skulls Corps, you agree to abide by the following Terms of Service. These terms exist to maintain the integrity, structure, and vision of the 228th across all platforms and games, including—but not limited to—VRChat, ARMA 3, Rec Room, Battlefront, and any future divisions.\n\n### 1. Rules & Regulations\nAll members and leaders are expected to follow the official 228th Rules and Regulations as outlined by High Command. These rules may be updated or amended at any time.\n\nIf an issue arises that is not currently addressed in the rules, Marshal Commander Flanker & High-Com holds full authority to make a final decision on how the matter will be handled and may issue immediate or retroactive updates to the rules as needed.\n\n### 2. Autonomy of Divisions\nLeaders will be granted significant freedom to operate and manage their individual divisions. High Command will intervene as little as possible to ensure organic growth, cohesion, and long-term success. However, oversight will still be maintained to ensure alignment with the 228th’s values and standards.\n\n### 3. Ownership & Final Authority\nThe 228th Black Skulls Corps is solely owned by Marshal Commander Flanker. As the creator and primary authority of the Corps, Flanker reserves the right to:\n- Step in and alter leadership structures, operations, or policies if deemed necessary\n- Overrule or reverse decisions made by other High Command members\n- Implement or block any major changes to the unit or its divisions\n\nNo other High Command member may authorize major changes to the 228th without Flanker’s direct approval.\n\n### 4. Division Control\nAll present and future divisions (e.g., VRChat, ARMA 3, Rec Room, Battlefront) exist at the discretion of Flanker.\nHe holds the right to:\n- Approve or deny the creation of new divisions\n- Disband or dissolve existing divisions at any time, with or without prior notice\n- Determine when divisions are opened, closed, or placed on hold\n\n### 5. Leadership Appointments\nFlanker reserves the right to promote or demote division leaders at any time, based on performance, conduct, activity, or alignment with the 228th’s core directives.\n\nNo position is guaranteed, and all leadership roles operate under the continued trust and confidence of Flanker.\n\n### 6. Acknowledgment of Terms\nBy continuing to serve or lead within the 228th Black Skulls Corps, you acknowledge that:\n- These terms are binding and subject to change\n- Your position is subject to review at any time\n- Violations or disputes will be handled at the discretion of Flanker and may result in removal or reassignment\n\n### 7. Ownership Protection Clause\nBy signing this agreement, you confirm and agree that you will never attempt to create, rebrand, restart, or open any group, server, unit, community, or organization under the name \"228th\" by itself or in conjunction with “Black Skulls” or any variation thereof without the express written permission of Marshal Commander Flanker.\n\nDoing so constitutes a direct violation of this agreement. You further agree that if you attempt to start or replicate any 228th-based group without authorization, you accept full responsibility for the consequences, which may include removal from all affiliated communities, public notice of the breach, and any necessary legal action taken to protect the integrity of the 228th brand and identity.\n\n228th Black Skulls Corps™ | Always Stalking ~ Always Lurking | For the Republic"}, {"id": "signature", "type": "signature", "label": "Signature", "help": "Sign with your CT-#### \"Nickname\", then sign in the box with your finger or mouse.", "required": true}, {"id": "discord", "type": "text", "label": "Discord ID / username", "required": true}]$j$;
begin
  update public.forms set questions = q, description = '228th Black Skulls Corps™ – Terms of Service Agreement'
    where questions @> '[{"id":"terms","help":"Command: paste the terms here (Forms > Edit > Edit form)."}]';
  if exists (select 1 from public.forms) then return; end if;
  insert into public.forms (title, description, questions, sort, category) values
    ('Arma 3 Terms of Service Agreement', '228th Black Skulls Corps™ – Terms of Service Agreement', q, 0, 'Arma 3'),
    ('VRChat Terms of Service Agreement', '228th Black Skulls Corps™ – Terms of Service Agreement', q, 1, 'VRChat');
end $$;

-- First run only: the public Alliance Agreement (shown on the Alliance page). Edit it on the Forms page.
do $$
begin
  if exists (select 1 from public.forms where category = 'Alliance') then return; end if;
  insert into public.forms (title, description, questions, sort, category, public) values
    ('Alliance Agreement', '228th Black Skulls Corps – Alliance Agreement Form', $a$[{"id": "sec1", "type": "info", "label": "Section I: Expectations, Protocols, and Operational Conduct", "help": "The 228th Black Skulls Corps maintains a high standard of professionalism, order, and mutual respect across all operations and alliances. The following points outline our expectations from any unit or organization seeking formal alliance with the 228th. Acceptance of these conditions is mandatory for alliance status.\n\n### I.1 – Respect and Discipline\n- Drama-Free Zone: Alliances are expected to operate free of drama, toxicity, and immature conduct. Disagreements must be handled through appropriate command channels.\n- Chain of Command: Members of allied units are to follow their own internal chain of command and resolve issues through leadership, not public confrontation.\n- Mutual Discipline: Allies must uphold a culture of discipline and responsibility. Any form of rule-breaking, trolling, or targeted harassment will not be tolerated.\n\n### I.2 – Guest Conduct Policy\n- Host Rules Apply: When members of one ally are present in the server or events of the other ally, they are to abide by the host unit’s rules without exception.\n- Reporting Issues: If a guest member feels mistreated or disagrees with an enforcement, they are to report the issue to their own high command. That command may then engage in discussion with the host’s leadership to resolve the matter diplomatically.\n- No Direct Confrontation: Guests are not to argue or challenge the host’s moderators or staff. All concerns go through proper leadership channels.\n\n### I.3 – Operational Alignment\n- Independent Command Structure: In joint operations, each allied unit will retain its own internal command structure. Troopers are not to take direct orders from another unit’s officers unless cleared by their own command.\n- Order Relay Protocol: Orders from the host command will be relayed to the guest unit’s high command, who will then distribute those orders to their own personnel. This ensures discipline and unity of command. This same protocol applies in reverse when the guest becomes the host.\n- Unified Objectives: While operational independence is respected, allied units are expected to work toward common mission objectives, support each other, and coordinate effectively.\n- Training and Events: Joint trainings and operations should be planned with mutual communication and respect for each unit’s roles and structure.\n- Rank Recognition: Members should respect each other’s ranks and positions, but not assume authority over another unit’s personnel without prior arrangement.\n\n### I.4 – Internal Affairs and Boundaries\n- Autonomy: The 228th will not interfere with the internal structure, punishments, or promotions of allied units, and expects the same respect in return.\n- Conflict Resolution: If a dispute arises between members of allied units, it must be handled between high commands only — not member-to-member unless instructed otherwise.\n- Member Transfers: If a member of one unit wishes to join the other, both parties’ leadership will be notified. Poaching is strictly forbidden.\n\n### I.5 – Communication & Activity\n- Leadership Contact: A line of communication between high commands must be maintained. Both parties will identify at least one command-level contact for alliance matters.\n- Status Checks: The alliance may be reviewed periodically to ensure activity, relevance, and mutual benefit.\n- Termination Clause: Either party may dissolve the alliance at any time, with or without cause. A courtesy notice is expected if possible.\n\nBy entering into alliance with the 228th Black Skulls Corps, you acknowledge that you have read and understood all policies listed above."}, {"id": "sec2", "type": "info", "label": "Section II: Alliance Questionnaire", "help": "Please fill out the following form below. Answers should be honest and complete."}, {"id": "unit", "type": "text", "label": "Unit name", "required": true}, {"id": "leader", "type": "text", "label": "Your name and rank in your unit", "required": true}, {"id": "discord", "type": "text", "label": "Your Discord username", "required": true}, {"id": "server", "type": "text", "label": "Your unit's Discord server invite"}, {"id": "games", "type": "text", "label": "Games or platforms your unit plays", "required": true}, {"id": "size", "type": "text", "label": "About how many active members do you have?"}, {"id": "about", "type": "long", "label": "Tell us about your unit", "required": true}, {"id": "why", "type": "long", "label": "Why do you want to ally with the 228th?", "required": true}, {"id": "agree", "type": "agree", "label": "On behalf of my unit, I have read and understood all policies listed above.", "required": true}, {"id": "signature", "type": "signature", "label": "Signature", "help": "Sign with your name, then sign in the box with your finger or mouse.", "required": true}]$a$::jsonb, 0, 'Alliance', true);
end $$;

-- First run only: the Disciplinary Action Submission (High-Com and up; officers can send many). Edit it on the Forms page.
do $$
begin
  if exists (select 1 from public.forms where title = 'Disciplinary Action Submission') then return; end if;
  insert into public.forms (title, description, questions, sort, category, visible_to, multiple) values
    ('Disciplinary Action Submission', $d$This form is used by officers of the 228th Black Skulls Corps to formally document disciplinary actions, misconduct, or behavioral concerns involving members of the unit. Submissions should be factual, detailed, and based on witness statements, logs, or personal observation.$d$, $q$[{"id": "trooper", "type": "text", "label": "Trooper Receiving D.A. {CT-#### \"Nickname\"} & {Discord Tag}", "required": true}, {"id": "trooper_discord", "type": "text", "label": "Trooper Discord ID", "required": true}, {"id": "today", "type": "date", "label": "Today's Date"}, {"id": "division", "type": "select", "label": "Division", "options": ["Arma 3", "VRChat"], "required": true}, {"id": "mos", "type": "text", "label": "MOS", "required": true}, {"id": "rank", "type": "long", "label": "Trooper's Rank", "required": true}, {"id": "officer1", "type": "text", "label": "Your CT-#### \"Nickname\" (1)", "required": true}, {"id": "officer2", "type": "text", "label": "Officer CT-#### \"Nickname\" (2)"}, {"id": "officer3", "type": "text", "label": "Officer CT-#### \"Nickname\" (3)"}, {"id": "officer4", "type": "text", "label": "Officer CT-#### \"Nickname\" (4)"}, {"id": "hc", "type": "select", "label": "High Command Member if Present", "options": ["Flanker", "Wendigo", "Terminator", "Phoenix", "Wayside"]}, {"id": "concern", "type": "checks", "label": "Type of Concern", "options": ["Insubordination", "Violation of Unit Rules", "Unauthorized Use of Role or Rank", "Excessive Absenteeism", "Excessive Leaving Early (Without Reason)", "Poor Attitude Towards Unit Members", "Poor Attitude Towards Non - Members", "Poor Representation of 228th Values in a Public Setting", "Stagnant Growth with their Position", "Dress Code Violation", "Lacks Following Through with tactics taught in training", "Doesn't Accept Coaching well from Officers or C.O.C.", "Poor Workmanship - Doesn't put effort into events", "Inconsistent Performance", "Lacks Initiative at Times", "Profanity", "Disappears for Longer than Expected at Times", "Has a Bad Habit of Disappearing during Events to do own thing", "Negative Attitude in General", "Struggles being a Team Player", "Rude Towards Allies", "Rude Towards Fellow Unit Members", "Intentionally or Unintentionally Starting Rumors about Fellow Unit Members", "Didn't Show up to a Mandatory Meeting", "Didn't Fill out LOA Form after not attending many events", "Didn't Fill out Unit Discharge Form before leaving the unit"], "other": true, "required": true}, {"id": "timeframe", "type": "choice", "label": "Time Frame Measured for Attendance Issues", "options": ["1 Week", "2 Weeks", "30 Days", "90 Days", "6 Months"]}, {"id": "absences", "type": "text", "label": "If Problem is Attendance, what's the number of Absences in the time frame measured"}, {"id": "leave_early", "type": "text", "label": "If Problem is Attendance, what's the number of Leave Early's in the time frame measured"}, {"id": "date", "type": "date", "label": "Date of Concern", "required": true}, {"id": "time", "type": "time", "label": "Time of Incident if Relevant"}, {"id": "explain", "type": "long", "label": "Officer, please give a detailed explanation of the concern", "required": true}, {"id": "evidence", "type": "long", "label": "Supporting Documents, Photo's, or Video's", "help": "Paste links to screenshots, clips or documents (Discord, Google Drive, YouTube, etc.)."}, {"id": "statement", "type": "long", "label": "Trooper Statement"}, {"id": "action", "type": "checks", "label": "Action(s) to be taken today", "options": ["Written Warning", "Probation (Continue to attend events under supervision)", "Suspension (Suspended from attending events)", "Demotion", "Removal from current MOS", "Dismissal", "Blacklist"], "other": true, "required": true}, {"id": "next", "type": "checks", "label": "Consequence(s) should similar incident happen again", "options": ["Written Warning", "Probation (Continue to attend events under supervision)", "Suspension (Suspended from attending events)", "Demotion", "Removal from current MOS", "Dismissal", "Blacklist"], "other": true, "required": true}, {"id": "comments", "type": "long", "label": "Officer, additional comments if needed"}]$q$::jsonb, 0, 'High Command', array['admin','high-com'], true);
end $$;

-- Matches the Google Form's order (Flanker 2026-10-23): Today's Date, Division and MOS after Discord ID; Stagnant Growth added.
update public.forms set questions = $q$[{"id": "trooper", "type": "text", "label": "Trooper Receiving D.A. {CT-#### \"Nickname\"} & {Discord Tag}", "required": true}, {"id": "trooper_discord", "type": "text", "label": "Trooper Discord ID", "required": true}, {"id": "today", "type": "date", "label": "Today's Date"}, {"id": "division", "type": "select", "label": "Division", "options": ["Arma 3", "VRChat"], "required": true}, {"id": "mos", "type": "text", "label": "MOS", "required": true}, {"id": "rank", "type": "long", "label": "Trooper's Rank", "required": true}, {"id": "officer1", "type": "text", "label": "Your CT-#### \"Nickname\" (1)", "required": true}, {"id": "officer2", "type": "text", "label": "Officer CT-#### \"Nickname\" (2)"}, {"id": "officer3", "type": "text", "label": "Officer CT-#### \"Nickname\" (3)"}, {"id": "officer4", "type": "text", "label": "Officer CT-#### \"Nickname\" (4)"}, {"id": "hc", "type": "select", "label": "High Command Member if Present", "options": ["Flanker", "Wendigo", "Terminator", "Phoenix", "Wayside"]}, {"id": "concern", "type": "checks", "label": "Type of Concern", "options": ["Insubordination", "Violation of Unit Rules", "Unauthorized Use of Role or Rank", "Excessive Absenteeism", "Excessive Leaving Early (Without Reason)", "Poor Attitude Towards Unit Members", "Poor Attitude Towards Non - Members", "Poor Representation of 228th Values in a Public Setting", "Stagnant Growth with their Position", "Dress Code Violation", "Lacks Following Through with tactics taught in training", "Doesn't Accept Coaching well from Officers or C.O.C.", "Poor Workmanship - Doesn't put effort into events", "Inconsistent Performance", "Lacks Initiative at Times", "Profanity", "Disappears for Longer than Expected at Times", "Has a Bad Habit of Disappearing during Events to do own thing", "Negative Attitude in General", "Struggles being a Team Player", "Rude Towards Allies", "Rude Towards Fellow Unit Members", "Intentionally or Unintentionally Starting Rumors about Fellow Unit Members", "Didn't Show up to a Mandatory Meeting", "Didn't Fill out LOA Form after not attending many events", "Didn't Fill out Unit Discharge Form before leaving the unit"], "other": true, "required": true}, {"id": "timeframe", "type": "choice", "label": "Time Frame Measured for Attendance Issues", "options": ["1 Week", "2 Weeks", "30 Days", "90 Days", "6 Months"]}, {"id": "absences", "type": "text", "label": "If Problem is Attendance, what's the number of Absences in the time frame measured"}, {"id": "leave_early", "type": "text", "label": "If Problem is Attendance, what's the number of Leave Early's in the time frame measured"}, {"id": "date", "type": "date", "label": "Date of Concern", "required": true}, {"id": "time", "type": "time", "label": "Time of Incident if Relevant"}, {"id": "explain", "type": "long", "label": "Officer, please give a detailed explanation of the concern", "required": true}, {"id": "evidence", "type": "long", "label": "Supporting Documents, Photo's, or Video's", "help": "Paste links to screenshots, clips or documents (Discord, Google Drive, YouTube, etc.)."}, {"id": "statement", "type": "long", "label": "Trooper Statement"}, {"id": "action", "type": "checks", "label": "Action(s) to be taken today", "options": ["Written Warning", "Probation (Continue to attend events under supervision)", "Suspension (Suspended from attending events)", "Demotion", "Removal from current MOS", "Dismissal", "Blacklist"], "other": true, "required": true}, {"id": "next", "type": "checks", "label": "Consequence(s) should similar incident happen again", "options": ["Written Warning", "Probation (Continue to attend events under supervision)", "Suspension (Suspended from attending events)", "Demotion", "Removal from current MOS", "Dismissal", "Blacklist"], "other": true, "required": true}, {"id": "comments", "type": "long", "label": "Officer, additional comments if needed"}]$q$::jsonb
  where title = 'Disciplinary Action Submission' and not questions @> '[{"id":"mos"}]';

-- AFTER you log in on the site for the first time, run this one line (with your email or Discord name)
-- to make yourself the first admin. Everything after that is done from the dashboard.
-- update public.profiles set status = 'approved', role = 'admin' where email = 'YOUR-EMAIL-HERE';
