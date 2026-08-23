# ITGMania Content Browser

*by GregTech*

A drop-in Simply Love module that adds a **Find Content** entry to the ITGmania
title menu (home screen). It opens an in-game browser for
[stepmaniaonline.net](https://stepmaniaonline.net)'s pack index and lets you
download and install packs without ever leaving the game.

## Features

- **Native-looking title menu entry** — *Find Content* sits between Options and
  Exit. The theme's scroller re-runs its own layout every frame, so the module
  hides the engine's rows and draws all five itself; that is what allows a row
  in the middle and a pitch that is not cramped.
- **Featured grid** — the **most played packs on
  [arrowcloud.dance](https://arrowcloud.dance/packs)**, in that site's own
  popularity order. Its front end reads a public, keyless JSON API; a page is
  25 packs and the limit caps at 100, so the top 300 arrives in three requests.
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
- **Tabs** — Search, Pad, Keyboard, Beginner, All Around, Stamina, Years and
  Installed. (There is no *All* tab: Pad shows 97.9% of the catalogue, so it
  and Keyboard between them cover everything.)
  Left/Right moves between them and every one but Search applies as you land on
  it; Search only takes focus, and Start opens the keyboard prompt.
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
- **The keyboard tab has no featured grid.** Keyboard packs are barely
  represented on arrowcloud, so there was no ranking to draw on, and their CSV
  rows carry neither a banner nor a date — which meant a pack page per candidate
  purely to fill a strip. It is a plain list under a header now.
- **Browsable pack list** — newest packs first (the same ordering as
  `stepmaniaonline.net/packs` sorted by date), with banner thumbnails, song
  count, size, release date, and game types per pack, plus an "In Library"
  badge for packs you already have. The list refreshes automatically when you
  open it (Left on page 1 re-fetches on demand).
- **Pack details** — banner, song/chart counts, size, difficulty range, a
  difficulty distribution histogram coloured green through yellow to red by
  difficulty, the pack's most frequent chart authors, and a scrollable
  per-song list with each song's art at banner proportions, title, artist, BPM,
  length, chart credit and meter range, scraped live from the pack's page.
  (stepmaniaonline.net serves a song's own jacket where it has one and the pack
  banner where it does not, so the frame takes whatever shape the image fits
  to rather than forcing everything into a square.)
- **Installed Packs tab** — 22 packs at a time in two columns, your local
  library cross-checked against
  stepmaniaonline.net: every song group with its song count and whether it
  matches the SMO copy, differs from it, or is not on SMO at all. Packs can be
  deleted here without leaving the game (see below).
- **Search** — a tab rather than a button: land on **Search** and press Start
  for a keyboard prompt that searches **pack names, chart authors and song
  titles** at once. The featured grid steps aside while results are showing,
  and a spinner runs in the band above the list until the deep passes land. Name matches come back first and
  instantly; author and song matches stream in behind them, each row saying why
  it matched ("charts by midtown", "song: Bear's Breeches"). Results are ranked
  and paged locally.
- **By Year** — a page per calendar year back to **2015**, plus an **OLDER**
  page for everything before that, showing what was added to
  stepmaniaonline.net in each. It reuses the background index the featured grid
  builds; opening the tab deepens that walk to cover the whole catalogue,
  resuming where the shallow pass stopped rather than starting over.
- **Lists arrive in helpings.** A view gathers a few hundred rows, or a couple
  of pages where each row costs a request (the beginner list), and then stops.
  The count says **400+** or **14+** rather than pretending that is all there
  is, and reaching the end of what has been gathered fetches the next helping.
  It is what keeps these tabs quick: the expensive part was never the row
  count, it was reading a pack page for every pack that SMO had not tagged.
- **A list that is still filling shows placeholder rows** — dim bars with a
  spinner where each row will land — rather than claiming to be empty.
- **Scroll indicators** — the pack list, song list and installed list each show
  a thin bar with a proportional thumb, hidden when there is nothing more to
  see. The featured grid uses a row of dots instead — one per row of cards,
  with the visible rows lit — which reads as a position rather than a progress
  meter.
- **Direct downloads** — packs download in the background with a progress bar
  and are unzipped straight into `/Songs`. When you leave the browser it
  offers ITGmania's fast differential song reload so the new packs appear
  immediately.

## Install

Run the **Find Content installer** for your platform. It finds ITGmania, copies
this module into Simply Love, and enables the one network setting the module
needs — nothing to unzip, no config files to edit.

Then start ITGmania: *Find Content* is on the title menu, below Exit.

### Installing by hand instead

1. Copy every file in this folder into `Themes/Simply Love/Modules/`.
2. With ITGmania **closed**, run `Enable Network Access.bat`
   (Linux/macOS: `bash enable-network-access.sh`) from that folder.
3. Start ITGmania.

Or edit it yourself: with the game closed, add this to the `HttpAllowHosts`
line in `Save/Preferences.ini`:

    stepmaniaonline.net,*.stepmaniaonline.net

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

Home screen: navigate past **Exit** (Right or Down) — *Find Content* is the
row underneath. **Start** opens the browser; Left/Up/Back returns to the
normal menu.

In the browser, Up/Down moves between three rows: the **tabs**
(Pad / Keyboard / All / By Year / Installed — change with Left/Right), the
**featured grid** or **year picker** (browse with Left/Right), and the
**pack list**. Up/Down inside the grid moves between its two rows before
leaving it, and the grid scrolls a row at a time.

| Button | Tabs | Featured / Years | Pack list | Detail view | Installed list |
|---|---|---|---|---|---|
| Up / Down | down a row | move between rows | move selection (Up from row 1 goes back up) | scroll the song list | move selection |
| Left / Right | change tab | previous / next | previous / next page (Left on page 1 = refresh) | page the song list | previous / next page |
| Start | search prompt, else down a row | open / choose | open pack details | download the pack | delete the pack |
| Back | exit browser | exit browser | exit browser | back to the list | exit browser |

Dialogs (download, reload, removal) print their own confirm/cancel keys inside
the dialog itself.

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

The service refuses any name that does not resolve to a plain folder directly
inside a `Songs/` directory, so a malformed request cannot reach outside your
song library. If it is not running, the Installed Packs tab says "removal
unavailable" instead of offering a button that would not work; re-running the
installer sets it up again.

One wrinkle worth knowing: the engine keeps its song list in memory, so a
deleted pack stays in the music wheel until songs are reloaded. The browser
offers that reload when you leave, exactly as it does after a download.

## Notes & known quirks

- **Install hitch:** unzipping a large pack happens synchronously, so the game
  may freeze for a few seconds at the moment a download reaches 100%. This is
  the same behavior as Simply Love's built-in GrooveStats unlock downloads.
- **Downloads continue in the background** if you leave the browser; a system
  message appears when a pack finishes installing.
- **Banner cache:** banners are cached in `Save/SMOFindContent/Banners/` so
  they don't re-download every session. Safe to delete at any time.
- **Zip layout:** packs are unzipped to `/Songs` as-is. StepmaniaOnline packs
  contain a single top-level pack folder, which becomes the group folder.
- The pack list/detail data comes from stepmaniaonline.net's public endpoints;
  if the site changes its markup the detail view may show less information.
- **Charter recency index:** the first time the featured grid needs it, the
  module walks the dated pack list back five years (about seven requests,
  gzipped by the engine's HTTP client) and keeps the result in memory for the
  session. It loads in the background; the grid works without it and simply
  falls back to quality-only picks if the site is unreachable.
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
- **The featured grid** covers the **last five months** for pad packs and the
  **last three years** for keyboard packs, which release far less often, and is
  limited to packs of **15 to 100 songs** — below that there is not enough pack
  to recommend, above it you are looking at a megapack rather than a night's
  material.
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
`Themes/Simply Love/Modules/` by hand. Optionally also delete
`Save/SMOFindContent/` (the banner cache) and
`Save/ITGmaniaContentBrowser/` (the delete helper and its config) and remove the stepmaniaonline.net
entries from `HttpAllowHosts` in `Save/Preferences.ini` with the game closed.
Any `Preferences.ini.bak-*` files in `Save/` can be deleted too.
