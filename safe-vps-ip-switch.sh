#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM="safe-vps-ip-switch"
VERSION="1.1.0"
STATE_DIR="/var/lib/${PROGRAM}"
BACKUP_ROOT="/root/${PROGRAM}-backups"
LOG_FILE="/var/log/${PROGRAM}.log"
NETPLAN_FILE="/etc/netplan/99-safe-vps-ip-switch.yaml"
TRY_TIMEOUT=120

# Defaults. Override with flags where documented.
PREFIX="24"
DNS1="1.1.1.1"
DNS2="1.0.0.1"
DOMAIN=""
NEW_IP=""
NEW_GW=""
ASSUME_YES=0
SKIP_NGINX=0

C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_CYAN='\033[36m'

log() {
  local msg="$*"
  printf '%b[%s]%b %s\n' "$C_CYAN" "$PROGRAM" "$C_RESET" "$msg"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date -Is)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

ok()   { printf '%bOK%b  %s\n' "$C_GREEN" "$C_RESET" "$*"; log "OK: $*" >/dev/null; }
warn() { printf '%bWARN%b %s\n' "$C_YELLOW" "$C_RESET" "$*"; log "WARN: $*" >/dev/null; }
die()  { printf '%bERROR%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; log "ERROR: $*" >/dev/null; exit 1; }

usage() {
  cat <<'USAGE'
Safe VPS IP Switch

Usage:
  sudo zamenaip                         # interactive safe IP switch
  sudo zamenaip [options]               # same switch, with options
  sudo zamenaip switch [options]
  sudo zamenaip verify
  sudo zamenaip rollback [backup-dir]
  zamenaip status

Without a subcommand, the script starts the interactive `switch` flow.
The original ./safe-vps-ip-switch.sh command remains supported.

Switch options:
  --new-ip IP       New public IPv4. If omitted, the script asks interactively.
  --gateway IP      New gateway. If omitted and prefix is /24, defaults to X.Y.Z.1.
  --prefix N        IPv4 prefix length. Default: 24.
  --domain NAME     Optional site domain to verify locally and publicly.
  --dns1 IP         Primary DNS. Default: 1.1.1.1.
  --dns2 IP         Secondary DNS. Default: 1.0.0.1.
  --skip-nginx      Do not update existing nginx proxy_bind entries.
  -y, --yes         Skip non-critical confirmation prompts. netplan try still requires confirmation.
  -h, --help        Show this help.

What switch does:
  1. Detects current public IPv4, interface and default gateway.
  2. Asks only for the new IP unless flags are supplied.
  3. Creates timestamped backups of /etc/netplan and /etc/nginx.
  4. Temporarily adds the new IP and checks the new gateway.
  5. Verifies the new IP can reach the Internet before changing persistent networking.
  6. Writes a Netplan override and validates it.
  7. Updates existing nginx proxy_bind OLD_IP entries to NEW_IP (if present).
  8. Runs nginx -t.
  9. Uses `netplan try --timeout 120`, so an unconfirmed broken network is reverted automatically.
 10. Verifies public IPv4, routing, nginx and the optional domain.

The script NEVER removes or releases the old IP in your hosting provider panel.
Do that only after `verify` succeeds after a reboot.
USAGE
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root: sudo $0 $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_ipv4() {
  local ip="$1"
  python3 - "$ip" <<'PY' >/dev/null 2>&1
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

calc_gateway_24() {
  local ip="$1"
  python3 - "$ip" <<'PY'
import ipaddress, sys
ip = ipaddress.IPv4Address(sys.argv[1])
net = ipaddress.IPv4Network(f"{ip}/24", strict=False)
print(next(net.hosts()))
PY
}

public_ipv4() {
  local bind_ip="${1:-}"
  local opt=()
  [[ -n "$bind_ip" ]] && opt=(--interface "$bind_ip")
  local url out
  for url in "https://ifconfig.me/ip" "https://api.ipify.org" "https://icanhazip.com"; do
    out="$(curl -4fsS --connect-timeout 5 --max-time 10 "${opt[@]}" "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$out" ]] && is_ipv4 "$out"; then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}

current_iface() {
  ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

current_gateway() {
  ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}'
}

current_route_src() {
  ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
}

first_global_ipv4_on_iface() {
  local iface="$1"
  ip -4 -o addr show dev "$iface" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}'
}

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  local ans
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

backup_all() {
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${BACKUP_ROOT}/${stamp}"
  mkdir -p "$backup"

  tar -C / -czf "$backup/netplan.tgz" etc/netplan
  if [[ -d /etc/nginx ]]; then
    tar -C / -czf "$backup/nginx.tgz" etc/nginx
  fi
  ip addr show > "$backup/ip-addr.txt"
  ip route show table all > "$backup/ip-route.txt"
  netplan get > "$backup/netplan-get.txt" 2>&1 || true
  printf '%s\n' "$backup" > "${STATE_DIR}/latest-backup"
  printf '%s\n' "$backup"
}

save_state() {
  local backup="$1" iface="$2" old_ip="$3" old_gw="$4"
  mkdir -p "$STATE_DIR"
  cat > "${STATE_DIR}/current.env" <<EOFSTATE
TARGET_IP='$NEW_IP'
TARGET_GW='$NEW_GW'
PREFIX='$PREFIX'
IFACE='$iface'
OLD_IP='$old_ip'
OLD_GW='$old_gw'
DOMAIN='$DOMAIN'
BACKUP_DIR='$backup'
CREATED_AT='$(date -Is)'
EOFSTATE
  chmod 600 "${STATE_DIR}/current.env"
}

rollback_from() {
  local backup="$1"
  [[ -d "$backup" ]] || die "Backup directory not found: $backup"
  [[ -f "$backup/netplan.tgz" ]] || die "Missing $backup/netplan.tgz"

  warn "Restoring network configuration from: $backup"
  rm -f "$NETPLAN_FILE"
  tar -C / -xzf "$backup/netplan.tgz"

  if [[ -f "$backup/nginx.tgz" ]]; then
    tar -C / -xzf "$backup/nginx.tgz"
  fi

  netplan generate || die "Restored Netplan files, but netplan generate failed. Inspect /etc/netplan manually."
  warn "Applying restored network configuration. Existing SSH session may briefly pause."
  netplan apply

  if command -v nginx >/dev/null 2>&1; then
    nginx -t && systemctl reload nginx || warn "nginx restore needs manual attention."
  fi
  ok "Rollback completed."
}

update_nginx_proxy_bind() {
  local old_ip="$1" new_ip="$2"
  [[ "$SKIP_NGINX" -eq 0 ]] || { warn "Skipping nginx changes (--skip-nginx)."; return 0; }
  command -v nginx >/dev/null 2>&1 || return 0
  [[ -d /etc/nginx/sites-enabled ]] || return 0

  local files changed=0 f real tmp
  mapfile -t files < <(find /etc/nginx/sites-enabled -maxdepth 1 -type f -o -type l 2>/dev/null | sort)
  for f in "${files[@]}"; do
    real="$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")"
    [[ -f "$real" ]] || continue
    if grep -Eq "^[[:space:]]*proxy_bind[[:space:]]+${old_ip//./\\.}[[:space:]]*;" "$real"; then
      tmp="$(mktemp)"
      sed -E "s#^([[:space:]]*proxy_bind[[:space:]]+)${old_ip//./\\.}([[:space:]]*;)#\\1${new_ip}\\2#" "$real" > "$tmp"
      cat "$tmp" > "$real"
      rm -f "$tmp"
      log "Updated proxy_bind in $real: $old_ip -> $new_ip"
      changed=1
    fi
  done

  if [[ "$changed" -eq 1 ]]; then
    nginx -t || die "nginx -t failed after proxy_bind update. Run rollback to restore."
    systemctl reload nginx
    ok "nginx proxy_bind entries updated to $new_ip and reloaded."
  else
    log "No active nginx proxy_bind entries using $old_ip were found; nothing changed."
  fi
}

auto_detect_domain() {
  [[ -n "$DOMAIN" ]] && return 0
  command -v nginx >/dev/null 2>&1 || return 0
  local candidate
  candidate="$(nginx -T 2>/dev/null | awk '
    $1=="server_name" {
      for(i=2;i<=NF;i++) {
        gsub(";","",$i)
        if($i !~ /^_/ && $i !~ /^localhost$/ && $i !~ /\\*/) { print $i; exit }
      }
    }' || true)"
  [[ -n "$candidate" ]] && DOMAIN="$candidate"
}

verify_domain() {
  [[ -n "$DOMAIN" ]] || return 0
  log "Testing site domain: $DOMAIN"
  local code_local code_public
  code_local="$(curl -kIsS --connect-timeout 5 --max-time 20 --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" 2>/dev/null | awk 'NR==1 {print $2}' || true)"
  code_public="$(curl -kIsS --connect-timeout 5 --max-time 20 "https://${DOMAIN}/" 2>/dev/null | awk 'NR==1 {print $2}' || true)"

  if [[ "$code_local" =~ ^[123][0-9][0-9]$ ]]; then
    ok "Local nginx/domain test: HTTP $code_local"
  else
    warn "Local domain test did not return 1xx/2xx/3xx (got: ${code_local:-no response})."
  fi
  if [[ "$code_public" =~ ^[123][0-9][0-9]$ ]]; then
    ok "Public domain test: HTTP $code_public"
  else
    warn "Public domain test did not return 1xx/2xx/3xx (DNS may still point to the old IP)."
  fi
}

status_cmd() {
  need_cmd ip
  need_cmd curl
  local iface gw pub src
  iface="$(current_iface || true)"
  gw="$(current_gateway || true)"
  src="$(current_route_src || true)"
  pub="$(public_ipv4 || true)"
  printf 'Public IPv4 : %s\n' "${pub:-unknown}"
  printf 'Interface   : %s\n' "${iface:-unknown}"
  printf 'Route source: %s\n' "${src:-unknown}"
  printf 'Gateway     : %s\n' "${gw:-unknown}"
  printf '\nIPv4 addresses:\n'
  ip -4 -br addr show
  printf '\nDefault routes:\n'
  ip -4 route show default
}

verify_cmd() {
  require_root verify
  need_cmd ip
  need_cmd curl
  [[ -f "${STATE_DIR}/current.env" ]] || die "No saved state. Run switch first."
  # shellcheck disable=SC1090
  source "${STATE_DIR}/current.env"

  log "Expected public IPv4: $TARGET_IP"
  local pub route
  pub="$(public_ipv4 || true)"
  route="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"

  printf 'Public IPv4 : %s\n' "${pub:-unknown}"
  printf 'Route       : %s\n' "$route"

  [[ "$pub" == "$TARGET_IP" ]] || die "Public IPv4 is ${pub:-unknown}, expected $TARGET_IP. Do NOT release the old provider IP yet."
  grep -q "src $TARGET_IP" <<<"$route" || die "Default route is not selecting source $TARGET_IP."

  if command -v nginx >/dev/null 2>&1; then
    nginx -t || die "nginx configuration test failed."
  fi
  verify_domain
  ok "Post-reboot verification passed. It is now safe to detach the old provider IP, then verify once more before deleting it."
}

switch_cmd() {
  require_root switch
  need_cmd ip
  need_cmd curl
  need_cmd awk
  need_cmd sed
  need_cmd grep
  need_cmd tar
  need_cmd python3
  need_cmd netplan

  [[ -t 0 && -t 1 ]] || die "Run switch interactively from a terminal/SSH session."
  [[ -d /etc/netplan ]] || die "This version supports Ubuntu/Netplan only."

  local iface old_gw old_ip public_old suggested_gw backup test_public
  iface="$(current_iface)"
  [[ -n "$iface" ]] || die "Could not detect the default IPv4 interface."
  old_gw="$(current_gateway || true)"
  public_old="$(public_ipv4 || true)"
  old_ip="${public_old:-$(current_route_src || true)}"
  [[ -n "$old_ip" ]] || old_ip="$(first_global_ipv4_on_iface "$iface")"

  printf '\nCurrent network\n'
  printf '  Public IPv4 : %s\n' "${public_old:-unknown}"
  printf '  Interface   : %s\n' "$iface"
  printf '  Gateway     : %s\n' "${old_gw:-unknown}"
  printf '  Addresses   : %s\n' "$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}' | xargs)"

  if [[ -z "$NEW_IP" ]]; then
    read -r -p "\nNew public IPv4: " NEW_IP
  fi
  is_ipv4 "$NEW_IP" || die "Invalid IPv4: $NEW_IP"
  [[ "$NEW_IP" != "$old_ip" ]] || die "New IP equals current IP ($old_ip). Nothing to do."

  [[ "$PREFIX" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || die "Invalid prefix: $PREFIX"
  if [[ -z "$NEW_GW" ]]; then
    if [[ "$PREFIX" == "24" ]]; then
      suggested_gw="$(calc_gateway_24 "$NEW_IP")"
      read -r -p "Gateway [$suggested_gw]: " NEW_GW
      NEW_GW="${NEW_GW:-$suggested_gw}"
    else
      read -r -p "Gateway for $NEW_IP/$PREFIX: " NEW_GW
    fi
  fi
  is_ipv4 "$NEW_GW" || die "Invalid gateway: $NEW_GW"

  auto_detect_domain

  printf '\nPlanned change\n'
  printf '  Old public IP : %s\n' "${old_ip:-unknown}"
  printf '  New public IP : %s/%s\n' "$NEW_IP" "$PREFIX"
  printf '  New gateway   : %s\n' "$NEW_GW"
  printf '  Interface     : %s\n' "$iface"
  [[ -n "$DOMAIN" ]] && printf '  Site test     : %s\n' "$DOMAIN"
  printf '\nThe old provider IP will NOT be detached or deleted by this script.\n'

  confirm "Continue with backup and preflight checks?" || die "Cancelled by user."

  mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
  backup="$(backup_all)"
  ok "Backup created: $backup"

  # Add the new address only for preflight testing; harmless if it is already configured.
  if ! ip -4 addr show dev "$iface" | grep -qE "[[:space:]]inet ${NEW_IP//./\\.}/"; then
    ip addr add "$NEW_IP/$PREFIX" dev "$iface"
    log "Temporarily added $NEW_IP/$PREFIX to $iface"
  fi

  log "Checking gateway reachability: $NEW_GW"
  if ping -c 2 -W 2 "$NEW_GW" >/dev/null 2>&1; then
    ok "Gateway $NEW_GW is reachable."
  else
    warn "Gateway $NEW_GW did not answer ping. Some providers block ICMP; continuing with outbound test."
  fi

  log "Checking outbound Internet access specifically from $NEW_IP"
  test_public="$(public_ipv4 "$NEW_IP" || true)"
  if [[ "$test_public" != "$NEW_IP" ]]; then
    warn "Outbound check from $NEW_IP returned '${test_public:-no response}'."
    warn "The new IP may not be attached/routed by the provider yet."
    confirm "Continue anyway and rely on netplan try auto-rollback?" || {
      ip addr del "$NEW_IP/$PREFIX" dev "$iface" 2>/dev/null || true
      die "Stopped safely. Provider-side IP assignment should be checked first."
    }
  else
    ok "New IP has working outbound Internet: $test_public"
  fi

  cat > "$NETPLAN_FILE" <<EOFNET
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - "${NEW_IP}/${PREFIX}"
      routes:
        - to: "0.0.0.0/0"
          via: "${NEW_GW}"
          metric: 50
      nameservers:
        addresses:
          - "${DNS1}"
          - "${DNS2}"
EOFNET
  chmod 600 "$NETPLAN_FILE"

  netplan generate || {
    rm -f "$NETPLAN_FILE"
    rollback_from "$backup"
    die "netplan generate failed. Previous configuration restored."
  }
  ok "Netplan syntax is valid."

  update_nginx_proxy_bind "$old_ip" "$NEW_IP"
  if command -v nginx >/dev/null 2>&1; then
    nginx -t || {
      rollback_from "$backup"
      die "nginx -t failed. Previous configuration restored."
    }
  fi

  save_state "$backup" "$iface" "$old_ip" "$old_gw"

  printf '\n%bIMPORTANT%b\n' "$C_YELLOW" "$C_RESET"
  printf 'Keep this SSH window open. Netplan will now try the new configuration.\n'
  printf 'If you lose connectivity and cannot confirm it, Netplan should revert after %s seconds.\n\n' "$TRY_TIMEOUT"
  confirm "Run netplan try now?" || die "Stopped before applying. Backup: $backup"

  netplan try --timeout "$TRY_TIMEOUT"
  ok "Netplan configuration accepted."

  local public_new route_check
  public_new="$(public_ipv4 || true)"
  route_check="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"

  printf '\nVerification\n'
  printf '  Public IPv4 : %s\n' "${public_new:-unknown}"
  printf '  Route       : %s\n' "$route_check"

  if [[ "$public_new" != "$NEW_IP" ]] || ! grep -q "src $NEW_IP" <<<"$route_check"; then
    warn "Verification failed: expected public/source IP $NEW_IP."
    if confirm "Rollback now?"; then
      rollback_from "$backup"
      exit 1
    fi
    die "Network state is not verified. Do NOT release the old provider IP. Backup: $backup"
  fi

  ok "Public/source IPv4 is now $NEW_IP."
  verify_domain

  printf '\n%bSUCCESS%b\n' "$C_GREEN" "$C_RESET"
  printf 'New primary IPv4: %s\n' "$NEW_IP"
  printf 'Gateway:          %s\n' "$NEW_GW"
  printf 'Backup:           %s\n' "$backup"
  printf '\nNext safe step:\n'
  printf '  1. Reboot the VPS.\n'
  printf '  2. Run: sudo %s verify\n' "$0"
  printf '  3. Only after verify passes, detach the old IP in the provider panel.\n'
  printf '  4. Verify again before permanently deleting/releasing the old IP.\n'
}

rollback_cmd() {
  require_root rollback
  need_cmd netplan
  need_cmd tar
  local backup="${1:-}"
  if [[ -z "$backup" && -f "${STATE_DIR}/latest-backup" ]]; then
    backup="$(cat "${STATE_DIR}/latest-backup")"
  fi
  [[ -n "$backup" ]] || die "No backup specified and no latest backup is recorded."
  rollback_from "$backup"
}

# Quick mode: `zamenaip` starts switch directly. Options can also be passed
# without writing the `switch` subcommand, e.g. `zamenaip --domain example.com`.
if [[ $# -eq 0 ]]; then
  COMMAND="switch"
elif [[ "$1" == -* ]]; then
  COMMAND="switch"
else
  COMMAND="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --new-ip) NEW_IP="${2:-}"; shift 2 ;;
    --gateway) NEW_GW="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --dns1) DNS1="${2:-}"; shift 2 ;;
    --dns2) DNS2="${2:-}"; shift 2 ;;
    --skip-nginx) SKIP_NGINX=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ "$COMMAND" == "rollback" && -z "${ROLLBACK_ARG:-}" ]]; then
        ROLLBACK_ARG="$1"; shift
      else
        die "Unknown option: $1"
      fi
      ;;
  esac
done

case "$COMMAND" in
  switch) switch_cmd ;;
  verify) verify_cmd ;;
  rollback) rollback_cmd "${ROLLBACK_ARG:-}" ;;
  status) status_cmd ;;
  help|-h|--help) usage ;;
  *) usage; die "Unknown command: $COMMAND" ;;
esac
