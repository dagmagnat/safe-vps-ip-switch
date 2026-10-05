#!/usr/bin/env bash
set -Eeuo pipefail

APP="safe-vps-ip-switch"
INSTALL_DIR="/usr/local/lib/${APP}"
BIN_LINK="/usr/local/bin/zamenaip"
CONFIG_FILE="/etc/${APP}.conf"
STATE_DIR="/var/lib/${APP}"
BACKUP_ROOT="/var/backups/${APP}"
LOG_FILE="/var/log/${APP}.log"
MANAGED_NETPLAN="/etc/netplan/99-zamenaip.yaml"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root / Запустите от root: sudo ./uninstall.sh" >&2
  exit 1
fi

rm -f "$BIN_LINK"
rm -rf "$INSTALL_DIR"

cat <<MSG
ZAMENAIP executable removed / программа удалена.

For safety, the following were NOT removed / в целях безопасности НЕ удалены:
  config:   $CONFIG_FILE
  state:    $STATE_DIR
  backups:  $BACKUP_ROOT
  log:      $LOG_FILE
  netplan:  $MANAGED_NETPLAN

Review and remove them manually only if you no longer need them.
Удаляйте их вручную только если уверены, что они больше не нужны.
MSG
