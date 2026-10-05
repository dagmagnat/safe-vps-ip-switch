#!/usr/bin/env bash
set -Eeuo pipefail

APP="safe-vps-ip-switch"
REPO="dagmagnat/safe-vps-ip-switch"
BRANCH="${ZAMENAIP_UPDATE_BRANCH:-main}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
SCRIPT="${ROOT}/${APP}.sh"

usage() {
  cat <<USAGE
ZAMENAIP installer

Local install:
  sudo ./install.sh

Emergency/remote install (does not depend on install.sh already being installed):
  curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/${APP}.sh -o /tmp/zamenaip-latest.sh
  sudo bash /tmp/zamenaip-latest.sh install

After installation:
  sudo zamenaip
  sudo zamenaip update
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root / Запустите от root: sudo ./install.sh" >&2
  exit 1
fi

# Install basic dependencies on Ubuntu/Debian when missing.
missing=()
command -v ip >/dev/null 2>&1 || missing+=(iproute2)
command -v curl >/dev/null 2>&1 || missing+=(curl)
command -v python3 >/dev/null 2>&1 || missing+=(python3)
command -v netplan >/dev/null 2>&1 || missing+=(netplan.io)
command -v tar >/dev/null 2>&1 || missing+=(tar)
if (( ${#missing[@]} > 0 )); then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    echo "Missing dependencies / Не хватает зависимостей: ${missing[*]}" >&2
    exit 1
  fi
fi

# If install.sh was downloaded alone, fetch only the main script. This avoids
# depending on a full git clone or repository layout.
if [[ ! -f "$SCRIPT" ]]; then
  tmp="$(mktemp /tmp/zamenaip-install.XXXXXX.sh)"
  trap 'rm -f "${tmp:-}"' EXIT
  url="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${APP}.sh"
  echo "Downloading / Скачиваем: $url"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$tmp"
  SCRIPT="$tmp"
fi

bash -n "$SCRIPT"
bash "$SCRIPT" install

echo
printf 'Start / Запуск: sudo zamenaip\n'
printf 'Update / Обновление: sudo zamenaip update\n'
