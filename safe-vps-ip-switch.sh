#!/usr/bin/env bash
set -Eeuo pipefail

APP="safe-vps-ip-switch"
DISPLAY_NAME="ZAMENAIP"
VERSION="2.1.1"
CONFIG_FILE="/etc/${APP}.conf"
STATE_DIR="/var/lib/${APP}"
BACKUP_ROOT="/var/backups/${APP}"
LOG_FILE="/var/log/${APP}.log"
MANAGED_NETPLAN="/etc/netplan/99-zamenaip.yaml"
TRY_TIMEOUT=120
ROUTE_TABLE=51820
ROUTE_RULE_PRIORITY=10990
GITHUB_REPO="dagmagnat/safe-vps-ip-switch"
UPDATE_BRANCH="${ZAMENAIP_UPDATE_BRANCH:-main}"
INSTALL_DIR="/usr/local/lib/${APP}"
INSTALL_TARGET="${INSTALL_DIR}/${APP}.sh"
BIN_LINK="/usr/local/bin/zamenaip"

LANGUAGE=""
DEFAULT_DOMAIN=""
DNS1="1.1.1.1"
DNS2="1.0.0.1"

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_CYAN='\033[36m'

ORIGINAL_ARGS=("$@")
TEMP_ADDED_CIDR=""
TEMP_IFACE=""

# ---------- UI ----------

T() {
  if [[ "${LANGUAGE:-ru}" == "en" ]]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

clear_screen() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear || true
  fi
}

rule() {
  printf '%b%s%b\n' "$C_DIM" '------------------------------------------------------------------------' "$C_RESET"
}

logo() {
  printf '%b%b' "$C_CYAN" "$C_BOLD"
  cat <<'LOGO'
  ______  ___    __  ___ ______ _   __ ___     ______ ____
 /_  __/ /   |  /  |/  // ____// | / //   |   /  _/ // __ \
  / /   / /| | / /|_/ // __/  /  |/ // /| |   / // // /_/ /
 / /   / ___ |/ /  / // /___ / /|  // ___ | _/ // // ____/
/_/   /_/  |_/_/  /_//_____//_/ |_//_/  |_|/___/_//_/
LOGO
  printf '%b' "$C_RESET"
  printf '%b%s%b  v%s\n' "$C_BOLD" "Safe VPS IPv4 Switch" "$C_RESET" "$VERSION"
  printf '%s\n' "$(T 'Безопасная смена основного IPv4 для Ubuntu/Netplan' 'Safe primary IPv4 switching for Ubuntu/Netplan')"
  rule
}

header() {
  clear_screen
  logo
  printf '%b%s%b\n\n' "$C_BOLD" "$1" "$C_RESET"
}

info() { printf '%b[INFO]%b %s\n' "$C_CYAN" "$C_RESET" "$*"; log "INFO: $*"; }
ok()   { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; log "OK: $*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*"; log "WARN: $*"; }
err()  { printf '%b[ERR ]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; log "ERROR: $*"; }

log() {
  local msg="$*"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date -Is)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

pause_menu() {
  printf '\n'
  read -r -p "$(T 'Нажмите Enter, чтобы продолжить...' 'Press Enter to continue...')" _ || true
}

read_menu_choice() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt" value || return 1
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    printf '%b%s%b\n' "$C_YELLOW" "$(T 'Введите номер пункта.' 'Enter a menu number.')" "$C_RESET" >&2
  done
}

confirm_choice() {
  local question="$1" choice
  printf '\n%s\n' "$question"
  printf '  1) %s\n' "$(T 'Да, продолжить' 'Yes, continue')"
  printf '  2) %s\n' "$(T 'Нет' 'No')"
  printf '  0) %s\n' "$(T 'Назад' 'Back')"
  while true; do
    choice="$(read_menu_choice "> ")" || return 2
    case "$choice" in
      1) return 0 ;;
      2) return 1 ;;
      0) return 2 ;;
      *) warn "$(T 'Нет такого пункта.' 'No such menu item.')" ;;
    esac
  done
}

# ---------- Config / language ----------

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
  chmod 700 "$STATE_DIR" "$BACKUP_ROOT" 2>/dev/null || true
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  LANGUAGE="${LANGUAGE:-}"
  DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-}"
  DNS1="${DNS1:-1.1.1.1}"
  DNS2="${DNS2:-1.0.0.1}"
}

save_config() {
  ensure_dirs
  {
    printf 'LANGUAGE=%q\n' "$LANGUAGE"
    printf 'DEFAULT_DOMAIN=%q\n' "$DEFAULT_DOMAIN"
    printf 'DNS1=%q\n' "$DNS1"
    printf 'DNS2=%q\n' "$DNS2"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

choose_language() {
  local c
  clear_screen
  printf '%b%bZAMENAIP%b - Language / Язык\n' "$C_CYAN" "$C_BOLD" "$C_RESET"
  rule
  printf '  1) Русский\n'
  printf '  2) English\n'
  printf '\n'
  while true; do
    c="$(read_menu_choice "> ")" || exit 1
    case "$c" in
      1) LANGUAGE="ru"; break ;;
      2) LANGUAGE="en"; break ;;
      *) printf '%s\n' '1 / 2' ;;
    esac
  done
  save_config
}

ensure_language() {
  [[ "$LANGUAGE" == "ru" || "$LANGUAGE" == "en" ]] || choose_language
}

# ---------- Privileges / dependencies ----------

ensure_root_for_menu() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    printf '%s\n' 'ZAMENAIP needs administrator privileges / нужны права администратора.'
    exec sudo -E "$0" "${ORIGINAL_ARGS[@]}"
  fi
  printf '%s\n' 'Run as root / Запустите от root.' >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "$(T "Не найдена команда: $1" "Required command not found: $1")"
    return 1
  }
}

check_base_dependencies() {
  local c missing=()
  for c in ip curl awk sed grep tar python3 netplan; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    err "$(T 'Не хватает системных команд:' 'Missing system commands:') ${missing[*]}"
    printf '%s\n' "$(T 'Запустите установщик повторно или установите зависимости вручную.' 'Run the installer again or install the dependencies manually.')"
    return 1
  fi
}

# ---------- Network helpers ----------

is_ipv4() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

is_prefix() {
  [[ "$1" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]]
}

network_first_host() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import ipaddress, sys
ip = ipaddress.IPv4Address(sys.argv[1])
p = int(sys.argv[2])
net = ipaddress.IPv4Network(f"{ip}/{p}", strict=False)
if net.num_addresses < 4:
    raise SystemExit(1)
print(next(net.hosts()))
PY
}

current_iface() {
  ip -4 route show default 2>/dev/null | head -n1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

current_gateway() {
  ip -4 route show default 2>/dev/null | head -n1 | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}'
}

current_route_src() {
  local src
  src="$(ip -4 route show default 2>/dev/null | head -n1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  if [[ -z "$src" ]]; then
    src="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  fi
  printf '%s\n' "$src"
}

public_ipv4_once() {
  local bind_ip="${1:-}" url="${2:-https://api.ipify.org}" out
  local opts=(-4fsS --connect-timeout 4 --max-time 7)
  [[ -n "$bind_ip" ]] && opts+=(--interface "$bind_ip")
  out="$(curl "${opts[@]}" "$url" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$out" ]] && is_ipv4 "$out"; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

public_ipv4() {
  local bind_ip="${1:-}" out url
  for url in 'https://api.ipify.org' 'https://ifconfig.me/ip' 'https://icanhazip.com'; do
    out="$(public_ipv4_once "$bind_ip" "$url" || true)"
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}

local_ipv4_cidrs() {
  local iface="$1"
  ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}'
}

cidr_ip() { printf '%s\n' "${1%%/*}"; }
cidr_prefix() { printf '%s\n' "${1#*/}"; }

iface_has_ip() {
  local iface="$1" ipaddr="$2"
  ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$ipaddr"
}

cleanup_probe_route() {
  while ip -4 rule del priority "$ROUTE_RULE_PRIORITY" >/dev/null 2>&1; do :; done
  ip -4 route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  ip -4 route flush cache >/dev/null 2>&1 || true
}

cleanup_temp_ip() {
  cleanup_probe_route
  if [[ -n "$TEMP_ADDED_CIDR" && -n "$TEMP_IFACE" ]]; then
    ip addr del "$TEMP_ADDED_CIDR" dev "$TEMP_IFACE" >/dev/null 2>&1 || true
  fi
  TEMP_ADDED_CIDR=""
  TEMP_IFACE=""
}

trap cleanup_temp_ip EXIT

probe_ip_gateway() {
  local iface="$1" ipaddr="$2" gateway="$3" result
  cleanup_probe_route

  if ! ip -4 route add default via "$gateway" dev "$iface" src "$ipaddr" onlink table "$ROUTE_TABLE" >/dev/null 2>&1; then
    cleanup_probe_route
    return 1
  fi
  if ! ip -4 rule add priority "$ROUTE_RULE_PRIORITY" from "$ipaddr/32" lookup "$ROUTE_TABLE" >/dev/null 2>&1; then
    cleanup_probe_route
    return 1
  fi
  ip -4 route flush cache >/dev/null 2>&1 || true

  result="$(public_ipv4_once "$ipaddr" || true)"
  cleanup_probe_route
  [[ "$result" == "$ipaddr" ]]
}

resolve_ipv4s() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++'
}

http_code() {
  local url="$1" resolve_arg="${2:-}" code
  local args=(-kIsS --connect-timeout 5 --max-time 15)
  [[ -n "$resolve_arg" ]] && args+=(--resolve "$resolve_arg")
  code="$(curl "${args[@]}" "$url" 2>/dev/null | awk 'NR==1 {print $2}' || true)"
  printf '%s\n' "$code"
}

# ---------- Status / diagnostics ----------

print_network_summary() {
  local iface gw src pub
  iface="$(current_iface || true)"
  gw="$(current_gateway || true)"
  src="$(current_route_src || true)"
  pub="$(public_ipv4 || true)"

  printf '%-22s %s\n' "$(T 'Внешний IPv4:' 'Public IPv4:')" "${pub:-$(T 'не определён' 'unknown')}"
  printf '%-22s %s\n' "$(T 'Интерфейс:' 'Interface:')" "${iface:-$(T 'не определён' 'unknown')}"
  printf '%-22s %s\n' "$(T 'Исходный IPv4:' 'Route source:')" "${src:-$(T 'не определён' 'unknown')}"
  printf '%-22s %s\n' "$(T 'Шлюз:' 'Gateway:')" "${gw:-$(T 'не определён' 'unknown')}"
  printf '\n%s\n' "$(T 'IPv4 в Linux:' 'IPv4 addresses in Linux:')"
  if [[ -n "$iface" ]]; then
    ip -4 -br addr show dev "$iface" || true
  else
    ip -4 -br addr show || true
  fi
  printf '\n%s\n' "$(T 'Маршруты по умолчанию:' 'Default routes:')"
  ip -4 route show default || true
}

test_all_local_ips() {
  local iface cidr ipaddr result count=0
  iface="$(current_iface || true)"
  [[ -n "$iface" ]] || { err "$(T 'Не удалось определить сетевой интерфейс.' 'Could not detect network interface.')"; return 1; }

  printf '%s\n' "$(T 'Проверяем исходящий доступ каждого IPv4. Это может занять несколько секунд.' 'Testing outbound access for every IPv4. This can take a few seconds.')"
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] || continue
    count=$((count + 1))
    ipaddr="$(cidr_ip "$cidr")"
    printf '  %-18s ... ' "$cidr"
    result="$(public_ipv4_once "$ipaddr" || true)"
    if [[ "$result" == "$ipaddr" ]]; then
      printf '%bOK%b (%s)\n' "$C_GREEN" "$C_RESET" "$result"
    elif [[ -n "$result" ]]; then
      printf '%b%s%b -> %s\n' "$C_YELLOW" "$(T 'доступ есть, внешний IP другой' 'online, public IP differs')" "$C_RESET" "$result"
    else
      printf '%b%s%b\n' "$C_RED" "$(T 'нет ответа' 'no response')" "$C_RESET"
    fi
  done < <(local_ipv4_cidrs "$iface")
  (( count > 0 )) || warn "$(T 'Глобальные IPv4 не найдены.' 'No global IPv4 addresses found.')"
}

site_check_screen() {
  local domain="${1:-$DEFAULT_DOMAIN}" dns_ips current code_local code_public input
  header "$(T 'Проверка сайта и DNS' 'Website and DNS check')"

  if [[ -n "$domain" ]]; then
    read -r -p "$(T "Домен [$domain] (0 = назад): " "Domain [$domain] (0 = back): ")" input || return
    [[ "$input" == "0" ]] && return
    [[ -n "$input" ]] && domain="$input"
  else
    read -r -p "$(T 'Введите домен без https:// (0 = назад): ' 'Enter domain without https:// (0 = back): ')" domain || return
    [[ "$domain" == "0" ]] && return
  fi
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  [[ -n "$domain" ]] || { warn "$(T 'Домен не указан.' 'No domain entered.')"; pause_menu; return; }

  current="$(public_ipv4 || true)"
  dns_ips="$(resolve_ipv4s "$domain" || true)"
  printf '\n%-22s %s\n' "$(T 'Домен:' 'Domain:')" "$domain"
  printf '%-22s %s\n' "$(T 'DNS IPv4:' 'DNS IPv4:')" "${dns_ips//$'\n'/, }"
  printf '%-22s %s\n' "$(T 'IPv4 сервера:' 'Server public IPv4:')" "${current:-unknown}"

  if [[ -n "$current" ]] && grep -Fxq "$current" <<<"$dns_ips"; then
    ok "$(T 'DNS уже указывает на текущий IPv4 сервера.' 'DNS already points to the current server IPv4.')"
  else
    warn "$(T 'DNS не указывает на текущий IPv4. A-запись, возможно, нужно изменить у DNS-провайдера.' 'DNS does not point to the current IPv4. The A record may need updating at your DNS provider.')"
  fi

  code_local="$(http_code "https://${domain}/" "${domain}:443:127.0.0.1")"
  code_public="$(http_code "https://${domain}/")"
  printf '%-22s %s\n' "$(T 'Локально через nginx:' 'Local via web server:')" "${code_local:-$(T 'нет ответа' 'no response')}"
  printf '%-22s %s\n' "$(T 'Через публичный DNS:' 'Via public DNS:')" "${code_public:-$(T 'нет ответа' 'no response')}"

  if [[ "$code_local" =~ ^[123][0-9][0-9]$ ]]; then
    ok "$(T 'Локальная проверка сайта успешна.' 'Local website check passed.')"
  else
    warn "$(T 'Локальная HTTPS-проверка не получила успешный ответ.' 'Local HTTPS check did not return a successful response.')"
  fi
  if [[ "$code_public" =~ ^[123][0-9][0-9]$ ]]; then
    ok "$(T 'Публичная проверка сайта успешна.' 'Public website check passed.')"
  else
    warn "$(T 'Публичная проверка неуспешна. Проверьте DNS, firewall и web-сервер.' 'Public check failed. Check DNS, firewall, and the web server.')"
  fi
  pause_menu
}

diagnostics_menu() {
  local c
  while true; do
    header "$(T 'Состояние и диагностика' 'Status and diagnostics')"
    print_network_summary
    printf '\n'
    printf '  1) %s\n' "$(T 'Проверить интернет с каждого IPv4' 'Test Internet access from every IPv4')"
    printf '  2) %s\n' "$(T 'Проверить сайт и DNS' 'Check website and DNS')"
    printf '  3) %s\n' "$(T 'Показать полный ip addr / ip route' 'Show full ip addr / ip route')"
    printf '  0) %s\n' "$(T 'Назад' 'Back')"
    c="$(read_menu_choice "> ")" || return
    case "$c" in
      1) printf '\n'; test_all_local_ips; pause_menu ;;
      2) site_check_screen ;;
      3) header "$(T 'Полная сетевая информация' 'Full network information')"; ip addr; printf '\n'; ip route show table all; pause_menu ;;
      0) return ;;
      *) warn "$(T 'Нет такого пункта.' 'No such menu item.')"; sleep 1 ;;
    esac
  done
}

# ---------- Backup / restore ----------

create_backup() {
  local reason="${1:-manual}" stamp dir
  ensure_dirs
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="${BACKUP_ROOT}/${stamp}-${reason//[^A-Za-z0-9_.-]/_}"
  mkdir -p "$dir"
  chmod 700 "$dir"

  tar -C / -czf "$dir/netplan.tgz" etc/netplan
  [[ -d /etc/nginx ]] && tar -C / -czf "$dir/nginx.tgz" etc/nginx || true
  [[ -f "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "$dir/app.conf" || true
  ip addr show > "$dir/ip-addr.txt"
  ip route show table all > "$dir/ip-route.txt"
  netplan get > "$dir/netplan-get.txt" 2>&1 || true

  {
    printf 'CREATED_AT=%q\n' "$(date -Is)"
    printf 'REASON=%q\n' "$reason"
    printf 'PUBLIC_IP=%q\n' "$(public_ipv4 || true)"
    printf 'INTERFACE=%q\n' "$(current_iface || true)"
    printf 'GATEWAY=%q\n' "$(current_gateway || true)"
  } > "$dir/meta.env"
  chmod 600 "$dir/meta.env"
  printf '%s\n' "$dir" > "$STATE_DIR/latest-backup"
  printf '%s\n' "$dir"
}

list_backups() {
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

restore_backup_dir() {
  local dir="$1" safety
  [[ -d "$dir" && -f "$dir/netplan.tgz" ]] || { err "$(T 'Резервная копия повреждена или не найдена.' 'Backup is missing or incomplete.')"; return 1; }

  info "$(T 'Создаём страховочную копию текущего состояния перед восстановлением...' 'Creating a safety backup of the current state before restore...')"
  safety="$(create_backup pre-restore)"
  ok "$(T 'Страховочная копия:' 'Safety backup:') $safety"

  rm -f "$MANAGED_NETPLAN"
  tar -C / -xzf "$dir/netplan.tgz"
  if [[ -f "$dir/nginx.tgz" ]]; then
    tar -C / -xzf "$dir/nginx.tgz"
  fi

  if ! netplan generate; then
    err "$(T 'Восстановленный Netplan не прошёл проверку. Возвращаем страховочную копию.' 'Restored Netplan failed validation. Restoring the safety copy.')"
    rm -f "$MANAGED_NETPLAN"
    tar -C / -xzf "$safety/netplan.tgz"
    [[ -f "$safety/nginx.tgz" ]] && tar -C / -xzf "$safety/nginx.tgz" || true
    netplan generate || true
    return 1
  fi
  if command -v nginx >/dev/null 2>&1 && ! nginx -t; then
    err "$(T 'Восстановленный nginx не прошёл проверку. Возвращаем страховочную копию.' 'Restored nginx failed validation. Restoring the safety copy.')"
    rm -f "$MANAGED_NETPLAN"
    tar -C / -xzf "$safety/netplan.tgz"
    [[ -f "$safety/nginx.tgz" ]] && tar -C / -xzf "$safety/nginx.tgz" || true
    netplan generate || true
    return 1
  fi

  warn "$(T 'Сейчас Netplan применит восстановленную конфигурацию в безопасном режиме.' 'Netplan will now apply the restored configuration in safe mode.')"
  if ! netplan try --timeout "$TRY_TIMEOUT"; then
    warn "$(T 'Настройки не были подтверждены и Netplan вернул предыдущую конфигурацию.' 'Settings were not confirmed and Netplan reverted the previous configuration.')"
    return 1
  fi
  command -v nginx >/dev/null 2>&1 && { nginx -t && systemctl reload nginx; } || true
  ok "$(T 'Резервная копия восстановлена.' 'Backup restored.')"
  return 0
}

backup_menu() {
  local c selected idx name dir
  local backups=()
  while true; do
    header "$(T 'Резервные копии и восстановление' 'Backups and restore')"
    printf '  1) %s\n' "$(T 'Создать резервную копию сейчас' 'Create a backup now')"
    printf '  2) %s\n' "$(T 'Восстановить резервную копию' 'Restore a backup')"
    printf '  3) %s\n' "$(T 'Показать список копий' 'List backups')"
    printf '  0) %s\n' "$(T 'Назад' 'Back')"
    c="$(read_menu_choice "> ")" || return
    case "$c" in
      1)
        dir="$(create_backup manual)"
        ok "$(T 'Создана резервная копия:' 'Backup created:') $dir"
        pause_menu
        ;;
      2)
        mapfile -t backups < <(list_backups)
        if (( ${#backups[@]} == 0 )); then
          warn "$(T 'Резервных копий пока нет.' 'No backups found.')"
          pause_menu
          continue
        fi
        header "$(T 'Выберите резервную копию' 'Choose a backup')"
        idx=1
        for name in "${backups[@]}"; do
          printf '  %d) %s\n' "$idx" "$name"
          idx=$((idx + 1))
        done
        printf '  0) %s\n' "$(T 'Назад' 'Back')"
        selected="$(read_menu_choice "> ")" || continue
        [[ "$selected" == "0" ]] && continue
        if (( selected < 1 || selected > ${#backups[@]} )); then
          warn "$(T 'Нет такой резервной копии.' 'No such backup.')"
          pause_menu
          continue
        fi
        dir="${BACKUP_ROOT}/${backups[$((selected-1))]}"
        printf '\n%s: %s\n' "$(T 'Будет восстановлено' 'Will restore')" "$dir"
        warn "$(T 'Сетевое соединение может кратковременно прерваться.' 'The network connection may briefly pause.')"
        if confirm_choice "$(T 'Продолжить восстановление?' 'Continue with restore?')"; then
          if restore_backup_dir "$dir"; then
            if confirm_choice "$(T 'Перезагрузить сервер сейчас? Все активные SSH-сессии будут разорваны.' 'Reboot the server now? All active SSH sessions will disconnect.')"; then
              systemctl reboot
              exit 0
            fi
          fi
        fi
        pause_menu
        ;;
      3)
        header "$(T 'Список резервных копий' 'Backup list')"
        list_backups || true
        pause_menu
        ;;
      0) return ;;
      *) warn "$(T 'Нет такого пункта.' 'No such menu item.')"; sleep 1 ;;
    esac
  done
}

# ---------- Nginx helpers ----------

nginx_find_old_ip_refs() {
  local old_ip="$1"
  [[ -d /etc/nginx/sites-enabled ]] || return 0
  grep -RIl --include='*' -E "(^|[^0-9])${old_ip//./\\.}([^0-9]|$)" /etc/nginx/sites-enabled 2>/dev/null || true
}

nginx_update_network_binds() {
  local old_ip="$1" new_ip="$2" f real tmp changed=0
  command -v nginx >/dev/null 2>&1 || return 0
  [[ -d /etc/nginx/sites-enabled ]] || return 0

  local files=()
  mapfile -t files < <(nginx_find_old_ip_refs "$old_ip")
  (( ${#files[@]} > 0 )) || return 0

  info "$(T 'Найдены активные конфиги nginx со старым IP. Обновляем только proxy_bind и listen.' 'Active nginx configs reference the old IP. Updating only proxy_bind and listen directives.')"
  for f in "${files[@]}"; do
    real="$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")"
    [[ -f "$real" ]] || continue
    tmp="$(mktemp)"
    sed -E \
      -e "s#^([[:space:]]*proxy_bind[[:space:]]+)${old_ip//./\\.}([[:space:]]*;)#\\1${new_ip}\\2#" \
      -e "s#^([[:space:]]*listen[[:space:]]+)${old_ip//./\\.}:#\\1${new_ip}:#" \
      "$real" > "$tmp"
    if ! cmp -s "$real" "$tmp"; then
      cat "$tmp" > "$real"
      changed=1
      info "nginx: $real"
    fi
    rm -f "$tmp"
  done

  if (( changed == 1 )); then
    if ! nginx -t; then
      return 1
    fi
    systemctl reload nginx
    ok "$(T 'nginx проверен и перезагружен.' 'nginx validated and reloaded.')"
  fi
  return 0
}

# ---------- Switch wizard ----------

choose_target_ip() {
  local iface="$1" current_ip="$2" c idx cidr ipaddr input prefix
  local cidrs=()
  mapfile -t cidrs < <(local_ipv4_cidrs "$iface")

  while true; do
    header "$(T 'Замена основного IPv4 - выбор адреса' 'Change primary IPv4 - choose address')"
    printf '%s\n\n' "$(T 'Ниже показаны IPv4, которые Linux уже видит на этом сервере.' 'These are IPv4 addresses currently visible to Linux on this server.')"
    printf '%b%s%b\n' "$C_DIM" "$(T 'IP из панели провайдера, который ещё не добавлен в Linux, здесь не появится. Его можно ввести вручную.' 'An IP attached at the provider but not yet added to Linux will not appear here. You can enter it manually.')" "$C_RESET"
    printf '\n'

    idx=1
    for cidr in "${cidrs[@]}"; do
      ipaddr="$(cidr_ip "$cidr")"
      if [[ "$ipaddr" == "$current_ip" ]]; then
        printf '  %d) %-20s %b%s%b\n' "$idx" "$cidr" "$C_GREEN" "$(T '[текущий основной]' '[current primary]')" "$C_RESET"
      else
        printf '  %d) %s\n' "$idx" "$cidr"
      fi
      idx=$((idx + 1))
    done
    printf '  %d) %s\n' "$idx" "$(T 'Ввести новый IPv4 вручную' 'Enter a new IPv4 manually')"
    printf '  0) %s\n' "$(T 'Назад' 'Back')"

    c="$(read_menu_choice "> ")" || return 1
    [[ "$c" == "0" ]] && return 1
    if (( c >= 1 && c <= ${#cidrs[@]} )); then
      cidr="${cidrs[$((c-1))]}"
      ipaddr="$(cidr_ip "$cidr")"
      if [[ "$ipaddr" == "$current_ip" ]]; then
        warn "$(T 'Этот IPv4 уже является основным.' 'This IPv4 is already primary.')"
        pause_menu
        continue
      fi
      TARGET_IP="$ipaddr"
      TARGET_PREFIX="$(cidr_prefix "$cidr")"
      return 0
    fi
    if (( c == idx )); then
      while true; do
        read -r -p "$(T 'Новый IPv4 (0 = назад): ' 'New IPv4 (0 = back): ')" input || return 1
        [[ "$input" == "0" ]] && break
        if [[ "$input" == */* ]]; then
          ipaddr="${input%%/*}"
          prefix="${input#*/}"
        else
          ipaddr="$input"
          prefix="24"
        fi
        if is_ipv4 "$ipaddr" && is_prefix "$prefix"; then
          TARGET_IP="$ipaddr"
          TARGET_PREFIX="$prefix"
          return 0
        fi
        warn "$(T 'Некорректный IPv4/CIDR. Пример: 5.42.120.63 или 5.42.120.63/24' 'Invalid IPv4/CIDR. Example: 5.42.120.63 or 5.42.120.63/24')"
      done
      continue
    fi
    warn "$(T 'Нет такого пункта.' 'No such menu item.')"
    sleep 1
  done
}

prepare_target_ip_for_test() {
  local iface="$1" cidr="${TARGET_IP}/${TARGET_PREFIX}"
  if iface_has_ip "$iface" "$TARGET_IP"; then
    return 0
  fi
  info "$(T "Временно добавляем $cidr только для проверки..." "Temporarily adding $cidr for testing...")"
  if ! ip addr add "$cidr" dev "$iface"; then
    err "$(T 'Не удалось временно добавить адрес.' 'Could not temporarily add the address.')"
    return 1
  fi
  TEMP_ADDED_CIDR="$cidr"
  TEMP_IFACE="$iface"
  return 0
}

choose_working_gateway() {
  local iface="$1" current_gw="$2" suggested="" manual choice
  suggested="$(network_first_host "$TARGET_IP" "$TARGET_PREFIX" || true)"

  header "$(T 'Проверка нового IPv4 и шлюза' 'Testing new IPv4 and gateway')"
  printf '%s %s/%s\n' "$(T 'Новый адрес:' 'New address:')" "$TARGET_IP" "$TARGET_PREFIX"
  [[ -n "$suggested" ]] && printf '%s %s\n' "$(T 'Предполагаемый шлюз подсети:' 'Suggested subnet gateway:')" "$suggested"
  [[ -n "$current_gw" ]] && printf '%s %s\n' "$(T 'Текущий шлюз:' 'Current gateway:')" "$current_gw"
  printf '\n%s\n' "$(T 'Скрипт проверит маршрут, не меняя постоянную конфигурацию.' 'The script will test routing without changing persistent configuration.')"

  if [[ -n "$suggested" ]]; then
    printf '\n%s %s ...\n' "$(T 'Проверяем шлюз' 'Testing gateway')" "$suggested"
    if probe_ip_gateway "$iface" "$TARGET_IP" "$suggested"; then
      ok "$(T 'Новый IPv4 имеет независимый выход в интернет через этот шлюз.' 'The new IPv4 has independent Internet access through this gateway.')"
      TARGET_GW="$suggested"
      return 0
    fi
    warn "$(T 'Через предполагаемый шлюз интернет не подтвердился.' 'Internet access through the suggested gateway was not confirmed.')"
  fi

  if [[ -n "$current_gw" && "$current_gw" != "$suggested" ]]; then
    printf '\n%s %s ...\n' "$(T 'Дополнительно проверяем текущий шлюз' 'Also testing current gateway')" "$current_gw"
    if probe_ip_gateway "$iface" "$TARGET_IP" "$current_gw"; then
      warn "$(T 'Новый IP работает через старый шлюз, но это может оставить зависимость от старой сети.' 'The new IP works through the old gateway, but that may keep a dependency on the old network.')"
      printf '\n  1) %s\n' "$(T 'Использовать текущий шлюз (старый IP у провайдера пока НЕ удалять)' 'Use current gateway (do NOT remove the old provider IP yet)')"
      printf '  2) %s\n' "$(T 'Ввести другой шлюз и проверить' 'Enter another gateway and test it')"
      printf '  0) %s\n' "$(T 'Назад' 'Back')"
      while true; do
        choice="$(read_menu_choice "> ")" || return 1
        case "$choice" in
          1) TARGET_GW="$current_gw"; DEPENDENT_GATEWAY=1; return 0 ;;
          2) break ;;
          0) return 1 ;;
          *) warn "$(T 'Нет такого пункта.' 'No such menu item.')" ;;
        esac
      done
    fi
  fi

  while true; do
    read -r -p "$(T 'Введите шлюз вручную (0 = назад): ' 'Enter gateway manually (0 = back): ')" manual || return 1
    [[ "$manual" == "0" ]] && return 1
    if ! is_ipv4 "$manual"; then
      warn "$(T 'Некорректный IPv4 шлюза.' 'Invalid gateway IPv4.')"
      continue
    fi
    printf '%s %s ...\n' "$(T 'Проверяем' 'Testing')" "$manual"
    if probe_ip_gateway "$iface" "$TARGET_IP" "$manual"; then
      TARGET_GW="$manual"
      ok "$(T 'Шлюз работает с новым IPv4.' 'Gateway works with the new IPv4.')"
      return 0
    fi
    warn "$(T 'Через этот шлюз новый IPv4 не вышел в интернет.' 'The new IPv4 could not reach the Internet through this gateway.')"
  done
}

write_managed_netplan() {
  local iface="$1" metric=10
  cat > "$MANAGED_NETPLAN" <<EOFNET
# Managed by ZAMENAIP (${APP}) v${VERSION}
# Generated: $(date -Is)
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - "${TARGET_IP}/${TARGET_PREFIX}"
      routes:
        - to: "0.0.0.0/0"
          via: "${TARGET_GW}"
          metric: ${metric}
          on-link: true
      nameservers:
        addresses:
          - "${DNS1}"
          - "${DNS2}"
EOFNET
  chmod 600 "$MANAGED_NETPLAN"
}

save_switch_state() {
  local backup="$1" iface="$2" old_ip="$3" old_gw="$4"
  ensure_dirs
  {
    printf 'TARGET_IP=%q\n' "$TARGET_IP"
    printf 'TARGET_PREFIX=%q\n' "$TARGET_PREFIX"
    printf 'TARGET_GW=%q\n' "$TARGET_GW"
    printf 'IFACE=%q\n' "$iface"
    printf 'OLD_IP=%q\n' "$old_ip"
    printf 'OLD_GW=%q\n' "$old_gw"
    printf 'DOMAIN=%q\n' "$DEFAULT_DOMAIN"
    printf 'BACKUP_DIR=%q\n' "$backup"
    printf 'DEPENDENT_GATEWAY=%q\n' "${DEPENDENT_GATEWAY:-0}"
    printf 'CREATED_AT=%q\n' "$(date -Is)"
  } > "$STATE_DIR/current.env"
  chmod 600 "$STATE_DIR/current.env"
}

switch_wizard() {
  local iface old_gw old_ip public_old backup pub_after route_after rc
  if [[ ! -t 0 || ! -t 1 ]]; then
    err "$(T 'Мастер замены нужно запускать из интерактивного терминала/SSH.' 'The switch wizard must be run from an interactive terminal/SSH session.')"
    return 1
  fi
  TARGET_IP=""
  TARGET_PREFIX="24"
  TARGET_GW=""
  DEPENDENT_GATEWAY=0

  iface="$(current_iface || true)"
  old_gw="$(current_gateway || true)"
  public_old="$(public_ipv4 || true)"
  old_ip="${public_old:-$(current_route_src || true)}"
  [[ -n "$iface" ]] || { err "$(T 'Не удалось определить основной сетевой интерфейс.' 'Could not detect the primary network interface.')"; pause_menu; return; }
  [[ -n "$old_ip" ]] || { err "$(T 'Не удалось определить текущий IPv4.' 'Could not detect the current IPv4.')"; pause_menu; return; }

  if ! choose_target_ip "$iface" "$old_ip"; then
    cleanup_temp_ip
    return
  fi

  if ! prepare_target_ip_for_test "$iface"; then
    cleanup_temp_ip
    pause_menu
    return
  fi

  if ! choose_working_gateway "$iface" "$old_gw"; then
    cleanup_temp_ip
    return
  fi

  header "$(T 'План замены IPv4' 'IPv4 switch plan')"
  printf '%-25s %s\n' "$(T 'Текущий внешний IPv4:' 'Current public IPv4:')" "$old_ip"
  printf '%-25s %s/%s\n' "$(T 'Новый IPv4:' 'New IPv4:')" "$TARGET_IP" "$TARGET_PREFIX"
  printf '%-25s %s\n' "$(T 'Новый шлюз:' 'New gateway:')" "$TARGET_GW"
  printf '%-25s %s\n' "$(T 'Интерфейс:' 'Interface:')" "$iface"
  printf '%-25s %s, %s\n' "$(T 'DNS:' 'DNS:')" "$DNS1" "$DNS2"
  [[ -n "$DEFAULT_DOMAIN" ]] && printf '%-25s %s\n' "$(T 'Домен для проверки:' 'Domain to verify:')" "$DEFAULT_DOMAIN"
  printf '\n'
  if (( DEPENDENT_GATEWAY == 1 )); then
    warn "$(T 'Выбран старый шлюз. Старый IP/сетевое подключение у провайдера нельзя удалять, пока не настроен независимый шлюз нового IP.' 'The old gateway is selected. Do not remove the old provider IP/network until the new IP has an independent gateway.')"
  else
    ok "$(T 'Новый IP успешно проверен через выбранный шлюз.' 'The new IP was successfully tested through the selected gateway.')"
  fi
  printf '%s\n' "$(T 'Перед изменением будут сохранены Netplan, nginx, адреса и маршруты.' 'Netplan, nginx, addresses, and routes will be backed up before changes.')"
  printf '%s\n' "$(T 'Скрипт НЕ удаляет IP из панели хостинг-провайдера.' 'The script NEVER deletes an IP from the hosting provider panel.')"

  if confirm_choice "$(T 'Начать безопасную замену?' 'Start the safe switch?')"; then
    rc=0
  else
    rc=$?
  fi
  (( rc == 0 )) || { cleanup_temp_ip; return; }

  backup="$(create_backup before-switch)"
  ok "$(T 'Резервная копия создана:' 'Backup created:') $backup"

  write_managed_netplan "$iface"
  if ! netplan generate; then
    err "$(T 'Netplan не прошёл проверку. Изменения отменены.' 'Netplan validation failed. Changes were cancelled.')"
    rm -f "$MANAGED_NETPLAN"
    tar -C / -xzf "$backup/netplan.tgz"
    cleanup_temp_ip
    pause_menu
    return
  fi
  ok "$(T 'Новая конфигурация Netplan синтаксически корректна.' 'New Netplan configuration is syntactically valid.')"

  # Remove temporary address before Netplan takes ownership of it.
  cleanup_temp_ip

  warn "$(T "Сейчас будет запущен netplan try на ${TRY_TIMEOUT} секунд. НЕ закрывайте SSH. Если связь пропадёт и вы не подтвердите настройки, Netplan постарается вернуть прежнюю сеть." "netplan try will run for ${TRY_TIMEOUT} seconds. KEEP THIS SSH SESSION OPEN. If connectivity is lost and settings are not confirmed, Netplan will try to revert the previous network.")"
  if confirm_choice "$(T 'Запустить netplan try?' 'Run netplan try?')"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc != 0 )); then
    warn "$(T 'Применение отменено. Резервная копия сохранена.' 'Apply cancelled. The backup has been kept.')"
    pause_menu
    return
  fi

  if ! netplan try --timeout "$TRY_TIMEOUT"; then
    warn "$(T 'Netplan не был подтверждён или вернул старую конфигурацию.' 'Netplan was not confirmed or reverted the old configuration.')"
    pause_menu
    return
  fi

  pub_after="$(public_ipv4 || true)"
  route_after="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
  printf '\n%s\n' "$(T 'Проверка после применения:' 'Post-apply verification:')"
  printf '  %-20s %s\n' "$(T 'Внешний IPv4:' 'Public IPv4:')" "${pub_after:-unknown}"
  printf '  %-20s %s\n' "$(T 'Маршрут:' 'Route:')" "$route_after"

  if [[ "$pub_after" != "$TARGET_IP" ]] || ! grep -q "src $TARGET_IP" <<<"$route_after"; then
    err "$(T 'Новый IP не стал основным. Не удаляйте старый IP у провайдера.' 'The new IP did not become primary. Do not remove the old provider IP.')"
    if confirm_choice "$(T 'Восстановить резервную копию прямо сейчас?' 'Restore the backup now?')"; then
      restore_backup_dir "$backup" || true
    fi
    pause_menu
    return
  fi
  ok "$(T 'Новый IPv4 стал основным для исходящих соединений.' 'The new IPv4 is now primary for outbound connections.')"

  if ! nginx_update_network_binds "$old_ip" "$TARGET_IP"; then
    err "$(T 'После обновления сетевых директив nginx проверка nginx -t не прошла.' 'nginx -t failed after updating network bind directives.')"
    if confirm_choice "$(T 'Восстановить резервную копию?' 'Restore the backup?')"; then
      restore_backup_dir "$backup" || true
    fi
    pause_menu
    return
  fi

  save_switch_state "$backup" "$iface" "$old_ip" "$old_gw"

  if [[ -n "$DEFAULT_DOMAIN" ]]; then
    printf '\n'
    info "$(T "Проверяем сайт ${DEFAULT_DOMAIN}..." "Checking website ${DEFAULT_DOMAIN}...")"
    local code_local code_public dns_ips
    code_local="$(http_code "https://${DEFAULT_DOMAIN}/" "${DEFAULT_DOMAIN}:443:127.0.0.1")"
    code_public="$(http_code "https://${DEFAULT_DOMAIN}/")"
    dns_ips="$(resolve_ipv4s "$DEFAULT_DOMAIN" || true)"
    printf '  %-20s %s\n' "$(T 'Локальный HTTPS:' 'Local HTTPS:')" "${code_local:-no-response}"
    printf '  %-20s %s\n' "$(T 'Публичный HTTPS:' 'Public HTTPS:')" "${code_public:-no-response}"
    printf '  %-20s %s\n' "$(T 'DNS A:' 'DNS A:')" "${dns_ips//$'\n'/, }"
    if ! grep -Fxq "$TARGET_IP" <<<"$dns_ips"; then
      warn "$(T "DNS ещё не указывает на $TARGET_IP. Измените A-запись у вашего DNS-провайдера, если сайт должен открываться по новому IP." "DNS does not yet point to $TARGET_IP. Update the A record at your DNS provider if the website should use the new IP.")"
    fi
  fi

  printf '\n%b%s%b\n' "$C_GREEN$C_BOLD" "$(T 'ЗАМЕНА УСПЕШНА' 'SWITCH COMPLETED')" "$C_RESET"
  printf '%s %s\n' "$(T 'Новый основной IPv4:' 'New primary IPv4:')" "$TARGET_IP"
  printf '%s %s\n' "$(T 'Резервная копия:' 'Backup:')" "$backup"
  printf '\n%s\n' "$(T 'Рекомендуется перезагрузка и повторная проверка. Старый IP у провайдера удаляйте только после успешной проверки после reboot.' 'A reboot and another verification are recommended. Remove the old provider IP only after a successful post-reboot verification.')"

  if confirm_choice "$(T 'Перезагрузить сервер сейчас? SSH-сессия будет разорвана.' 'Reboot the server now? The SSH session will disconnect.')"; then
    systemctl reboot
    exit 0
  fi
  pause_menu
}

# ---------- Verify ----------

verify_saved_state() {
  local target iface pub route domain dependent
  if [[ ! -f "$STATE_DIR/current.env" ]]; then
    warn "$(T 'Нет сохранённой информации о последней замене.' 'No saved information about the last switch.')"
    return 1
  fi
  # shellcheck disable=SC1090
  source "$STATE_DIR/current.env"
  target="${TARGET_IP:-}"
  iface="${IFACE:-$(current_iface || true)}"
  domain="${DOMAIN:-$DEFAULT_DOMAIN}"
  dependent="${DEPENDENT_GATEWAY:-0}"
  pub="$(public_ipv4 || true)"
  route="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"

  printf '%-24s %s\n' "$(T 'Ожидаемый IPv4:' 'Expected IPv4:')" "$target"
  printf '%-24s %s\n' "$(T 'Текущий внешний IPv4:' 'Current public IPv4:')" "${pub:-unknown}"
  printf '%-24s %s\n' "$(T 'Интерфейс:' 'Interface:')" "$iface"
  printf '%-24s %s\n' "$(T 'Маршрут:' 'Route:')" "$route"

  if [[ "$pub" != "$target" ]] || ! grep -q "src $target" <<<"$route"; then
    err "$(T 'Проверка не пройдена. Старый IP у провайдера НЕ удаляйте.' 'Verification failed. Do NOT remove the old provider IP.')"
    return 1
  fi
  command -v nginx >/dev/null 2>&1 && nginx -t || true
  ok "$(T 'Основной исходящий IPv4 подтверждён.' 'Primary outbound IPv4 verified.')"

  if [[ -n "$domain" ]]; then
    local code dns_ips
    code="$(http_code "https://${domain}/")"
    dns_ips="$(resolve_ipv4s "$domain" || true)"
    printf '%-24s %s\n' "$(T 'Сайт HTTPS:' 'Website HTTPS:')" "${code:-no-response}"
    printf '%-24s %s\n' "$(T 'DNS A:' 'DNS A:')" "${dns_ips//$'\n'/, }"
  fi

  if [[ "$dependent" == "1" ]]; then
    warn "$(T 'Последняя замена использует старый шлюз. Не удаляйте старое подключение у провайдера без отдельной проверки.' 'The last switch uses the old gateway. Do not remove the old provider network without a separate check.')"
  else
    ok "$(T 'После reboot сеть работает на новом IPv4. Теперь можно сначала ОТВЯЗАТЬ старый IP у провайдера, проверить ещё раз и только затем удалять его окончательно.' 'After reboot the network works on the new IPv4. You may now DETACH the old provider IP first, verify again, and only then delete/release it permanently.')"
  fi
  return 0
}

verify_screen() {
  header "$(T 'Проверка после замены / reboot' 'Post-switch / post-reboot verification')"
  verify_saved_state || true
  pause_menu
}

# ---------- Settings / help ----------

settings_menu() {
  local c input
  while true; do
    header "$(T 'Настройки' 'Settings')"
    printf '%-22s %s\n' "$(T 'Язык:' 'Language:')" "$([[ "$LANGUAGE" == ru ]] && echo 'Русский' || echo 'English')"
    printf '%-22s %s\n' "$(T 'Домен:' 'Domain:')" "${DEFAULT_DOMAIN:-$(T 'не задан' 'not set')}"
    printf '%-22s %s, %s\n\n' 'DNS:' "$DNS1" "$DNS2"
    printf '  1) %s\n' "$(T 'Изменить язык' 'Change language')"
    printf '  2) %s\n' "$(T 'Задать домен для проверки сайта' 'Set website domain for checks')"
    printf '  3) %s\n' "$(T 'Изменить DNS-серверы' 'Change DNS servers')"
    printf '  0) %s\n' "$(T 'Назад' 'Back')"
    c="$(read_menu_choice "> ")" || return
    case "$c" in
      1) choose_language ;;
      2)
        read -r -p "$(T 'Домен без https:// (пусто = очистить, 0 = назад): ' 'Domain without https:// (blank = clear, 0 = back): ')" input || continue
        [[ "$input" == "0" ]] && continue
        input="${input#http://}"; input="${input#https://}"; input="${input%%/*}"
        DEFAULT_DOMAIN="$input"
        save_config
        ok "$(T 'Настройка домена сохранена.' 'Domain setting saved.')"
        pause_menu
        ;;
      3)
        read -r -p "DNS 1 [$DNS1] (0 = $(T 'назад' 'back')): " input || continue
        [[ "$input" == "0" ]] && continue
        [[ -n "$input" ]] && DNS1="$input"
        read -r -p "DNS 2 [$DNS2] (0 = $(T 'назад' 'back')): " input || continue
        [[ "$input" == "0" ]] && continue
        [[ -n "$input" ]] && DNS2="$input"
        if ! is_ipv4 "$DNS1" || ! is_ipv4 "$DNS2"; then
          warn "$(T 'DNS должен быть IPv4-адресом.' 'DNS must be an IPv4 address.')"
        else
          save_config
          ok "$(T 'DNS сохранён.' 'DNS settings saved.')"
        fi
        pause_menu
        ;;
      0) return ;;
      *) warn "$(T 'Нет такого пункта.' 'No such menu item.')"; sleep 1 ;;
    esac
  done
}

help_screen() {
  header "$(T 'Справка оператору' 'Operator guide')"
  if [[ "$LANGUAGE" == "ru" ]]; then
    cat <<'HELP_RU'
Как безопасно заменить IPv4:

  1. В панели хостинг-провайдера сначала привяжите новый IPv4 к VPS.
  2. Запустите: sudo zamenaip
  3. Пункт 1 — проверьте текущее состояние и доступ IP.
  4. Пункт 2 — выберите новый IP из списка или введите вручную.
  5. Скрипт временно проверит IP и шлюз до изменения Netplan.
  6. Перед изменениями автоматически создаётся резервная копия.
  7. Netplan применяется через `netplan try` с автооткатом по таймауту.
  8. После успешной замены проверьте сайт/DNS.
  9. Перезагрузите сервер и выполните пункт 3 "Проверка после reboot".
 10. Только после успешной проверки отвяжите старый IP у провайдера.
 11. Проверьте ещё раз. Затем старый IP можно удалить окончательно.

Важно:
  - Скрипт не может универсально увидеть IP, который существует только в панели
    провайдера и ещё не добавлен в Linux. Такой адрес вводится вручную.
  - Скрипт никогда сам не удаляет IP у хостинг-провайдера.
  - Автоматическая смена DNS у регистратора не выполняется без API конкретного
    DNS-провайдера. Скрипт проверит DNS и подскажет нужный A-адрес.
  - 0 в меню всегда означает "Назад".
HELP_RU
  else
    cat <<'HELP_EN'
How to change IPv4 safely:

  1. Attach the new IPv4 to the VPS in your hosting provider panel first.
  2. Run: sudo zamenaip
  3. Option 1 checks the current network and IP connectivity.
  4. Option 2 lets you choose a detected IP or enter one manually.
  5. The script tests the IP and gateway before changing Netplan.
  6. A backup is created automatically before changes.
  7. Netplan is applied with `netplan try` and timeout rollback protection.
  8. After the switch, check the website and DNS.
  9. Reboot, then use option 3 "Post-reboot verification".
 10. Only after successful verification should you detach the old provider IP.
 11. Verify once more, then permanently release/delete the old IP if desired.

Important:
  - The script cannot generically discover an IP that exists only in a provider
    control panel and is not yet configured in Linux. Enter such an IP manually.
  - The script never deletes an IP at the hosting provider.
  - DNS cannot be changed generically without a specific DNS provider API.
    The script checks DNS and tells the operator which A record is needed.
  - 0 always means "Back" in menus.
HELP_EN
  fi
  pause_menu
}

# ---------- Program install / update / repair ----------

latest_raw_url() {
  local branch="${1:-$UPDATE_BRANCH}"
  printf 'https://raw.githubusercontent.com/%s/%s/%s.sh\n' "$GITHUB_REPO" "$branch" "$APP"
}

download_latest_script() {
  local dest="$1" branch="$UPDATE_BRANCH" url
  url="$(latest_raw_url "$branch")"
  if curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$dest"; then
    return 0
  fi
  if [[ "$branch" == "main" ]]; then
    branch="master"
    warn "$(T 'Ветка main недоступна, пробуем master.' 'main branch unavailable; trying master.')"
    url="$(latest_raw_url "$branch")"
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$dest"
    return $?
  fi
  return 1
}

script_version_from_file() {
  awk -F'"' '/^VERSION="/{print $2; exit}' "$1" 2>/dev/null || true
}

install_file_atomically() {
  local source="$1" target="$2" dir tmp
  dir="$(dirname "$target")"
  install -d -m 755 "$dir"
  tmp="$(mktemp "${dir}/.zamenaip-install.XXXXXX")"
  install -m 755 "$source" "$tmp"
  mv -f "$tmp" "$target"
}

repair_launcher_from_current() {
  local self
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  install -d -m 755 "$INSTALL_DIR"

  if [[ -f "$self" && "$self" != "$INSTALL_TARGET" ]]; then
    bash -n "$self" || return 1
    install_file_atomically "$self" "$INSTALL_TARGET" || return 1
  fi

  if [[ ! -f "$INSTALL_TARGET" ]]; then
    err "$(T 'Установленный файл программы не найден.' 'Installed program file was not found.')"
    return 1
  fi

  rm -f "$BIN_LINK"
  ln -s "$INSTALL_TARGET" "$BIN_LINK"
  [[ "$(readlink -f "$BIN_LINK")" == "$INSTALL_TARGET" ]]
}

install_self_cli() {
  local self backup_dir
  self="$(readlink -f "${BASH_SOURCE[0]}")"

  if [[ ! -f "$self" ]]; then
    cat >&2 <<'EOF_INSTALL_ERR'
Cannot install directly from stdin.
Нельзя установить программу прямо из stdin.

Use / Используйте:
  curl -fsSL https://raw.githubusercontent.com/dagmagnat/safe-vps-ip-switch/main/safe-vps-ip-switch.sh -o /tmp/zamenaip-latest.sh
  sudo bash /tmp/zamenaip-latest.sh install
EOF_INSTALL_ERR
    return 1
  fi

  bash -n "$self" || return 1
  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT" 2>/dev/null || true

  if [[ -f "$INSTALL_TARGET" ]]; then
    backup_dir="${BACKUP_ROOT}/program-install-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "$INSTALL_TARGET" "${backup_dir}/${APP}.sh" 2>/dev/null || true
    [[ -e "$BIN_LINK" || -L "$BIN_LINK" ]] && cp -a "$BIN_LINK" "${backup_dir}/zamenaip-launcher" 2>/dev/null || true
    printf '%s\n' "$VERSION" > "${backup_dir}/source-version.txt"
    printf 'Backup / Резервная копия: %s\n' "$backup_dir"
  fi

  install_file_atomically "$self" "$INSTALL_TARGET"
  rm -f "$BIN_LINK"
  ln -s "$INSTALL_TARGET" "$BIN_LINK"
  hash -r 2>/dev/null || true

  printf '\nInstalled / Установлено:\n  %s\n' "$INSTALL_TARGET"
  printf 'Quick command / Быстрая команда:\n  %s\n' "$BIN_LINK"
  printf 'Version / Версия: %s\n\n' "$($BIN_LINK --version 2>/dev/null || printf unknown)"
  printf 'Run / Запуск:\n  sudo zamenaip\n\n'
  printf 'Update / Обновление:\n  sudo zamenaip update\n'
}

repair_screen() {
  header "$(T 'Исправление установки' 'Repair installation')"
  printf '%s\n\n' "$(T 'Команда будет заново привязана к установленному скрипту. Сеть и Netplan не изменяются.' 'The launcher will be relinked to the installed script. Network and Netplan are not changed.')"
  if repair_launcher_from_current; then
    ok "$(T 'Команда zamenaip исправлена.' 'zamenaip launcher repaired.')"
    printf '  %s -> %s\n' "$BIN_LINK" "$INSTALL_TARGET"
  else
    err "$(T 'Не удалось исправить установку.' 'Could not repair the installation.')"
    return 1
  fi
}

update_app() {
  local context="${1:-cli}"; shift || true
  local assume_yes=0 force=0 arg tmp latest backup_dir new_version
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) assume_yes=1 ;;
      --force) force=1 ;;
      *) err "$(T "Неизвестный параметр обновления: $arg" "Unknown update option: $arg")"; return 2 ;;
    esac
  done

  header "$(T 'Обновление ZAMENAIP' 'Update ZAMENAIP')"
  printf '%-24s %s\n' "$(T 'Текущая версия:' 'Current version:')" "$VERSION"
  printf '%-24s %s\n' "$(T 'Репозиторий:' 'Repository:')" "https://github.com/${GITHUB_REPO}"
  printf '%-24s %s\n\n' "$(T 'Ветка:' 'Branch:')" "$UPDATE_BRANCH"
  info "$(T 'Скачиваем основной скрипт с GitHub...' 'Downloading the main script from GitHub...')"

  tmp="$(mktemp /tmp/zamenaip-update.XXXXXX.sh)"
  if ! download_latest_script "$tmp"; then
    rm -f "$tmp"
    err "$(T 'Не удалось скачать новую версию с GitHub.' 'Could not download the new version from GitHub.')"
    return 1
  fi

  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    err "$(T 'Новая версия не прошла bash -n. Обновление отменено.' 'The downloaded version failed bash -n. Update cancelled.')"
    return 1
  fi

  latest="$(script_version_from_file "$tmp")"
  if [[ -z "$latest" ]]; then
    rm -f "$tmp"
    err "$(T 'Не удалось определить версию скачанного скрипта.' 'Could not determine downloaded script version.')"
    return 1
  fi

  printf '%-24s %s\n\n' "$(T 'Версия на GitHub:' 'GitHub version:')" "$latest"
  if [[ "$latest" == "$VERSION" && $force -eq 0 ]]; then
    ok "$(T 'Уже установлена актуальная версия. Для переустановки: zamenaip update --force' 'The current version is already installed. To reinstall: zamenaip update --force')"
    rm -f "$tmp"
    return 0
  fi

  if (( assume_yes == 0 )) && [[ -t 0 ]]; then
    if ! confirm_choice "$(T "Обновить ZAMENAIP ${VERSION} -> ${latest}? Сеть, Netplan и сетевые backup не изменяются." "Update ZAMENAIP ${VERSION} -> ${latest}? Network, Netplan, and network backups are preserved.")"; then
      rm -f "$tmp"
      info "$(T 'Обновление отменено.' 'Update cancelled.')"
      return 0
    fi
  fi

  ensure_dirs
  backup_dir="${BACKUP_ROOT}/program-update-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  if [[ -f "$INSTALL_TARGET" ]]; then
    cp -a "$INSTALL_TARGET" "${backup_dir}/${APP}.sh"
  fi
  if [[ -e "$BIN_LINK" || -L "$BIN_LINK" ]]; then
    cp -a "$BIN_LINK" "${backup_dir}/zamenaip-launcher" 2>/dev/null || true
  fi
  printf '%s\n' "$VERSION" > "${backup_dir}/version.txt"
  ok "$(T 'Резервная копия программы:' 'Program backup:') $backup_dir"

  if ! install_file_atomically "$tmp" "$INSTALL_TARGET"; then
    rm -f "$tmp"
    err "$(T 'Не удалось установить скачанный файл.' 'Could not install the downloaded file.')"
    return 1
  fi
  rm -f "$BIN_LINK"
  ln -s "$INSTALL_TARGET" "$BIN_LINK"
  hash -r 2>/dev/null || true

  if ! bash -n "$INSTALL_TARGET"; then
    err "$(T 'Проверка установленной версии не прошла. Возвращаем предыдущую.' 'Installed version validation failed. Restoring previous version.')"
    if [[ -f "${backup_dir}/${APP}.sh" ]]; then
      install_file_atomically "${backup_dir}/${APP}.sh" "$INSTALL_TARGET"
      rm -f "$BIN_LINK"
      ln -s "$INSTALL_TARGET" "$BIN_LINK"
    fi
    rm -f "$tmp"
    return 1
  fi

  new_version="$($BIN_LINK --version 2>/dev/null || true)"
  rm -f "$tmp"
  ok "$(T 'Обновление установлено.' 'Update installed.')"
  printf '%s: %s\n' "$(T 'Установлено' 'Installed')" "${new_version:-unknown}"
  printf '%s\n' "$(T 'Сеть, Netplan, настройки языка и резервные копии не изменялись.' 'Network, Netplan, language settings, and backups were not changed.')"

  if [[ "$context" == "menu" && -t 0 ]]; then
    if confirm_choice "$(T 'Перезапустить ZAMENAIP сейчас, чтобы открыть новую версию?' 'Restart ZAMENAIP now to open the new version?')"; then
      exec "$BIN_LINK"
    fi
  fi
}

update_screen() {
  update_app menu || true
  pause_menu
}

# ---------- Main menu ----------

main_menu() {
  local c
  while true; do
    header "$(T 'Главное меню' 'Main menu')"
    local pub iface
    pub="$(public_ipv4_once || true)"
    [[ -n "$pub" ]] || pub="$(current_route_src || true)"
    iface="$(current_iface || true)"
    printf '%s %b%s%b    %s %s\n\n' "$(T 'Текущий внешний IPv4:' 'Current public IPv4:')" "$C_GREEN" "${pub:-unknown}" "$C_RESET" "$(T 'Интерфейс:' 'Interface:')" "${iface:-unknown}"
    printf '  1) %s\n' "$(T 'Состояние IP и диагностика' 'IP status and diagnostics')"
    printf '  2) %s\n' "$(T 'Заменить основной IPv4' 'Change primary IPv4')"
    printf '  3) %s\n' "$(T 'Проверка после замены / reboot' 'Verify after switch / reboot')"
    printf '  4) %s\n' "$(T 'Резервные копии и восстановление' 'Backups and restore')"
    printf '  5) %s\n' "$(T 'Проверить сайт и DNS' 'Check website and DNS')"
    printf '  6) %s\n' "$(T 'Настройки / язык' 'Settings / language')"
    printf '  7) %s\n' "$(T 'Справка оператору' 'Operator guide')"
    printf '  8) %s\n' "$(T 'Обновить ZAMENAIP' 'Update ZAMENAIP')"
    printf '  0) %s\n' "$(T 'Выход' 'Exit')"
    printf '\n%b%s%b\n' "$C_DIM" "$(T 'Подсказка: в любом вложенном меню 0 = назад.' 'Tip: 0 means Back in every submenu.')" "$C_RESET"

    c="$(read_menu_choice "> ")" || exit 0
    case "$c" in
      1) diagnostics_menu ;;
      2) switch_wizard ;;
      3) verify_screen ;;
      4) backup_menu ;;
      5) site_check_screen ;;
      6) settings_menu ;;
      7) help_screen ;;
      8) update_screen ;;
      0) clear_screen; exit 0 ;;
      *) warn "$(T 'Нет такого пункта.' 'No such menu item.')"; sleep 1 ;;
    esac
  done
}

# ---------- CLI ----------

usage() {
  cat <<EOF_USAGE
ZAMENAIP / Safe VPS IP Switch v${VERSION}

Usage:
  sudo zamenaip                 Interactive menu / Интерактивное меню
  zamenaip status               Quick status
  sudo zamenaip switch          Open guided switch wizard
  sudo zamenaip verify          Verify last switch
  sudo zamenaip backup          Create backup
  sudo zamenaip rollback        Open backup/restore menu
  sudo zamenaip language        Change language
  sudo zamenaip update          Update from GitHub
  sudo zamenaip update --force  Reinstall current GitHub version
  sudo zamenaip repair          Repair /usr/local/bin/zamenaip
  sudo ./safe-vps-ip-switch.sh install
                              Install/repair quick command from this file
  zamenaip --version
EOF_USAGE
}

status_cli() {
  header "$(T 'Состояние сети' 'Network status')"
  print_network_summary
}

main() {
  local cmd="${1:-menu}"
  if (( $# > 0 )); then
    shift
  fi
  case "$cmd" in
    --version|version) printf '%s %s\n' "$APP" "$VERSION"; return 0 ;;
    -h|--help|help) usage; return 0 ;;
    install)
      ensure_root_for_menu
      install_self_cli "$@"
      return $?
      ;;
  esac

  load_config
  ensure_root_for_menu
  ensure_dirs
  ensure_language
  check_base_dependencies || exit 1

  case "$cmd" in
    menu) main_menu ;;
    status) status_cli ;;
    switch) switch_wizard ;;
    verify) header "$(T 'Проверка' 'Verification')"; verify_saved_state || exit 1 ;;
    backup) printf '%s\n' "$(create_backup manual-cli)" ;;
    rollback) backup_menu ;;
    language) choose_language ;;
    update) update_app cli "$@" ;;
    repair) repair_screen ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
