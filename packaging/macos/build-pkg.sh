#!/usr/bin/env bash
# Build the macOS GUI installer (.pkg) for ITGMania Content Browser.
#
# Installer.app provides the graphical wizard: the artwork appears as the
# window background and the welcome/conclusion panes carry the product name
# and author. The package payload is just the console helper; the postinstall
# script runs it, so the GUI and CLI share one implementation.
#
# Must run on macOS (pkgbuild/productbuild are Apple tools).
#   ./packaging/macos/build-pkg.sh 1.0.0
set -euo pipefail

VERSION="${1:-0.0.0-dev}"
ID="net.gregtech.itgmania-content-browser"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIST="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Universal helper so one package covers Intel and Apple silicon.
mkdir -p "$STAGE/root/usr/local/share/itgmania-content-browser"
if command -v lipo >/dev/null 2>&1 &&
   [ -f "$DIST/itgmania-content-browser-installer-macos-amd64" ] &&
   [ -f "$DIST/itgmania-content-browser-installer-macos-arm64" ]; then
    lipo -create -output "$STAGE/root/usr/local/share/itgmania-content-browser/itgmania-content-browser-installer" \
        "$DIST/itgmania-content-browser-installer-macos-amd64" \
        "$DIST/itgmania-content-browser-installer-macos-arm64"
else
    cp "$DIST/itgmania-content-browser-installer-macos-arm64" \
       "$STAGE/root/usr/local/share/itgmania-content-browser/itgmania-content-browser-installer"
fi
chmod +x "$STAGE/root/usr/local/share/itgmania-content-browser/itgmania-content-browser-installer"

pkgbuild \
    --root "$STAGE/root" \
    --scripts "$HERE/scripts" \
    --identifier "$ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$STAGE/component.pkg"

cat > "$STAGE/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>ITGMania Content Browser</title>
    <organization>net.gregtech</organization>
    <background file="background.png" alignment="topleft" scaling="proportional"/>
    <welcome file="welcome.html"/>
    <conclusion file="conclusion.html"/>
    <options customize="never" require-scripts="true" hostArchitectures="x86_64,arm64"/>
    <domains enable_localSystem="true"/>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="ITGMania Content Browser"><pkg-ref id="$ID"/></choice>
    <pkg-ref id="$ID" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

mkdir -p "$DIST"
productbuild \
    --distribution "$STAGE/distribution.xml" \
    --resources "$HERE/resources" \
    --package-path "$STAGE" \
    "$DIST/itgmania-content-browser-setup-$VERSION.pkg"

echo "built $DIST/itgmania-content-browser-setup-$VERSION.pkg"
