#!/usr/bin/env bash
# Makes the Ed25519 key pair that signs release disk images for the in app updater.
#
# Usage: scripts/make_update_keys.sh [OUT_DIR] [--set-config]
#   OUT_DIR       Where the keys go. Default: ~/.<asset stem>-release-keys. Never inside this repo.
#   --set-config  Also write the public key into AppConfig.updatePublicKey.
#
# Writes OUT_DIR/update_private_key.txt (secret, mode 600) and OUT_DIR/update_public_key.txt.
# The private key goes into the UPDATE_SIGNING_KEY GitHub secret, then keep it offline.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

OUT_DIR=""
SET_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --set-config) SET_CONFIG=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) OUT_DIR="$arg" ;;
  esac
done
STEM_LOWER="$(echo "$ASSET_STEM" | tr '[:upper:]' '[:lower:]')"
OUT_DIR="${OUT_DIR:-$HOME/.$STEM_LOWER-release-keys}"

REPO_ROOT="$(pwd -P)"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
OUT_REAL="$(cd "$OUT_DIR" && pwd -P)"
if [[ "$OUT_REAL" == "$REPO_ROOT" || "$OUT_REAL" == "$REPO_ROOT"/* ]]; then
  echo "error: $OUT_DIR is inside the repository. Keep private keys out of git." >&2
  exit 1
fi

PUBLIC_KEY="$(swift scripts/update_signer.swift keygen "$OUT_REAL")"

if [[ "$SET_CONFIG" == "1" ]]; then
  sed -i '' "s#static let updatePublicKey = \"[^\"]*\"#static let updatePublicKey = \"$PUBLIC_KEY\"#" "$APP_CONFIG"
  echo "==> Wrote the public key into $APP_CONFIG"
fi

cat <<INFO

Update signing keys for $APP_NAME
  Private key: $OUT_REAL/update_private_key.txt   (secret, never commit it)
  Public key:  $PUBLIC_KEY

Next steps
  1. Put the public key in $APP_CONFIG:
       public static let updatePublicKey = "$PUBLIC_KEY"
     (the --set-config option writes it for you)
  2. Add this GitHub secret (Settings, Secrets and variables, Actions) to $REPOSITORY:
       UPDATE_SIGNING_KEY = the contents of update_private_key.txt
     For example: gh secret set UPDATE_SIGNING_KEY --repo $REPOSITORY < "$OUT_REAL/update_private_key.txt"
  3. Store update_private_key.txt in a password manager, then delete the file.

INFO
