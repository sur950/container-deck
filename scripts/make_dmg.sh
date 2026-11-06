#!/usr/bin/env bash
# Packs "build/<appName>.app" into build/<AssetStem>-<VERSION>.dmg
# (for example build/ContainerDeck.dmg) with an Applications shortcut.
# The volume is named after the app. Names come from AppConfig.swift (scripts/config.sh).
#
# Usage: scripts/make_dmg.sh [VERSION]
#   VERSION  Default: CFBundleShortVersionString of the built app.
#
# Environment:
#   SIGN_IDENTITY  A "Developer ID Application: ..." identity also signs the disk image
#                  (needed for notarization). Self signed releases leave the image unsigned:
#                  the app inside is signed, and the updater checks the image with Ed25519.
#   SIGN_KEYCHAIN  Optional keychain to find the identity in.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

VOLUME_NAME="$APP_NAME"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found. Run scripts/bundle.sh first." >&2
  exit 1
fi

VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")}"
VERSION="${VERSION#v}"
DMG="build/$(dmg_name "$VERSION")"
STAGING="build/dmg-staging"
RW_DMG="build/$ASSET_STEM-rw.dmg"

echo "==> Staging"
rm -rf "$STAGING" "$RW_DMG" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
fi

echo "==> Creating disk image"
# APFS, not HFS+: macOS 27 no longer mounts HFS+ disk images, and APFS images open on every
# macOS this app supports (15 and later). The in app updater mounts this image too.
if hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGING" -fs APFS -format UDRW -ov "$RW_DMG"; then
  # Give the volume our icon when SetFile is around (it ships with the Xcode tools).
  if command -v SetFile >/dev/null 2>&1 && [[ -f "$STAGING/.VolumeIcon.icns" ]]; then
    MOUNT_DIR="$(mktemp -d)"
    hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT_DIR" "$RW_DMG"
    SetFile -a C "$MOUNT_DIR" || true
    sync
    hdiutil detach -quiet "$MOUNT_DIR" || hdiutil detach -quiet -force "$MOUNT_DIR"
    rmdir "$MOUNT_DIR" 2>/dev/null || true
  fi
  hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
else
  # macOS 27 and later: hdiutil create from a folder is gone. diskutil image makes an APFS image.
  echo "==> hdiutil create failed, using diskutil image create"
  diskutil image create from --format UDZO --volumeName "$VOLUME_NAME" "$STAGING" "$DMG"
fi
rm -rf "$STAGING" "$RW_DMG"

if [[ "${SIGN_IDENTITY:-}" == "Developer ID"* ]]; then
  echo "==> Signing disk image"
  SIGN_ARGS=(--force --timestamp --sign "$SIGN_IDENTITY")
  if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
    SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
  fi
  codesign "${SIGN_ARGS[@]}" "$DMG"
fi

hdiutil verify -quiet "$DMG"
echo "Done: $DMG"
