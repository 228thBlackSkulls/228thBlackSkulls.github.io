
-- One-time change (2026-10-19): roles become Admin, High-Com and the 228th rank list (Recruit at the bottom).
-- Anyone who was Officer moves to High-Com and anyone who was NCO moves to Recruit, then those two roles are removed.
update public.profiles set role = 'high-com' where role = 'officer';
update public.profiles set role = 'member'   where role = 'nco';
update public.posts set visible_to = array(select distinct v from unnest(array_replace(visible_to, 'officer', 'high-com')) v) where 'officer' = any(visible_to);
update public.posts set visible_to = array_remove(visible_to, 'nco') where 'nco' = any(visible_to);
delete from public.roles where name in ('officer', 'nco');
update public.roles set label = 'Recruit', rank = 10 where name = 'member';
