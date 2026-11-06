#!/usr/bin/env bash
# Builds an installer package from "build/<appName>.app" into build/<AssetStem>.pkg
# (for example build/ContainerDeck.pkg). It always installs into /Applications.
#
# Usage: scripts/make_pkg.sh VERSION
#
# Users install it with:
#   curl -fsSLO https://github.com/<repo>/releases/latest/download/ContainerDeck.pkg
#   sudo installer -pkg ContainerDeck.pkg -target /
# Files downloaded with curl carry no quarantine flag, so the app opens without a Gatekeeper prompt.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh

VERSION="${1:?usage: scripts/make_pkg.sh VERSION}"
VERSION="${VERSION#v}"
[[ -d "$APP" ]] || { echo "error: $APP not found. Run scripts/bundle.sh first." >&2; exit 1; }

PKG="build/$(pkg_name "$VERSION")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Staging $APP_NAME $VERSION"
mkdir -p "$WORK/root"
ditto --norsrc --noextattr --noqtn "$APP" "$WORK/root/$APP_NAME.app"

# Never relocate: always install into /Applications, even if another copy exists elsewhere.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$WORK/component.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/component.plist"

# Drop extended attributes from the payload. macOS 15 and later keep com.apple.provenance on
# files it creates and does not let it be removed, so pkgbuild may still store a few ._ entries
# carrying only that attribute. They are harmless and do not affect the code signature.
xattr -cr "$WORK/root" 2>/dev/null || true

# Give the installed app to the person who installed it, like a drag and drop install from the
# disk image. The installer writes files as root, and a root owned app could not be replaced by
# the in app updater without an admin password.
mkdir -p "$WORK/scripts"
cat > "$WORK/scripts/postinstall" <<'POSTINSTALL'
#!/bin/sh
APP="$2/Container Deck.app"
OWNER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)"
case "$OWNER" in ""|root|loginwindow|_mbsetupuser) OWNER="${SUDO_USER:-}" ;; esac
if [ -n "$OWNER" ] && [ "$OWNER" != "root" ] && [ -d "$APP" ]; then
  /usr/sbin/chown -R "$OWNER":staff "$APP"
fi
exit 0
POSTINSTALL
sed -i '' "s|Container Deck.app|$APP_NAME.app|" "$WORK/scripts/postinstall"
chmod 755 "$WORK/scripts/postinstall"

echo "==> Building $PKG"
rm -f "$PKG"
COPYFILE_DISABLE=1 pkgbuild \
  --root "$WORK/root" \
  --scripts "$WORK/scripts" \
  --component-plist "$WORK/component.plist" \
  --identifier "$BUNDLE_ID.pkg" \
  --version "$VERSION" \
  --install-location /Applications \
  "$PKG" >/dev/null

(cd build && shasum -a 256 "$(basename "$PKG")" > "$(basename "$PKG").sha256")
echo "Done: $PKG"
cat "$PKG.sha256"
