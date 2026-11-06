#!/usr/bin/env bash
# Prints the CHANGELOG.md section for one version, for the GitHub release notes.
#
# Usage: scripts/release_notes.sh VERSION
# Exits 1 when CHANGELOG.md has no "## [VERSION]" section, so a release never ships without notes.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh
VERSION="${1:?usage: scripts/release_notes.sh VERSION}"
VERSION="${VERSION#v}"

NOTES="$(awk -v version="$VERSION" '
  $0 ~ "^## \\[" version "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found && /^\[[^]]+\]: / { next }
  found { print }
' CHANGELOG.md)"

# Trim blank lines at the start and the end.
NOTES="$(printf '%s\n' "$NOTES" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [[ -z "$NOTES" ]]; then
  echo "error: CHANGELOG.md has no section for $VERSION. Add \"## [$VERSION] - <date>\" first." >&2
  exit 1
fi

printf '%s\n\n## Install\n\n```bash\ncurl -fsSLO https://github.com/%s/releases/latest/download/ContainerDeck.pkg && sudo installer -pkg ContainerDeck.pkg -target /\n```\n\nOr download `ContainerDeck.dmg` below. Releases are not notarized by Apple, so a package or app downloaded in a browser needs **Open Anyway** in System Settings, Privacy & Security, once. See the [README](https://github.com/%s#install). Checksums are in `SHA256SUMS.txt`.\n' "$NOTES" "$REPOSITORY" "$REPOSITORY"
