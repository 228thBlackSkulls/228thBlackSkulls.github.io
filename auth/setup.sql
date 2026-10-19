-- 228th Black Skulls Corps: member accounts, approval and roles.
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run. Safe to run once on a new project.

-- Roles. "rank" decides what a role can see: a higher rank sees everything a lower rank can.
create table if not exists public.roles (
  name  text primary key,
  label text not null,
  rank  int  not null default 10
);
insert into public.roles (name, label, rank) values
  ('admin',   'Admin',   100),
  ('officer', 'Officer',  50),
  ('nco',     'NCO',      30),
  ('member',  'Member',   10)
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

-- Members-page posts. min_role is the lowest role that can read the post.
create table if not exists public.posts (
  id         bigint generated always as identity primary key,
  title      text not null,
  body       text,
  min_role   text not null default 'member' references public.roles(name) on update cascade,
  pinned     boolean not null default false,
  author     uuid default auth.uid(),
  created_at timestamptz not null default now()
);

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

-- Create a profile whenever someone signs up (Discord or email).
-- Names must be the 228th callsign: two to four letters, a dash, four numbers, then the nickname in quotes,
-- like CC-5733 "Flanker". Curly quotes from phone keyboards are straightened. Each number can only be used once.
create or replace function public.check_callsign() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.display_name is null then return new; end if;
  new.display_name := regexp_replace(btrim(translate(new.display_name, '“”„‟″', '"""""')), '\s+', ' ', 'g');
  new.display_name := regexp_replace(new.display_name, '^([A-Za-z]{2,4})\s*-\s*([0-9]{4})\s*"\s*(.*?)\s*"$', '\1-\2 "\3"');
  new.display_name := upper(split_part(new.display_name, '-', 1)) || substr(new.display_name, length(split_part(new.display_name, '-', 1)) + 1);
  if new.display_name !~ '^[A-Z]{2,4}-[0-9]{4} "[A-Za-z0-9][A-Za-z0-9 .''-]{0,23}"$' then
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
  insert into public.profiles (id, email, display_name, discord_name, avatar_url)
  values (
    new.id,
    new.email,
    nullif(m->>'display_name', ''),
    case when new.raw_app_meta_data->>'provider' = 'discord' then coalesce(m->>'full_name', m->>'name') end,
    m->>'avatar_url'
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

-- Roster for approved members: names, roles and pictures only (no emails).
create or replace function public.member_roster()
returns table (display_name text, avatar_url text, role text, role_label text, rank int, approved_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.display_name, p.avatar_url, p.role, r.label, r.rank, p.approved_at
  from profiles p join roles r on r.name = p.role
  where p.status = 'approved' and my_rank() > 0
  order by r.rank desc, p.display_name;
$$;

revoke execute on function public.set_member(uuid, text, text) from public, anon;
revoke execute on function public.member_roster() from public, anon;
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
grant  update (display_name, note) on public.profiles to authenticated;
drop policy if exists profiles_read   on public.profiles;
drop policy if exists profiles_update on public.profiles;
drop policy if exists profiles_delete on public.profiles;
create policy profiles_read   on public.profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());
create policy profiles_delete on public.profiles for delete to authenticated using (is_admin());

-- Posts: approved members read posts at or below their rank; admins manage them.
drop policy if exists posts_read  on public.posts;
drop policy if exists posts_admin on public.posts;
create policy posts_read  on public.posts for select to authenticated
  using (my_rank() > 0 and my_rank() >= coalesce((select r.rank from roles r where r.name = posts.min_role), 0));
create policy posts_admin on public.posts for all to authenticated using (is_admin()) with check (is_admin());


-- AFTER you log in on the site for the first time, run this one line (with your email or Discord name)
-- to make yourself the first admin. Everything after that is done from the dashboard.
-- update public.profiles set status = 'approved', role = 'admin' where email = 'YOUR-EMAIL-HERE';
