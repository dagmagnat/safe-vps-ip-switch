#!/usr/bin/env bash
set -Eeuo pipefail

APP="safe-vps-ip-switch"
QUICK_COMMAND="zamenaip"
GITHUB_REPO="dagmagnat/safe-vps-ip-switch"
UPDATE_BRANCH="${ZAMENAIP_UPDATE_BRANCH:-main}"
INSTALL_DIR="/usr/local/lib/${APP}"
INSTALL_TARGET="${INSTALL_DIR}/${APP}.sh"
BIN_LINK="/usr/local/bin/${QUICK_COMMAND}"
NO_START=0
TEMP_ROOT=""

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
SOURCE_SCRIPT="${SOURCE_DIR}/${APP}.sh"

cleanup() {
  if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

usage() {
  cat <<HELP
Install ZAMENAIP / ${APP}

Usage:
  sudo ./install.sh
  sudo ./install.sh --no-start

Remote bootstrap:
  curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/${UPDATE_BRANCH}/install.sh | sudo bash

Environment:
  ZAMENAIP_UPDATE_BRANCH=main   Git branch used for bootstrap/update
HELP
}

for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root / Запустите от root: sudo ./install.sh" >&2
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

fetch_source_tree() {
  local branch="$UPDATE_BRANCH"
  local archive root
  TEMP_ROOT="$(mktemp -d /tmp/zamenaip-install.XXXXXX)"
  archive="${TEMP_ROOT}/repo.tar.gz"

  echo "Local project files were not found. / Локальные файлы проекта не найдены."
  echo "Downloading ${GITHUB_REPO}@${branch} ..."

  if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
      "https://github.com/${GITHUB_REPO}/archive/refs/heads/${branch}.tar.gz" \
      -o "$archive"; then
    if [[ "$branch" == "main" ]]; then
      branch="master"
      echo "main not available; trying master ..."
      curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
        "https://github.com/${GITHUB_REPO}/archive/refs/heads/${branch}.tar.gz" \
        -o "$archive"
    else
      return 1
    fi
  fi

  mkdir -p "${TEMP_ROOT}/src"
  tar -xzf "$archive" -C "${TEMP_ROOT}/src" --strip-components=1
  root="${TEMP_ROOT}/src"

  if [[ ! -f "${root}/${APP}.sh" ]]; then
    echo "Downloaded project does not contain ${APP}.sh" >&2
    return 1
  fi

  SOURCE_DIR="$root"
  SOURCE_SCRIPT="${root}/${APP}.sh"
}

# This makes the installer usable both from a cloned repository and directly
# via `curl .../install.sh | sudo bash`.
if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  fetch_source_tree
fi

if ! bash -n "$SOURCE_SCRIPT"; then
  echo "Syntax check failed / Ошибка синтаксиса: $SOURCE_SCRIPT" >&2
  exit 1
fi

install -d -m 755 "$INSTALL_DIR"

# Keep one copy of the previously installed program before replacing it.
if [[ -f "$INSTALL_TARGET" ]]; then
  cp -a "$INSTALL_TARGET" "${INSTALL_TARGET}.previous" 2>/dev/null || true
fi

# Install atomically so an interrupted copy never leaves a partial executable.
tmp="$(mktemp "${INSTALL_DIR}/.zamenaip.XXXXXX")"
install -m 755 "$SOURCE_SCRIPT" "$tmp"
mv -f "$tmp" "$INSTALL_TARGET"

# Keep installer/uninstaller/docs next to the installed program when available.
for extra in install.sh uninstall.sh README.md README.ru.md CHANGELOG.md SECURITY.md; do
  if [[ -f "${SOURCE_DIR}/${extra}" ]]; then
    install -m 644 "${SOURCE_DIR}/${extra}" "${INSTALL_DIR}/${extra}" 2>/dev/null || true
  fi
done
if [[ -f "${SOURCE_DIR}/install.sh" ]]; then chmod 755 "${INSTALL_DIR}/install.sh"; fi
if [[ -f "${SOURCE_DIR}/uninstall.sh" ]]; then chmod 755 "${INSTALL_DIR}/uninstall.sh"; fi
if [[ -d "${SOURCE_DIR}/docs" ]]; then
  rm -rf "${INSTALL_DIR}/docs"
  cp -a "${SOURCE_DIR}/docs" "${INSTALL_DIR}/docs"
fi

# Self-heal any old hand-made wrapper or stale symlink.
old_kind="missing"
if [[ -L "$BIN_LINK" ]]; then
  old_kind="symlink"
elif [[ -e "$BIN_LINK" ]]; then
  old_kind="regular-file"
fi
rm -f "$BIN_LINK"
ln -s "$INSTALL_TARGET" "$BIN_LINK"

if [[ ! -L "$BIN_LINK" ]] || [[ "$(readlink -f "$BIN_LINK")" != "$INSTALL_TARGET" ]]; then
  echo "Failed to repair quick command / Не удалось исправить команду: $BIN_LINK" >&2
  exit 1
fi

installed_version="$($BIN_LINK --version 2>/dev/null || true)"

printf '\nInstalled / Установлено:\n'
printf '  %s\n' "$INSTALL_TARGET"
printf 'Quick command / Быстрая команда:\n'
printf '  %s\n' "$QUICK_COMMAND"
printf 'Launcher repair / Исправление команды: %s -> symlink\n' "$old_kind"
printf 'Version / Версия: %s\n\n' "${installed_version:-unknown}"
printf 'Run anytime / Запуск в любое время:\n'
printf '  sudo %s\n\n' "$QUICK_COMMAND"
printf 'Update later / Обновление в будущем:\n'
printf '  sudo %s update\n\n' "$QUICK_COMMAND"
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
