# Find Content installer for ITGmania

One-click installer for **SMO Find Content**, a Simply Love module that adds a
*Find Content* entry to the ITGmania title menu: an in-game browser for
[stepmaniaonline.net](https://stepmaniaonline.net) that downloads and installs
song packs without leaving the game.

Download the binary for your platform, run it, and you're done. It finds your
ITGmania installation, copies the module into Simply Love, and enables the one
network setting the module needs. No unzipping, no editing config files, no
moving files by hand.

## Install

1. Download the binary for your platform from
   [Releases](../../releases/latest):

   | Platform | File |
   |---|---|
   | Windows (x64) | `find-content-installer-windows-amd64.exe` |
   | Windows (ARM64) | `find-content-installer-windows-arm64.exe` |
   | macOS (Apple silicon) | `find-content-installer-macos-arm64` |
   | macOS (Intel) | `find-content-installer-macos-amd64` |
   | Linux (x64) | `find-content-installer-linux-amd64` |
   | Linux (ARM64) | `find-content-installer-linux-arm64` |

2. **Close ITGmania**, then run it.
   * Windows: double-click the `.exe`.
   * macOS / Linux: `chmod +x find-content-installer-*` then run it from a
     terminal.
3. Start ITGmania. **Find Content** is on the title menu, below Exit.

macOS marks downloads from the internet as quarantined; if Gatekeeper blocks
it, either right-click → Open, or clear the flag:
`xattr -d com.apple.quarantine find-content-installer-macos-*`.

## What it does

* Detects ITGmania automatically — portable and non-portable layouts, every
  release, on all three platforms. Falls back to `-install-dir` if your install
  lives somewhere unusual, and asks which to use if you have several.
* Copies the module into `Themes/Simply Love/Modules/`.
* Adds `stepmaniaonline.net` to `HttpAllowHosts` in your `Preferences.ini` and
  makes sure `HttpEnabled=1`.

The preferences edit **keeps every host already on your allowlist** (GrooveStats
keeps working), changes exactly one line, writes a timestamped `.bak` next to
the file, and writes atomically so an interrupted run cannot corrupt it. Running
the installer twice is harmless — it reports "already enabled" and touches
nothing.

It refuses to run while ITGmania is open, because ITGmania rewrites
`Preferences.ini` from memory when it exits and would discard the change.

### Why the allowlist step is needed

ITGmania does not let a theme grant itself internet access. `HttpEnabled` and
`HttpAllowHosts` are `PreferenceType::Immutable` so every Lua write is refused;
`Preferences.ini`, `Static.ini` and `Defaults.ini` are all passed to
`FILEMAN->ProtectPath()` so the game refuses to write them even through its own
file layer; and the Lua sandbox has no `os`/`io` library and no way to launch a
program. That is a deliberate boundary — themes are untrusted content.

So the privileged edit is done by this installer, which you run yourself,
outside the game. The module never asks for permission in-game and never tries
to change the setting behind your back; if the setting is missing it simply
shows a warning telling you how to fix it.

## Usage

```
find-content-installer [flags]

  -install-dir <path>   ITGmania install directory (default: auto-detect)
  -list                 list detected installations and exit
  -y                    don't prompt; use the first detected install
  -uninstall            remove the module files
  -version              print version and exit
```

Examples:

```bash
# see what it finds
./find-content-installer -list

# install to a specific location, no prompts
./find-content-installer -install-dir "D:\Games\ITGmania" -y

# remove the module (leaves the allowlist alone)
./find-content-installer -uninstall
```

## If something goes wrong

The module shows a **Network Access Not Enabled** warning inside the game if
the allowlist is not right. Fix it by running this installer again, or — with
ITGmania closed — by running `Enable Network Access.bat` (Windows) or
`enable-network-access.sh` (macOS/Linux) from
`Themes/Simply Love/Modules/`. Both are plain-text and safe to read first.

To do it entirely by hand, add this to the `HttpAllowHosts` line in
`Save/Preferences.ini` while the game is closed:

```
stepmaniaonline.net,*.stepmaniaonline.net
```

## Requirements

* ITGmania **1.1 or newer** (the module uses `NETWORK:HttpRequest`, added in
  0.5.1; tested against 1.3.0).
* The **Simply Love** theme — this is a Simply Love add-on. ITGmania ships it
  by default.

## Building from source

Requires Go 1.21+ (no C toolchain; `CGO_ENABLED=0` throughout, so one machine
cross-compiles every target).

```bash
go test ./...
./build.sh 1.0.0     # writes every platform binary to dist/
```

The module payload lives in `cmd/find-content-installer/payload/Modules/` and is
embedded into the binary with `go:embed`, so each artifact is fully
self-contained.

CI (`.github/workflows/release.yml`) vets, tests and gofmt-checks on every push,
and publishes all six binaries plus `SHA256SUMS.txt` when a `v*` tag is pushed.

If you fork and publish this, change the module path in `go.mod` from
`itgmania-find-content` to your own (e.g. `github.com/you/itgmania-find-content`)
and update the import in `cmd/find-content-installer/main.go`.

## Layout

```
cmd/find-content-installer/    CLI entry point
  payload/Modules/             the module, embedded into the binary
internal/installer/
  discover.go                  finds ITGmania across platforms/layouts
  prefs.go                     the Preferences.ini allowlist merge (+ tests)
  install.go                   copies the payload into Simply Love
  running.go                   refuses to run while the game is open
build.sh                       cross-compiles every target into dist/
```

## License

The installer is released under the MIT License; see [LICENSE](LICENSE).
