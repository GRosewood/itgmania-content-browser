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
| **Linux** | `itgmania-content-browser-installer-linux-amd64` (or `-arm64`) | Console installer |

**Close ITGmania first.** ITGmania rewrites `Preferences.ini` from memory when
it exits, so the installers refuse to run while it is open.

On macOS and Linux you may need `chmod +x` first, and macOS marks downloads as
quarantined — right-click → Open, or
`xattr -d com.apple.quarantine <file>`.

Then start ITGmania: **Find Content** is on the title menu, below Exit.

### Console installer

Every platform also ships the plain console installer, which is what the
graphical ones drive underneath. Useful for scripting and cabinets:

```
itgmania-content-browser-installer [flags]

  -install-dir <path>   ITGmania install directory (default: auto-detect)
  -list                 list detected installations and exit
  -detect               print the best-guess install directory (for front-ends)
  -y                    don't prompt; use the first detected install
  -uninstall            remove the module files
  -helper               run the loopback service the in-game browser deletes packs with
  -no-banner            don't draw the artwork banner
  -version              print version and exit
```

### How in-game pack deletion works

The module's **Installed Packs** tab deletes packs outright, without the player
leaving the game. It cannot do that on its own: ITGmania's Lua file manager
exposes only `Copy`, `DoesFileExist`, `GetFileSizeBytes`, `GetHashForFile`,
`GetDirListing` and `Unzip`, and no delete, move or rename exists anywhere in
the Lua API.

What Lua *can* do is issue an HTTP request, and `NetworkManager::IsUrlAllowed`
matches on host only — the port is not part of the check. So the installer adds
`127.0.0.1` to `HttpAllowHosts` and registers a per-user login item that runs
this same binary with `-helper`. That service:

* binds **127.0.0.1 on an OS-assigned port** and nothing else;
* generates a fresh token per run and publishes `{port, token}` to
  `Save/ITGmaniaContentBrowser/helper.json` with mode 0600;
* rejects any request that is not loopback and does not carry the token
  (compared in constant time);
* accepts only `GET /health` and `POST /remove`;
* resolves the pack name through the same guard the tests cover — it must be a
  plain folder name that lands directly inside a `Songs/` directory, so
  `../Program` and friends are refused rather than acted on;
* exits when its config file disappears or names another process, which is how
  uninstall stops it and how an upgrade replaces it.

No elevation, no system service, and `-uninstall` removes the login item, the
binary and the config.

## What the installer does

* **Finds ITGmania automatically** — portable and non-portable layouts, every
  release, on all three platforms. Pick a folder manually if yours lives
  somewhere unusual; the Windows wizard pre-fills the detected path and lets
  you Browse.
* **Copies the module** into `Themes/Simply Love/Modules/`, removing files from
  older versions so the module never loads twice.
* **Enables network access** by adding `stepmaniaonline.net`,
  `arrowcloud.dance` (which curates the featured grid, supplies its artwork
  and dates its releases) and `127.0.0.1` (the
  local delete helper) to `HttpAllowHosts` in `Preferences.ini`, and setting
  `HttpEnabled=1`.

The preferences edit keeps every host already on your allowlist (GrooveStats
keeps working), changes exactly one line, preserves CRLF endings, writes a
timestamped `.bak` next to the file, and writes atomically so an interrupted
run cannot corrupt it. Running it twice is harmless.

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

Run the installer again. Or, with ITGmania closed, run
`Enable Network Access.bat` (Windows) / `enable-network-access.sh`
(macOS/Linux) from `Themes/Simply Love/Modules/` — both are plain text and
safe to read first. To do it by hand, add this to the `HttpAllowHosts` line in
`Save/Preferences.ini`:

```
stepmaniaonline.net,*.stepmaniaonline.net
```

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

## Layout

```
cmd/content-browser-installer/   console installer (the engine for all platforms)
  payload/Modules/               the Lua module, embedded into the binary
internal/
  assets/                        banner.jpg, embedded
  banner/                        terminal artwork rendering (+ tests)
  branding/                      product name, author, slug in one place
  helper/                        loopback delete service (+ tests)
  installer/                     discovery, Preferences.ini merge, copy,
                                 pack removal, login item (+ tests)
packaging/
  windows/setup.iss              Inno Setup wizard + generated wizard bitmaps
  macos/                         productbuild .pkg, background art, postinstall
tools/mkwizardart/               regenerates installer artwork from banner.jpg
build.sh                         every binary + available GUI installers
```

## Naming

The product is **ITGMania Content Browser**. The in-game menu entry is
deliberately called **Find Content** — that is what players see on the title
menu.

## License

MIT, © Rosewood <rosewoodsteps@gmail.com>; see [LICENSE](LICENSE). The bundled artwork is licensed stock imagery and
is not covered by the MIT grant — replace `internal/assets/banner.jpg` if you
redistribute a fork.
