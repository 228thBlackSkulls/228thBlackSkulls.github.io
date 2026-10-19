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
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_signup_fields_check') then
    alter table public.profiles add constraint profiles_signup_fields_check check (
      (division is null or division in ('Arma 3', 'VRChat')) and coalesce(length(current_rank), 0) <= 60
      and coalesce(length(discord_name), 0) <= 60 and coalesce(length(note), 0) <= 1000);
  end if;
end $$;

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

-- Keep role and all_roles in step. Setting role on its own (approving someone) replaces the list with that one role;
-- changing the list keeps only real roles, falls back to Recruit when empty, and makes role the highest one.
create or replace function public.sync_roles() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.all_roles is not distinct from old.all_roles and new.role is distinct from old.role then
    new.all_roles := array[new.role];
  elsif tg_op = 'INSERT' and cardinality(new.all_roles) = 0 then
    new.all_roles := array[new.role];
  end if;
  new.all_roles := coalesce((select array_agg(r.name order by r.rank desc) from roles r where r.name = any(new.all_roles)), '{}');
  if cardinality(new.all_roles) = 0 then new.all_roles := array['member']; end if;
  new.role := new.all_roles[1];
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
  return old;
end $$;
drop trigger if exists roles_removed on public.roles;
create trigger roles_removed before delete on public.roles for each row execute function public.role_removed();

create or replace function public.roles_reordered() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profiles set all_roles = all_roles where cardinality(all_roles) > 1;
  return null;
end $$;
drop trigger if exists roles_reordered on public.roles;
create trigger roles_reordered after update of rank on public.roles for each statement execute function public.roles_reordered();

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
  if tg_op = 'UPDATE' and new.display_name is distinct from old.display_name and old.status = 'approved' and not is_admin() then
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
    case when m->>'division' in ('Arma 3', 'VRChat') then m->>'division' end,
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
  if not is_admin() then raise exception 'Admins only'; end if;
  if target = auth.uid() and (new_status <> 'approved' or new_role <> 'admin') then
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
  if not is_admin() then raise exception 'Admins only'; end if;
  if target = auth.uid() and not ('admin' = any(new_roles)) then raise exception 'You can''t remove your own admin access'; end if;
  update profiles set all_roles = new_roles where id = target;
end $$;
revoke execute on function public.set_roles(uuid, text[]) from public, anon;
grant  execute on function public.set_roles(uuid, text[]) to authenticated;

-- Roster for approved members: names, roles and pictures only (no emails).
drop function if exists public.member_roster();
create or replace function public.member_roster()
returns table (display_name text, avatar_url text, role text, role_label text, rank int, approved_at timestamptz, role_labels text[])
language sql stable security definer set search_path = public as $$
  select p.display_name, p.avatar_url, p.role, r.label, r.rank, p.approved_at,
    (select array_agg(x.label order by x.rank desc) from roles x where x.name = any(p.all_roles))
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
create policy profiles_read   on public.profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());
create policy profiles_delete on public.profiles for delete to authenticated using (is_admin());

-- Posts: approved members read posts meant for everyone or for their role; admins see and manage all of them.
drop policy if exists posts_read  on public.posts;
drop policy if exists posts_admin on public.posts;
create policy posts_read  on public.posts for select to authenticated
  using (my_roles() is not null and (cardinality(visible_to) = 0 or visible_to && my_roles() or is_admin()));
create policy posts_admin on public.posts for all to authenticated using (is_admin()) with check (is_admin());


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

-- AFTER you log in on the site for the first time, run this one line (with your email or Discord name)
-- to make yourself the first admin. Everything after that is done from the dashboard.
-- update public.profiles set status = 'approved', role = 'admin' where email = 'YOUR-EMAIL-HERE';
