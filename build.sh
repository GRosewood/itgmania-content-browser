#!/usr/bin/env bash
# Cross-compile the installer for every platform ITGmania ships on.
#
# Go cross-compiles this project with no C toolchain (CGO is off), so one
# machine can produce every artifact. Output lands in dist/.
#
# Usage:  ./build.sh [version]

set -euo pipefail

# The version lives in internal/branding, so a release is one line changed in
# one file. Passing one here still overrides it for a throwaway build.
# [[:space:]] rather than \t: \t is a GNU extension, and BSD sed -- which is
# what macOS ships, and what the macos-pkg job runs -- reads it as a literal
# "t". The pattern then matched nothing there, BRANDED came back empty, and the
# drift check below failed every tagged build on macOS while passing everywhere
# else. A POSIX bracket expression means the same thing to both.
BRANDED="$(sed -n 's/^[[:space:]]*Version = "\(.*\)"$/\1/p' internal/branding/branding.go)"
VERSION="${1:-${BRANDED:-dev}}"
OUT="dist"
LDFLAGS="-s -w -X main.version=${VERSION}"

if [ -z "$BRANDED" ]; then
  echo "  warning: could not read Version from internal/branding/branding.go" >&2
fi

# Version truth lives in three places -- branding.go, the module payload
# (UP.VERSION and the VERSION stamp), and whatever tag CI is building -- and
# nothing used to notice when they drifted apart. A release built from
# disagreeing numbers plants the update-nag loop on every machine that takes
# it, so a disagreement fails the build here instead of shipping. Dev builds
# (dev-<sha>) are exempt: they are not releases and never match on purpose.
case "$VERSION" in
  dev-*) ;;
  *)
    STAMP="$(tr -d ' \r\n' < "cmd/content-browser-installer/payload/Modules/ITGmania Content Browser/VERSION" 2>/dev/null || true)"
    UPVER="$(sed -n 's/^UP.VERSION = "\(.*\)".*$/\1/p' "cmd/content-browser-installer/payload/Modules/ITGmania Content Browser/04 queues.lua" | head -1)"
    if [ -z "$STAMP" ]; then STAMP="(missing)"; fi
    if [ -z "$UPVER" ]; then UPVER="(missing)"; fi
    if [ "$VERSION" != "$BRANDED" ] || [ "$VERSION" != "$STAMP" ] || [ "$VERSION" != "$UPVER" ]; then
      echo "version drift: building $VERSION, branding.go says $BRANDED," >&2
      echo "the payload VERSION stamp says $STAMP, UP.VERSION says $UPVER." >&2
      echo "All four must agree before a release can be cut." >&2
      exit 1
    fi
    ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT"

# ITGmania publishes Windows x64, macOS universal (arm64 + x64), and Linux x64.
# arm64 Linux is included for single-board cabinet builds.
targets=(
  "windows amd64 itgmania-content-browser-installer-windows-amd64.exe"
  "windows arm64 itgmania-content-browser-installer-windows-arm64.exe"
  "darwin  amd64 itgmania-content-browser-installer-macos-amd64"
  "darwin  arm64 itgmania-content-browser-installer-macos-arm64"
  "linux   amd64 itgmania-content-browser-installer-linux-amd64"
  "linux   arm64 itgmania-content-browser-installer-linux-arm64"
)

for entry in "${targets[@]}"; do
  read -r goos goarch name <<<"$entry"
  printf '  building %-10s %-6s -> %s\n' "$goos" "$goarch" "$name"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/$name" ./cmd/content-browser-installer
done

# macOS universal binary, when building on a Mac with lipo available.
if command -v lipo >/dev/null 2>&1; then
  echo "  building darwin     universal -> itgmania-content-browser-installer-macos-universal"
  lipo -create -output "$OUT/itgmania-content-browser-installer-macos-universal" \
    "$OUT/itgmania-content-browser-installer-macos-amd64" "$OUT/itgmania-content-browser-installer-macos-arm64"
fi


# ---------------------------------------------------------------------------
# Graphical installers, where the platform has one.
#
# Windows: an Inno Setup wizard (artwork, folder picker, progress, finish).
# macOS:   an Installer.app .pkg with the artwork as the window background.
# Linux:   no universal GUI installer format; the CLI binary is the artifact.
#
# Both wrap the console binary rather than reimplementing anything, and both
# are skipped with a note when their toolchain is not on this machine.

ISCC="${ISCC:-}"
if [ -z "$ISCC" ]; then
  for c in "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe"; do
    [ -x "$c" ] && ISCC="$c" && break
  done
fi
if [ -n "$ISCC" ] && [ -x "$ISCC" ]; then
  echo "  building windows    setup    -> itgmania-content-browser-setup-${VERSION}.exe"
  "$ISCC" "//DAppVersion=${VERSION}" "packaging\windows\setup.iss" >/dev/null
else
  echo "  skipping Windows setup.exe (Inno Setup not found; set ISCC=/path/to/ISCC.exe)"
fi

if [ "$(uname -s)" = "Darwin" ]; then
  echo "  building macos      pkg      -> itgmania-content-browser-setup-${VERSION}.pkg"
  ./packaging/macos/build-pkg.sh "$VERSION"
else
  echo "  skipping macOS .pkg (requires macOS; CI builds it on a macos runner)"
fi

# ---------------------------------------------------------------------------
# The in-game update payload.
#
# The browser updates itself by fetching this archive and unpacking it over
# Themes/Simply Love/Modules/. It is the same payload the installer embeds, so
# a player who updates in game ends up with exactly the files a fresh install
# would have given them.
#
# The manifest beside it is what the helper reads to decide whether there is
# anything to offer. Publishing a release is: run this, upload the zip to the
# release, verify the download's sha256 matches the manifest, and only THEN
# commit update.json -- the commit is what makes the update live, and a live
# manifest pointing at an asset that is not there yet offers every player a
# download that fails.
MODULE_ZIP="itgmania-content-browser-module-${VERSION}.zip"
echo "  building module     payload  -> ${MODULE_ZIP}"
go run ./tools/mkmodulezip -version "${VERSION}" -out "$OUT"
echo
echo "  To publish: fill in the manifest notes, set minHelper to the oldest"
echo "  helper that can run this module, copy dist/update.json to the repo root,"
echo "  commit it, and upload ${MODULE_ZIP} to the v${VERSION} release."
echo
echo "  Artifacts in $OUT/:"
ls -1 "$OUT"
