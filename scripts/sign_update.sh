#!/usr/bin/env bash
# Writes "<dmg>.sha256" and, with an update key, "<dmg>.sig" next to a release disk image.
# The in app updater needs both before it installs anything.
#
# Usage: scripts/sign_update.sh build/ContainerDeck.dmg
#
# Environment:
#   UPDATE_SIGNING_KEY       Ed25519 private key, base64 (from scripts/make_update_keys.sh).
#   UPDATE_SIGNING_KEY_FILE  Or a file with it.
#   UPDATE_PUBLIC_KEY        Public key to check against. Default: AppConfig.updatePublicKey.
#   REQUIRE_UPDATE_SIGNATURE 1 to fail when there is no private key.
#
# The signature covers the raw SHA-256 digest of the disk image. When AppConfig has a public
# key, the private key must match it, or installed copies would refuse the update.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

DMG="${1:?usage: scripts/sign_update.sh FILE.dmg}"
[[ -f "$DMG" ]] || { echo "error: $DMG not found" >&2; exit 1; }
DIR="$(dirname "$DMG")"
NAME="$(basename "$DMG")"
EXPECTED_KEY="${UPDATE_PUBLIC_KEY:-}"

# "hash  name", the format the updater and shasum -c read.
(cd "$DIR" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "==> $(cat "$DMG.sha256")"

if [[ -z "${UPDATE_SIGNING_KEY:-}" && -z "${UPDATE_SIGNING_KEY_FILE:-}" ]]; then
  if [[ "${REQUIRE_UPDATE_SIGNATURE:-0}" == "1" || -n "$EXPECTED_KEY" ]]; then
    echo "error: no UPDATE_SIGNING_KEY. Installed copies (AppConfig.updatePublicKey is set) would refuse this release." >&2
    exit 1
  fi
  echo "warning: no UPDATE_SIGNING_KEY, so no $NAME.sig. Installed copies will not update themselves." >&2
  exit 0
fi

KEY_PUBLIC="$(swift scripts/update_signer.swift public-key)"
if [[ -n "$EXPECTED_KEY" && "$KEY_PUBLIC" != "$EXPECTED_KEY" ]]; then
  echo "error: UPDATE_SIGNING_KEY does not match AppConfig.updatePublicKey." >&2
  echo "       key gives $KEY_PUBLIC, AppConfig has $EXPECTED_KEY" >&2
  exit 1
fi
if [[ -z "$EXPECTED_KEY" ]]; then
  echo "warning: AppConfig.updatePublicKey is empty. Builds from this source will not install updates by themselves." >&2
fi

swift scripts/update_signer.swift sign "$DMG" > "$DMG.sig"
swift scripts/update_signer.swift verify "$DMG" "$DMG.sig" "$KEY_PUBLIC" >/dev/null
echo "==> Signed: $DMG.sig (public key $KEY_PUBLIC)"
