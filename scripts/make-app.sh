#!/usr/bin/env bash
#
# Assemble a proper macOS .app bundle around the Swift Package executable.
# Run from the repo root:
#
#   ./scripts/make-app.sh         (release build)
#   ./scripts/make-app.sh --debug (debug build)
#
# Outputs:  build/Scarlett MixControl.app
#
# To launch from Finder: open "build/Scarlett MixControl.app"

set -euo pipefail

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG="debug"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/build"
APP_NAME="Scarlett MixControl"
APP_DIR="$BUILD_ROOT/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
BUNDLE_ID="dev.marekkramar.ScarlettMixControl"
EXE_NAME="ScarlettMixControl"
# Version shown in-app and in the bundle. CI passes the release tag via
# APP_VERSION; local builds derive it from git ("0.2.0-6-ga258ff3-dirty", or
# "0.2.1" on an exact tag), or "dev" when there's no git checkout.
# A leading "v" is stripped so "v0.2.0-beta.3" → "0.2.0-beta.3".
if [[ -z "${APP_VERSION:-}" ]]; then
  APP_VERSION="$(git -C "$REPO_ROOT" describe --tags --dirty --match 'v[0-9]*' 2>/dev/null || echo dev)"
fi
APP_VERSION="${APP_VERSION#v}"
# Build number: commit count, increasing along main (needs full history in CI).
APP_BUILD="${APP_BUILD:-$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)}"
ICON_SRC="$REPO_ROOT/Sources/ScarlettApp/Resources/AppIcon.png"
ICONSET_DIR="$BUILD_ROOT/AppIcon.iconset"
ICNS_FILE="$RESOURCES_DIR/AppIcon.icns"

echo "→ Version $APP_VERSION ($APP_BUILD)"
echo "→ Building swift-package executable ($CONFIG)…"
swift build -c "$CONFIG" --product scarlett-app

# SwiftPM places the binary + its resource bundle here.
SPM_BIN_DIR="$REPO_ROOT/.build/$CONFIG"

# --- Clean previous bundle ---------------------------------------------------
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# --- Copy binary -------------------------------------------------------------
echo "→ Copying binary → MacOS/$EXE_NAME"
cp "$SPM_BIN_DIR/scarlett-app" "$MACOS_DIR/$EXE_NAME"
chmod +x "$MACOS_DIR/$EXE_NAME"

# Copy AppIcon.png into the bundle too (optional runtime use via Bundle.main).
cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.png"

# We deliberately do NOT copy the SwiftPM resource bundle into the .app.
# Finder/Dock icons come from Resources/AppIcon.icns (CFBundleIconFile).
echo "→ Generating AppIcon.icns from $(basename "$ICON_SRC")"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
# macOS .iconset expects these specific sizes.  We resize the master PNG
# (which is 2048²) down with `sips` for each one.
for size in 16 32 64 128 256 512 1024; do
  out="$ICONSET_DIR/icon_${size}x${size}.png"
  sips -z "$size" "$size" "$ICON_SRC" --out "$out" >/dev/null
done
# Apple also wants @2x retina variants.
cp "$ICONSET_DIR/icon_32x32.png"      "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICONSET_DIR/icon_64x64.png"      "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICONSET_DIR/icon_256x256.png"    "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICONSET_DIR/icon_512x512.png"    "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICONSET_DIR/icon_1024x1024.png"  "$ICONSET_DIR/icon_512x512@2x.png"
rm "$ICONSET_DIR/icon_64x64.png" "$ICONSET_DIR/icon_1024x1024.png"
iconutil --convert icns "$ICONSET_DIR" --output "$ICNS_FILE"
rm -rf "$ICONSET_DIR"

# --- Write Info.plist --------------------------------------------------------
echo "→ Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>           <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>     <string>$EXE_NAME</string>
    <key>CFBundleIdentifier</key>     <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>       <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundlePackageType</key>    <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>        <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key> <string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key>       <string>NSApplication</string>
    <!-- Starts as a menu bar app; AppController switches to a regular app
         with a Dock icon when "Show in Dock" is on (the default). -->
    <key>LSUIElement</key>            <true/>
</dict>
</plist>
EOF

# --- Code-sign with an ad-hoc signature so Gatekeeper doesn't flag it -------
# We use ad-hoc (no identity) — fine for local installation, would need a
# real Developer ID cert for distribution.
echo "→ Ad-hoc codesigning"
codesign --force --sign - "$APP_DIR"

echo
echo "✓ Bundle ready:  $APP_DIR"
echo "  Launch with:   open \"$APP_DIR\""
