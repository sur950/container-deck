#!/usr/bin/env bash
# Makes the free self signed code signing certificate used for every release.
# No Apple Developer Program needed. The name comes from AppConfig
# ("<appName> Code Signing", that is "Container Deck Code Signing").
#
# Usage: scripts/make_signing_cert.sh [OUT_DIR]
#   OUT_DIR  Where the files go. Default: ~/.<asset stem>-signing. Never inside this repo.
#
# Environment:
#   IMPORT_KEYCHAIN     Also import the identity into this keychain (for local signing).
#                       "login" means your login keychain.
#   KEYCHAIN_PASSWORD   Password of IMPORT_KEYCHAIN, to allow codesign without prompts.
#   CERT_DAYS           Validity in days. Default 7300 (20 years). Keep it long: a new
#                       certificate means installed copies stop updating themselves.
#
# Writes OUT_DIR/signing.p12, signing.p12.base64, signing.p12.password, cert.pem.
# The private key only lives inside the password protected .p12.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

OPENSSL=/usr/bin/openssl   # LibreSSL on macOS. Its .p12 files import cleanly with `security`.
IDENTITY="$CODE_SIGNING_IDENTITY"
STEM_LOWER="$(echo "$ASSET_STEM" | tr '[:upper:]' '[:lower:]')"
OUT_DIR="${1:-$HOME/.$STEM_LOWER-signing}"
DAYS="${CERT_DAYS:-7300}"

REPO_ROOT="$(pwd -P)"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
OUT="$(cd "$OUT_DIR" && pwd -P)"
if [[ "$OUT" == "$REPO_ROOT" || "$OUT" == "$REPO_ROOT"/* ]]; then
  echo "error: $OUT_DIR is inside the repository. Keep signing keys out of git." >&2
  exit 1
fi
if [[ -e "$OUT/signing.p12" ]]; then
  echo "error: $OUT/signing.p12 exists. A new certificate breaks updates for installed copies." >&2
  echo "       Move the old files away first if you really want a new one." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077

cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $IDENTITY
O = $COMPANY_SHORT
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

echo "==> Creating \"$IDENTITY\" (RSA 3072, $DAYS days)"
"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -sha256 -days "$DAYS" \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$OUT/cert.pem" 2>/dev/null

PASSWORD="$("$OPENSSL" rand -base64 24)"
"$OPENSSL" pkcs12 -export -name "$IDENTITY" -inkey "$WORK/key.pem" -in "$OUT/cert.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out "$OUT/signing.p12" -passout "pass:$PASSWORD"
printf '%s\n' "$PASSWORD" > "$OUT/signing.p12.password"
base64 -i "$OUT/signing.p12" > "$OUT/signing.p12.base64"
rm -f "$WORK/key.pem"

LEAF_SHA256="$("$OPENSSL" x509 -in "$OUT/cert.pem" -outform der | shasum -a 256 | cut -d ' ' -f 1)"
LEAF_SHA1="$("$OPENSSL" x509 -in "$OUT/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
printf '%s\n' "$LEAF_SHA256" > "$OUT/cert.sha256"

if [[ -n "${IMPORT_KEYCHAIN:-}" ]]; then
  KEYCHAIN="$IMPORT_KEYCHAIN"
  if [[ "$KEYCHAIN" == "login" ]]; then KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"; fi
  echo "==> Importing into $KEYCHAIN"
  security import "$OUT/signing.p12" -k "$KEYCHAIN" -P "$PASSWORD" -f pkcs12 -T /usr/bin/codesign
  if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  fi
fi

cat <<INFO

Code signing certificate for $APP_NAME
  Name:         $IDENTITY
  SHA-1:        $LEAF_SHA1   (the app's designated requirement pins this)
  SHA-256:      $LEAF_SHA256   (the updater compares this)
  Files:        $OUT
                signing.p12, signing.p12.base64, signing.p12.password, cert.pem

GitHub secrets for $REPOSITORY (Settings, Secrets and variables, Actions):
  MACOS_CERTIFICATE_P12       contents of signing.p12.base64
  MACOS_CERTIFICATE_PASSWORD  contents of signing.p12.password
  MACOS_SIGN_IDENTITY         optional, defaults to "$IDENTITY"

With gh:
  gh secret set MACOS_CERTIFICATE_P12 --repo $REPOSITORY < "$OUT/signing.p12.base64"
  gh secret set MACOS_CERTIFICATE_PASSWORD --repo $REPOSITORY < "$OUT/signing.p12.password"

Keep signing.p12 and its password in a password manager. Use the same certificate for every
release, or installed copies stop updating themselves and macOS asks for permissions again.
"security find-identity" lists it as CSSMERR_TP_NOT_TRUSTED. That is expected and codesign still works.
INFO
