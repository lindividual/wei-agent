#!/usr/bin/env bash
#
# Package the native shell as a `.app`.
#
#     macos/make-app.sh [debug|release]        → macos/dist/pi.app        (default: release)
#
# What this does that `swift run PiShell` does not:
#
#   - the icon, the version and the identifier, which a bare executable cannot carry — a bare
#     executable in the Dock is a generic document icon with a name taken from its file;
#   - a bundle, so LaunchServices treats it as an app: a menu bar, a real name, and a place in
#     the Dock and in the app switcher;
#   - a signature. Ad-hoc, which is enough for this machine and says so out loud rather than
#     pretending a downloaded copy would open.
#
# The bundle is assembled rather than produced by an Xcode project on purpose. There is no nib, no
# asset catalog and no build phase that does anything SwiftPM cannot, so an `.xcodeproj` would be a
# second description of the same program and a second thing to keep true.

set -euo pipefail

PROFILE="${1:-release}"
case "$PROFILE" in
  debug | release) ;;
  *)
    echo "unknown profile '$PROFILE': expected debug or release" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS="$ROOT/macos"
SHELL_DIR="$MACOS/PiShell"
DIST="$MACOS/dist"
APP="$DIST/pi.app"

# The version is the module's, so there is one place that says what this is. A packaging script with
# its own version constant is a number nobody remembers to change.
VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/moon.mod" | head -1)"
VERSION="${VERSION:-0.0.0}"
# The identifier is reversed-DNS by convention and this one is a placeholder: a real release sets it
# to a domain the project controls, because changing it later is what makes macOS forget which app a
# document or a saved window belongs to.
BUNDLE_ID="${PI_SHELL_BUNDLE_ID:-io.github.lindividual.pi-shell}"

echo "==> MoonBit side ($PROFILE)"
"$MACOS/build-moonbit.sh" "$PROFILE"

echo "==> Swift side ($PROFILE)"
cd "$SHELL_DIR"
LOG="$(mktemp)"
# The linker's `was built for newer macOS` warnings are expected — the MoonBit archive is built with
# this machine's SDK and the package targets 14 — so they are filtered rather than shown; anything
# else is a real build message and is printed. Quietly, because a packaging step that prints a
# thousand lines of link warnings is a step whose real errors nobody reads. The build's own exit
# status is what decides: a failure here prints everything it said and stops.
if ! swift build -c "$PROFILE" --product PiShell >"$LOG" 2>&1; then
  cat "$LOG"
  rm -f "$LOG"
  echo "swift build failed" >&2
  exit 1
fi
grep -v "^ld: warning: object file" "$LOG" | grep -v "^$" || true
rm -f "$LOG"
BIN_DIR="$(swift build -c "$PROFILE" --product PiShell --show-bin-path)"
BINARY="$BIN_DIR/PiShell"
# Removed and rebuilt rather than trusted: SwiftPM has no idea that `libpiweb.a` changed — the archive
# is MoonBit's output, in MoonBit's build directory, and nothing in the package graph points at it —
# so a MoonBit-side change can leave the old executable in place while reporting a successful build.
# The symptom is the worst kind: the app behaves exactly like the version before the fix.
rm -f "$BINARY"
swift build -c "$PROFILE" --product PiShell >>"$LOG" 2>&1 || {
  cat "$LOG"
  echo "swift build failed" >&2
  exit 1
}
if [ ! -x "$BINARY" ]; then
  echo "no executable at $BINARY" >&2
  exit 1
fi

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/pi"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>pi</string>
  <key>CFBundleDisplayName</key>
  <string>pi</string>
  <key>CFBundleExecutable</key>
  <string>pi</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Apache-2.0</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$MACOS/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc, and `--force` because rebuilding over an existing bundle is the common case. Not `--deep`:
# there is one executable here, and signing everything under a path is the flag that hides a second
# binary somebody forgot to sign.
echo "==> sign (ad-hoc)"
codesign --force --sign - "$APP"

echo
echo "$APP"
echo "  version   $VERSION"
echo "  bundle id $BUNDLE_ID"
echo
echo "open $APP        # or double-click it in Finder"
echo
echo "Note: ad-hoc signed, so a copy that arrives over the network is refused by Gatekeeper. A"
echo "release wants a Developer ID signature and notarization; this is enough for the machine that"
echo "built it."
