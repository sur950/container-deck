#!/usr/bin/env bash
# Runs what GitHub runs (ci.yml, release.yml without publishing, pages.yml) on a clean copy
# of the repo, before you push or tag. The copy has only the files git would push (tracked,
# plus untracked files that are not ignored), and starts from an empty build folder, so a
# missing or ignored file fails here instead of on GitHub.
#
# Usage: scripts/ci_local.sh [VERSION]     (VERSION defaults to the one in scripts/Info.plist)
#
# Differences from GitHub, on purpose:
#   - The app is signed ad hoc. GitHub signs with the release certificate from its secrets.
#   - No Ed25519 update signature (.sig). GitHub makes it with the UPDATE_SIGNING_KEY secret.
#   - Nothing is uploaded or deployed. The website is only built.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${CI_LOCAL_DIR:-${TMPDIR:-/tmp}/container-deck-ci}"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO/scripts/Info.plist")}"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

step "Clean copy of what git would push ($WORK)"
rm -rf "$WORK"
mkdir -p "$WORK"
# Files deleted in the working tree are still in the index until the commit, so skip those.
(cd "$REPO" && git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
  [[ -e "$f" ]] && printf '%s\0' "$f"
done) | (cd "$REPO" && rsync -a --from0 --files-from=- ./ "$WORK/")
cd "$WORK"
echo "$(git -C "$REPO" ls-files --cached --others --exclude-standard | wc -l | tr -d ' ') files, version $VERSION"

# ---------------------------------------------------------------- ci.yml
step "CI: build"
swift build --arch arm64

step "CI: test"
swift test --parallel

step "CI: check scripts and Info.plist"
for f in scripts/*.sh; do bash -n "$f"; done
for f in contrib/docker/docker; do /bin/bash -n "$f"; done
plutil -lint scripts/Info.plist packaging/ContainerDeck.entitlements

# ---------------------------------------------------------------- release.yml
step "Release: tag v$VERSION is a version"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || fail "$VERSION is not a version like 1.2.3"

step "Release: notes from CHANGELOG.md"
scripts/release_notes.sh "$VERSION" > "$WORK/release-notes.md"
cat "$WORK/release-notes.md"

step "Release: product names"
source scripts/config.sh
DMG="$(dmg_name "$VERSION")"
PKG="$(pkg_name "$VERSION")"
echo "app $APP, id $BUNDLE_ID, dmg $DMG, pkg $PKG"

step "Release: build the app"
scripts/bundle.sh "$VERSION" 0

step "Release: app version, bundle id and signature"
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$BUILT" == "$VERSION" ]] || fail "app version $BUILT does not match $VERSION"
[[ "$ID" == "$BUNDLE_ID" ]] || fail "bundle id $ID is not $BUNDLE_ID"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $ID $BUILT"

step "Release: disk image (must be APFS)"
scripts/make_dmg.sh "$VERSION"
MOUNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "build/$DMG" >/dev/null
trap 'hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict --verbose=2 "$MOUNT/$APP_NAME.app"
FS="$(diskutil info "$MOUNT" | awk -F: '/File System Personality/ {gsub(/^ +/, "", $2); print $2}')"
echo "Disk image file system: $FS"
[[ "$FS" == *APFS* ]] || fail "the disk image is $FS, not APFS"
hdiutil detach "$MOUNT" -force >/dev/null
trap - EXIT

step "Release: installer package"
scripts/make_pkg.sh "$VERSION"
pkgutil --payload-files "build/$PKG" | grep -q "$APP_NAME.app/Contents/MacOS/" || fail "the package does not contain the app"

step "Release: checksums (GitHub also signs the disk image with the update key)"
(cd build && shasum -a 256 "$DMG" > "$DMG.sha256" && shasum -a 256 "$PKG" > "$PKG.sha256")
cat "build/$DMG.sha256" "build/$PKG.sha256" > build/SHA256SUMS.txt
cat build/SHA256SUMS.txt

# ---------------------------------------------------------------- pages.yml
step "Website: guide pages and the downloads badge"
python3 -m venv "$WORK/.docs-venv"
"$WORK/.docs-venv/bin/pip" install --quiet "markdown==3.11.3" "pygments==2.21.0"
"$WORK/.docs-venv/bin/python" scripts/build_docs.py
python3 scripts/badge_stats.py
[[ -f website/index.html && -f website/badges/downloads.json ]] || fail "the website is incomplete"

step "All steps passed for $VERSION"
echo "Artifacts: $WORK/build ($DMG, $PKG, checksums)"
