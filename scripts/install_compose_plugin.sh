#!/usr/bin/env bash
# Installs the `container compose` plugin for Apple's container CLI.
#
#   <prefix>/libexec/container-plugins/compose/bin/compose
#   <prefix>/libexec/container-plugins/compose/config.toml
#
# Usage:
#   scripts/install_compose_plugin.sh              build (release) and install
#   scripts/install_compose_plugin.sh --uninstall  remove it
#
# Environment:
#   PREFIX   Install root of the container CLI (default /usr/local).
#   BIN      Use this plugin binary instead of building one.
#
# The folder is owned by root, so the copy step asks for your password (sudo).
# The build runs as you, never as root. Apple's container installer wipes this
# folder on every upgrade, so run this again after updating container.
set -euo pipefail

cd "$(dirname "$0")/.."

PREFIX="${PREFIX:-/usr/local}"
PLUGIN_DIR="$PREFIX/libexec/container-plugins/compose"
APP_CONFIG="Sources/DeckCore/Config/AppConfig.swift"
cfg() { sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" "$APP_CONFIG" | head -n 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "==> Removing $PLUGIN_DIR"
  sudo rm -rf "$PLUGIN_DIR"
  echo "Done."
  exit 0
fi

if [[ -z "${BIN:-}" ]]; then
  echo "==> Building container-compose (release)"
  swift build -c release --product container-compose
  BIN="$(swift build -c release --show-bin-path)/container-compose"
fi

[[ -x "$BIN" ]] || { echo "error: no plugin binary at $BIN" >&2; exit 1; }
VERSION_LINE="$("$BIN" version)" || { echo "error: $BIN does not run" >&2; exit 1; }
VERSION="$(sed -n 's/^container compose version \([^ ]*\).*/\1/p' <<<"$VERSION_LINE")"
[[ -n "$VERSION" ]] || { echo "error: unexpected version output: $VERSION_LINE" >&2; exit 1; }
echo "==> $VERSION_LINE"

CONFIG_FILE="$(mktemp -t deck-compose-config)"
trap 'rm -f "$CONFIG_FILE"' EXIT
cat > "$CONFIG_FILE" <<EOF
abstract = "Run compose files with Apple's container tool ($(cfg appName))"
author = "$(cfg author)"
version = "$VERSION"
EOF

echo "==> Installing into $PLUGIN_DIR (needs admin)"
sudo install -d "$PLUGIN_DIR/bin"
sudo install -m 0755 "$BIN" "$PLUGIN_DIR/bin/compose"
sudo install -m 0644 "$CONFIG_FILE" "$PLUGIN_DIR/config.toml"

echo "==> Checking with the container CLI"
if ! command -v container >/dev/null 2>&1; then
  echo "warning: the container CLI is not on PATH. Installed, but not checked." >&2
  exit 0
fi
if container compose --help >/dev/null 2>&1; then
  echo "Done. Try: container compose up -d"
else
  echo "warning: container compose did not answer. Start the services with 'container system start'," >&2
  echo "         and check that PREFIX ($PREFIX) is where the container CLI is installed." >&2
  exit 1
fi
