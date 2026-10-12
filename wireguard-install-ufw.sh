#!/usr/bin/env bash
# WireGuard + UFW installer, v7.0 (multi-distribution review candidate)
# Derivative work inspired by angristan/wireguard-install:
# https://github.com/angristan/wireguard-install
# Copyright (c) 2019 angristan
# Copyright (c) 2026 WireGuard UFW installer contributors
# MIT License
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# Target distributions: AlmaLinux >=8, Alpine, Arch, CentOS Stream >=8,
# Debian >=10, Fedora >=32, Oracle Linux, Rocky >=8, Ubuntu >=18.04.
# Retired distributions require their archived repos and a working WG kernel module.
# Debian 10 requires administrator-configured archived buster-backports BEFORE use.
# Alpine requires the wireguard-tools-openrc integration package; check availability in enabled repositories.
# Existing v3 installer state is intentionally NOT migrated automatically.
# Requires bash; on Alpine install bash before running this script.
# Private client files are stored root-only in /etc/wireguard/clients.
set -Eeuo pipefail
umask 077

readonly WG_DIR=/etc/wireguard
readonly STATE_FILE="${WG_DIR}/ufw-installer.state"
readonly SYSCTL_FILE=/etc/sysctl.d/99-z-wg-ufw-installer.conf
readonly BEGIN_TAG='# BEGIN WG-UFW-INSTALLER '
readonly END_TAG='# END WG-UFW-INSTALLER '

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() { ((EUID == 0)) || die 'Run this script with sudo or as root.'; }
require_os() {
  [[ -r /etc/os-release ]] || die 'Cannot identify the Linux distribution.'
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO="${ID:-}"
  # Rolling releases (notably Arch) may omit VERSION_ID entirely.
  MAJOR="${VERSION_ID:-0}"
  MAJOR="${MAJOR%%.*}"
  [[ "$MAJOR" =~ ^[0-9]+$ ]] || MAJOR=0
  case "$DISTRO" in
    ubuntu)
      ((MAJOR >= 18)) || die 'Ubuntu 18.04 or newer is required.'
      INIT_SYSTEM=systemd
      ;;
    debian)
      ((MAJOR >= 10)) || die 'Debian 10 or newer is required.'
      INIT_SYSTEM=systemd
      ;;
    fedora)
      ((MAJOR >= 32)) || die 'Fedora 32 or newer is required.'
      INIT_SYSTEM=systemd
      ;;
    almalinux | rocky | centos)
      ((MAJOR >= 8)) || die 'Enterprise Linux 8 or newer is required.'
      INIT_SYSTEM=systemd
      ;;
    ol | oracle)
      DISTRO=oracle
      ((MAJOR >= 8)) || die 'Oracle Linux 8 or newer is required.'
      INIT_SYSTEM=systemd
      ;;
    arch) INIT_SYSTEM=systemd ;;
    alpine) INIT_SYSTEM=openrc ;;
    *) die "Unsupported distribution: $DISTRO" ;;
  esac
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    command -v systemctl >/dev/null || die 'systemd is required for this distribution.'
  else
    command -v rc-service >/dev/null || die 'OpenRC is required for Alpine.'
    command -v rc-update >/dev/null || die 'OpenRC is required for Alpine.'
  fi
  command -v ip >/dev/null || warn 'The ip command is unavailable until dependencies are installed.'
  if [[ "$DISTRO" == debian && "$MAJOR" == 10 ]] || [[ "$DISTRO" == ubuntu && "$MAJOR" == 18 ]] || [[ "$DISTRO" == centos && "$MAJOR" == 8 ]]; then
    warn 'This is a legacy/end-of-life release. Its package repositories or WireGuard module may be unavailable.'
    warn 'The installer will not silently rewrite archived repositories or install untrusted kernel modules.'
  fi
}

service_start() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl enable --now "wg-quick@$IFACE"
  else
    local name="wg-quick.$IFACE"
    [[ -f /etc/init.d/wg-quick ]] || die 'Missing /etc/init.d/wg-quick (wireguard-tools-openrc).'
    [[ -e "/etc/init.d/$name" ]] || ln -s /etc/init.d/wg-quick "/etc/init.d/$name"
    rc-update add "$name" default
    rc-service "$name" start
  fi
}
service_active() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl is-active --quiet "wg-quick@$IFACE"
  else
    rc-service "wg-quick.$IFACE" status >/dev/null 2>&1
  fi
}
service_stop() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl disable --now "wg-quick@$IFACE" 2>/dev/null || :
  else
    rc-service "wg-quick.$IFACE" stop 2>/dev/null || :
    rc-update del "wg-quick.$IFACE" default 2>/dev/null || :
    [[ -L "/etc/init.d/wg-quick.$IFACE" ]] && rm -f "/etc/init.d/wg-quick.$IFACE" || :
  fi
}
firewalld_active() { [[ "$INIT_SYSTEM" == systemd ]] && systemctl is-active --quiet firewalld 2>/dev/null; }
stop_firewalld() {
  if [[ "${FIREWALLD_PREVIOUS_ACTIVE:-no}" == yes ]]; then
    systemctl disable --now firewalld
  fi
}
restore_firewalld() {
  if [[ "${FIREWALLD_PREVIOUS_ACTIVE:-no}" == yes ]]; then
    if ! systemctl enable --now firewalld; then
      warn 'CRITICAL: Could not restore previous firewalld service!'
      return 1
    fi
  fi
}

ufw_service_enabled() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl is-enabled --quiet ufw 2>/dev/null
  else
    local runlevels
    runlevels=$(rc-update show default 2>/dev/null) || return 1
    [[ "$runlevels" =~ (^|[[:space:]])ufw([[:space:]]|$) ]]
  fi
}
restore_ufw_service_state() {
  if [[ "${UFW_SERVICE_PREVIOUS_ENABLED:-no}" == no ]]; then
    if [[ "$INIT_SYSTEM" == systemd ]]; then
      systemctl disable ufw >/dev/null 2>&1 || :
    else
      rc-update del ufw default >/dev/null 2>&1 || :
    fi
  fi
}

ask() { # ask VARIABLE LABEL DEFAULT
  local var="$1" label="$2" default="$3" answer
  read -r -p "${label} [${default}]: " answer || die 'Input ended.'
  printf -v "$var" '%s' "${answer:-$default}"
}
confirm_exact() {
  local answer
  read -r -p "$1 (type $2): " answer || die 'Input ended.'
  [[ "$answer" == "$2" ]] || die 'Canceled; nothing further changed.'
}

ipv4_integer() { # prints unsigned integer; fail on invalid IPv4
  local input="$1" a b c d part
  [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r a b c d <<<"$input"
  for part in "$a" "$b" "$c" "$d"; do
    ((${#part} <= 3)) || return 1
    ((10#$part <= 255)) || return 1
  done
  printf '%u\n' "$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))"
}
valid_cidr4() {
  local prefix="${1%/*}" length="${1##*/}"
  [[ "$1" == */* ]] || return 1
  [[ "$length" =~ ^([0-9]|[12][0-9]|3[012])$ ]] || return 1
  ipv4_integer "$prefix" >/dev/null
}
cidr_overlap() { # two CIDR arguments, valid IPv4 only
  local a="${1%/*}" al="${1##*/}" b="${2%/*}" bl="${2##*/}" ai bi bits mask
  ai=$(ipv4_integer "$a") || return 1
  bi=$(ipv4_integer "$b") || return 1
  bits=$((al < bl ? al : bl))
  if ((bits == 0)); then return 0; fi
  mask=$(((0xffffffff << (32 - bits)) & 0xffffffff))
  (((ai & mask) == (bi & mask)))
}
subnet_in_use() {
  local proposed="$1" token
  # All route tables, connected interfaces, and existing WG configurations.
  # Ignore default/0 but reject covering routes, e.g. 10.0.0.0/8.
  while read -r token; do
    [[ -n "$token" ]] || continue
    if [[ "$token" != */* ]]; then token="${token}/32"; fi
    valid_cidr4 "$token" || continue
    [[ "$token" == '0.0.0.0/0' ]] && continue
    if cidr_overlap "$proposed" "$token"; then return 0; fi
  done < <(
    {
      ip -4 route show table all
      ip -o -4 addr show
      grep -hE '^[[:space:]]*(Address|AllowedIPs)[[:space:]]*=' "$WG_DIR"/*.conf 2>/dev/null || :
    } |
      grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' || :
  )
  return 1
}
pick_subnet() {
  local attempt octets first second candidate
  for ((attempt = 0; attempt < 1024; attempt++)); do
    octets=$(od -An -N2 -tu1 /dev/urandom) || return 1
    read -r first second <<<"$octets"
    candidate="10.${first}.${second}.0/24"
    if ! subnet_in_use "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
valid_10_24() {
  local input="$1" ip="${1%/*}" a b c d
  [[ "$input" == */24 ]] || return 1
  ipv4_integer "$ip" >/dev/null || return 1
  IFS=. read -r a b c d <<<"$ip"
  ((10#$a == 10 && 10#$d == 0))
}
valid_endpoint() {
  local val="$1"
  # Accept numeric IPv4, DNS labels, or a plain IPv6 literal. No shell metacharacters.
  [[ ${#val} -ge 1 && ${#val} -le 253 ]] || return 1
  if [[ "$val" =~ ^[0-9.]+$ ]]; then
    ipv4_integer "$val" >/dev/null || return 1
    [[ "$val" != 0.0.0.0 ]] || return 1
    return 0
  fi
  [[ "$val" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] && return 0
  [[ "$val" == *:* && "$val" =~ ^[0-9a-fA-F:.]+$ ]] && return 0
  return 1
}
valid_iface() { [[ "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,14}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_client_name() { [[ "$1" =~ ^[a-zA-Z0-9_-]{1,15}$ ]]; }
valid_routes() {
  local item arr
  IFS=',' read -r -a arr <<<"$1"
  ((${#arr[@]} > 0)) || return 1
  for item in "${arr[@]}"; do
    item="${item//[[:space:]]/}"
    valid_cidr4 "$item" || return 1
  done
}

has_global_ipv6() {
  local iface="$1" routes addresses
  routes=$(ip -6 route show default 2>/dev/null || :)
  [[ "$routes" =~ [[:space:]]dev[[:space:]]${iface}([[:space:]]|$) ]] || return 1
  addresses=$(ip -o -6 addr show dev "$iface" scope global 2>/dev/null || :)
  # Global unicast addresses in 2000::/3; reject ULA/link local.
  [[ "$addresses" =~ [[:space:]]inet6[[:space:]]2[0-9a-fA-F]{3}: ]] ||
    [[ "$addresses" =~ [[:space:]]inet6[[:space:]]3[0-9a-fA-F]{3}: ]]
}

random_ula_prefix() {
  local raw
  raw=$(od -An -N7 -tx1 /dev/urandom | tr -d ' \n') || return 1
  printf 'fd%s:%s:%s:%s\n' "${raw:0:2}" "${raw:2:4}" "${raw:6:4}" "${raw:10:4}"
}

# Valid ULA /64 base: fdXX:XXXX:XXXX:XXXX. No embedded CLI/config syntax.
valid_prefix6() {
  [[ "$1" =~ ^fd[0-9a-fA-F]{2}:[0-9a-fA-F]{4}:[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]
}

is_private_dns() { # Includes RFC1918 and CGNAT, not link-local/metadata.
  local ip="$1" range
  for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
    if cidr_overlap "$ip/32" "$range"; then return 0; fi
  done
  return 1
}

is_host_dns() { # Server's VPN IPv4 or any directly assigned host IPv4 address.
  local target="$1" address
  [[ "$target" == "$SERVER4" ]] && return 0
  while IFS= read -r address; do
    [[ "${address%/*}" == "$target" ]] && return 0
  done < <(ip -o -4 addr show 2>/dev/null | awk '{print $4}')
  return 1
}

# Split tunnels: a DNS server outside the client's AllowedIPs is never sent into
# the tunnel, so lookups to it fail. Add each such resolver as a /32 route,
# except the VPN endpoint itself (routing the endpoint into the tunnel breaks it).
dns_client_routes() { # ROUTES -> ROUTES plus uncovered DNS /32s
  local routes="$1" dns route covered
  local -a arr
  for dns in "$DNS1" "$DNS2"; do
    covered=no
    IFS=',' read -r -a arr <<<"$routes"
    for route in "${arr[@]}"; do
      route="${route//[[:space:]]/}"
      if cidr_overlap "$dns/32" "$route"; then
        covered=yes
        break
      fi
    done
    [[ "$covered" == no ]] || continue
    if [[ "$dns" == "$ENDPOINT_HOST" ]]; then
      warn "DNS $dns is the VPN endpoint; it is not routed through the tunnel."
      continue
    fi
    say "Note: routing DNS server $dns through the tunnel so split-tunnel lookups work." >&2
    routes+=",$dns/32"
  done
  printf '%s\n' "$routes"
}

needs_lan_dns_exception() {
  is_private_dns "$1" && ! is_host_dns "$1"
}

ufw_ipv6_value() {
  local value
  [[ -f /etc/default/ufw ]] || {
    printf 'unset\n'
    return
  }
  value=$(sed -n -E 's/^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*(yes|no)[[:space:]]*(#.*)?$/\1/p' /etc/default/ufw | tail -n1)
  printf '%s\n' "${value:-unset}"
}

load_state() {
  [[ -r "$STATE_FILE" ]] || die 'Installer state missing.'
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      STATE_VERSION) STATE_VERSION="$value" ;;
      ALLOW_LAN) ALLOW_LAN="$value" ;;
      ALLOW_HOST) ALLOW_HOST="$value" ;;
      ALLOW_DNS_ONLY) ALLOW_DNS_ONLY="$value" ;;
      UFW_IPV6_PREVIOUS) UFW_IPV6_PREVIOUS="$value" ;;
      UFW_IPV6_CHANGED) UFW_IPV6_CHANGED="$value" ;;
      FIREWALLD_PREVIOUS_ACTIVE) FIREWALLD_PREVIOUS_ACTIVE="$value" ;;
      IFACE) IFACE="$value" ;;
      PUB_IF) PUB_IF="$value" ;;
      PORT) PORT="$value" ;;
      ENDPOINT_HOST) ENDPOINT_HOST="$value" ;;
      SUBNET4) SUBNET4="$value" ;;
      SERVER4) SERVER4="$value" ;;
      DNS1) DNS1="$value" ;;
      DNS2) DNS2="$value" ;;
      ROUTES4) ROUTES4="$value" ;;
      IPV6_ENABLED) IPV6_ENABLED="$value" ;;
      PREFIX6) PREFIX6="$value" ;;
      PREV_IP_FORWARD) PREV_IP_FORWARD="$value" ;;
      PREV_IP6_FORWARD) PREV_IP6_FORWARD="$value" ;;
      PREV_ACCEPT_RA) PREV_ACCEPT_RA="$value" ;;
      UFW_PREVIOUS_ACTIVE) UFW_PREVIOUS_ACTIVE="$value" ;;
      PREV_ROUTED_POLICY) PREV_ROUTED_POLICY="$value" ;;
    esac
  done <"$STATE_FILE"
  [[ "${STATE_VERSION:-}" == 4 ]] || die 'This state file belongs to an earlier release. Use its own version for removal, or migrate it manually after a backup.'
  if ! valid_iface "${IFACE:-}" || ! valid_iface "${PUB_IF:-}"; then
    die 'Invalid installer state (interface).'
  fi
  if ! valid_port "${PORT:-}" || ! valid_10_24 "${SUBNET4:-}"; then
    die 'Invalid installer state (address).'
  fi
  valid_endpoint "${ENDPOINT_HOST:-}" || die 'Invalid installer state (endpoint).'
  valid_routes "${ROUTES4:-}" || die 'Invalid installer state (client routes).'
  for key in ALLOW_LAN ALLOW_HOST ALLOW_DNS_ONLY UFW_IPV6_CHANGED FIREWALLD_PREVIOUS_ACTIVE; do
    case "${!key:-}" in yes | no) ;; *) die "Invalid installer state ($key)." ;; esac
  done
  case "${UFW_IPV6_PREVIOUS:-}" in yes | no | unset) ;; *) die 'Invalid installer state (prior IPv6 policy).' ;; esac
  ipv4_integer "${SERVER4:-}" >/dev/null || die 'Invalid installer state (server IPv4).'
  [[ "$SERVER4" == "${SUBNET4%0/24}1" ]] || die 'Server IPv4 differs from the saved subnet.'
  if ! ipv4_integer "${DNS1:-}" >/dev/null || ! ipv4_integer "${DNS2:-}" >/dev/null; then
    die 'Invalid installer state (DNS).'
  fi
  if [[ "${IPV6_ENABLED:-no}" != no ]]; then
    valid_prefix6 "${PREFIX6:-}" || die 'Invalid installer state (IPv6 prefix).'
  else
    [[ -z "${PREFIX6:-}" ]] || die 'Unexpected IPv6 prefix in state.'
  fi
  case "${IPV6_ENABLED:-}" in yes | no | block) ;; *) die 'Invalid installer state (IPv6 mode).' ;; esac
  [[ -r "$WG_DIR/$IFACE.conf" ]] || die 'WireGuard interface config is missing.'
}
save_state() {
  local tmp
  tmp=$(mktemp "$WG_DIR/.state.XXXXXX")
  cat >"$tmp" <<STATE
# WireGuard UFW installer v7 (state schema 4); root-owned; data only (never source this file)
STATE_VERSION=4
ALLOW_LAN=$ALLOW_LAN
ALLOW_HOST=$ALLOW_HOST
ALLOW_DNS_ONLY=$ALLOW_DNS_ONLY
UFW_IPV6_PREVIOUS=$UFW_IPV6_PREVIOUS
UFW_IPV6_CHANGED=$UFW_IPV6_CHANGED
FIREWALLD_PREVIOUS_ACTIVE=$FIREWALLD_PREVIOUS_ACTIVE
IFACE=$IFACE
PUB_IF=$PUB_IF
PORT=$PORT
ENDPOINT_HOST=$ENDPOINT_HOST
SUBNET4=$SUBNET4
SERVER4=$SERVER4
DNS1=$DNS1
DNS2=$DNS2
ROUTES4=$ROUTES4
IPV6_ENABLED=$IPV6_ENABLED
PREFIX6=$PREFIX6
PREV_IP_FORWARD=$PREV_IP_FORWARD
PREV_IP6_FORWARD=$PREV_IP6_FORWARD
PREV_ACCEPT_RA=$PREV_ACCEPT_RA
UFW_PREVIOUS_ACTIVE=$UFW_PREVIOUS_ACTIVE
PREV_ROUTED_POLICY=$PREV_ROUTED_POLICY
STATE
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

install_packages() {
  say "Installing WireGuard, UFW and dependencies for $DISTRO..."
  case "$DISTRO" in
    ubuntu | debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update || die 'APT update failed. Fix repositories before proceeding.'
      if [[ "$DISTRO" == debian && "$MAJOR" == 10 ]] &&
        ! apt-cache policy wireguard-tools | grep -Eq 'Candidate: [^ (]+'; then
        die 'Debian 10: wireguard-tools is unavailable. Manually configure archived buster-backports and kernel support, or upgrade the OS.'
      fi
      apt-get install -y wireguard-tools ufw iptables qrencode iproute2 kmod || die 'APT package installation failed; on Debian 10, configure archived buster-backports FIRST.'
      # Old distro kernels need a working, separately packaged WG module.
      if [[ "$DISTRO" == debian && "$MAJOR" == 10 ]] || [[ "$DISTRO" == ubuntu && "$MAJOR" == 18 ]]; then
        if ! modprobe wireguard >/dev/null 2>&1; then
          warn 'Trying the legacy wireguard package with matching running-kernel headers.'
          local kernel_release headers_package
          kernel_release=$(uname -r)
          headers_package="linux-headers-$kernel_release"
          if ! apt-cache show "$headers_package" >/dev/null 2>&1; then
            die "Missing $headers_package. Install headers for the running kernel, or boot a backports kernel with WireGuard support, then retry."
          fi
          apt-get install -y "$headers_package" wireguard ||
            die "Legacy WireGuard/DKMS installation failed. Ensure $headers_package is installable, or boot a compatible backports kernel."
          modprobe wireguard >/dev/null 2>&1 ||
            die 'WireGuard kernel driver still unavailable after DKMS installation. Inspect DKMS logs and kernel/header compatibility.'
        fi
      fi
      ;;
    fedora)
      dnf install -y wireguard-tools ufw iptables iproute qrencode kmod || die 'Fedora package installation failed.'
      ;;
    almalinux | rocky | centos | oracle)
      command -v dnf >/dev/null || die 'dnf is required for this Enterprise Linux version.'
      # EPEL provides UFW on EL8/EL9/EL10; repo enabling remains explicit.
      if ! dnf -q list --available ufw >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
        say 'UFW is not in the enabled repositories. Attempting distro-provided EPEL release package.'
        case "$DISTRO" in
          oracle) dnf install -y "oracle-epel-release-el$MAJOR" || dnf install -y epel-release || die 'Enable a trustworthy EPEL repository for Oracle Linux.' ;;
          *) dnf install -y epel-release || die 'Enable the official EPEL repository and retry.' ;;
        esac
        dnf makecache --refresh || die 'Unable to refresh EPEL metadata.'
      fi
      dnf install -y wireguard-tools ufw iptables iproute kmod || die 'Essential Enterprise Linux packages unavailable.'
      dnf install -y qrencode || warn 'qrencode unavailable; manual .conf enrollment still works.'
      # EL8 often needs ELRepo kmod-wireguard for the distribution kernel.
      # Never silently add a kernel module repository or force a different kernel.
      if ! modprobe wireguard >/dev/null 2>&1; then
        die 'WireGuard kernel module missing. Install a module matching this kernel (EL8: ELRepo kmod-wireguard), then rerun.'
      fi
      ;;
    arch)
      # Avoid pacman -Sy: upgrading only the repository DB can cause partial upgrades.
      # Arch may provide different iptables backends; preserve the installed one
      # instead of forcing a conflicting package replacement.
      # sysctl comes from procps-ng; include it for minimal Arch installs.
      local -a arch_pkgs=(wireguard-tools ufw iproute2 qrencode kmod procps-ng)
      if ! command -v iptables >/dev/null 2>&1 || ! command -v ip6tables >/dev/null 2>&1; then
        arch_pkgs+=(iptables)
      fi
      pacman -S --needed --noconfirm "${arch_pkgs[@]}" ||
        die 'Pacman failed; review any iptables backend conflicts, perform a full supported update, and retry.'
      ;;
    alpine)
      # Bash must be installed to invoke this script in the first place.
      apk update || die 'apk update failed; ensure main/community repos are enabled.'
      apk add bash iproute2 coreutils wireguard-tools wireguard-tools-openrc \
        ufw ufw-openrc iptables libqrencode-tools kmod ||
        die 'Alpine packages missing. Alpine <3.20 may lack wireguard-tools-openrc; enable main/community or upgrade.'
      ;;
  esac
  local command_name
  for command_name in wg wg-quick ufw ip iptables ip6tables sysctl awk grep od; do
    command -v "$command_name" >/dev/null || die "Missing required tool: $command_name"
  done
  if ! modprobe wireguard >/dev/null 2>&1; then
    die 'WireGuard kernel driver is unavailable for the currently running kernel.'
  fi
  # A real interface creation probe catches unsupported kernels and missing CAP_NET_ADMIN
  # *before* changing firewall state. The temporary interface has no keys or addresses.
  local probe="wgp${RANDOM}${RANDOM}"
  probe="${probe:0:14}"
  if ! ip link add "$probe" type wireguard; then
    die 'Kernel cannot create a WireGuard interface. Check module, kernel and permissions.'
  fi
  ip link del "$probe" || die 'Unable to remove WireGuard preflight interface.'
}

ufw_active() {
  local status
  status=$(ufw status 2>/dev/null) || return 1
  [[ "$status" == *'Status: active'* ]]
}

ufw_routed_policy() {
  local result
  result=$(ufw status verbose | grep '^Default:' || :)
  if [[ "$result" =~ ([a-z]+)[[:space:]]\(routed\) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf 'unknown\n'
  fi
}

# File snapshots and rollback protect a failed *new* install. The backup directory
# is private. Package installation isn't rolled back because packages may be shared.
backup_file() {
  local path="$1" label="${1//\//_}"
  if [[ -e "$path" ]]; then cp -a -- "$path" "$BACKUP_DIR/$label"; else touch "$BACKUP_DIR/$label.absent"; fi
}
restore_file() {
  local path="$1" label="${1//\//_}"
  if [[ -f "$BACKUP_DIR/$label" ]]; then
    cp -a -- "$BACKUP_DIR/$label" "$path"
  elif [[ -f "$BACKUP_DIR/$label.absent" ]]; then rm -f -- "$path"; fi
}
rollback_new_install() {
  local status="${1:-1}" file rollback_failed=no
  trap - EXIT ERR INT TERM
  warn "Installation failed (exit $status); attempting to restore the prior firewall."
  if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]]; then
    service_stop || :
    # Stop modified firewall before restoring the snapshot. Never edit other networks.
    for file in /etc/ufw/before.rules /etc/ufw/before6.rules /etc/ufw/user.rules /etc/ufw/user6.rules /lib/ufw/user.rules /lib/ufw/user6.rules /var/lib/ufw/user.rules /var/lib/ufw/user6.rules /usr/lib/ufw/user.rules /usr/lib/ufw/user6.rules /etc/default/ufw /etc/ufw/ufw.conf /etc/ufw/sysctl.conf "$SYSCTL_FILE"; do
      restore_file "$file" || {
        warn "Failed restoring $file"
        rollback_failed=yes
      }
    done
    # Re-enable the original firewalld before undoing temporary UFW protection.
    # This minimizes the exposure window if the initial handoff already stopped it.
    if [[ "${FIREWALLD_PREVIOUS_ACTIVE:-no}" == yes ]]; then
      restore_firewalld || rollback_failed=yes
    fi
    if [[ "${UFW_PREVIOUS_ACTIVE:-no}" == yes ]]; then
      ufw --force reload >/dev/null 2>&1 || {
        warn 'CRITICAL: Manual UFW reload required.'
        rollback_failed=yes
      }
    else
      ufw --force disable >/dev/null 2>&1 || {
        warn 'CRITICAL: Manual UFW disable required.'
        rollback_failed=yes
      }
    fi
    if [[ -n "${SUBNET4:-}" && -n "${PUB_IF:-}" ]]; then
      if [[ "${IPV6_ENABLED:-no}" == yes ]]; then
        remove_live_nat "$SUBNET4" "${PREFIX6:-}" || :
      else
        remove_live_nat "$SUBNET4" || :
      fi
    fi
    [[ -n "${PREV_IP_FORWARD:-}" ]] && sysctl -q -w "net.ipv4.ip_forward=$PREV_IP_FORWARD" || :
    if [[ "${IPV6_ENABLED:-no}" == yes ]]; then
      [[ -n "${PREV_IP6_FORWARD:-}" ]] && sysctl -q -w "net.ipv6.conf.all.forwarding=$PREV_IP6_FORWARD" || :
      [[ -n "${PREV_ACCEPT_RA:-}" ]] && sysctl -q -w "net.ipv6.conf.${PUB_IF}.accept_ra=$PREV_ACCEPT_RA" || :
    fi
    restore_ufw_service_state
    rm -f -- "$STATE_FILE" "$WG_DIR/${IFACE:-wg0}.conf"
    rmdir "$WG_DIR/clients" 2>/dev/null || :
    if [[ "$rollback_failed" == yes ]]; then
      warn "CRITICAL: Rollback was incomplete. Recovery snapshots retained: $BACKUP_DIR"
    else
      rm -rf -- "$BACKUP_DIR"
    fi
  fi
  warn 'Verify remote access and firewall status manually before disconnecting.'
}
installation_exit_handler() {
  local rc=$?
  trap - EXIT
  if [[ "${ROLLBACK_ARMED:-no}" == yes && $rc -ne 0 ]]; then
    rollback_new_install "$rc"
  fi
  exit "$rc"
}

# Every NAT rule this installer writes carries a unique iptables comment, so
# checks and cleanup touch only our rule, never an identical admin-created one.
nat_comment() { printf 'wgufw-%s-nat\n' "$1"; } # TAG (e.g. wg0-v4)

append_nat_block() { # FILE SOURCE_SUBNET TAG
  local target="$1" cidr="$2" tag="$3" nat_count temp comment
  comment=$(nat_comment "$tag")
  [[ -f "$target" ]] || die "Missing UFW rules file: $target"
  if grep -Fq "${BEGIN_TAG}${tag}" "$target"; then die "Existing NAT block for $tag"; fi
  nat_count=$(grep -Ec '^\*nat([[:space:]]|$)' "$target" || :)
  if ((nat_count > 1)); then
    die "Multiple NAT sections found in $target. Refusing to risk replacing existing rules."
  fi
  if ((nat_count == 1)); then
    # Merge into the existing NAT section: adding a second *nat section could
    # flush/redefine pre-existing NAT rules when iptables-restore loads it.
    temp=$(mktemp "${target}.XXXXXX")
    if ! awk -v begin="${BEGIN_TAG}${tag}" -v end="${END_TAG}${tag}" \
      -v cidr="$cidr" -v iface="$PUB_IF" -v comment="$comment" '
      /^\*nat([[:space:]]|$)/ {innat=1}
      innat && /^COMMIT([[:space:]]|$)/ && !inserted {
        print begin
        print "-A POSTROUTING -s " cidr " -o " iface " -m comment --comment " comment " -j MASQUERADE"
        print end
        inserted=1
        innat=0
      }
      {print}
      END { if (!inserted) exit 1 }
    ' "$target" >"$temp"; then
      rm -f "$temp"
      die "NAT section in $target had no COMMIT."
    fi
    chmod --reference="$target" "$temp"
    chown --reference="$target" "$temp"
    mv -f "$temp" "$target"
  else
    # No leading blank line: everything appended lies between the markers, so
    # removal restores the original file byte-for-byte whatever its layout.
    # A file lacking a final newline would glue the marker onto its last line.
    if [[ -s "$target" && -n "$(tail -c1 "$target")" ]]; then
      warn "$target did not end with a newline; adding one before the NAT block."
      printf '\n' >>"$target"
    fi
    cat >>"$target" <<NAT
${BEGIN_TAG}${tag}
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${cidr} -o ${PUB_IF} -m comment --comment ${comment} -j MASQUERADE
COMMIT
${END_TAG}${tag}
NAT
  fi
}
remove_nat_block() {
  local target="$1" tag="$2" tmp
  [[ -f "$target" ]] || return 0
  if ! grep -Fqx "${BEGIN_TAG}${tag}" "$target"; then return 0; fi
  grep -Fqx "${END_TAG}${tag}" "$target" || die "Missing closing NAT marker in $target; manual review required."
  tmp=$(mktemp "${target}.XXXXXX")
  awk -v begin="${BEGIN_TAG}${tag}" -v end="${END_TAG}${tag}" \
    '$0 == begin {drop=1; next} $0 == end && drop {drop=0; next} !drop {print}' "$target" >"$tmp"
  chmod --reference="$target" "$tmp"
  chown --reference="$target" "$tmp"
  mv -f "$tmp" "$target"
}

# The live NAT rule this installer owns, as iptables match arguments.
nat_live_args() { # SOURCE_CIDR TAG
  printf '%s\n' -s "$1" -o "$PUB_IF" -m comment --comment "$(nat_comment "$2")" -j MASQUERADE
}

# UFW loads the before.rules NAT section with iptables-restore --noflush, so
# removing the block and reloading leaves the live rule in place until reboot,
# and every reload adds another copy. Delete every live copy of OUR tagged rule;
# an identical rule without our comment is left alone.
remove_live_nat() { # SUBNET4 [PREFIX6]
  local subnet4="$1" prefix6="${2:-}"
  local -a args
  mapfile -t args < <(nat_live_args "$subnet4" "$IFACE-v4")
  while iptables -t nat -D POSTROUTING "${args[@]}" 2>/dev/null; do :; done
  if [[ -n "$prefix6" ]] && command -v ip6tables >/dev/null 2>&1; then
    mapfile -t args < <(nat_live_args "${prefix6}::/64" "$IFACE-v6")
    while ip6tables -t nat -D POSTROUTING "${args[@]}" 2>/dev/null; do :; done
  fi
}

nat_loaded() { # iptables|ip6tables SOURCE_CIDR TAG -> true if our tagged rule is live
  local tool="$1"
  local -a args
  mapfile -t args < <(nat_live_args "$2" "$3")
  "$tool" -t nat -C POSTROUTING "${args[@]}"
}

check_ufw_sysctl_overrides() {
  # UFW reads its own sysctl.conf on startup. Explicit forwarding=0 overrides
  # systemd-sysctl; refuse rather than silently rewriting someone else's file.
  local file=/etc/ufw/sysctl.conf
  [[ -f "$file" ]] || return 0
  if grep -Eq '^[[:space:]]*net/ipv4/ip_forward[[:space:]]*=[[:space:]]*0([[:space:]#]|$)' "$file"; then
    die "Active IPv4 forwarding=0 in $file. Review/remove that setting before running the installer."
  fi
  if [[ "$IPV6_ENABLED" == yes ]] &&
    grep -Eq '^[[:space:]]*net/ipv6/conf/(all|default)/forwarding[[:space:]]*=[[:space:]]*0([[:space:]#]|$)' "$file"; then
    die "Active IPv6 forwarding=0 in $file. Review/remove that setting before running the installer."
  fi
}

# Only WireGuard traffic can use these transit rules. Denies precede broad allow.
configure_firewall() {
  local range dns proto label
  if [[ "${UFW_PREVIOUS_ACTIVE}" != yes ]]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny routed
  else
    case "$PREV_ROUTED_POLICY" in
      deny | reject) ;;
      *) ufw default deny routed ;;
    esac
  fi
  ufw allow in on "$PUB_IF" to any port "$PORT" proto udp comment "wgufw-$IFACE-listen"
  if [[ "$ALLOW_HOST" == no ]]; then
    ufw prepend deny in on "$IFACE" from "$SUBNET4" comment "wgufw-$IFACE-hostdeny"
  else
    ufw allow in on "$IFACE" from "$SUBNET4" comment "wgufw-$IFACE-hostallow"
  fi
  # Inbound VPN packets are never allowed to route to cloud provider metadata.
  ufw route prepend deny in on "$IFACE" from "$SUBNET4" to 169.254.0.0/16 comment "wgufw-$IFACE-metadata"
  if [[ "$ALLOW_LAN" == no ]]; then
    for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
      ufw route prepend deny in on "$IFACE" from "$SUBNET4" to "$range" comment "wgufw-$IFACE-private${range%%.*}"
    done
  fi
  ufw route allow in on "$IFACE" out on "$PUB_IF" from "$SUBNET4" to any comment "wgufw-$IFACE-v4"
  # DNS-only exception rules must be prepended AFTER the blanket RFC1918 denies.
  if [[ "$ALLOW_DNS_ONLY" == yes ]]; then
    for label in 1 2; do
      if [[ "$label" == 2 && "$DNS1" == "$DNS2" ]]; then continue; fi
      if [[ "$label" == 1 ]]; then dns="$DNS1"; else dns="$DNS2"; fi
      if is_private_dns "$dns" && ! is_host_dns "$dns"; then
        for proto in udp tcp; do
          ufw route prepend allow in on "$IFACE" from "$SUBNET4" to "$dns" port 53 proto "$proto" comment "wgufw-$IFACE-dns${label}-${proto}"
        done
      fi
    done
  fi
  for label in 1 2; do
    if [[ "$label" == 2 && "$DNS1" == "$DNS2" ]]; then continue; fi
    if [[ "$label" == 1 ]]; then dns="$DNS1"; else dns="$DNS2"; fi
    if is_host_dns "$dns" && [[ "$ALLOW_HOST" == no ]]; then
      for proto in udp tcp; do
        ufw prepend allow in on "$IFACE" from "$SUBNET4" to "$dns" port 53 proto "$proto" comment "wgufw-$IFACE-hostdns${label}-${proto}"
      done
    fi
  done
  append_nat_block /etc/ufw/before.rules "$SUBNET4" "$IFACE-v4"
  if [[ "$IPV6_ENABLED" == yes ]]; then
    if [[ "$ALLOW_HOST" == no ]]; then
      ufw prepend deny in on "$IFACE" from "${PREFIX6}::/64" comment "wgufw-$IFACE-host6deny"
    else
      ufw allow in on "$IFACE" from "${PREFIX6}::/64" comment "wgufw-$IFACE-host6allow"
    fi
    ufw route prepend deny in on "$IFACE" from "${PREFIX6}::/64" to fe80::/10 comment "wgufw-$IFACE-local6"
    if [[ "$ALLOW_LAN" == no ]]; then
      ufw route prepend deny in on "$IFACE" from "${PREFIX6}::/64" to fc00::/7 comment "wgufw-$IFACE-private6"
    fi
    ufw route allow in on "$IFACE" out on "$PUB_IF" from "${PREFIX6}::/64" to any comment "wgufw-$IFACE-v6"
    append_nat_block /etc/ufw/before6.rules "${PREFIX6}::/64" "$IFACE-v6"
  elif [[ "$IPV6_ENABLED" == block ]]; then
    if [[ "$ALLOW_HOST" == no ]]; then
      ufw prepend deny in on "$IFACE" from "${PREFIX6}::/64" comment "wgufw-$IFACE-host6deny"
    else
      ufw allow in on "$IFACE" from "${PREFIX6}::/64" comment "wgufw-$IFACE-host6allow"
    fi
    ufw route prepend deny in on "$IFACE" from "${PREFIX6}::/64" to any comment "wgufw-$IFACE-v6-block"
  fi
  if [[ "${UFW_PREVIOUS_ACTIVE}" == yes ]]; then ufw --force reload; else ufw --force enable; fi
  [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || die 'IPv4 forwarding disabled after UFW reload.'
  if [[ "$IPV6_ENABLED" == yes ]]; then
    [[ $(sysctl -n net.ipv6.conf.all.forwarding) == 1 ]] || die 'IPv6 forwarding disabled after UFW reload.'
  fi
  nat_loaded iptables "$SUBNET4" "$IFACE-v4" || die 'IPv4 NAT was not loaded by UFW.'
  if [[ "$IPV6_ENABLED" == yes ]]; then
    nat_loaded ip6tables "${PREFIX6}::/64" "$IFACE-v6" || die 'IPv6 NAT was not loaded by UFW.'
  fi
}

ssh_ports() {
  local port
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    port="${SSH_CONNECTION##* }"
    if valid_port "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | paste -sd, -
  elif [[ -x /usr/sbin/sshd ]]; then
    /usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | paste -sd, -
  else
    printf '22\n'
  fi
}

add_ssh_rules() {
  local ports="$1" token arr
  IFS=',' read -r -a arr <<<"$ports"
  ((${#arr[@]} > 0)) || die 'At least one SSH port is required for safe remote installation.'
  for token in "${arr[@]}"; do
    token="${token//[[:space:]]/}"
    valid_port "$token" || die "Invalid SSH port: $token"
    ufw allow "$token/tcp" comment 'wgufw-ssh-safety'
  done
}

write_sysctl() {
  {
    say '# WireGuard UFW installer - managed values'
    say 'net.ipv4.ip_forward = 1'
    if [[ "$IPV6_ENABLED" == yes ]]; then
      say 'net.ipv6.conf.all.forwarding = 1'
      say "net.ipv6.conf.${PUB_IF}.accept_ra = 2"
    fi
  } >"$SYSCTL_FILE"
  # Make sure a router using SLAAC keeps receiving RAs when forwarding is on.
  if [[ "$IPV6_ENABLED" == yes ]]; then sysctl -q -w "net.ipv6.conf.${PUB_IF}.accept_ra=2"; fi
  sysctl -q -w net.ipv4.ip_forward=1
  if [[ "$IPV6_ENABLED" == yes ]]; then sysctl -q -w net.ipv6.conf.all.forwarding=1; fi
}

make_server_config() {
  local priv pub
  priv=$(wg genkey)
  pub=$(printf '%s\n' "$priv" | wg pubkey)
  SERVER_PUBLIC_KEY="$pub"
  {
    say '[Interface]'
    say "Address = ${SERVER4}/24"
    if [[ "$IPV6_ENABLED" != no ]]; then say "Address = ${PREFIX6}::1/64"; fi
    say "ListenPort = $PORT"
    say "PrivateKey = $priv"
  } >"$WG_DIR/$IFACE.conf"
  chmod 600 "$WG_DIR/$IFACE.conf"
}

install_server() {
  [[ ! -e "$STATE_FILE" && ! -e "$WG_DIR/params" ]] || die 'Existing WireGuard installer state detected; refusing to overwrite it.'
  [[ ! -e "$SYSCTL_FILE" ]] || die "Refusing to overwrite an existing $SYSCTL_FILE"
  say 'This installer will install distribution packages before making any firewall changes.'
  confirm_exact 'Authorize prerequisite package installation' PACKAGES
  install_packages
  FIREWALLD_PREVIOUS_ACTIVE=no
  if firewalld_active; then
    FIREWALLD_PREVIOUS_ACTIVE=yes
    warn 'firewalld is active. This installer uses UFW, not firewalld.'
    warn 'Replacing the host firewall can interrupt other applications or SSH.'
    say 'Current firewalld runtime zone/services/ports/rich-rules:'
    firewall-cmd --list-all-zones || warn 'Unable to inspect current firewalld zones.'
    say 'Persisted firewalld zone configuration (may differ from runtime):'
    firewall-cmd --permanent --list-all-zones || warn 'Unable to inspect saved firewalld zones.'
    warn 'ONLY UFW SSH protection and the WireGuard UDP port are created automatically.'
    warn 'Manually migrate all other required allowed ports/services to UFW first.'
    confirm_exact 'Confirm you reviewed firewalld rules and authorize replacement' REPLACE
  fi
  if { [[ "$INIT_SYSTEM" == systemd ]] && systemctl is-active --quiet nftables 2>/dev/null; } ||
    { [[ "$INIT_SYSTEM" == openrc ]] && rc-service nftables status >/dev/null 2>&1; }; then
    die 'The standalone nftables service is active. Review existing firewall ownership before using UFW.'
  fi
  local guess_net suggested_ip suggested_if suggested_ssh answer dns_item
  suggested_if=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' | head -1)
  [[ -n "$suggested_if" ]] || die 'No default IPv4 route. Configure connectivity before installation.'
  ask PUB_IF 'Outgoing/public network interface' "$suggested_if"
  if ! valid_iface "$PUB_IF" || ! ip link show dev "$PUB_IF" >/dev/null 2>&1; then
    die 'Invalid or missing public interface.'
  fi
  suggested_ip=$(ip -o -4 addr show dev "$PUB_IF" scope global | awk '{split($4,a,"/");print a[1];exit}')
  [[ -n "$suggested_ip" ]] || die "No IPv4 address on $PUB_IF."
  say 'Use the actual PUBLIC IPv4 address or DNS hostname clients will connect to.'
  say 'If the server is behind a home router, you also need UDP port forwarding.'
  ask ENDPOINT_HOST 'Client endpoint host/IP' "$suggested_ip"
  valid_endpoint "$ENDPOINT_HOST" || die 'Invalid endpoint host/IP.'
  ask IFACE 'WireGuard interface' wg0
  valid_iface "$IFACE" || die 'Invalid WireGuard interface name.'
  [[ "$IFACE" != "$PUB_IF" ]] || die 'Public and WireGuard interfaces must be different.'
  local preexisting_rules
  preexisting_rules=$(ufw show added 2>/dev/null) || die 'Cannot inspect existing UFW rules.'
  if [[ "$preexisting_rules" == *"wgufw-$IFACE-"* ]]; then
    die 'Existing UFW rules carry this installer interface label. Review them before a fresh installation.'
  fi
  [[ ! -e "$WG_DIR/$IFACE.conf" && ! -L "$WG_DIR/$IFACE.conf" && ! -e "/sys/class/net/$IFACE" ]] || die "Interface/config $IFACE exists; not overwriting it."
  PORT=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
  PORT=$((49152 + PORT % 16384))
  ask PORT 'WireGuard UDP port' "$PORT"
  valid_port "$PORT" || die 'Invalid WireGuard UDP port.'
  guess_net=$(pick_subnet) || die 'Unable to find a free 10.x.y.0/24 range; check existing routes.'
  say "Random collision-checked VPN network: $guess_net"
  ask SUBNET4 'Use subnet (must be 10.x.y.0/24)' "$guess_net"
  valid_10_24 "$SUBNET4" || die 'Invalid 10.x.y.0/24 subnet.'
  ! subnet_in_use "$SUBNET4" || die 'Subnet overlaps an existing route, address or WireGuard config.'
  SERVER4="${SUBNET4%0/24}1"
  ask DNS1 'Client DNS resolver #1 (IPv4)' 1.1.1.1
  ipv4_integer "$DNS1" >/dev/null || die 'Invalid IPv4 DNS #1.'
  ask DNS2 'Client DNS resolver #2 (IPv4)' 1.0.0.1
  ipv4_integer "$DNS2" >/dev/null || die 'Invalid IPv4 DNS #2.'
  for dns_item in "$DNS1" "$DNS2"; do
    if cidr_overlap "$dns_item/32" 127.0.0.0/8 || cidr_overlap "$dns_item/32" 169.254.0.0/16 ||
      [[ "$dns_item" == 0.0.0.0 ]] || cidr_overlap "$dns_item/32" 224.0.0.0/4; then
      die "Unsafe/nonroutable client DNS IPv4 address: $dns_item"
    fi
  done
  ask ROUTES4 'Client IPv4 AllowedIPs (comma-separated CIDRs)' '0.0.0.0/0'
  valid_routes "$ROUTES4" || die 'Only IPv4 CIDRs, e.g. 0.0.0.0/0 or 10.0.0.0/8, are supported here.'
  ask ALLOW_LAN 'Allow VPN clients to reach private LAN ranges? (yes/no)' no
  [[ "$ALLOW_LAN" == yes || "$ALLOW_LAN" == no ]] || die 'Answer yes or no for LAN access.'
  if [[ "$ALLOW_LAN" == yes ]]; then warn 'LAN access allowed if the server has a route and the destination can return traffic; apply separate LAN policy if needed.'; fi
  ask ALLOW_HOST 'Allow VPN clients to reach services running on this server? (yes/no)' no
  [[ "$ALLOW_HOST" == yes || "$ALLOW_HOST" == no ]] || die 'Answer yes or no for server access.'
  if [[ "$ALLOW_HOST" == yes ]]; then warn 'Server access enabled; any listening service may be reachable from VPN clients.'; fi
  ALLOW_DNS_ONLY=no
  if [[ "$ALLOW_LAN" == no ]] && { needs_lan_dns_exception "$DNS1" || needs_lan_dns_exception "$DNS2"; }; then
    warn 'A private LAN DNS resolver was specified, but general private-LAN access is denied.'
    warn 'A DNS-only exception (TCP/UDP 53) may work if routing and return paths exist.'
    ask ALLOW_DNS_ONLY 'Allow private DNS resolver(s) only on TCP/UDP 53? (yes/no)' yes
    [[ "$ALLOW_DNS_ONLY" == yes || "$ALLOW_DNS_ONLY" == no ]] || die 'Answer yes or no for DNS-only access.'
    [[ "$ALLOW_DNS_ONLY" == yes ]] || die 'Private DNS would be blocked; change DNS servers or allow a DNS-only exception.'
  fi
  if { is_host_dns "$DNS1" || is_host_dns "$DNS2"; } && [[ "$ALLOW_HOST" == no ]]; then
    warn 'A DNS resolver address belongs to this server; only TCP/UDP 53 will be allowed to that host address.'
  fi
  IPV6_ENABLED=no
  PREFIX6=''
  if has_global_ipv6 "$PUB_IF"; then
    ask answer 'Enable IPv6 through WireGuard? Uses IPv6 NAT66 (yes/no)' no
    if [[ "$answer" == yes ]]; then
      IPV6_ENABLED=yes
    elif [[ "$answer" != no ]]; then die 'Answer yes or no.'; fi
  else
    say 'No suitable native global IPv6 default route detected.'
  fi
  # If this is a full-tunnel IPv4 configuration, don't leave native client
  # IPv6 internet traffic going around the VPN. Route it into wg and drop it
  # unless the server explicitly enables working IPv6 egress above.
  if [[ "$IPV6_ENABLED" == no && "$ROUTES4" == *'/0'* ]]; then
    [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1) == 0 ]] ||
      die 'Kernel IPv6 is disabled: cannot install IPv6 leak-blocking tunnel address.'
    IPV6_ENABLED=block
    say 'IPv6 safety mode: client IPv6 is tunneled and BLOCKED (not leaked outside VPN).'
  fi
  if [[ "$IPV6_ENABLED" != no ]]; then PREFIX6=$(random_ula_prefix); fi
  if [[ "$IPV6_ENABLED" == no ]]; then
    say 'Split-tunnel IPv4 mode: client IPv6 follows the normal client network.'
  fi
  suggested_ssh=$(ssh_ports)
  [[ -n "$suggested_ssh" ]] || suggested_ssh=22
  ask SSH_PORTS 'SSH TCP port(s) to protect in UFW (comma-separated)' "$suggested_ssh"
  # Validate every SSH port before touching UFW.
  local port_item arr
  IFS=',' read -r -a arr <<<"$SSH_PORTS"
  for port_item in "${arr[@]}"; do valid_port "${port_item//[[:space:]]/}" || die "Invalid SSH port: $port_item"; done
  say ''
  say "Interface: $IFACE | Public: $PUB_IF | UDP: $PORT | Endpoint: $ENDPOINT_HOST"
  say "VPN: $SUBNET4 | Server: $SERVER4 | DNS: $DNS1, $DNS2 | IPv6: $IPV6_ENABLED"
  say "Access: private LAN=$ALLOW_LAN, VPN server=$ALLOW_HOST, DNS-only=$ALLOW_DNS_ONLY"
  say 'The installer will install packages, adjust UFW, enable forwarding and start WireGuard.'
  say 'Existing non-UFW firewall rules and any router port-forwarding must be managed separately.'
  confirm_exact 'Proceed with installation' INSTALL

  UFW_PREVIOUS_ACTIVE=no
  if ufw_active; then UFW_PREVIOUS_ACTIVE=yes; fi
  UFW_SERVICE_PREVIOUS_ENABLED=no
  if ufw_service_enabled; then UFW_SERVICE_PREVIOUS_ENABLED=yes; fi
  PREV_ROUTED_POLICY=$(ufw_routed_policy)
  UFW_IPV6_PREVIOUS=$(ufw_ipv6_value)
  UFW_IPV6_CHANGED=no
  if [[ "$IPV6_ENABLED" != no && "$UFW_IPV6_PREVIOUS" != yes ]]; then
    warn "IPv6 safety mode needs UFW IPv6=yes; currently ${UFW_IPV6_PREVIOUS}."
    warn 'This changes filtering for ALL host IPv6 services (including existing inbound IPv6 connections).'
    warn 'Confirm existing IPv6 services are permitted in UFW before authorizing.'
    if [[ "$UFW_PREVIOUS_ACTIVE" == yes ]]; then
      confirm_exact 'Authorize enabling UFW IPv6 filtering for the entire server' ENABLE-IPV6
    else
      confirm_exact 'Authorize enabling IPv6 filtering when UFW starts' ENABLE-IPV6
    fi
    UFW_IPV6_CHANGED=yes
  fi
  if [[ "$UFW_PREVIOUS_ACTIVE" == yes && "$PREV_ROUTED_POLICY" != deny && "$PREV_ROUTED_POLICY" != reject ]]; then
    warn "Active UFW routed policy is '$PREV_ROUTED_POLICY'. Setting it to deny may affect other forwarded networks."
    confirm_exact 'Authorize changing the UFW default routed policy to deny' CHANGE
  fi
  if [[ "$UFW_PREVIOUS_ACTIVE" == no ]]; then
    warn 'UFW is currently INACTIVE. Enabling it can disconnect sessions not covered by firewall rules.'
    confirm_exact 'Authorize enabling UFW (SSH ports above will be allowed first)' ENABLE
  fi
  PREV_IP_FORWARD=$(sysctl -n net.ipv4.ip_forward)
  PREV_IP6_FORWARD=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)
  PREV_ACCEPT_RA=$(sysctl -n "net.ipv6.conf.${PUB_IF}.accept_ra" 2>/dev/null || echo 0)
  mkdir -p "$WG_DIR" "$WG_DIR/clients"
  chmod 700 "$WG_DIR" "$WG_DIR/clients"
  BACKUP_DIR=$(mktemp -d /root/.wgufw-install-backup.XXXXXXXX)
  for file in /etc/ufw/before.rules /etc/ufw/before6.rules /etc/ufw/user.rules /etc/ufw/user6.rules /lib/ufw/user.rules /lib/ufw/user6.rules /var/lib/ufw/user.rules /var/lib/ufw/user6.rules /usr/lib/ufw/user.rules /usr/lib/ufw/user6.rules /etc/default/ufw /etc/ufw/ufw.conf /etc/ufw/sysctl.conf "$SYSCTL_FILE"; do backup_file "$file"; done
  ROLLBACK_ARMED=yes
  trap installation_exit_handler EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  check_ufw_sysctl_overrides
  if [[ "$IPV6_ENABLED" != no ]]; then
    [[ -f /etc/default/ufw ]] || die 'Missing /etc/default/ufw configuration.'
    if [[ "$(ufw_ipv6_value)" != yes ]]; then
      if grep -Eq '^IPV6[[:space:]]*=' /etc/default/ufw; then
        sed -i -E 's/^IPV6[[:space:]]*=.*/IPV6=yes/' /etc/default/ufw
      else
        printf '\nIPV6=yes\n' >>/etc/default/ufw
      fi
    fi
  fi
  make_server_config
  write_sysctl
  if [[ "$UFW_PREVIOUS_ACTIVE" == no ]]; then add_ssh_rules "$SSH_PORTS"; fi
  # Apply UFW protection first, avoiding an unfiltered period between firewalls.
  # Both firewalls may coexist briefly; reload UFW after stopping firewalld to
  # re-establish its chains/NAT in case firewalld changed shared netfilter state.
  configure_firewall
  stop_firewalld
  if [[ "$FIREWALLD_PREVIOUS_ACTIVE" == yes ]]; then
    ufw --force reload || die 'UFW reload failed after stopping firewalld.'
    ufw_active || die 'UFW is inactive after stopping firewalld.'
    nat_loaded iptables "$SUBNET4" "$IFACE-v4" ||
      die 'IPv4 NAT disappeared after stopping firewalld.'
    if [[ "$IPV6_ENABLED" == yes ]]; then
      nat_loaded ip6tables "${PREFIX6}::/64" "$IFACE-v6" ||
        die 'IPv6 NAT disappeared after stopping firewalld.'
    fi
  fi
  if [[ "$IPV6_ENABLED" != no && "$(ufw_ipv6_value)" != yes ]]; then
    die 'UFW IPv6 filtering is not enabled after configuration.'
  fi
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl enable ufw >/dev/null 2>&1 || die 'UFW service could not be enabled for boot persistence.'
  else
    rc-update add ufw default
    rc-update add sysctl boot || warn 'Could not confirm sysctl boot persistence on OpenRC.'
  fi
  service_start
  service_active || die 'WireGuard service did not start.'
  save_state
  ROLLBACK_ARMED=no
  trap - EXIT INT TERM
  rm -rf -- "$BACKUP_DIR"
  say ''
  say "Installed successfully. Server public key: $SERVER_PUBLIC_KEY"
  say "UDP $PORT must be reachable at $ENDPOINT_HOST."
  say "VPN subnet: $SUBNET4 (recorded in $STATE_FILE)"
  say ''
  add_client
}

read_server_public_key() {
  wg show "$IFACE" public-key 2>/dev/null ||
    { grep -m1 '^PrivateKey' "$WG_DIR/$IFACE.conf" | cut -d= -f2- | tr -d ' ' | wg pubkey; }
}
allocated_ip() { # detect exact /32 in server peer AllowedIPs
  local ip="$1" line val part
  local -a parts
  while IFS= read -r line; do
    [[ "$line" =~ ^AllowedIPs[[:space:]]*= ]] || continue
    val="${line#*=}"
    IFS=',' read -r -a parts <<<"$val"
    for part in "${parts[@]}"; do
      part="${part//[[:space:]]/}"
      [[ "$part" == "$ip/32" ]] && return 0
    done
  done <"$WG_DIR/$IFACE.conf"
  return 1
}
next_client_ip() {
  local host ip base="${SUBNET4%0/24}"
  while read -r host; do
    ip="${base}${host}"
    if ! allocated_ip "$ip"; then
      printf '%s %s\n' "$ip" "$host"
      return 0
    fi
  done < <(seq 2 254)
  return 1
}

sync_server_config() {
  local stripped
  stripped=$(mktemp "$WG_DIR/.wg-strip.XXXXXX") || return 1
  # Do not pass process substitutions to wg syncconf: errors in wg-quick strip
  # can otherwise go unnoticed, potentially loading an empty peer config.
  if ! wg-quick strip "$IFACE" >"$stripped"; then
    rm -f "$stripped"
    return 1
  fi
  if ! wg syncconf "$IFACE" "$stripped"; then
    rm -f "$stripped"
    return 1
  fi
  rm -f "$stripped"
}

add_client() {
  local name ip host clientpriv clientpub psk serverpub tmpbackup path endpoint_string routes peer_allowed
  command -v wg >/dev/null || die 'WireGuard tools missing.'
  ip link show dev "$IFACE" >/dev/null 2>&1 || die 'WireGuard interface is not up; fix the service first.'
  ask name 'New client name (1–15 letters/numbers/_/-)' client1
  valid_client_name "$name" || die 'Invalid client name.'
  path="$WG_DIR/clients/$name.conf"
  [[ ! -e "$path" && ! -L "$path" ]] || die "Client $name already exists."
  ! grep -Fqx "# BEGIN WG-UFW CLIENT $name" "$WG_DIR/$IFACE.conf" || die "Client $name already exists."
  read -r ip host < <(next_client_ip) || die 'No unused client IPv4 addresses remain.'
  [[ -n "$ip" ]] || die 'No unused client IPv4 addresses remain.'
  clientpriv=$(wg genkey)
  clientpub=$(printf '%s\n' "$clientpriv" | wg pubkey)
  psk=$(wg genpsk)
  serverpub=$(read_server_public_key) || die 'Cannot determine server public key.'
  endpoint_string="$ENDPOINT_HOST"
  if [[ "$endpoint_string" == *:* ]]; then endpoint_string="[$endpoint_string]"; fi
  routes=$(dns_client_routes "$ROUTES4")
  if [[ "$IPV6_ENABLED" != no ]]; then routes="${routes}, ::/0"; fi
  {
    say '[Interface]'
    say "PrivateKey = $clientpriv"
    say "Address = $ip/32"
    if [[ "$IPV6_ENABLED" != no ]]; then say "Address = ${PREFIX6}::$(printf '%x' "$host")/128"; fi
    say "DNS = $DNS1, $DNS2"
    say ''
    say '[Peer]'
    say "PublicKey = $serverpub"
    say "PresharedKey = $psk"
    say "Endpoint = $endpoint_string:$PORT"
    say "AllowedIPs = $routes"
    say 'PersistentKeepalive = 25'
  } >"$path"
  chmod 600 "$path"
  tmpbackup=$(mktemp "$WG_DIR/.wg-backup.XXXXXX")
  cp -a "$WG_DIR/$IFACE.conf" "$tmpbackup"
  peer_allowed="$ip/32"
  if [[ "$IPV6_ENABLED" != no ]]; then peer_allowed+=", ${PREFIX6}::$(printf '%x' "$host")/128"; fi
  {
    say ''
    say "# BEGIN WG-UFW CLIENT $name"
    say '[Peer]'
    say "PublicKey = $clientpub"
    say "PresharedKey = $psk"
    say "AllowedIPs = $peer_allowed"
    say "# END WG-UFW CLIENT $name"
  } >>"$WG_DIR/$IFACE.conf"
  # Use a separate command here: reliable errors and rollback are critical.
  if ! sync_server_config; then
    mv -f "$tmpbackup" "$WG_DIR/$IFACE.conf"
    sync_server_config || warn 'Could not restore the previous running peer configuration.'
    rm -f "$path"
    die 'Failed to activate new peer; server config restored.'
  fi
  rm -f "$tmpbackup"
  say "Client $name created: $ip | configuration: $path (root-readable only)"
  if command -v qrencode >/dev/null; then
    say 'Scan this WireGuard QR code on the client device:'
    qrencode -t ansiutf8 -l L <"$path" || warn 'QR output failed; client file was created.'
  fi
  say 'Keep client .conf files private; they contain keys.'
}

list_clients() {
  local any=0 name
  say 'Clients:'
  for name in "$WG_DIR"/clients/*.conf; do
    [[ -e "$name" ]] || continue
    any=1
    printf '  %s\n' "${name##*/}"
  done
  ((any == 1)) || say '  (none)'
}

revoke_client() {
  local name path backup tmp
  list_clients
  ask name 'Client name to revoke' ''
  valid_client_name "$name" || die 'Invalid name.'
  path="$WG_DIR/clients/$name.conf"
  [[ -f "$path" ]] || die 'Client does not exist.'
  grep -Fqx "# BEGIN WG-UFW CLIENT $name" "$WG_DIR/$IFACE.conf" || die 'Server peer marker not found; not touching config.'
  confirm_exact "Remove client $name (revocation cannot be undone)" REVOKE
  backup=$(mktemp "$WG_DIR/.wg-backup.XXXXXX")
  cp -a "$WG_DIR/$IFACE.conf" "$backup"
  tmp=$(mktemp "$WG_DIR/.wg-new.XXXXXX")
  awk -v begin="# BEGIN WG-UFW CLIENT $name" -v end="# END WG-UFW CLIENT $name" \
    '$0 == begin {drop=1; next} $0 == end && drop {drop=0; next} !drop {print}' \
    "$WG_DIR/$IFACE.conf" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$WG_DIR/$IFACE.conf"
  if ! sync_server_config; then
    mv -f "$backup" "$WG_DIR/$IFACE.conf"
    sync_server_config || warn 'Could not restore the previous running peer configuration.'
    die 'Peer synchronization failed; server config restored.'
  fi
  rm -f "$backup" "$path"
  say "Revoked $name. Any copies of its client .conf must also be deleted manually."
}

ufw_rule_owned() {
  local rules line marker="wgufw-${IFACE}-${1}"
  rules=$(ufw show added 2>/dev/null) || return 1
  while IFS= read -r line; do
    [[ "$line" == *"comment '$marker'"* || "$line" == *"comment \"$marker\""* ||
      "$line" == *"comment $marker" ]] && return 0
  done <<<"$rules"
  return 1
}
remove_ufw_rules_by_comment() {
  # 'ufw show added' includes command lines, even on older UFW releases
  # where 'ufw status' omits comments. Avoid removing a preexisting generic rule.
  local tag
  for tag in listen hostdeny hostallow metadata private10 private172 private192 private100 v4 host6deny host6allow local6 private6 v6 v6-block dns1-udp dns1-tcp dns2-udp dns2-tcp hostdns1-udp hostdns1-tcp hostdns2-udp hostdns2-tcp; do
    if ! ufw_rule_owned "$tag"; then continue; fi
    case "$tag" in
      listen) ufw --force delete allow in on "$PUB_IF" to any port "$PORT" proto udp ;;
      hostdeny) ufw --force delete deny in on "$IFACE" from "$SUBNET4" ;;
      hostallow) ufw --force delete allow in on "$IFACE" from "$SUBNET4" ;;
      metadata) ufw --force route delete deny in on "$IFACE" from "$SUBNET4" to 169.254.0.0/16 ;;
      private10) ufw --force route delete deny in on "$IFACE" from "$SUBNET4" to 10.0.0.0/8 ;;
      private172) ufw --force route delete deny in on "$IFACE" from "$SUBNET4" to 172.16.0.0/12 ;;
      private192) ufw --force route delete deny in on "$IFACE" from "$SUBNET4" to 192.168.0.0/16 ;;
      private100) ufw --force route delete deny in on "$IFACE" from "$SUBNET4" to 100.64.0.0/10 ;;
      v4) ufw --force route delete allow in on "$IFACE" out on "$PUB_IF" from "$SUBNET4" to any ;;
      host6deny) ufw --force delete deny in on "$IFACE" from "${PREFIX6}::/64" ;;
      host6allow) ufw --force delete allow in on "$IFACE" from "${PREFIX6}::/64" ;;
      local6) ufw --force route delete deny in on "$IFACE" from "${PREFIX6}::/64" to fe80::/10 ;;
      private6) ufw --force route delete deny in on "$IFACE" from "${PREFIX6}::/64" to fc00::/7 ;;
      v6) ufw --force route delete allow in on "$IFACE" out on "$PUB_IF" from "${PREFIX6}::/64" to any ;;
      v6-block) ufw --force route delete deny in on "$IFACE" from "${PREFIX6}::/64" to any ;;
      dns1-* | dns2-*)
        local n="${tag:3:1}" protocol="${tag##*-}" destination
        if [[ "$n" == 1 ]]; then destination="$DNS1"; else destination="$DNS2"; fi
        ufw --force route delete allow in on "$IFACE" from "$SUBNET4" to "$destination" port 53 proto "$protocol"
        ;;
      hostdns1-* | hostdns2-*)
        local n="${tag:7:1}" protocol="${tag##*-}" destination
        if [[ "$n" == 1 ]]; then destination="$DNS1"; else destination="$DNS2"; fi
        ufw --force delete allow in on "$IFACE" from "$SUBNET4" to "$destination" port 53 proto "$protocol"
        ;;
    esac
  done
  # SSH safety rules deliberately retained to avoid remote lockouts.
}

remove_server() {
  warn 'This stops WireGuard and removes installer-owned WireGuard configs/NAT/port rules.'
  warn 'UFW is left enabled; SSH safety rules from a first-time UFW activation are retained.'
  warn 'Other host firewall rules and current kernel forwarding settings stay unchanged.'
  confirm_exact "Remove $IFACE and its managed clients" UNINSTALL
  service_stop
  remove_ufw_rules_by_comment
  remove_nat_block /etc/ufw/before.rules "$IFACE-v4"
  if [[ "$IPV6_ENABLED" == yes ]]; then remove_nat_block /etc/ufw/before6.rules "$IFACE-v6"; fi
  ufw --force reload
  if [[ "$IPV6_ENABLED" == yes ]]; then
    remove_live_nat "$SUBNET4" "$PREFIX6"
  else
    remove_live_nat "$SUBNET4"
  fi
  rm -f -- "$SYSCTL_FILE"
  # Restore only the interface-specific RA setting we set to 2, if unchanged.
  if [[ "$IPV6_ENABLED" == yes && "$PREV_ACCEPT_RA" =~ ^[012]$ ]]; then
    local current_ra
    current_ra=$(sysctl -n "net.ipv6.conf.${PUB_IF}.accept_ra" 2>/dev/null || :)
    if [[ "$current_ra" == 2 ]]; then
      sysctl -q -w "net.ipv6.conf.${PUB_IF}.accept_ra=$PREV_ACCEPT_RA" || warn 'Could not restore original IPv6 RA setting.'
    else
      warn 'IPv6 RA setting changed since installation; leaving its runtime value untouched.'
    fi
  fi
  # Restoring IPv6=no globally is dangerous: user must explicitly approve.
  if [[ "$UFW_IPV6_CHANGED" == yes && "$UFW_IPV6_PREVIOUS" != yes && "$(ufw_ipv6_value)" == yes ]]; then
    warn "This installation originally changed UFW IPV6=${UFW_IPV6_PREVIOUS} to yes."
    warn 'Restoring the prior global setting could expose services over IPv6.'
    local restore_ipv6_answer
    ask restore_ipv6_answer 'Restore original global UFW IPv6 setting? (yes/no)' no
    if [[ "$restore_ipv6_answer" == yes ]]; then
      if [[ "$UFW_IPV6_PREVIOUS" == no ]]; then
        sed -i -E 's/^[[:space:]]*IPV6[[:space:]]*=.*/IPV6=no/' /etc/default/ufw
      else
        sed -i -E '/^[[:space:]]*IPV6[[:space:]]*=/d' /etc/default/ufw
      fi
      ufw --force reload || warn 'UFW IPv6 setting changed but reload failed; inspect manually.'
    fi
  fi
  if [[ "${FIREWALLD_PREVIOUS_ACTIVE:-no}" == yes ]]; then
    warn 'firewalld was active before installation; it has NOT been restored automatically.'
    warn 'Before switching back, migrate services/ports and carefully plan which firewall is active.'
  fi
  # Do not reset kernel forwarding or global UFW settings: other networks may rely on them.
  # No longer persist forwarding from this installer; reboot applies other system policy.
  # Only remove clients whose names have this installer's server peer markers.
  # A manually added file in clients/ must not be erased.
  local client_path client_name
  for client_path in "$WG_DIR"/clients/*.conf; do
    [[ -f "$client_path" ]] || continue
    client_name="${client_path##*/}"
    client_name="${client_name%.conf}"
    if valid_client_name "$client_name" && grep -Fqx "# BEGIN WG-UFW CLIENT $client_name" "$WG_DIR/$IFACE.conf"; then
      rm -f -- "$client_path"
    fi
  done
  rmdir "$WG_DIR/clients" 2>/dev/null || warn 'Non-client files left in /etc/wireguard/clients; preserved.'
  rm -f -- "$WG_DIR/$IFACE.conf" "$STATE_FILE"
  say 'Removed WireGuard installation. UFW and system-wide forwarding policy were preserved.'
  say 'Review global UFW IPv6/forwarding/default-routed policy; such settings may affect other services.'
}

main() {
  require_root
  require_os
  mkdir -p "$WG_DIR"
  if [[ -f "$STATE_FILE" ]]; then
    load_state
    say "Managed WireGuard server: $IFACE | $SUBNET4 | port $PORT"
    say '1) Add client   2) List clients   3) Revoke client   4) Uninstall   5) Exit'
    local option
    ask option 'Select an option' 5
    case "$option" in
      1) add_client ;;
      2) list_clients ;;
      3) revoke_client ;;
      4) remove_server ;;
      5) exit 0 ;;
      *) die 'Invalid option.' ;;
    esac
  else
    install_server
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
