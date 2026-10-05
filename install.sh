#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="safe-vps-ip-switch"
QUICK_COMMAND="zamenaip"
INSTALL_DIR="/usr/local/lib/${APP_NAME}"
INSTALL_TARGET="${INSTALL_DIR}/safe-vps-ip-switch.sh"
BIN_LINK="/usr/local/bin/${QUICK_COMMAND}"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="${SOURCE_DIR}/safe-vps-ip-switch.sh"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./install.sh" >&2
  exit 1
fi

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  echo "Cannot find $SOURCE_SCRIPT" >&2
  exit 1
fi

install -d -m 755 "$INSTALL_DIR"

# Copy through a temporary file so an update never leaves a partial executable.
tmp="$(mktemp "${INSTALL_DIR}/.safe-vps-ip-switch.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
install -m 755 "$SOURCE_SCRIPT" "$tmp"
mv -f "$tmp" "$INSTALL_TARGET"
trap - EXIT

ln -sfn "$INSTALL_TARGET" "$BIN_LINK"

printf 'Installed: %s\n' "$INSTALL_TARGET"
printf 'Command:   %s\n\n' "$BIN_LINK"
printf 'Start IP switch with:\n  sudo %s\n\n' "$QUICK_COMMAND"
printf 'Other commands:\n'
printf '  %s status\n' "$QUICK_COMMAND"
printf '  sudo %s verify\n' "$QUICK_COMMAND"
printf '  sudo %s rollback\n' "$QUICK_COMMAND"
printf '  %s --help\n' "$QUICK_COMMAND"
