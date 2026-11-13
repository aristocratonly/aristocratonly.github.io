<div align="center">

<img src="assets/button-88x31.png" alt="status448" width="88" height="31">

# status448

[Русский](docs/README.ru.md) · **English**

**A social network with a population of one. For now.**

A personal site styled after mid-2000s social networks: profile, wall, feed, friends and chat.
The whole frontend fits in one `index.html`, and the data lives in Supabase.

![HTML](https://img.shields.io/badge/HTML-one_file-7a1c26?style=flat-square)
![Vanilla JS](https://img.shields.io/badge/JS-vanilla-7a1c26?style=flat-square)
![Supabase](https://img.shields.io/badge/Supabase-Postgres_·_Auth_·_Realtime-5a111a?style=flat-square)
![GitHub Pages](https://img.shields.io/badge/hosted_on-GitHub_Pages-5a111a?style=flat-square)
![No build](https://img.shields.io/badge/build_step-none-d3b9b5?style=flat-square)

</div>

---

## ✦ What it is

`status448` is the profile of **448 / тринадцатый** (FullStack Developer, Georgia), made to look like a page on an old social network. The color is deep crimson, the fonts are Tahoma and Georgia, and there's an 88×31 button and a relationship status of "with my code".

It started as a single page. Now it's a small social network: you can sign up, get your own page, follow people, and write on walls, in the feed and in the shared chat.

## ✦ Features

| | |
|---|---|
| 🎬 **Intro** | "press any key to compile": an on-screen IDE types out the code of this very site, then the site appears. Plays once per visit. |
| 👤 **Profiles** | The owner's page plus a page for every user. The owner edits their page right on the site: switch on edit mode and change the text in place. |
| 🖼 **Photo** | Pick an image, crop it to a square, shrink it to a 400×400 JPEG and upload it to Supabase Storage. |
| 🧱 **Wall** | Messages on walls. Guests without an account can post only on the main wall, with limits enforced on the server. |
| 📰 **Feed** | Posts from the "What's new?" box and articles, newest first, with comments. |
| 📝 **Articles** | Long posts in Markdown. |
| 🤝 **Friends** | Following and followers. When the follow goes both ways, that person is a friend. |
| 💬 **Chat** | One shared real-time room. |
| 🟢 **Now on page** | Who is viewing the page right now (Supabase Presence). |
| 🎵 **Player** | An hour-long track, "448 radio: one hour, no skips". Keeps playing while you move around the site. |
| 🥚 **Easter eggs** | There are some. Which ones is a secret. |

## ✦ How it works

```
index.html  ──┬── shell   opened directly, the page holds the <audio>
              │           and shows the site in a full-window iframe,
              │           so the music never stops between pages
              │
              └── site    HTML + CSS + vanilla JS, no build step, no frameworks
                          supabase-js is loaded from jsDelivr on demand
                     │
                     ▼
              Supabase ── Postgres   tables, RLS policies, triggers and functions
                       ── Auth       nickname sign-in (technical e-mail <nick>@…)
                       ── Storage    profile photos
                       ── Realtime   live walls, feed and chat, Presence
```

The database itself checks every permission: RLS policies, triggers and `security definer` functions. The client only decides which buttons to show. The `sb_publishable_…` key in the code is meant to be public, by Supabase's design.

### Page addresses

| URL | Page |
|---|---|
| `./` | The owner's main page. Once you've signed up, your own page opens instead. |
| `?u=448` | The owner's profile |
| `?u=nick` | A user's profile |
| `?feed` | Feed |
| `?friends` | Friends, following and followers |
| `?chat` | Chat |
| `?nointro` | Open without the intro (handy while developing) |
| `?noshell` | Open without the player shell |

### Who can do what

| | Read | Write on walls | Own profile | Delete others' content |
|---|:-:|:-:|:-:|:-:|
| Guest | ✅ | main wall only | — | — |
| User | ✅ | ✅ | ✅ | — |
| Owner | ✅ | ✅ | ✅ | ✅ |

## ✦ Files

```
.
├── index.html              the whole site: markup, styles, scripts
├── .nojekyll               makes GitHub Pages serve files as they are
├── assets/
│   ├── photo.jpg           default photo
│   ├── button-88x31.png    88×31 banner button
│   └── music.mp3           track for the player
├── supabase/               database scripts, run in numeric order
│   ├── 01-base.sql         owner, profile, posts, articles, photo storage
│   ├── 02-guests.sql       guests: wall posts, followers, limits
│   ├── 03-users.sql        accounts, user profiles, follows
│   ├── 04-feed.sql         feed, comments, chat
│   └── 05-feed-fix.sql     only posts written in the feed go to the feed
└── docs/
    └── README.ru.md        README in Russian
```

## ✦ Running your own copy

1. **Create a project** at [supabase.com](https://supabase.com).
2. **Register the owner**: Authentication → Users. Copy their User UID.
3. **Set up the database.** In the SQL Editor, run the scripts strictly in this order:
   `supabase/01-base.sql` → `02-guests.sql` → `03-users.sql` → `04-feed.sql` → `05-feed-fix.sql`.
   Before that, paste your UID into the first line of `01-base.sql`. Every script is safe to re-run.
4. **Connect the site.** In `index.html`, section `1. SUPABASE`, replace `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `OWNER_ID` and `NICK_DOMAIN` with your own values.
5. **Publish.** Push the files to a repository and turn on GitHub Pages (Settings → Pages → branch `main`, folder `/`).

Any static server works locally:

```bash
python3 -m http.server 8000
```

Then open <http://localhost:8000/?nointro>.

---

<div align="center">
<sub>Handmade, no frameworks, no build step. Relationship status: with my code.</sub>
</div>
