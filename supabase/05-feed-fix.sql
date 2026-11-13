-- =====================================================================
--  status448: only posts written in the feed go to the feed.
--  Run AFTER 04-feed.sql. Paste into SQL Editor, press Run.
--  Safe to re-run.
--
--  Before: everything a person wrote on their own wall showed in the feed,
--  so messages on The Wall leaked into it. Now a post carries from_feed,
--  set only by the feed's own "What's new?" box. Wall messages stay on walls.
-- =====================================================================

alter table public.posts add column if not exists from_feed boolean not null default false;

-- a feed post is always written by the wall's own person (the owner on the main
-- wall, or a person on their own wall), so nobody can push a post into the feed
-- through someone else's wall
alter table public.posts drop constraint if exists posts_from_feed_check;
alter table public.posts add constraint posts_from_feed_check check (not from_feed or in_feed);

-- an author may edit the text of a post, but not move it in or out of the feed
create or replace function public.posts_keep_feed() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not public.is_owner() then new.from_feed := old.from_feed; end if;
  return new;
end $$;
drop trigger if exists keep_feed on public.posts;
create trigger keep_feed before update on public.posts for each row execute function public.posts_keep_feed();

create index if not exists posts_from_feed on public.posts (created_at desc) where from_feed;

-- the feed: posts written in the feed + every article
create or replace view public.feed with (security_invoker = true) as
  select 'post'::text as kind, p.id, p.user_id as author_id, null::text as title,
         p.text as body, p.created_at, p.edited_at is not null as edited
    from public.posts p where p.from_feed
  union all
  select 'article'::text, a.id, a.user_id, a.title,
         left(a.body, 400), a.created_at, (a.updated_at - a.created_at) > interval '1 minute'
    from public.articles a;
grant select on public.feed to anon, authenticated;

select 'the feed now shows only posts written in the feed, plus articles' as done;
