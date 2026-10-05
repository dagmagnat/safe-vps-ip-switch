#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="safe-vps-ip-switch"
QUICK_COMMAND="zamenaip"
INSTALL_DIR="/usr/local/lib/${APP_NAME}"
BIN_LINK="/usr/local/bin/${QUICK_COMMAND}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./uninstall.sh" >&2
  exit 1
fi

rm -f "$BIN_LINK"
rm -rf "$INSTALL_DIR"

cat <<'MSG'
Removed the installed program and the `zamenaip` command.

Safety data was intentionally kept:
  /root/safe-vps-ip-switch-backups/
  /var/lib/safe-vps-ip-switch/
  /var/log/safe-vps-ip-switch.log
  /etc/netplan/99-safe-vps-ip-switch.yaml

Remove those manually only if you are sure they are no longer needed.
MSG
