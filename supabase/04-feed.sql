-- =====================================================================
--  status448: the feed, comments and the chat room.
--  Run AFTER 01-base.sql, 02-guests.sql and 03-users.sql.
--  Paste into SQL Editor, press Run. Safe to re-run.
--
--    feed       posts people write on their own wall + every article,
--               newest first (a read-only view, nothing is copied)
--    comments   under feed posts and articles; accounts write, everyone
--               reads, authors edit their own, only the owner deletes
--    chat       one shared room; accounts write, everyone reads,
--               only the owner deletes
-- =====================================================================

-- ---------- which posts belong in the feed ----------
-- the owner on the main wall, or a person on their own wall
alter table public.posts add column if not exists in_feed boolean
  generated always as ((user_id is null and author_key is null and wall is null)
                    or (user_id is not null and wall = user_id)) stored;
create index if not exists posts_in_feed on public.posts (created_at desc) where in_feed;

-- author_id: null means the owner
create or replace view public.feed with (security_invoker = true) as
  select 'post'::text as kind, p.id, p.user_id as author_id, null::text as title,
         p.text as body, p.created_at, p.edited_at is not null as edited
    from public.posts p where p.in_feed
  union all
  select 'article'::text, a.id, a.user_id, a.title,
         left(a.body, 400), a.created_at, (a.updated_at - a.created_at) > interval '1 minute'
    from public.articles a;
grant select on public.feed to anon, authenticated;

-- the display name of an account: a person's profile name, or the owner's
create or replace function public.account_name(uid uuid, out name text, out nick text)
language plpgsql stable security definer set search_path = '' as $$
begin
  select u.name, u.nick into name, nick from public.users_profile u where u.id = uid;
  if name is null and public.is_owner() and uid = auth.uid() then
    select p.name into name from public.profile p where p.id = 1;
    nick := null;
  end if;
end $$;
revoke all on function public.account_name(uuid) from public, anon, authenticated;

-- ---------- comments ----------
create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  target_kind text not null check (target_kind in ('post', 'article')),
  target_id   uuid not null,
  user_id     uuid not null references auth.users (id) on delete cascade,
  author      text not null default '' check (char_length(author) <= 40),
  author_nick text check (author_nick is null or author_nick ~ '^[a-z0-9_]{3,20}$'),
  text        text not null check (char_length(text) between 1 and 1000),
  created_at  timestamptz not null default now(),
  edited_at   timestamptz
);
create index if not exists comments_target on public.comments (target_id, created_at);

create or replace function public.comments_accounts() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n text; k text;
begin
  if tg_op = 'INSERT' then
    if new.target_kind = 'post' and not exists (select 1 from public.posts where id = new.target_id) then
      raise exception 'That post is gone.';
    end if;
    if new.target_kind = 'article' and not exists (select 1 from public.articles where id = new.target_id) then
      raise exception 'That article is gone.';
    end if;
    select a.name, a.nick into n, k from public.account_name(new.user_id) a;
    if n is null then raise exception 'Your account has no profile yet.'; end if;
    new.author := n; new.author_nick := k; new.created_at := now(); new.edited_at := null;
    if not public.is_owner() then
      if exists (select 1 from public.comments where user_id = new.user_id and created_at > now() - interval '5 seconds') then
        raise exception 'Slow down: one comment every 5 seconds.';
      end if;
      if (select count(*) from public.comments where user_id = new.user_id and created_at > now() - interval '1 day') >= 300 then
        raise exception 'That is 300 comments today. Come back tomorrow.';
      end if;
    end if;
  else
    -- an author may change the text, nothing else
    new.id := old.id; new.target_kind := old.target_kind; new.target_id := old.target_id;
    new.user_id := old.user_id; new.author := old.author; new.author_nick := old.author_nick;
    new.created_at := old.created_at; new.edited_at := now();
  end if;
  return new;
end $$;
drop trigger if exists accounts on public.comments;
create trigger accounts before insert or update on public.comments for each row execute function public.comments_accounts();

alter table public.comments enable row level security;
drop policy if exists "read: everyone"       on public.comments;
drop policy if exists "insert: account"      on public.comments;
drop policy if exists "update: own comment"  on public.comments;
drop policy if exists "delete: owner"        on public.comments;
create policy "read: everyone" on public.comments for select to anon, authenticated using (true);
create policy "insert: account" on public.comments for insert to authenticated
  with check (user_id = auth.uid() and (public.is_owner() or exists (select 1 from public.users_profile u where u.id = auth.uid())));
create policy "update: own comment" on public.comments for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "delete: owner" on public.comments for delete to authenticated using (public.is_owner());

-- comments leave together with their post or article
create or replace function public.drop_comments() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.comments where target_id = old.id;
  return old;
end $$;
drop trigger if exists drop_comments on public.posts;
drop trigger if exists drop_comments on public.articles;
create trigger drop_comments after delete on public.posts    for each row execute function public.drop_comments();
create trigger drop_comments after delete on public.articles for each row execute function public.drop_comments();

-- ---------- the chat room ----------
create table if not exists public.chat_messages (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  author      text not null default '' check (char_length(author) <= 40),
  author_nick text check (author_nick is null or author_nick ~ '^[a-z0-9_]{3,20}$'),
  text        text not null check (char_length(text) between 1 and 500),
  created_at  timestamptz not null default now()
);
create index if not exists chat_created on public.chat_messages (created_at desc);

create or replace function public.chat_accounts() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n text; k text;
begin
  select a.name, a.nick into n, k from public.account_name(new.user_id) a;
  if n is null then raise exception 'Your account has no profile yet.'; end if;
  new.author := n; new.author_nick := k; new.created_at := now();
  if not public.is_owner() then
    if exists (select 1 from public.chat_messages where user_id = new.user_id and created_at > now() - interval '2 seconds') then
      raise exception 'Slow down a little.';
    end if;
    if (select count(*) from public.chat_messages where user_id = new.user_id and created_at > now() - interval '1 day') >= 500 then
      raise exception 'That is 500 messages today. Come back tomorrow.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists accounts on public.chat_messages;
create trigger accounts before insert on public.chat_messages for each row execute function public.chat_accounts();

alter table public.chat_messages enable row level security;
drop policy if exists "read: everyone"  on public.chat_messages;
drop policy if exists "insert: account" on public.chat_messages;
drop policy if exists "delete: owner"   on public.chat_messages;
create policy "read: everyone" on public.chat_messages for select to anon, authenticated using (true);
create policy "insert: account" on public.chat_messages for insert to authenticated
  with check (user_id = auth.uid() and (public.is_owner() or exists (select 1 from public.users_profile u where u.id = auth.uid())));
create policy "delete: owner" on public.chat_messages for delete to authenticated using (public.is_owner());

-- ---------- live updates ----------
do $$
declare t text;
begin
  foreach t in array array['comments', 'chat_messages'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

select 'feed, comments and chat are set up' as done;
