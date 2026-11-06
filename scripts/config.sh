#!/usr/bin/env bash
# Shared product values for the release scripts. Source it from the repo root:
#   source scripts/config.sh
# Values come from the one config file, Sources/DeckCore/Config/AppConfig.swift,
# with the same cfg() helper scripts/bundle.sh uses.

APP_CONFIG="Sources/DeckCore/Config/AppConfig.swift"
cfg() { sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" "$APP_CONFIG" | head -n 1; }

APP_NAME="$(cfg appName)"
BUNDLE_ID="$(cfg bundleID)"
REPOSITORY="$(cfg repository)"
UPDATE_ASSET_SUFFIX="$(cfg updateAssetSuffix)"
for v in APP_NAME BUNDLE_ID REPOSITORY UPDATE_ASSET_SUFFIX; do
  [[ -n "${!v}" ]] || { echo "error: $v missing in $APP_CONFIG" >&2; exit 1; }
done

AUTHOR="$(cfg author)"
# Organization field of the signing certificate.
COMPANY_SHORT="$AUTHOR"
# May be empty: then installed apps never update themselves (they open the download page).
UPDATE_PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-$(cfg updatePublicKey)}"
[[ -n "$AUTHOR" ]] || { echo "error: author missing in $APP_CONFIG" >&2; exit 1; }
# Name of the free self signed code signing certificate. Same rule as AppConfig.codeSigningIdentity (appName + " Code Signing").
CODE_SIGNING_IDENTITY="$APP_NAME Code Signing"

APP="build/$APP_NAME.app"
# File name stem for release assets: the app name without spaces ("Container Deck" -> "ContainerDeck").
ASSET_STEM="${APP_NAME// /}"

# Release assets use fixed names, so https://github.com/<repo>/releases/latest/download/ContainerDeck.pkg
# always points at the newest version. The version lives in the release tag and in the app itself.
# dmg_name [VERSION] -> ContainerDeck.dmg (the suffix comes from AppConfig.updateAssetSuffix)
dmg_name() { echo "$ASSET_STEM$UPDATE_ASSET_SUFFIX"; }
# pkg_name [VERSION] -> ContainerDeck.pkg
pkg_name() { echo "$ASSET_STEM.pkg"; }
