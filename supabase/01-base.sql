-- =====================================================================
--  status448: database, rules and photo storage for Supabase.
--
--  1. Paste YOUR user id between the quotes on the next line
--     (Authentication -> Users -> your row -> User UID).
--  2. Select everything, paste into SQL Editor, press Run.
--  Safe to run again: it updates what is already there.
-- =====================================================================
select set_config('s448.owner', '601e29a2-e3d6-4437-a6b5-b71663a8bdcd', false);

-- ---------- who is the owner ----------
-- One function holds the owner's id; every rule below asks it.
do $$
declare uid text := current_setting('s448.owner');
begin
  if uid !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    raise exception 'Paste your user id on line 9 first (it looks like 1a2b3c4d-...).';
  end if;
  execute format($f$
    create or replace function public.is_owner() returns boolean
    language sql stable security definer set search_path = ''
    as $b$ select coalesce(auth.uid() = %L::uuid, false) $b$
  $f$, uid);
end $$;
revoke all on function public.is_owner() from public;
grant execute on function public.is_owner() to anon, authenticated;

-- ---------- limits for the profile lists ----------
-- fields: up to 12 lines of { label: 1-30 chars, value: 0-120 chars }
create or replace function public.valid_fields(j jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(j) = 'array' and jsonb_array_length(j) <= 12 and not exists (
    select 1 from jsonb_array_elements(j) e
    where jsonb_typeof(e) <> 'object'
       or (select count(*) from jsonb_object_keys(e)) <> 2
       or jsonb_typeof(e->'label') is distinct from 'string'
       or jsonb_typeof(e->'value') is distinct from 'string'
       or char_length(e->>'label') not between 1 and 30
       or char_length(e->>'value') > 120)
$$;
-- links: up to 6 of { label: 1-24, sub: 0-40, url: http(s) or mailto, up to 300 }
create or replace function public.valid_links(j jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(j) = 'array' and jsonb_array_length(j) <= 6 and not exists (
    select 1 from jsonb_array_elements(j) e
    where jsonb_typeof(e) <> 'object'
       or (select count(*) from jsonb_object_keys(e)) <> 3
       or jsonb_typeof(e->'label') is distinct from 'string'
       or jsonb_typeof(e->'sub') is distinct from 'string'
       or jsonb_typeof(e->'url') is distinct from 'string'
       or char_length(e->>'label') not between 1 and 24
       or char_length(e->>'sub') > 40
       or char_length(e->>'url') > 300
       or (e->>'url') !~* '^(https?://|mailto:)[^[:space:]]+$')
$$;

-- ---------- tables ----------
create table if not exists public.profile (
  id          smallint primary key default 1 check (id = 1),     -- exactly one row
  name        text not null check (char_length(name) between 1 and 40),
  aka         text not null default '' check (char_length(aka) <= 60),
  tagline     text not null default '' check (char_length(tagline) <= 60),
  track       text not null default '' check (char_length(track) <= 80),
  fields      jsonb not null default '[]' check (public.valid_fields(fields)),
  links       jsonb not null default '[]' check (public.valid_links(links)),
  avatar_path text check (avatar_path ~ '^avatar-[0-9]{10,16}\.jpg$'),
  updated_at  timestamptz not null default now()
);

create table if not exists public.posts (
  id         uuid primary key default gen_random_uuid(),
  text       text not null check (char_length(text) between 1 and 500),
  created_at timestamptz not null default now(),
  edited_at  timestamptz
);
create index if not exists posts_created on public.posts (created_at desc);

create table if not exists public.articles (
  id         uuid primary key default gen_random_uuid(),
  title      text not null check (char_length(title) between 1 and 120),
  body       text not null check (char_length(body) between 1 and 100000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists articles_created on public.articles (created_at desc);

-- ---------- times are set by the server, never by the browser ----------
create or replace function public.stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_table_name = 'profile' then
    new.id := 1; new.updated_at := now();
  elsif tg_table_name = 'posts' then
    if tg_op = 'INSERT' then new.created_at := now(); new.edited_at := null;
    else new.created_at := old.created_at; new.edited_at := now(); end if;
  else
    if tg_op = 'INSERT' then new.created_at := now();
    else new.created_at := old.created_at; end if;
    new.updated_at := now();
  end if;
  if tg_op = 'UPDATE' then new.id := old.id; end if;
  return new;
end $$;
drop trigger if exists stamp on public.profile;
drop trigger if exists stamp on public.posts;
drop trigger if exists stamp on public.articles;
create trigger stamp before insert or update on public.profile  for each row execute function public.stamp();
create trigger stamp before insert or update on public.posts    for each row execute function public.stamp();
create trigger stamp before insert or update on public.articles for each row execute function public.stamp();

-- the one profile row, with the starting content
insert into public.profile (id, name, aka, tagline, track, fields, links) values (1,
  '448', 'тринадцатый', 'Too Busy Shipping', '448 radio: one hour, no skips',
  '[{"label":"Occupation","value":"FullStack Developer"},{"label":"Location","value":"Georgia"},
    {"label":"Relationship","value":"with my code"},{"label":"Member since","value":"before the first commit"},
    {"label":"Looking for","value":"the missing semicolon"},{"label":"Interests","value":"shipping, dark themes, 3 a.m."},
    {"label":"Political views","value":"tabs"},{"label":"Favorite music","value":"a mechanical keyboard, solo"},
    {"label":"Favorite quote","value":"\"it worked yesterday\""}]',
  '[{"label":"Telegram","sub":"@outsidero","url":"https://t.me/outsidero"},
    {"label":"Discord","sub":"@sl1nkix","url":"https://discord.com/"},
    {"label":"GitHub","sub":"aristocratonly","url":"https://github.com/aristocratonly"}]')
on conflict (id) do nothing;

-- ---------- Row Level Security: everyone reads, only the owner writes ----------
alter table public.profile  enable row level security;
alter table public.posts    enable row level security;
alter table public.articles enable row level security;

drop policy if exists "read: everyone"  on public.profile;
drop policy if exists "update: owner"   on public.profile;
create policy "read: everyone" on public.profile for select to anon, authenticated using (true);
create policy "update: owner"  on public.profile for update to authenticated using (public.is_owner()) with check (public.is_owner());
-- no insert or delete policy for the profile: the single row can only be edited

do $$
declare t text;
begin
  foreach t in array array['posts', 'articles'] loop
    execute format('drop policy if exists "read: everyone" on public.%I', t);
    execute format('drop policy if exists "insert: owner" on public.%I', t);
    execute format('drop policy if exists "update: owner" on public.%I', t);
    execute format('drop policy if exists "delete: owner" on public.%I', t);
    execute format('create policy "read: everyone" on public.%I for select to anon, authenticated using (true)', t);
    execute format('create policy "insert: owner" on public.%I for insert to authenticated with check (public.is_owner())', t);
    execute format('create policy "update: owner" on public.%I for update to authenticated using (public.is_owner()) with check (public.is_owner())', t);
    execute format('create policy "delete: owner" on public.%I for delete to authenticated using (public.is_owner())', t);
  end loop;
end $$;

-- ---------- live updates (Supabase Realtime) ----------
do $$
declare t text;
begin
  foreach t in array array['profile', 'posts', 'articles'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---------- photo storage: public to look at, only the owner uploads ----------
-- The bucket itself refuses anything that is not a JPEG of 200 KB or less.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 200000, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 200000, allowed_mime_types = array['image/jpeg'];

drop policy if exists "avatars: owner sees files" on storage.objects;
drop policy if exists "avatars: owner uploads"    on storage.objects;
drop policy if exists "avatars: owner replaces"   on storage.objects;
drop policy if exists "avatars: owner deletes"    on storage.objects;
create policy "avatars: owner sees files" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and public.is_owner());
create policy "avatars: owner uploads" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and public.is_owner() and name ~ '^avatar-[0-9]{10,16}\.jpg$');
create policy "avatars: owner replaces" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and public.is_owner())
  with check (bucket_id = 'avatars' and public.is_owner() and name ~ '^avatar-[0-9]{10,16}\.jpg$');
create policy "avatars: owner deletes" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and public.is_owner());

select 'status448 is set up. Owner: ' || current_setting('s448.owner') as done;
