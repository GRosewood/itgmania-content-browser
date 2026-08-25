# The browser, in parts

This folder is the ITGMania Content Browser. The file beside it — `ITGmania
Content Browser.lua` — is the only thing Simply Love loads; it lists these parts
in order, loads each one, and hands the theme back the screens they built.

Simply Love loads every `.lua` sitting directly in `Modules/` and does not look
inside folders. That is why the parts are in here: the theme never sees them, so
the entry file has complete control over what loads and in what order.

## Why it is not one file

It was, for a long time — eleven thousand lines in a single chunk. Lua 5.1 caps
a chunk at 200 local variables and a function at 60 upvalues, and it had reached
exactly 200 and 59. Adding anything meant taking something out first, and the
error you got for forgetting was a line number with no explanation attached.

Each file here is its own chunk with its own budget. The worst one — the input
handler, which by its nature touches everything — now uses 43 locals of its 200
and 41 upvalues of its 60; everything else sits far lower. Run
`node tools/lua-checks/check.js` for the live numbers rather than trusting
this sentence to stay current.

Being able to find things turned out to be the better half of the bargain.

## How the parts talk to each other

One table, built fresh by the entry file and handed to every part in turn. A
part takes what it needs off the top and puts back what later parts need at the
bottom:

```lua
local CB = ...                       -- the shared table

-- what this part uses
local state    = CB.state
local Refresh  = CB.Refresh

local function FetchPacks(...) end

-- what it offers
CB.FetchPacks = FetchPacks
```

Names are copied into locals rather than reached through the table every time.
A local is a register read and a table field is a hash lookup, and a good deal
of this runs on every frame. The happy side effect is that the block at the top
of a file is also its dependency list — you can see what a part needs without
reading it.

Nothing is kept in a global. The browser can replace itself and reload in place
after an update, and a global would let the old, retired copy leak into the new
one.

## The order is a dependency order

A part may only use names an **earlier** part has set. Lua binds a name when it
compiles the line that mentions it, so a part that has not run yet has set
nothing — the name would quietly be a global, and a global nobody sets is `nil`.

The numbers in the filenames are that order. They are also written out in the
entry file, because that list — not the folder — is what actually runs.

The parts are named there one by one rather than found by listing this folder,
on purpose: nothing on the update path deletes files, so a part dropped by a
later release would sit here forever. Because only the entry file's list loads
anything, a leftover is ignored rather than quietly becoming live code again.

## The map

**The things everything else is built from**

| | |
|---|---|
| `01 state.lua` | every piece of state the browser keeps, in one table |
| `02 text.lua` | tidying text, sizes, dates, difficulty colours |
| `03 packs.lua` | what a pack is, and which ones are on show |
| `04 queues.lua` | the download queue, and the self-updater |
| `05 redraw.lua` | telling the screen something changed |

**Talking to the outside world**

| | |
|---|---|
| `06 parse.lua` | reading the catalogue's HTML |
| `07 banners.lua` | fetching pack artwork, a few at a time |
| `08 catalogue.lua` | asking the catalogue for pages of packs |
| `09 search.lua` | search |
| `10 pack page.lua` | fetching one pack's own page |

**This machine**

| | |
|---|---|
| `11 library.lua` | the songs folder, pack sync, the helper service |
| `12 sound.lua` | song previews and the chart preview |
| `13 installed.lua` | which packs are already here |

**Working out what to show, per tab**

| | |
|---|---|
| `14 featured pool.lua` | scoring a pack, and the index of what is recent |
| `15 levels.lua` | the difficulty levels, and the band heading them |
| `16 years.lua` | browsing by year |
| `17 arrowcloud.lua` | the second source, and charter lookups |
| `18 featured choice.lua` | choosing what to feature |

**Doing things, and being driven**

| | |
|---|---|
| `19 downloads.lua` | downloading a pack and putting it in place |
| `20 network gate.lua` | whether the browser may open at all, and the self-updater |
| `21 input.lua` | every key the browser answers to |
| `22 title menu.lua` | the Find Content row on the title menu, and the hooks that watch it |

**Drawing**

| | |
|---|---|
| `23 layout.lua` | where everything sits on screen |
| `24 widgets.lua` | small actors used all over |

**The screen** — start at `30 screen.lua`. It builds nothing itself; it is the
contents page for the seventeen files after it and says what order they go
together in, and why that order is two different orders at once.

| | |
|---|---|
| `30 screen.lua` | **read this first** — how the screen is assembled |
| `31 screen - frame.lua` | the outermost frame |
| `32 screen - hidden helpers.lua` | four actors that draw nothing |
| `33 screen - container.lua` | what everything visible hangs from |
| `34 screen - download ticker.lua` | the ticker in the corner |
| `35 screen - tabs.lua` | the tab row |
| `36 screen - featured grid.lua` | the featured grid |
| `37 screen - pack rows.lua` | the pack list |
| `38 screen - info pane.lua` | the pane beside the list |
| `39 screen - detail page.lua` | a pack's own page, and its equalizer |
| `40 screen - context band.lua` | the heading band |
| `41 screen - year picker.lua` | the year chips |
| `42 screen - installed view.lua` | the installed-packs view |
| `43 screen - doubles view.lua` | the doubles view |
| `44 screen - footer hints.lua` | the hints along the bottom |
| `45 screen - chart window.lua` | the chart preview window |
| `46 screen - dialogs.lua` | the modal dialogs |
| `47 screen - toast.lua` | the toast |

**Handing back**

| | |
|---|---|
| `48 screens.lua` | the table of screens the theme asked for |

## Two things that must never cross a file boundary by copy

The `local X = CB.X` idiom copies a value, and for two kinds of value a copy
is a trap:

- **A value that gets reassigned.** A boolean flag handed to another file
  leaves each file with its own variable — one file writes, the other never
  sees it, and nothing errors. That is why the title-menu row and the input
  hooks that watch it live together in `22 title menu.lua`: they share seven
  plain flags, and splitting them apart once produced a menu entry that never
  registered as focused.

- **A function defined later than the part that calls it.** The copy would be
  the nil the name held at load time. Names like this (`RefreshLevelView`,
  `FeaturedStep`, `Upstream` in the early parts, ...) are reached through
  the shared table at call time instead, via a one-line forwarder at the top
  of each part that uses them -- grep for `return CB.` to see the current
  set. `tools/lua-checks/check.js` proves every one of them resolves.

## Finding your way to a change

Start from what you can see. A bug in the doubles tab is either in
`43 screen - doubles view.lua` if it is about how it looks, or in
`03 packs.lua` / `14 featured pool.lua` if it is about which packs turn up
there. Something wrong with a download is `19 downloads.lua` for the fetching
and `11 library.lua` for where it lands. A key doing the wrong thing is
`21 input.lua`, always.

## Adding something

- Put it in the part it belongs to. If it does not belong to any of them, that
  is worth a moment's thought before it is worth a new file.
- If a later part needs it, add it to the export block at the bottom. If it
  needs something from an earlier part, add that to the import block at the top.
- A new file goes in the entry file's list, in the right place in the order, or
  it will not load at all. Nothing here scans the folder.
- Never reach forwards. If two parts need each other, they are one part.

## Checking your work

From the repository root:

```
node tools/lua-checks/check.js
```

That parses every file, checks its blocks balance, and reports both Lua limits
per file. It is the whole suite, and it takes about a second.
