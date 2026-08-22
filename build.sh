#!/usr/bin/env bash
# Cross-compile the installer for every platform ITGmania ships on.
#
# Go cross-compiles this project with no C toolchain (CGO is off), so one
# machine can produce every artifact. Output lands in dist/.
#
# Usage:  ./build.sh [version]

set -euo pipefail

VERSION="${1:-dev}"
OUT="dist"
LDFLAGS="-s -w -X main.version=${VERSION}"

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

echo
echo "  Artifacts in $OUT/:"
ls -1 "$OUT"
