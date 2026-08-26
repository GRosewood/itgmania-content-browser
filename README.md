# ITGMania Content Browser

*by GregTech*

**[itgcontent.net](https://itgcontent.net)**

A Simply Love module that adds a **Find Content** entry to the ITGmania title
menu: an in-game browser for [stepmaniaonline.net](https://stepmaniaonline.net)
that downloads and installs song packs without leaving the game.

Featured picks, pad/keyboard filtering, banners, chart details and difficulty
histograms, search, and one-button downloads that unzip straight into `/Songs`.

## Install

Download the installer for your platform from
[Releases](../../releases/latest) and run it. It finds your ITGmania
installation, copies the module into Simply Love, and enables the one network
setting the module needs.

| Platform | File | What you get |
|---|---|---|
| **Windows** | `itgmania-content-browser-setup-<version>.exe` | Graphical setup wizard |
| **macOS** | `itgmania-content-browser-setup-<version>.pkg` | Installer.app package |
| **Linux** | `itgmania-content-browser-installer-<version>-linux-amd64.tar.gz` (or `-arm64`) | Console installer |

**Close ITGmania first.** ITGmania rewrites `Preferences.ini` from memory when
it exits, so the installers refuse to run while it is open.

The Linux and macOS downloads are `.tar.gz` so the executable bit survives:
`tar -xzf <file>` gives you something that runs, with no `chmod` needed. macOS
still marks downloads as quarantined — right-click → Open, or
`xattr -d com.apple.quarantine <file>`.

Then start ITGmania: **Find Content** is on the title menu, above Exit.

### Console installer

Every platform also ships the plain console installer, which is what the
graphical ones drive underneath. Useful for scripting and cabinets:

```
itgmania-content-browser-installer [flags]

  -install-dir <path>   ITGmania install directory (default: auto-detect)
  -list                 list detected installations and exit
  -list-themes          list this install's themes and whether the module runs under them
  -theme <name>         theme folder to install into (default: the one in use)
  -detect               print the best-guess install directory (for front-ends)
  -check                report whether the browser will work here, and exit
  -y                    don't prompt; use the first detected install
  -uninstall            remove the module files
  -no-banner            don't draw the artwork banner
  -version              print version and exit
```

`-check` is the one to reach for on a cabinet: it changes nothing, prints what
is and is not in place, and exits non-zero when something needs attention.

### How it works without a helper

There is **no background service**: nothing to register, nothing running
while the game is closed, nothing to babysit on a cabinet. The game does its
own fetching, and one web service fills the engine's real gaps.

**Most traffic is the game talking straight to the source.** The catalogue,
search, pack pages and banners come from stepmaniaonline.net; popularity
from arrowcloud.dance; the doubles category from itgdb.net; update manifests
and module archives from GitHub. Pack installs stream the zip to disk with
the engine's own `downloadFile` and land it in `/Songs` with
`FILEMAN:Unzip`. Pack deletion truncates every file to zero bytes -- the one
kind of remove the engine allows -- reclaiming the disk immediately; the
emptied group leaves the music wheel on the next song reload, which the
browser offers on the way out. In-game updates verify the archive's SHA-256
with the engine's own hasher and unzip it over the module's folder. All of
this works even if the relay below is unreachable, and every one of those
hosts must therefore be on the allowlist -- the installer puts them there.

**Four things go through the preview relay at `https://itgcontent.net`**,
because the engine cannot make them for itself: ITGmania's Lua cannot write
binary data (`RageFile:Write` stops at the first zero byte), cannot inflate
anything except a complete zip archive, and has no delete, move or rename.
So the relay (the `itg-content-webapp` repo) reads the catalogue's pack zips
with ranged requests -- never a whole pack -- and serves:

* **song previews**: the one song's audio, inflated out of the pack's
  archive, whole, so the sample seek always lands;
* **chart windows**: the sample window and every difficulty's notes, parsed
  from the simfile;
* **single-song installs**: the song's folder re-served as a small real zip
  the engine will unzip;
* **pack facts**: `Pack.ini` sync, which songs carry Lua mods, and charter
  credits.

A machine running its own relay -- a developer with the dev server up --
points at it by writing that URL as the one line of
`Save/ITGmaniaContentBrowser/webapp.txt`.

Installs that ran an older version's background helper are cleaned on the
next install run: its login item, launcher line and binary are removed.

## What the installer does

* **Finds ITGmania automatically** — portable and non-portable layouts, every
  release, on all three platforms. Pick a folder manually if yours lives
  somewhere unusual; the Windows wizard pre-fills the detected path and lets
  you Browse.
* **Copies the module** into `Themes/Simply Love/Modules/`, removing files from
  older versions so the module never loads twice.
* **Enables network access** by adding the browser's hosts to
  `HttpAllowHosts` in `Preferences.ini` and setting `HttpEnabled=1`: the
  catalogue hosts, `localhost` for the preview relay in development, and the
  GitHub hosts the in-game updater reads.
* **Sweeps the old helper** if an earlier version installed one: its
  scheduled task or unit, its launcher line, and its binary.

The preferences edit keeps every host already on your allowlist (GrooveStats
keeps working), changes at most two lines — `HttpAllowHosts` and `HttpEnabled` —
and adds them, or a whole `[Options]` section, if they are missing. It preserves
CRLF endings, writes a timestamped `.bak` next to the file, and writes atomically
so an interrupted run cannot corrupt it. Running it twice is harmless.

### Why the allowlist step is needed

ITGmania does not let a theme grant itself internet access. `HttpEnabled` and
`HttpAllowHosts` are `PreferenceType::Immutable` so every Lua write is refused;
`Preferences.ini`, `Static.ini` and `Defaults.ini` are all passed to
`FILEMAN->ProtectPath()` so the game refuses to write them even through its own
file layer; and the Lua sandbox has no `os`/`io` library and no way to launch a
program. That is a deliberate boundary — themes are untrusted content.

So the privileged edit is done by this installer, which you run yourself. The
module never asks for permission in-game and never changes the setting behind
your back; if the setting is missing it shows a **Network Access Not Enabled**
warning naming the exact problem and how to fix it.

## If something goes wrong

Ask the installer. It reports the two things that can be wrong and changes
nothing:

```bash
itgmania-content-browser-installer -check
```

It prints whether the browser's hosts are on the allowlist, whether an old
version's background helper left anything behind, and whether the preview
relay is reachable. It exits non-zero when something needs attention, so a
cabinet's startup script can run it.

Most problems are one of these:

* **"Preview relay: NOT reachable"** — browsing, downloads and deletion all
  work without it; song previews and single-song installs do not. Check your
  internet connection; a machine meant to use its own relay puts that URL in
  `Save/ITGmaniaContentBrowser/webapp.txt`.
* **"Old helper: ... still registered"** — a leftover from an earlier version
  that ran a background service. Run the installer once; it sweeps the
  registration and the binary.
* **"Allowlist: NOT SET"** — re-run the installer **with ITGmania closed**. The
  game rewrites `Preferences.ini` from memory when it exits, so an edit made
  while it is running is thrown away.
* **Find Content disappeared after updating ITGmania itself (Linux)** — re-run
  this installer. ITGmania's Linux `setup.sh` preserves the theme's modules
  across an upgrade with `cp -r -n "<old>/Modules" "<new>/Modules"`, and
  because the new release already ships a `Modules` directory (Simply Love
  keeps a README there) `cp` copies the folder *into* it rather than over it.
  Everything ends up one level deeper, at `Modules/Modules/`. Simply Love lists
  `Modules/` non-recursively and loads only names ending `.lua`, so nothing
  there is ever read and the title-menu entry vanishes with no error anywhere.
  Re-running puts the files back where they belong and removes the orphaned
  copy. The same upgrade also re-copies them as root, so even where they do
  still load, the in-game updater — which runs as the player — could no longer
  replace them until the installer hands them back.

  (Both only affect the stock `Simply Love` theme. That script names it
  explicitly, so a fork such as `Simply Love-SM5` is left alone entirely and
  its copy keeps working.)

If the allowlist is the only thing missing — `Preferences.ini` was reset or
replaced — the manual scripts `Enable Network Access.bat` (Windows) and
`enable-network-access.sh` (macOS/Linux) in `Themes/Simply Love/Modules/`
put it back without re-running the installer. They add the same hosts the
installer writes, set `HttpEnabled=1`, and never remove a host you already
had. Both are plain text and safe to read first.

## Requirements

* ITGmania **1.1 or newer** (the module uses `NETWORK:HttpRequest`; tested
  against 1.3.0).
* The **Simply Love** theme, which ITGmania ships by default.

## Building from source

Go 1.21+ is the only hard requirement; `CGO_ENABLED=0` throughout, so one
machine cross-compiles every binary.

```bash
go test ./...
./build.sh                # version comes from branding.go -> dist/
./build.sh dev-$(git rev-parse --short HEAD)   # throwaway; skips the version checks
```

`build.sh` also produces the graphical installers when their toolchain is
present, and says so when it is skipping one:

* **Windows setup.exe** needs [Inno Setup 6](https://jrsoftware.org/isdl.php).
  Point at it with `ISCC=/path/to/ISCC.exe` if it is not in Program Files.
* **macOS .pkg** needs macOS (`pkgbuild`/`productbuild`).

CI builds all of them: the Windows job installs Inno Setup, a macOS job builds
the `.pkg`, and a `v*` tag publishes everything with `SHA256SUMS.txt`.

Artwork lives in `internal/assets/banner.jpg` and is embedded into the binary.
After changing it, regenerate the installer images:

```bash
go run ./tools/mkwizardart
```

If you fork and publish this, change the module path in `go.mod` from
`itgmania-content-browser` to your own and update the import in
`cmd/content-browser-installer/main.go`.

## Releasing

A release is one version number in **three files that have to agree** --
`Version` in [internal/branding/branding.go](internal/branding/branding.go),
`UP.VERSION` in the payload's `04 queues.lua`, and the payload's `VERSION`
stamp file -- plus the `v<version>` tag built from them. The stamp is what says
which module is actually installed; without it every module-only update
re-offers itself forever. `build.sh` compares all four and refuses to build a
release while any of them disagree, and `mkmodulezip` refuses to cut an archive
whose stamp does not match, so drift fails the build instead of shipping.

### Publish in this order

1. Run `go test ./...`, bump the three versions, then run `./build.sh` with no
   argument -- it takes the version from `branding.go`. It writes the release
   archive to `dist/` **and stages a copy at `release/module.zip`**. That copy
   is the one the release publishes.

2. Fill in `notes` and `minHelper` in `dist/update.json`.

   `notes` is read by players, inside the game, deciding whether to take the
   update. Write it for them, not for the changelog.

   `minHelper` is the **oldest version whose own updater can actually take
   this one** -- not automatically the version being cut, and not simply the
   oldest still in the wild. A version whose updater cannot verify a download
   can never accept one: 0.4 and older compare the engine's raw 32-byte digest
   against the manifest's hex and never match, so 0.6 sets `0.5` and everything
   older is sent to the installer instead of failing forever. When in doubt,
   read the updater in the oldest version you mean to include rather than
   guessing. It defaults to the version being cut, which excludes everybody.
   (The name is a fossil from when a helper applied updates; the field now
   gates the module's own updater.)

3. Copy `dist/update.json` to the repo root and commit it **together with**
   `release/module.zip`. They describe each other: the manifest carries that
   archive's sha256, and committing one without the other is the whole failure
   this ordering exists to prevent.

4. Tag `v<version>` and push.

`dist/` is gitignored and nothing in it is published directly -- CI rebuilds the
installers from the tag. Only the two files committed in step 3 cross over, and
the module archive is published from that committed copy rather than from the
one the runner builds.

That last part is not fussiness. The archive is deterministic only for a
**fixed Go toolchain**: `compress/flate` makes no promise across Go releases, so
a zip built locally and one built by CI can hold byte-identical files and still
differ by kilobytes. Publishing the runner's copy against a manifest describing
the local one is what failed the in-game update three releases running -- the
release looked fine, and every player who took it was told the download was
corrupt. The workflow now compares the committed archive against the manifest
and stops the release on any disagreement, so a mismatch costs a tag instead of
everybody's update.

## Layout

```
cmd/content-browser-installer/   console installer (the engine for all platforms)
  payload/Modules/               the Lua module, embedded into the binary
    ITGmania Content Browser.lua   the entry point: the only file the theme
                                   loads, and the map of everything below it
    ITGmania Content Browser/      the browser itself, in numbered parts,
                                   loaded in order by the entry point
                                   (see the README in that folder)
    ContentBrowserIcons/           tab, arrow and receptor artwork
internal/
  assets/                        banner.jpg, embedded
  banner/                        terminal artwork rendering (+ tests)
  branding/                      product name, author, slug, version
    installer/                     discovery, Preferences.ini merge, copy,
                                   pack removal, old-helper cleanup (+ tests)
  update/                        version check and in-game update (+ tests)
packaging/
  windows/setup.iss              Inno Setup wizard + generated wizard bitmaps
  macos/                         productbuild .pkg, background art, postinstall
tools/mkwizardart/               regenerates installer artwork from banner.jpg
tools/mkmodulezip/               builds the update payload and its manifest
build.sh                         every binary + available GUI installers
```

## Naming

The product is **ITGMania Content Browser**. The in-game menu entry is
deliberately called **Find Content** — that is what players see on the title
menu.

## License

GNU General Public License, version 3 — © 2026 Rosewood
<rosewoodsteps@gmail.com>; see [LICENSE](LICENSE) for the full text.

This program is free software: you may redistribute it and modify it under the
terms of the GPL version 3 as published by the Free Software Foundation. It is
distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.

A copy of the licence ships with the module itself, as
`ITGmania Content Browser LICENSE.txt` beside the module in
`Themes/Simply Love/Modules/`, so a player who only ever receives the module
still receives the terms with it.

The bundled artwork is licensed stock imagery and is **not** covered by the GPL
grant — replace `internal/assets/banner.jpg` if you redistribute a fork.
