-- =====================================================================
--  status448: accounts for everyone. Run AFTER 01-base.sql and
--  02-guests.sql. Paste into SQL Editor, press Run. Safe to re-run.
--
--  Who can do what:
--    everyone            reads every profile, wall, article, follower list
--    a registered user   edits only their own profile and photo, writes on
--                        any wall, edits only their own posts and articles,
--                        follows / unfollows people for themselves
--    the owner (you)     everything above, plus deletes any post, article
--                        or whole profile
--    guests (no account) read; post only on the owner's main wall, as before
-- =====================================================================

-- ---------- profiles ----------
create table if not exists public.users_profile (
  id          uuid primary key references auth.users (id) on delete cascade,
  nick        text not null unique check (nick ~ '^[a-z0-9_]{3,20}$'),
  name        text not null check (char_length(name) between 1 and 40),
  aka         text not null default '' check (char_length(aka) <= 60),
  tagline     text not null default '' check (char_length(tagline) <= 60),
  track       text not null default '' check (char_length(track) <= 80),
  fields      jsonb not null default '[]' check (public.valid_fields(fields)),
  links       jsonb not null default '[]' check (public.valid_links(links)),
  avatar_path text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint users_profile_avatar check (avatar_path is null or avatar_path ~ ('^u/' || id::text || '/avatar-[0-9]{10,16}\.jpg$'))
);
create index if not exists users_profile_created on public.users_profile (created_at desc);

-- the nickname and the id never change; times are the server's
create or replace function public.users_profile_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.id := old.id; new.nick := old.nick; new.created_at := old.created_at; new.updated_at := now();
  return new;
end $$;
drop trigger if exists guard on public.users_profile;
create trigger guard before update on public.users_profile for each row execute function public.users_profile_guard();

alter table public.users_profile enable row level security;
drop policy if exists "read: everyone" on public.users_profile;
drop policy if exists "update: self"   on public.users_profile;
drop policy if exists "delete: owner"  on public.users_profile;
create policy "read: everyone" on public.users_profile for select to anon, authenticated using (true);
create policy "update: self"   on public.users_profile for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "delete: owner"  on public.users_profile for delete to authenticated using (public.is_owner());
-- no insert policy: the profile is made by the sign-up trigger below

-- sign-up: the nickname travels in the account's metadata; a bad or taken one stops the sign-up
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n text := lower(btrim(coalesce(new.raw_user_meta_data ->> 'nick', '')));
begin
  if n = '' then return new; end if;                -- accounts made in the dashboard (like the owner's)
  if n !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Nickname: 3 to 20 latin letters, digits or _';
  end if;
  if n in ('448', 'admin', 'owner', 'status448', 'root', 'support', 'moderator', 'system', 'null') then
    raise exception 'That nickname is reserved.';
  end if;
  insert into public.users_profile (id, nick, name) values (new.id, n, n);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ---------- posts: every profile has a wall ----------
alter table public.posts add column if not exists wall        uuid references auth.users (id) on delete cascade;  -- null = the owner's main wall
alter table public.posts add column if not exists user_id     uuid references auth.users (id) on delete cascade;  -- the account that wrote it
alter table public.posts add column if not exists author_nick text;
create index if not exists posts_wall on public.posts (wall, created_at desc);
alter table public.posts drop constraint if exists posts_author_check;
alter table public.posts add constraint posts_author_check check (
  -- the owner on the main wall
     (user_id is null and author is null and author_key is null and author_nick is null and wall is null)
  -- a guest on the main wall
  or (user_id is null and author_key ~ '^[0-9a-f]{64}$' and char_length(author) between 1 and 24
      and author_nick is null and wall is null and char_length(text) <= 280)
  -- an account, on any wall
  or (user_id is not null and author_key is null and char_length(author) between 1 and 40
      and (author_nick is null or author_nick ~ '^[a-z0-9_]{3,20}$'))
);

create or replace function public.posts_accounts() returns trigger
language plpgsql security definer set search_path = '' as $$
declare pn text; pk text;
begin
  if tg_op = 'INSERT' then
    if new.wall is not null and not exists (select 1 from public.users_profile u where u.id = new.wall) then
      raise exception 'There is no such wall.';
    end if;
    if new.user_id is not null then
      new.author_key := null;
      if public.is_owner() then
        select p.name into pn from public.profile p where p.id = 1;
        new.author := pn; new.author_nick := null;
      else
        select u.name, u.nick into pn, pk from public.users_profile u where u.id = new.user_id;
        if pn is null then raise exception 'Your account has no profile yet.'; end if;
        new.author := pn; new.author_nick := pk;
        if exists (select 1 from public.posts where user_id = new.user_id and created_at > now() - interval '10 seconds') then
          raise exception 'Slow down: one post every 10 seconds.';
        end if;
        if (select count(*) from public.posts where user_id = new.user_id and created_at > now() - interval '1 day') >= 200 then
          raise exception 'That is 200 posts today. Come back tomorrow.';
        end if;
      end if;
    end if;
  elsif not public.is_owner() then
    -- an author may change the text of their post, nothing else
    new.wall := old.wall; new.user_id := old.user_id; new.author := old.author;
    new.author_nick := old.author_nick; new.author_key := old.author_key;
  end if;
  return new;
end $$;
drop trigger if exists accounts on public.posts;
create trigger accounts before insert or update on public.posts for each row execute function public.posts_accounts();

drop policy if exists "insert: account"    on public.posts;
drop policy if exists "update: own post"   on public.posts;
create policy "insert: account"  on public.posts for insert to authenticated
  with check (user_id = auth.uid() and author_key is null
              and exists (select 1 from public.users_profile u where u.id = auth.uid()));
create policy "update: own post" on public.posts for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- deleting stays with the owner ("delete: owner" from 01-base.sql)

-- only the owner deletes posts now: guests lose the delete button
revoke execute on function public.guest_delete(text, uuid) from anon, authenticated;

-- ---------- articles: everyone with an account can write their own ----------
alter table public.articles add column if not exists user_id uuid references auth.users (id) on delete cascade;  -- null = the owner's
create index if not exists articles_user on public.articles (user_id, created_at desc);

create or replace function public.articles_accounts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if public.is_owner() then return new; end if;
  if tg_op = 'INSERT' then
    if (select count(*) from public.articles where user_id = new.user_id and created_at > now() - interval '1 day') >= 20 then
      raise exception 'That is 20 articles today. Come back tomorrow.';
    end if;
  else
    new.user_id := old.user_id;
  end if;
  return new;
end $$;
drop trigger if exists accounts on public.articles;
create trigger accounts before insert or update on public.articles for each row execute function public.articles_accounts();

drop policy if exists "insert: account"     on public.articles;
drop policy if exists "update: own article" on public.articles;
create policy "insert: account" on public.articles for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from public.users_profile u where u.id = auth.uid()));
create policy "update: own article" on public.articles for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- follows: who follows whom ----------
create table if not exists public.follows (
  follower   uuid not null references auth.users (id) on delete cascade,
  followee   uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);
create index if not exists follows_followee on public.follows (followee);

create or replace function public.follows_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.created_at := now();
  if (select count(*) from public.follows where follower = new.follower and created_at > now() - interval '1 hour') >= 60 then
    raise exception 'That is a lot of following for one hour. Take a break.';
  end if;
  return new;
end $$;
drop trigger if exists limit_follows on public.follows;
create trigger limit_follows before insert on public.follows for each row execute function public.follows_limit();

alter table public.follows enable row level security;
drop policy if exists "read: everyone"   on public.follows;
drop policy if exists "follow: self"     on public.follows;
drop policy if exists "unfollow: self"   on public.follows;
create policy "read: everyone" on public.follows for select to anon, authenticated using (true);
create policy "follow: self"   on public.follows for insert to authenticated with check (follower = auth.uid());
create policy "unfollow: self" on public.follows for delete to authenticated using (follower = auth.uid() or public.is_owner());

-- ---------- the owner removes a whole account ----------
create or replace function public.admin_delete_user(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Only the owner can delete profiles.'; end if;
  if target = auth.uid() then raise exception 'That is your own account.'; end if;
  delete from auth.users where id = target;          -- profile, posts, articles, follows go with it
end $$;
revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- ---------- photos: each account has its own folder u/<id>/ ----------
drop policy if exists "avatars: account uploads" on storage.objects;
drop policy if exists "avatars: account sees own" on storage.objects;
drop policy if exists "avatars: account deletes own" on storage.objects;
create policy "avatars: account uploads" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and name ~ ('^u/' || auth.uid()::text || '/avatar-[0-9]{10,16}\.jpg$'));
create policy "avatars: account sees own" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and name like ('u/' || auth.uid()::text || '/%'));
create policy "avatars: account deletes own" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and name like ('u/' || auth.uid()::text || '/%'));

-- ---------- live updates ----------
do $$
declare t text;
begin
  foreach t in array array['users_profile', 'follows'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

select 'accounts, profiles, walls and follows are set up' as done;
