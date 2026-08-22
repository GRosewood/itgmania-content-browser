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
  "windows amd64 find-content-installer-windows-amd64.exe"
  "windows arm64 find-content-installer-windows-arm64.exe"
  "darwin  amd64 find-content-installer-macos-amd64"
  "darwin  arm64 find-content-installer-macos-arm64"
  "linux   amd64 find-content-installer-linux-amd64"
  "linux   arm64 find-content-installer-linux-arm64"
)

for entry in "${targets[@]}"; do
  read -r goos goarch name <<<"$entry"
  printf '  building %-10s %-6s -> %s\n' "$goos" "$goarch" "$name"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/$name" ./cmd/find-content-installer
done

# macOS universal binary, when building on a Mac with lipo available.
if command -v lipo >/dev/null 2>&1; then
  echo "  building darwin     universal -> find-content-installer-macos-universal"
  lipo -create -output "$OUT/find-content-installer-macos-universal" \
    "$OUT/find-content-installer-macos-amd64" "$OUT/find-content-installer-macos-arm64"
fi

echo
echo "  Artifacts in $OUT/:"
ls -1 "$OUT"
