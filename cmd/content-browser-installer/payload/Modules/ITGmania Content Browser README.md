# ITGMania Content Browser

*by GregTech*

A drop-in Simply Love module that adds a **Find Content** entry to the ITGmania
title menu (home screen). It opens an in-game browser for
[stepmaniaonline.net](https://stepmaniaonline.net)'s pack index and lets you
download and install packs without ever leaving the game.

## Features

- **Native-looking title menu entry** — *Find Content* sits between **Options**
  and **Exit**. The theme's scroller re-runs its own layout every frame, so the
  module hides the engine's rows and draws all five itself; that is what allows
  a row in the middle and a pitch that is not cramped.
- **One header row** — the tab row sits *beside* the theme's own screen header
  rather than under it, as a row of filled pills with a single rule under the
  lot. The tab you are on is a solid block in the accent colour; the one the
  cursor is on while you are choosing is brighter still. Putting the tabs on
  the header's own line gives every view below about eighteen pixels it did not
  have.
- **Featured grid** — the **most played packs on
  [arrowcloud.dance](https://arrowcloud.dance/packs)**, in that site's own
  popularity order. Its front end reads a public, keyless JSON API; a page is
  25 packs and the limit caps at 100, so three requests cover the top 300, of
  which the top 250 is used.
  The name, the release date and the artwork all come from there. SMO is asked
  only for the pack id and song count, because arrowcloud has neither and the
  id is what downloads a pack; the two sites share no identifier, so packs are
  matched on a normalised name, which resolves 244 of the top 250.

  **24** packs are shown, **six across in two rows**, so the grid is exactly two
  full pages and never gaps. A card is nothing but the pack's banner on a
  gradient block in the theme's accent colour: no text, because the detail pane
  on the right already follows the highlighted card and names it. Highlighting
  washes the banner in the same accent. The block and the focus ring are sized
  to the artwork rather than to the card, so neither overhangs it.

  Left/Right walk along a row and step a whole page at its end; Up/Down move
  between the two rows.

  **It requests no pack pages at all.** It used to fetch one per candidate to
  count charts and measure a difficulty spread, which meant well over a hundred
  requests to decide two dozen cards and left the grid half empty for a minute.
  Popularity answers the same question — is this pack any good — directly, and
  the row already carries the song count and the banner. A pack SMO has not
  typed at all is skipped, which is what keeps personal simfile dumps out.

- **Dance packs only** — packs built for other games (pump, kb7 and friends)
  are hidden. The pack list only reports which *game* a pack targets, so that
  is what the list filters on; wherever a pack's detail page is loaded anyway
  (the featured grid, the content levels) the finer check applies too, and
  anything carrying a chart type other than `dance-single` or `dance-double`
  is dropped.
- **Banners are required, and have to be the right shape.** A pack with no
  banner does not appear in the listing at all. Measured across the site,
  real banners sit on two standard ratios — 418x164 and its multiples (2.55)
  and 256x80 and its multiples (3.20) — so anything outside roughly 2.4 to 3.4
  is dropped: 2000x500, 256x256 and 200x40 all wreck the row and card layouts.
  Dimensions are only knowable once the image has downloaded, so a pack that
  turns out to be the wrong shape is pulled from the page the moment its banner
  loads, and the gap is backfilled from rows the over-fetch already brought in.
- **Tabs** — Search, Pad, Keyboard, Beginner, All Around, Stamina, Doubles,
  Years and Installed. (There is no *All* tab: Pad shows 97.9% of the
  catalogue, so it and Keyboard between them cover everything.)
  Left/Right moves between them; Search only takes focus, and Start opens the
  keyboard prompt.

  **Passing over a tab costs nothing.** The view changes as the cursor lands,
  but nothing is asked of the network until the row has been still for a
  moment. The engine runs one HTTP request at a time in the order they were
  asked for, so walking from Pad to Doubles used to put a popularity ranking, a
  catalogue crawl and a page of beginner pack reads in the queue ahead of the
  one list you actually stopped on.
- **Beginner Friendly** — packs whose **beginner-slot chart is a 1 to 4 on
  most of their songs**, drawn from the **top 250 on
  [arrowcloud.dance](https://arrowcloud.dance/packs) by popularity**. Only
  singles count: a doubles chart is not what a beginner stands on, so a song
  without a singles chart is ignored either way.

  This is the one list that has to read a pack page per candidate — a
  difficulty is in neither the catalogue nor arrowcloud's pack listing — so it
  gathers **one page at a time**, four requests at once, and only reaches
  further if you scroll to the bottom of what it has. Packs SMO tags *stamina*
  or *mods* are skipped without asking, since neither can qualify.

  SMO's pack page gives a meter range per song ("3-11") and the low end of that
  range is the easiest chart the song has, which is the one in the beginner
  slot. arrowcloud names the slots outright, but its simfile rows run about
  180 KB a pack against SMO's 71 because each carries its banner in several
  formats — so the cheaper page answers the same question.
- **Content levels** — two broad buckets, in two passes. The first reads the
  substyle SMO already records for every pack in the CSV this module downloads
  once anyway — 445 packs tagged *stamina*, 665 *technical* plus 51 *all
  around* — so both lists appear the moment the catalogue lands, with no
  requests at all. SMO only started tagging recently, though, so a
  second pass then works through the packs it never tagged the old way, from
  each one's chart distribution; those need a pack page each, so that pass is
  bounded and its results fill in behind the first. Neither list includes
  keyboard packs.
- **Doubles** — two columns, because a pack built for doubles and a pack with
  a few doubles charts buried in it are two different things to go looking for.

  **Made for doubles** is [itgdb.net](https://itgdb.net)'s own dedicated-doubles
  category — about thirty packs on one page, no reading required — joined to
  SMO by name so they can be downloaded, and listed **newest first**. **Some
  doubles** is SMO's own table filtered by chart type with every substyle
  ticked, which narrows nine and a half thousand packs to a couple of hundred
  candidates; each is read and kept only if **four or more of its songs** carry
  a doubles chart. Every row says how many.

  Up/Down moves within a column, Left/Right moves between them, and each column
  has its own scrollbar and its own spinner — so the dedicated column stops
  looking busy the moment it is done, while the other is still reading.

- **The keyboard tab has no featured grid.** Keyboard packs are barely
  represented on arrowcloud, so there was no ranking to draw on, and their CSV
  rows carry neither a banner nor a date — which meant a pack page per candidate
  purely to fill a strip. It is a plain list under a header now.
- **Browsable pack list** — newest packs first (the same ordering as
  `stepmaniaonline.net/packs` sorted by date), with banner thumbnails, song
  count, size, release date, and game types per pack, plus an "In Library"
  badge for packs you already have. It re-fetches when you open the browser if
  the last fetch was more than five minutes ago (Left on page 1 re-fetches on
  demand).

  **Pages you have already seen come back instantly.** A page that has been
  fetched is kept for as long as the filter and the search stay the same, so
  paging back through a list costs nothing and — on a queue that runs one
  request at a time — does not put five page fetches in front of the banners
  and pack pages the rows on screen are still waiting for.
- **Pack details** — banner, song/chart counts, size, a difficulty
  distribution histogram coloured green through yellow to red by difficulty,
  the pack's most frequent chart authors, and a scrollable per-song list with
  each song's art at banner proportions, title, artist, BPM, length, chart
  credit and meter range, scraped live from the pack's page.

  Under the charter line, **one row per style**: the same icon the tab row uses
  and the difficulties that style spans — no words, because the icon is the
  word. A pack with both gets both rows; a doubles-only pack gets one. Each
  song row carries the same icons, so which songs have doubles as well as
  singles is readable at a glance rather than something to go and check.

  A **DOWNLOAD PACK** button sits at the top of the page, one press of Up away
  from the first song, and says the pack's size. It reports its own progress
  and turns into *IN YOUR LIBRARY* when the pack is already there.
  (stepmaniaonline.net serves a song's own jacket where it has one and the pack
  banner where it does not, so the frame takes whatever shape the image fits
  to rather than forcing everything into a square.)
- **Hear a song before you download the pack.** Pick a song, press Start, and
  the first choice is **Preview**: about twenty seconds of that song's own
  audio, pulled out of the pack without downloading the pack. The helper reads
  the archive's index over HTTP range requests and fetches only the one file it
  needs — roughly 4 MB out of a 100 MB pack — so a preview costs a second or
  two rather than a download.

- **Watch the chart while you listen.** A window opens in the middle of the
  screen showing what the chart is doing over those twenty seconds, in **your
  own noteskin**, at a read speed derived the way the game derives one (a C-mod
  scaled by mini). Arrows are coloured by quantization the way ITG colours them
  — quarters red, eighths blue, sixteenths green — and stop at the receptors,
  which flash with the noteskin's own explosion as each one lands.

  Every difficulty the song has is listed under the title, colour-coded like
  the wheel, and **Up/Down moves between them** with nothing fetched: the whole
  set came back with the audio. It opens on **Expert**, because that is what
  somebody deciding whether a pack is worth downloading wants to see. Doubles
  charts draw all eight columns.

  This needs the helper, and the notes come out of the simfile inside the pack,
  so a chart with nothing inside the sampled twenty seconds says so rather than
  showing an empty field.

- **Take one song instead of the whole pack.** The second choice on that popup
  installs the single song into **Content Browser Singles - ITG Sync** or
  **Content Browser Singles - NULL Sync**, whichever matches what SMO says the
  pack is. The folders are created on first use with the right `Pack.ini`, so
  songs from differently-synced packs never end up sharing an offset. It goes
  through the same download queue as a pack.

- **Installed Packs tab** — 22 packs at a time in two columns, your local
  library cross-checked against
  stepmaniaonline.net: every song group with its song count and whether it
  matches the SMO copy, differs from it, or is not on SMO at all — and a
  **sync health** column that reads green, amber or red against what your
  machine is set to, with a key under the table and a **Select** screen that
  will write a `Pack.ini` for a pack that has none. Packs downloaded through
  the browser also show the day they arrived. Packs can be deleted here without
  leaving the game (see below).
- **Search** — a tab rather than a button: land on **Search** and press Start
  for a keyboard prompt that searches **pack names, chart authors and song
  titles** at once. The featured grid steps aside while results are showing,
  and a spinner runs in the band above the list until the deep passes land. Name matches come back first and
  instantly; author and song matches stream in behind them, each row saying why
  it matched ("charts by midtown", "song: Bear's Breeches"). Results are ranked
  and paged locally.
- **By Year** — a page per calendar year back to **2019**, plus an **OLDER**
  page for everything before that, showing what was added to
  stepmaniaonline.net in each. It reuses the background index the featured grid
  builds; opening the tab deepens that walk to cover the whole catalogue,
  resuming where the shallow pass stopped rather than starting over.
- **Lists arrive in helpings.** A view gathers a few hundred rows, or a couple
  of pages where each row costs a request (the beginner list), and then stops.
  Where a count is printed it says **400+** rather than pretending that is
  all there is, and reaching the end of what has been gathered fetches the
  next helping. The beginner and doubles views print no count at all, because
  a number that only means "as far as we have read" is worse than none.
  It is what keeps these tabs quick: the expensive part was never the row
  count, it was reading a pack page for every pack that SMO had not tagged.
- **A list that is still filling shows placeholder rows** — dim bars with a
  spinner where each row will land — rather than claiming to be empty.
- **A list you have built stays built.** Leave a tab and come back and it is as
  you left it, including a walk that had not finished, which picks up where it
  stopped. To go and look for new packs instead, press **Select** — or Left at
  the front of the list, the same gesture that refreshes the plain pack list.
- **Scroll indicators** — the pack list, song list and installed list each show
  a thin bar with a proportional thumb, hidden when there is nothing more to
  see; the two doubles columns have one each. The featured grid uses a row of
  dots instead — **one per page**, with the page you are on lit — which reads
  as a position rather than a progress meter.
- **Direct downloads** — packs download in the background with a progress bar,
  several at once if you start several, with a queue in the top corner. The
  helper does the downloading and unpacking, straight into the song folder you
  actually configured: every song folder is mounted at the same place inside
  the game, so the engine's own unzip always lands in `<install>/Songs` even
  when your library is a mounted drive. Without the helper the engine's unzip
  is used as a fallback, and that is where it goes. When you leave the browser
  it offers ITGmania's fast differential song reload so the new packs appear
  immediately.

## Install

Run the **Find Content installer** for your platform. It finds ITGmania, copies
this module into Simply Love, and enables the one network setting the module
needs — nothing to unzip, no config files to edit.

Then start ITGmania: *Find Content* is on the title menu, between **Options**
and **Exit**.

### Installing by hand instead

1. Copy everything in this folder into `Themes/Simply Love/Modules/` —
   **including both subfolders**, and keeping the layout exactly as it is here.

   `ITGmania Content Browser/` holds the browser itself, split into parts;
   `ITGmania Content Browser.lua` beside it is the only file the theme
   loads, and it loads the parts by name. Without that folder the browser does
   not start at all.

   `ContentBrowserIcons/` carries the tab, arrow and receptor artwork.
   Without it the browser still runs, but the tabs lose their icons and the
   chart preview falls back to plain arrows.
2. With ITGmania **closed**, run `Enable Network Access.bat`
   (Linux/macOS: `bash enable-network-access.sh`) from that folder.
3. Start ITGmania.

Or edit it yourself: with the game closed, add all of these to the
`HttpAllowHosts` line in `Save/Preferences.ini` (the full list, because a
hand install has no helper service to relay for it -- the installer's own
edit is just `127.0.0.1`, and the helper reaches the rest):

    stepmaniaonline.net,*.stepmaniaonline.net,arrowcloud.dance,*.arrowcloud.dance,itgdb.net,*.itgdb.net,127.0.0.1

stepmaniaonline.net is the catalogue and the packs themselves;
arrowcloud.dance is the popularity ranking the featured grid and the beginner
list are built from; itgdb.net is the dedicated-doubles category; and
`127.0.0.1` is the local helper that removes packs, downloads them and reads
song previews. Leave any of them out and the feature that needs it says so
rather than failing quietly.

### Why the network step exists

ITGmania does not let a theme grant itself internet access. `HttpEnabled` and
`HttpAllowHosts` are `PreferenceType::Immutable` so every Lua write is refused;
`Preferences.ini`, `Static.ini` and `Defaults.ini` are all passed to
`FILEMAN->ProtectPath()` so the game refuses to write them even through its own
file layer; and the Lua sandbox has no `os`/`io` library and no way to launch a
program. That boundary is deliberate — themes are untrusted content.

So the setting is applied by the installer (or the helper script), which you
run yourself, outside the game. This module never prompts for permission
in-game and never tries to change the setting behind your back. If network
access is missing it simply shows a **Network Access Not Enabled** warning
naming the exact problem and how to fix it.

Requires ITGmania **1.1 or newer** (tested on 1.3.0 / Simply Love 5.9.0).

## Controls

Home screen: **Down** to *Find Content*, between Options and Exit. **Start**
opens the browser; **Back** returns to the normal menu.

In the browser, Up and Down move between the rows of the screen: the **tab
row** at the top (change with Left/Right), the **featured grid** or **year
picker** beneath it, and the **list**. Up from the top of a list walks back
through its pages before handing the cursor to the row above.

| Button | Tab row | Featured / Years | Pack list | Doubles columns | Detail page | Chart preview | Installed list |
|---|---|---|---|---|---|---|---|
| Up / Down | into the page | between rows | move selection | move within a column | songs; Up from song 1 reaches the download button | **change difficulty** | move selection |
| Left / Right | change tab | previous / next | previous / next page (Left on page 1 refreshes) | between the two columns | page the song list | — | previous / next page |
| Start | search prompt, else into the page | open / choose | open pack details | open pack details | download the pack, or open the song popup | stop the preview | remove the pack |
| Select | — | — | sync screen | reload the list | preview the song | stop the preview | sync screen |
| Back | leave | leave | leave | leave | back to the list | stop the preview | leave |

On the lists this module builds for itself — Beginner, All Around, Stamina,
Doubles and the year pages — **Select reloads the list**, and so does Left at
the front of it. Select is a cabinet button and a keyboard often has nothing
bound to it, which is why the second gesture exists.

When an update is waiting, **Right past the last tab** reaches the UPDATE
button at the end of the row; Left comes back. See [Updating](#updating).

Dialogs (the song popup, download, reload, removal, sync) print their own keys
inside the dialog itself.

## Updating

The browser is version **0.1**, and it can update itself.

When a newer one has been published, an **UPDATE** button appears at the right
end of the tab row -- the tabs close up to make room for it, and it is only
there when there is something to install. Press Right past the last tab to
reach it, then Start. It downloads the new files, checks them against the
checksum in the release, writes them into place and reloads the browser where
you stand: no restart, no going back to the desktop.

If the download does not match its checksum, nothing is written and the dialog
says so. Your copy is left exactly as it was.

Some releases need a newer helper as well as a newer module -- the helper is a
program, and a running one cannot overwrite itself on Windows. Those say so
instead of offering a button, and you run the installer once as you did the
first time.

The check itself is made by the helper rather than by the game, and only when
the browser is opened. That is not for tidiness: the engine will only talk to
hosts on its own allowlist, and making you add another one to be told about an
update would be a poor trade. If the check cannot reach the internet -- a
cabinet on a closed network, say -- nothing appears and nothing complains.

## Removing packs

Select a pack on the Installed Packs tab, press Start, confirm, and it is gone.
No file manager, no second program to run, nothing outside the game.

Getting there took a detour, because ITGmania's Lua API cannot delete anything:
the file manager exposes only `Copy`, `DoesFileExist`, `GetFileSizeBytes`,
`GetHashForFile`, `GetDirListing` and `Unzip`, and there is no delete, move or
rename anywhere else in the API. (The in-game deletion you may be thinking of is
the engine's Ctrl+Backspace shortcut on the music wheel, gated by the
`AllowSongDeletion` preference — that is C++, unreachable from Lua, and removes
a single *song* rather than a pack.)

What a theme *can* do is make an HTTP request, and the engine's allowlist
matches on host alone. So the installer adds `127.0.0.1` to `HttpAllowHosts`
and leaves a small local service running that does the deleting. It listens on
loopback only, on a port the OS assigns, and every request must carry a token
regenerated each time it starts and stored where only this module can read it.
It starts with your session and does nothing until the browser asks it to.

It has since grown three more jobs, all for the same reason — they are things
Lua cannot do: it **downloads and unpacks** a pack into the song folder you
actually configured (the engine's own unzip cannot be aimed anywhere but
`<install>/Songs`), it **reads one song's audio and its charts** out of a pack
over HTTP range requests so a preview does not need the pack, and it
**installs a single song** into the singles folders. Without it the browser
still works: downloads fall back to the engine's unzip, and the parts that
cannot fall back say so.

The service refuses any name that does not resolve to a plain folder directly
inside a `Songs/` directory, so a malformed request cannot reach outside your
song library. If it is not running, the Installed Packs tab says "removal
unavailable" instead of offering a button that would not work; re-running the
installer sets it up again.

One wrinkle worth knowing: the engine keeps its song list in memory, so a
deleted pack stays in the music wheel until songs are reloaded. The browser
offers that reload when you leave, exactly as it does after a download.

## Notes & known quirks

- **Install hitch:** with no helper the engine unzips a pack synchronously,
  so the game may freeze for a few seconds as a download reaches 100% — the
  same behaviour as Simply Loves built-in GrooveStats unlock downloads. The
  helper unpacks off the games thread, so with it installed there is no hitch.
- **Downloads continue in the background** if you leave the browser; a system
  message appears when a pack finishes installing. The top corner carries a
  queue: up to three rows with their own progress bars, and a count of the
  rest. Single songs queue there alongside packs.
- **Banner cache:** banners are cached in `Cache/ITGmaniaContentBrowser/Banners/`
  so they don't re-download every session — under the game's Cache folder,
  wherever that lives on your machine, because it is refetchable data and
  cabinets often keep Cache on a bigger mounted drive. Safe to delete at any
  time. Extracted preview audio lives beside it in `previews/`.
- **Zip layout:** packs are unzipped to `/Songs` as-is. StepmaniaOnline packs
  contain a single top-level pack folder, which becomes the group folder.
- The pack list/detail data comes from stepmaniaonline.net's public endpoints;
  if the site changes its markup the detail view may show less information.
- **Charter recency index:** a walk back through the dated pack list (about
  seven requests, gzipped by the engine's HTTP client), kept in memory for the
  session. The featured grid is built from arrowcloud's popularity ranking now
  and only falls back to this; what still depends on it are the **year pages**
  and the second pass of **All Around** and **Stamina**. It loads in the
  background, and the views that use it show how far it has got.
- **Installed Packs matching** compares song counts against the site's pack
  CSV, matching on a punctuation- and case-insensitive form of the folder
  name. A renamed folder shows as "not on SMO".
- **"Added", not "released":** every date here is when stepmaniaonline.net
  listed the pack, which is why the year pages say "added in". A pack named for
  2024 can perfectly well have been added in 2026.
- **Difficulty colours** stay green all the way to 11 and only warm up past
  that, so the ramp reflects where pad difficulty actually starts to bite.
- **Pack sync** — every pack is either NULL synced or ITG synced, ITG meaning
  its charts carry the arcade's 9 ms bias, which ITGmania removes on the way
  in. A pack declares which in a `Pack.ini`; with no such file the machine's
  `DefaultSyncOffset` decides, and that ships as ITG — so an ITG pack is
  already right and only a NULL pack plays 9 ms out.

  **No published source can tell you which a pack needs**, and this was checked
  rather than assumed. SMO's Sync field has no value for ITG at all — its whole
  vocabulary across 9,555 packs is `n/a`, `null`, `0`, `mixed`, `other` — and it
  lists *In The Groove 2*, the pack the 9 ms offset is named for, as NULL. The
  community NULL Progress sheet only ever records NULL or blank, and blank
  means "not looked at yet". Of the packs on this machine that ship an
  author-written `Pack.ini`, five that the sheet marks NULL declare
  `SyncOffset=ITG`.

  **Old packs installed from here get one written for them.** A pack added to
  SMO more than four years ago that arrives without a `Pack.ini` is assumed to be
  ITG synced and has one written. Assuming ITG is the conservative half of that
  guess: with no file at all the engine already falls back to
  `DefaultSyncOffset`, which ships as ITG, so on a stock machine the written file
  pins the behaviour the pack already had rather than changing it. What it does
  cost is that `DefaultSyncOffset` stops reaching that pack, so the file says so
  in a comment and the Installed tab labels it *assumed* rather than declared.
  This only ever touches packs installed through this browser -- never the rest
  of a library -- and deleting the file hands the pack back to the preference.

  So the browser **reports what SMO says and attributes it** ("sync: NULL, per
  SMO" / "sync: not listed") and never guesses. The Installed tab reads each
  pack's own `Pack.ini` instead, which is the one place the real answer lives.
  Press **Select** for the sync screen; on an installed pack with no `Pack.ini`
  that screen will write one, with the value you choose. It refuses to touch a
  pack that already has one, and always writes `Version=1` — the engine gates
  the whole `[Group]` parse on that key and silently discards a file without
  it.
- **The featured grid** is the top of arrowcloud's popularity ranking, not a
  date window: what people are actually playing, whenever it came out. There is
  no keyboard grid at all — keyboard packs are barely represented there, so
  that tab is a plain list under a header.
- **Paging waits for the server.** Holding Down at the end of a page used to
  queue up more page changes while one was still in flight, skipping pages and
  landing the cursor in the wrong place. Navigation is now ignored until the
  page it is waiting on arrives, with a spinner beside the page readout.
- **Screen furniture:** ITGmania draws "PRESS START" and "EVENT MODE" from
  ScreenSystemLayer, the same overlay this module lives on, and those actors
  carry no name so there is nothing to hide. The browser draws itself above
  that layer and covers the band they occupy instead.
- **Absurd difficulty meters** (some packs carry joke charts rated in the
  thousands) are dropped above 30 so they cannot distort the histogram or the
  quoted difficulty range.

## Uninstall

Run the installer with `-uninstall`, or delete the module files from
`Themes/Simply Love/Modules/` by hand — including both the
`ITGmania Content Browser/` and `ContentBrowserIcons/` folders. Optionally also
delete `Cache/ITGmaniaContentBrowser/` (banners and extracted preview audio —
refetchable, so nothing is lost) and `Save/ITGmaniaContentBrowser/` (the
helper, its config, and the browser's small record files), and remove the stepmaniaonline.net,
arrowcloud.dance, itgdb.net and `127.0.0.1` entries from `HttpAllowHosts` in
`Save/Preferences.ini` with the game closed. Any `Preferences.ini.bak-*` files
in `Save/` can be deleted too.

Packs you downloaded stay where they are — uninstalling the browser does not
touch your song library, and the `Content Browser Singles` folders are
ordinary song groups you can keep or delete like any other.

## Licence

ITGMania Content Browser is free software, © 2026 Rosewood
<rosewoodsteps@gmail.com>, under the **GNU General Public License, version 3**.

You may redistribute it and modify it under the terms of that licence as
published by the Free Software Foundation. It is distributed in the hope that
it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the licence for
details.

The full text is `ITGmania Content Browser LICENSE.txt`, sitting beside this
file in `Themes/Simply Love/Modules/`. If it is missing, see
<https://www.gnu.org/licenses/>.
