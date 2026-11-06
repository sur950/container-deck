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

CMD="curl -fsSL https://github.com/$REPOSITORY/releases/latest/download/ContainerDeck.dmg -o /tmp/ContainerDeck.dmg && hdiutil attach -nobrowse -mountpoint /tmp/ContainerDeck /tmp/ContainerDeck.dmg >/dev/null && D=/Applications && { [ -w \"\$D\" ] || { D=\"\$HOME/Applications\"; mkdir -p \"\$D\"; }; } && rm -rf \"\$D/Container Deck.app\" && ditto \"/tmp/ContainerDeck/Container Deck.app\" \"\$D/Container Deck.app\" && hdiutil detach /tmp/ContainerDeck >/dev/null && rm -f /tmp/ContainerDeck.dmg && open \"\$D/Container Deck.app\""
printf '%s\n\n## Install\n\n**Terminal**, any account, no admin password and no security prompt:\n\n```bash\n%s\n```\n\n**Personal Macs:** download `ContainerDeck.dmg` or `ContainerDeck.pkg` below. Releases are not notarized by Apple, so the first time you open the app, use **Open Anyway** in System Settings, Privacy & Security. On Macs managed by a company or school, use the Terminal command. See the [README](https://github.com/%s#install). Checksums are in `SHA256SUMS.txt`.\n' "$NOTES" "$CMD" "$REPOSITORY"
