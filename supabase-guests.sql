-- =====================================================================
--  status448: visitors' names, their posts on the wall, followers.
--  Run AFTER supabase.sql. Paste into SQL Editor, press Run.
--  Safe to run again.
--
--  Visitors never write to tables directly. They call the functions
--  below, which check every limit on the server:
--    guest_post   name 1-24, text 1-280, one post per 20 s and 30 a day
--                 per visitor, at most 60 visitor posts per 10 min overall
--    guest_delete a visitor removes only their own posts
--    follow / unfollow / is_following   one follow per visitor,
--                 at most 120 new followers per hour overall
--  Each visitor is a random key kept in their browser; the database only
--  stores its SHA-256 fingerprint, never the key itself.
-- =====================================================================

-- ---------- visitors' posts live in the same posts table ----------
alter table public.posts add column if not exists author text;
alter table public.posts add column if not exists author_key text;
alter table public.posts drop constraint if exists posts_author_check;
alter table public.posts add constraint posts_author_check
  check ((author is null and author_key is null)
      or (char_length(author) between 1 and 24 and author_key ~ '^[0-9a-f]{64}$' and char_length(text) <= 280));
create index if not exists posts_author_key on public.posts (author_key, created_at desc) where author_key is not null;

-- visitor key -> fingerprint (the key itself is never stored)
create or replace function public.guest_fingerprint(token text) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if token is null or token !~ '^[A-Za-z0-9_-]{32,64}$' then
    raise exception 'Something is off with this browser''s visitor key. Reload the page.';
  end if;
  return encode(sha256(convert_to(token, 'UTF8')), 'hex');
end $$;

create or replace function public.guest_post(token text, name text, body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  k text := public.guest_fingerprint(token);
  n text := btrim(regexp_replace(coalesce(name, ''), '\s+', ' ', 'g'));
  b text := btrim(coalesce(body, ''));
  owner_name text;
  new_id uuid;
begin
  if char_length(n) not between 1 and 24 then raise exception 'Your name should be 1 to 24 characters.'; end if;
  if char_length(b) not between 1 and 280 then raise exception 'A post should be 1 to 280 characters.'; end if;
  select p.name into owner_name from public.profile p where p.id = 1;
  if lower(n) = lower(coalesce(owner_name, '')) or lower(n) in ('448', 'admin', 'owner', 'status448') then
    raise exception 'That name belongs to the owner. Pick another one.';
  end if;
  if exists (select 1 from public.posts where author_key = k and created_at > now() - interval '20 seconds') then
    raise exception 'Slow down: one post every 20 seconds.';
  end if;
  if (select count(*) from public.posts where author_key = k and created_at > now() - interval '1 day') >= 30 then
    raise exception 'That is 30 posts today. Come back tomorrow.';
  end if;
  if (select count(*) from public.posts where author_key is not null and created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'The wall is very busy right now. Try again in a few minutes.';
  end if;
  insert into public.posts (text, author, author_key) values (b, n, k) returning id into new_id;
  return new_id;
end $$;

create or replace function public.guest_delete(token text, post_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare k text := public.guest_fingerprint(token);
begin
  delete from public.posts where id = post_id and author_key = k;
  return found;
end $$;

-- ---------- followers ----------
create table if not exists public.followers (
  key        text primary key check (key ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);
alter table public.followers enable row level security;   -- no policies: nobody reads or writes it directly

create table if not exists public.site_stats (
  id        smallint primary key default 1 check (id = 1),
  followers integer not null default 0 check (followers >= 0)
);
insert into public.site_stats (id, followers) values (1, (select count(*) from public.followers))
on conflict (id) do update set followers = excluded.followers;
alter table public.site_stats enable row level security;
drop policy if exists "read: everyone" on public.site_stats;
create policy "read: everyone" on public.site_stats for select to anon, authenticated using (true);

create or replace function public.count_followers() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.site_stats set followers = (select count(*) from public.followers) where id = 1;
  return null;
end $$;
drop trigger if exists count_followers on public.followers;
create trigger count_followers after insert or delete on public.followers
  for each statement execute function public.count_followers();

create or replace function public.follow(token text) returns integer
language plpgsql security definer set search_path = '' as $$
declare k text := public.guest_fingerprint(token);
begin
  if not exists (select 1 from public.followers where key = k) then
    if (select count(*) from public.followers where created_at > now() - interval '1 hour') >= 120 then
      raise exception 'Too many new followers this hour. Try again later.';
    end if;
    insert into public.followers (key) values (k) on conflict do nothing;
  end if;
  return (select followers from public.site_stats where id = 1);
end $$;

create or replace function public.unfollow(token text) returns integer
language plpgsql security definer set search_path = '' as $$
declare k text := public.guest_fingerprint(token);
begin
  delete from public.followers where key = k;
  return (select followers from public.site_stats where id = 1);
end $$;

create or replace function public.is_following(token text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  return exists (select 1 from public.followers where key = public.guest_fingerprint(token));
end $$;

-- only these functions are callable from the site
revoke all on function public.guest_fingerprint(text) from public, anon, authenticated;
revoke all on function public.guest_post(text, text, text) from public;
revoke all on function public.guest_delete(text, uuid) from public;
revoke all on function public.follow(text) from public;
revoke all on function public.unfollow(text) from public;
revoke all on function public.is_following(text) from public;
revoke all on function public.count_followers() from public, anon, authenticated;
grant execute on function public.guest_post(text, text, text) to anon, authenticated;
grant execute on function public.guest_delete(text, uuid) to anon, authenticated;
grant execute on function public.follow(text) to anon, authenticated;
grant execute on function public.unfollow(text) to anon, authenticated;
grant execute on function public.is_following(text) to anon, authenticated;

-- live follower count
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'site_stats') then
    alter publication supabase_realtime add table public.site_stats;
  end if;
end $$;

select 'visitors, wall posts and followers are set up' as done;
