# ITGMania Content Browser

*by GregTech*

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
  -helper               run the local service the in-game browser needs
  -manifest <url>       where the helper looks for update news
  -no-banner            don't draw the artwork banner
  -version              print version and exit
```

`-check` is the one to reach for on a cabinet: it changes nothing, prints what
is and is not in place, and exits non-zero when something needs attention.

### The local helper

The browser talks to a small service on loopback. On a fresh install it is the
browser's **only** route to the internet, so it is worth understanding before
you put this on a cabinet.

ITGmania does not let a theme reach the network on its own, and its Lua file
manager exposes only `Copy`, `DoesFileExist`, `GetFileSizeBytes`,
`GetHashForFile`, `GetDirListing` and `Unzip` — no delete, move or rename exists
anywhere in the Lua API. What Lua *can* do is issue an HTTP request, and
`NetworkManager::IsUrlAllowed` matches on host only, ignoring the port. So the
installer adds `127.0.0.1` to `HttpAllowHosts`, copies itself to
`<SaveDir>/ITGmaniaContentBrowser/content-browser-helper` (about 10 MB) and
registers that copy to start with the user's session, running with `-helper`.

That service:

* binds **127.0.0.1 on an OS-assigned port** and nothing else;
* generates a fresh token per run and publishes `{port, token}` to
  `Save/ITGmaniaContentBrowser/helper.json` with mode 0600;
* rejects any request that is not loopback and does not carry the token
  (compared in constant time) — every route, without exception;
* **relays the browser's reads** to stepmaniaonline.net, arrowcloud.dance and
  itgdb.net, and refuses any other host, redirects included. It is not an open
  proxy;
* serves pack deletion, audio previews, pack installs, `Pack.ini`, chart
  credits, free space and the in-game updater;
* resolves a pack name through the same guard the tests cover — it must be a
  plain folder name landing directly inside a `Songs/` directory, so
  `../Program` and friends are refused rather than acted on;
* exits when its config file disappears or names another process, which is how
  uninstall stops it and how an upgrade replaces it.

No elevation and no system service on any platform, and `-uninstall` removes the
registration, the binary and the config.

## What the installer does

* **Finds ITGmania automatically** — portable and non-portable layouts, every
  release, on all three platforms. Pick a folder manually if yours lives
  somewhere unusual; the Windows wizard pre-fills the detected path and lets
  you Browse.
* **Copies the module** into `Themes/Simply Love/Modules/`, removing files from
  older versions so the module never loads twice.
* **Enables network access** by adding `127.0.0.1` to `HttpAllowHosts` in
  `Preferences.ini` and setting `HttpEnabled=1`. That single entry is all the
  game needs: the helper service relays the browser's reads to
  stepmaniaonline.net, arrowcloud.dance and itgdb.net, and refuses to fetch
  from anywhere else. (Where those hosts are already on the allowlist -- an
  older install, or the manual scripts -- the browser still reads them
  directly and skips the hop.)

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

It prints whether `127.0.0.1` is on the allowlist, whether the helper is
answering right now, and — the one that catches cabinets — **what is registered
to start the helper and what that needs before it fires**. It exits non-zero
when something needs attention, so a cabinet's startup script can run it.

Most problems are one of these:

* **"Local helper: NOT RUNNING"** — the browser reaches the internet through
  it, so the browser will not open at all. Re-run the installer.
* **"starts only once a DESKTOP session starts"** — the machine boots straight
  into the game, so nothing ever runs the helper. Re-run the installer, which
  moves the install to a mechanism that does not need one.
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
replaced, but the helper is still installed — the manual scripts
`Enable Network Access.bat` (Windows) and `enable-network-access.sh`
(macOS/Linux) in `Themes/Simply Love/Modules/` put it back without re-running
the installer. They add `127.0.0.1` and set `HttpEnabled=1`, exactly what the
installer writes, and never remove a host you already had. Both are plain text
and safe to read first.

They do **not** install the helper, and the browser reaches the internet through
it — so if it is missing, they say so and point at the installer rather than
leaving you with a loopback entry and nothing listening on it.

## Requirements

* ITGmania **1.1 or newer** (the module uses `NETWORK:HttpRequest`; tested
  against 1.3.0).
* The **Simply Love** theme, which ITGmania ships by default.

## Building from source

Go 1.21+ is the only hard requirement; `CGO_ENABLED=0` throughout, so one
machine cross-compiles every binary.

```bash
go test ./...
./build.sh 1.0.0          # all six binaries -> dist/
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

Cutting a release is changing the version in **three places that must agree**
-- `Version` in
[internal/branding/branding.go](internal/branding/branding.go),
`UP.VERSION` in the payload's `04 queues.lua`, and the `VERSION` stamp file
inside the payload's parts folder -- plus tagging `v<version>`. The stamp is
what a restarted helper reads to know which module is actually installed;
without it every module-only update re-offers itself forever. `build.sh`
refuses to build a release while any of the four disagree, and `mkmodulezip`
refuses to cut an archive whose stamp does not match, so a drift fails the
build instead of shipping.

### Publish in this order

1. Bump the three versions, run `./build.sh`.
2. Set `minHelper` in `dist/update.json` to the **oldest helper that can run
   this module** — not automatically this release. It defaults to the version
   being cut, which refuses the in-game update for everyone on an older
   helper and tells them to run the installer instead.
3. Tag `v<version>` and upload the module zip to that release.
4. Copy `dist/update.json` to the repo root and **check it against what you
   actually uploaded**:

   ```bash
   go run ./tools/mkmodulezip -verify update.json -fix
   ```

5. Only then commit `update.json`. That commit is what makes the update live.

Step 4 is not a formality. The archive is deterministic only for a **fixed Go
toolchain**: `compress/flate` gives no guarantee across Go releases, so a zip
built locally and one built by CI can hold byte-identical files and still
differ by kilobytes. The checksum worth committing is the one taken from the
file that is actually published — which is what `-verify` reads. Without it a
release looks fine until a player updates and is told the download is corrupt.

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
  helper/                        loopback delete service (+ tests)
  installer/                     discovery, Preferences.ini merge, copy,
                                 pack removal, autostart registration
                                 (scheduled task / systemd user unit /
                                 launch agent) (+ tests)
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
