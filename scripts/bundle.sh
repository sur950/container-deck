#!/usr/bin/env bash
# Builds "Container Deck.app" into ./build
#
# Usage: scripts/bundle.sh [VERSION] [BUILD_NUMBER]
#   VERSION       Marketing version, for example 1.2.0. Default: the value in scripts/Info.plist.
#   BUILD_NUMBER  CFBundleVersion. Default: the git commit count, or 1.
#
# Environment:
#   CONFIG         release (default) or debug
#   SCRATCH_PATH   Optional SwiftPM build folder (default .build).
#   SIGN_IDENTITY  Certificate to sign with, hardened runtime and entitlements. Releases use the
#                  free self signed "<appName> Code Signing" (scripts/make_signing_cert.sh).
#                  A "Developer ID Application: ..." identity works too.
#                  Not set means ad hoc signing (fine for local use, not for sharing).
#   SIGN_KEYCHAIN  Optional keychain to find the identity in (used by CI).
#   SIGN_TIMESTAMP 1 to ask Apple's timestamp server (default only for Developer ID), 0 to skip.
set -euo pipefail

cd "$(dirname "$0")/.."

# Old usage was "bundle.sh release|debug". Keep it working.
if [[ "${1:-}" == "release" || "${1:-}" == "debug" ]]; then
  CONFIG="$1"
  shift
fi

CONFIG="${CONFIG:-release}"

# Product values come from the one config file, Sources/DeckCore/Config/AppConfig.swift.
APP_CONFIG="Sources/DeckCore/Config/AppConfig.swift"
cfg() { sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" "$APP_CONFIG" | head -n 1; }
APP_NAME="$(cfg appName)"
BUNDLE_ID="$(cfg bundleID)"
URL_SCHEME="$(cfg urlScheme)"
COMPANY="$(cfg company)"
MIN_MACOS="$(cfg minimumMacOS)"
for v in APP_NAME BUNDLE_ID URL_SCHEME COMPANY MIN_MACOS; do
  [[ -n "${!v}" ]] || { echo "error: $v missing in $APP_CONFIG" >&2; exit 1; }
done
PLIST_SRC="scripts/Info.plist"
ENTITLEMENTS="packaging/ContainerDeck.entitlements"
APP="build/$APP_NAME.app"
ICON_SRC="$(cfg appIconFile)"
PLISTBUDDY="/usr/libexec/PlistBuddy"

VERSION="${1:-$("$PLISTBUDDY" -c "Print :CFBundleShortVersionString" "$PLIST_SRC")}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${2:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: version must look like 1.2.3 or 1.2.3-beta.1 (got '$VERSION')" >&2
  exit 1
fi

echo "==> Building Container Deck $VERSION ($BUILD_NUMBER), $CONFIG, arm64"
BUILD_ARGS=(-c "$CONFIG" --arch arm64)
if [[ -n "${SCRATCH_PATH:-}" ]]; then BUILD_ARGS+=(--scratch-path "$SCRATCH_PATH"); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "==> Creating app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ContainerDeck" "$APP/Contents/MacOS/ContainerDeck"
# The `container compose` plugin. The Compose screen offers to install it (one admin prompt).
HELPER="$APP/Contents/MacOS/container-compose"
if [[ -x "$BIN_DIR/container-compose" ]]; then
  cp "$BIN_DIR/container-compose" "$HELPER"
else
  echo "warning: container-compose was not built. The app will not offer the terminal command." >&2
fi
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundles, if any target gains resources later.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

PL="$APP/Contents/Info.plist"
"$PLISTBUDDY" -c "Set :CFBundleName $APP_NAME" "$PL"
"$PLISTBUDDY" -c "Set :CFBundleDisplayName $APP_NAME" "$PL"
"$PLISTBUDDY" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PL"
"$PLISTBUDDY" -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$PL"
"$PLISTBUDDY" -c "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID" "$PL"
"$PLISTBUDDY" -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $URL_SCHEME" "$PL"
"$PLISTBUDDY" -c "Set :NSHumanReadableCopyright © $(date +%Y) $COMPANY" "$PL"
"$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
"$PLISTBUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Compiling asset catalog (brand accent color)"
xcrun actool packaging/Assets.xcassets --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 \
  --output-partial-info-plist build/assets-partial.plist >/dev/null
"$PLISTBUDDY" -c "Delete :NSAccentColorName" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
"$PLISTBUDDY" -c "Add :NSAccentColorName string AccentColor" "$APP/Contents/Info.plist"
rm -f build/assets-partial.plist

echo "==> Making app icon"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

if [[ "$CONFIG" == "release" ]]; then
  echo "==> Stripping debug symbols"
  strip -x "$APP/Contents/MacOS/ContainerDeck"
  if [[ -f "$HELPER" ]]; then strip -x "$HELPER"; fi
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with: $SIGN_IDENTITY (hardened runtime)"
  # A secure timestamp only matters for notarization (Developer ID). Self signed builds skip it.
  if [[ "${SIGN_TIMESTAMP:-}" == "1" || ( -z "${SIGN_TIMESTAMP:-}" && "$SIGN_IDENTITY" == "Developer ID"* ) ]]; then
    TIMESTAMP=(--timestamp)
  else
    TIMESTAMP=(--timestamp=none)
  fi
  SIGN_ARGS=(--force --options runtime "${TIMESTAMP[@]}" --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY")
  if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
    SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
  fi
  # Sign nested code first, then the app itself. The compose plugin gets no app entitlements.
  if [[ -f "$HELPER" ]]; then
    HELPER_ARGS=(--force --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_IDENTITY")
    if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then HELPER_ARGS+=(--keychain "$SIGN_KEYCHAIN"); fi
    codesign "${HELPER_ARGS[@]}" "$HELPER"
  fi
  while IFS= read -r -d '' nested; do
    codesign "${SIGN_ARGS[@]}" "$nested"
  done < <(find "$APP/Contents" -depth \( -name "*.dylib" -o -name "*.framework" \) -print0)
  codesign "${SIGN_ARGS[@]}" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  # The designated requirement pins the certificate. It must stay the same across releases
  # so macOS keeps Automation and login item permissions.
  codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /==> Designated requirement: /p'
else
  echo "==> Signing ad hoc (set SIGN_IDENTITY to sign for distribution)"
  if [[ -f "$HELPER" ]]; then codesign --force --sign - "$HELPER" >/dev/null; fi
  codesign --force --sign - "$APP" >/dev/null
fi

echo "Done: $APP ($VERSION)"
echo "Open it with: open \"$APP\""
