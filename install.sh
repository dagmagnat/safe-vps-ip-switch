#!/usr/bin/env bash
set -Eeuo pipefail

APP="safe-vps-ip-switch"
QUICK_COMMAND="zamenaip"
INSTALL_DIR="/usr/local/lib/${APP}"
INSTALL_TARGET="${INSTALL_DIR}/${APP}.sh"
BIN_LINK="/usr/local/bin/${QUICK_COMMAND}"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="${SOURCE_DIR}/${APP}.sh"
NO_START=0

for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=1 ;;
    -h|--help)
      cat <<HELP
Install ZAMENAIP / ${APP}

Usage:
  sudo ./install.sh
  sudo ./install.sh --no-start
HELP
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root / Запустите от root: sudo ./install.sh" >&2
  exit 1
fi

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  echo "Cannot find / Не найден: $SOURCE_SCRIPT" >&2
  exit 1
fi

printf '\n============================================================\n'
printf ' ZAMENAIP - Safe VPS IPv4 Switch\n'
printf ' Безопасная смена основного IPv4 для Ubuntu/Netplan\n'
printf '============================================================\n\n'

missing_packages=()
command -v ip >/dev/null 2>&1 || missing_packages+=(iproute2)
command -v curl >/dev/null 2>&1 || missing_packages+=(curl)
command -v python3 >/dev/null 2>&1 || missing_packages+=(python3)
command -v netplan >/dev/null 2>&1 || missing_packages+=(netplan.io)
command -v getent >/dev/null 2>&1 || missing_packages+=(libc-bin)
command -v tar >/dev/null 2>&1 || missing_packages+=(tar)

if (( ${#missing_packages[@]} > 0 )); then
  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing dependencies / Устанавливаем зависимости: ${missing_packages[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
  else
    echo "Missing dependencies / Не хватает зависимостей: ${missing_packages[*]}" >&2
    echo "Install them manually and run install.sh again." >&2
    exit 1
  fi
fi

install -d -m 755 "$INSTALL_DIR"
tmp="$(mktemp "${INSTALL_DIR}/.zamenaip.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
install -m 755 "$SOURCE_SCRIPT" "$tmp"
mv -f "$tmp" "$INSTALL_TARGET"
trap - EXIT

# Replace an old regular wrapper or symlink with a direct symlink.
rm -f "$BIN_LINK"
ln -s "$INSTALL_TARGET" "$BIN_LINK"

printf '\nInstalled / Установлено:\n'
printf '  %s\n' "$INSTALL_TARGET"
printf 'Quick command / Быстрая команда:\n'
printf '  %s\n\n' "$QUICK_COMMAND"
printf 'Run anytime / Запуск в любое время:\n'
printf '  sudo %s\n\n' "$QUICK_COMMAND"
printf 'On first launch choose Russian or English.\n'
printf 'При первом запуске выберите Русский или English.\n\n'

if (( NO_START == 0 )) && [[ -t 0 && -t 1 ]]; then
  printf 'Start now? / Запустить сейчас?\n'
  printf '  1) Yes / Да\n'
  printf '  2) No / Нет\n'
  read -r -p '> ' answer || answer=2
  if [[ "$answer" == "1" ]]; then
    exec "$BIN_LINK"
  fi
fi

printf 'Done / Готово. Start with: sudo %s\n' "$QUICK_COMMAND"
