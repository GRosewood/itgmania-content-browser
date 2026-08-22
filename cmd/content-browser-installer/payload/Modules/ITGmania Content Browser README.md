# ITGMania Content Browser

*by GregTech*

A drop-in Simply Love module that adds a **Find Content** entry to the ITGmania
title menu (home screen). It opens an in-game browser for
[stepmaniaonline.net](https://stepmaniaonline.net)'s pack index and lets you
download and install packs without ever leaving the game.

## Features

- **Native-looking title menu entry** — *Find Content* sits below Exit and is
  part of the menu's wrap cycle: press Right (or Down) past Exit, or Left/Up
  from the top choice, to reach it.
- **Featured strip** — the browser opens onto a row of featured packs:
  releases from the current year (or the last four months while the year is
  young) that have a banner, 20+ charts across 3+ difficulties, and a wide
  difficulty spread in the 7-15 range. Qualification happens live against
  the site and the strip fills in as packs qualify.
- **Pad / Keyboard / All filter tabs** — pad packs by default (hides packs
  tagged `keyboard` on stepmaniaonline.net); the Keyboard tab lists exactly
  the site's keyboard-tagged packs, newest first. Filtering uses the site's
  pack-type metadata, which is sparse for newer packs, so untagged keyboard
  packs can still appear under Pad.
- **Browsable pack list** — newest packs first (the same ordering as
  `stepmaniaonline.net/packs` sorted by date), with banner thumbnails, song
  count, size, release date, and game types per pack, plus an "In Library"
  badge for packs you already have. The list refreshes automatically when you
  open it (Left on page 1 re-fetches on demand).
- **Pack details** — banner, song/chart counts, size, difficulty range, a
  difficulty distribution histogram, the pack's most frequent chart authors,
  and a scrollable per-song list (title, artist, BPM, length, chart credit,
  meter range) scraped live from the pack's page.
- **Search** — press Select in the list for a keyboard search prompt.
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

In the browser, Up/Down moves between three rows: the **filter tabs**
(Pad / Keyboard / All — change with Left/Right), the **featured strip**
(browse cards with Left/Right), and the **pack list**.

| Button | Filter tabs | Featured strip | Pack list | Detail view |
|---|---|---|---|---|
| Up / Down | down to featured | move between rows | move selection (Up from row 1 goes to featured) | scroll the song list |
| Left / Right | change filter | previous / next card | previous / next page (Left on page 1 = refresh) | page the song list |
| Start | to featured | open pack details | open pack details | download the pack |
| Select | search | search | search | — |
| Back | exit browser | exit browser | exit browser | back to the list |

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

## Uninstall

Run the installer with `-uninstall`, or delete the module files from
`Themes/Simply Love/Modules/` by hand. Optionally also delete
`Save/SMOFindContent/` (the banner cache) and remove the stepmaniaonline.net
entries from `HttpAllowHosts` in `Save/Preferences.ini` with the game closed.
Any `Preferences.ini.bak-*` files in `Save/` can be deleted too.
