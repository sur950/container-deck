#!/usr/bin/env bash
# Builds a full release into ./build:
#   <appName>.app, <AssetStem>.pkg, <AssetStem>.dmg, their .sha256 files and <dmg>.sig (read by the in app
#   updater) and SHA256SUMS.txt.
#   Names come from Sources/DeckCore/Config/AppConfig.swift (scripts/config.sh).
#
# Usage: scripts/release.sh VERSION [BUILD_NUMBER]
#
# Environment:
#   SIGN_IDENTITY   Code signing identity, normally the self signed "<appName> Code Signing"
#                   (scripts/make_signing_cert.sh). Not set means ad hoc (local test only).
#   SIGN_KEYCHAIN   Optional keychain for the identity.
#   UPDATE_SIGNING_KEY or UPDATE_SIGNING_KEY_FILE   Ed25519 key for <dmg>.sig. See scripts/sign_update.sh.
#   SKIP_TESTS=1    Skip swift test.
#   PUBLISH=1       Create a draft GitHub release with gh and upload the files.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

VERSION="${1:-}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${2:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh VERSION [BUILD_NUMBER]" >&2
  exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: version must look like 1.2.3 or 1.2.3-beta.1 (got '$VERSION')" >&2
  exit 1
fi

DMG="build/$(dmg_name "$VERSION")"
PKG="build/$(pkg_name "$VERSION")"

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  echo "==> Running tests"
  swift test
fi

if [[ -n "$BUILD_NUMBER" ]]; then
  scripts/bundle.sh "$VERSION" "$BUILD_NUMBER"
else
  scripts/bundle.sh "$VERSION"
fi
scripts/make_dmg.sh "$VERSION"
scripts/make_pkg.sh "$VERSION"

echo "==> Checksum and update signature"
scripts/sign_update.sh "$DMG"
cat "$DMG.sha256" "$PKG.sha256" > build/SHA256SUMS.txt

if [[ "${PUBLISH:-0}" == "1" ]]; then
  echo "==> Creating draft GitHub release v$VERSION"
  scripts/release_notes.sh "$VERSION" > build/release-notes.md
  PRERELEASE=()
  if [[ "$VERSION" == *-* ]]; then
    PRERELEASE=(--prerelease)
  fi
  SIG=()
  if [[ -f "$DMG.sig" ]]; then SIG=("$DMG.sig"); fi
  gh release create "v$VERSION" "$PKG" "$PKG.sha256" "$DMG" "$DMG.sha256" ${SIG[@]+"${SIG[@]}"} build/SHA256SUMS.txt \
    --draft --notes-file build/release-notes.md --title "$APP_NAME $VERSION" ${PRERELEASE[@]+"${PRERELEASE[@]}"}
fi

echo
echo "Release files:"
ls -lh "$PKG" "$PKG".sha256 "$DMG" "$DMG".sha256 "$DMG".sig build/SHA256SUMS.txt 2>/dev/null || true
