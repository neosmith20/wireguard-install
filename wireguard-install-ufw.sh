#!/usr/bin/env bash
# WireGuard + UFW installer, v8.0 (multi-distribution review candidate)
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
# Client .conf files are saved root-only next to this script (or /root if piped).
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

# Prompts work like angristan's installer: the default is pre-filled and can be
# edited or accepted with Enter, and an invalid answer asks again instead of
# quitting. Without a terminal (scripted input) the default is shown in brackets.
prompt() { # VARIABLE LABEL DEFAULT [VALIDATOR] [ERROR_MESSAGE]
  local _pv="$1" _pl="$2" _pd="$3" _pc="${4:-}" _pe="${5:-Invalid answer, please try again.}" _pa
  while :; do
    if [[ -t 0 ]]; then
      read -r -e -i "$_pd" -p "${_pl}: " _pa || die 'Input ended.'
    elif [[ -n "$_pd" ]]; then
      read -r -p "${_pl} [${_pd}]: " _pa || die 'Input ended.'
    else
      read -r -p "${_pl}: " _pa || die 'Input ended.'
    fi
    # In a terminal the default is pre-filled, so an empty answer really is empty.
    [[ -t 0 ]] || _pa="${_pa:-$_pd}"
    if [[ -z "$_pc" ]] || "$_pc" "$_pa"; then
      printf -v "$_pv" '%s' "$_pa"
      return 0
    fi
    say "$_pe"
  done
}
prompt_yn() { # VARIABLE LABEL DEFAULT(y|n) -> sets VARIABLE to yes or no
  local _pv="$1" _pl="$2" _pd="$3" _pa
  while :; do
    if [[ -t 0 ]]; then
      read -r -e -i "$_pd" -p "${_pl} [y/n]: " _pa || die 'Input ended.'
    else
      read -r -p "${_pl} [y/n]: " _pa || die 'Input ended.'
    fi
    _pa="${_pa:-$_pd}"
    case "${_pa,,}" in
      y | yes)
        printf -v "$_pv" yes
        return 0
        ;;
      n | no)
        printf -v "$_pv" no
        return 0
        ;;
    esac
    say 'Please answer y or n.'
  done
}
press_any_key() {
  if [[ -t 0 ]]; then
    read -n1 -r -s -p 'Press any key to continue...' || die 'Input ended.'
  else
    read -r -p 'Press any key to continue...' || die 'Input ended.'
  fi
  say ''
}

# Client .conf files go next to this script, like angristan's installer puts
# them in the user's home folder. When the script is piped (curl | bash) there
# is no script file, so fall back to the sudo user's home folder, then /root.
client_output_dir() {
  local source="${BASH_SOURCE[0]:-}" dir home
  if [[ -n "$source" && -f "$source" && "$source" != /dev/* && "$source" != /proc/* ]]; then
    dir=$(cd -- "$(dirname -- "$source")" && pwd -P) && [[ -d "$dir" ]] && {
      printf '%s\n' "$dir"
      return 0
    }
  fi
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -n "$home" && -d "$home" ]]; then
      printf '%s\n' "$home"
      return 0
    fi
  fi
  printf '/root\n'
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
# Answer checkers for the install questions (each returns true when valid).
check_pub_if() { valid_iface "$1" && ip link show dev "$1" >/dev/null 2>&1; }
check_wg_if() {
  valid_iface "$1" && [[ "$1" != "$PUB_IF" ]] &&
    [[ ! -e "$WG_DIR/$1.conf" && ! -L "$WG_DIR/$1.conf" && ! -e "/sys/class/net/$1" ]]
}
check_server4() { # 10.x.y.1 whose 10.x.y.0/24 is unused on this server
  [[ "$1" =~ ^10\.[0-9]{1,3}\.[0-9]{1,3}\.1$ ]] && valid_10_24 "${1%1}0/24" && ! subnet_in_use "${1%1}0/24"
}
check_client_dns() {
  ipv4_integer "$1" >/dev/null || return 1
  [[ "$1" != 0.0.0.0 ]] || return 1
  ! cidr_overlap "$1/32" 127.0.0.0/8 && ! cidr_overlap "$1/32" 169.254.0.0/16 && ! cidr_overlap "$1/32" 224.0.0.0/4
}
check_client_dns2() { [[ -z "$1" ]] || check_client_dns "$1"; }
# AllowedIPs: IPv4 CIDRs, plus ::/0 (IPv6 is handled automatically, see install).
allowed_ips_to_routes4() { # prints the IPv4 part; fails on anything unsupported
  local item out=''
  local -a arr
  IFS=',' read -r -a arr <<<"$1"
  for item in "${arr[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] || continue
    [[ "$item" == ::/0 ]] && continue
    valid_cidr4 "$item" || return 1
    out+="${out:+,}$item"
  done
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}
check_allowed_ips() { allowed_ips_to_routes4 "$1" >/dev/null; }
check_new_client_name() {
  valid_client_name "$1" && ! client_exists "$1"
}

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

# Split tunnels: a client allowed onto the LAN also needs the LAN in its own
# AllowedIPs, or its LAN traffic never enters the tunnel. Add each private
# network this server reaches through its public interface (its home LAN).
lan_client_routes() { # ROUTES -> ROUTES plus uncovered private LAN networks
  local routes="$1" net route covered private
  local -a arr
  while read -r net; do
    valid_cidr4 "$net" || continue
    [[ "$net" != 0.0.0.0/0 ]] || continue
    private=no
    for route in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
      if cidr_overlap "$net" "$route" && ((${net##*/} >= ${route##*/})); then private=yes; fi
    done
    [[ "$private" == yes ]] || continue
    ! cidr_overlap "$net" "$SUBNET4" || continue
    covered=no
    IFS=',' read -r -a arr <<<"$routes"
    for route in "${arr[@]}"; do
      route="${route//[[:space:]]/}"
      if cidr_overlap "$net" "$route" && ((${net##*/} >= ${route##*/})); then
        covered=yes
        break
      fi
    done
    [[ "$covered" == no ]] || continue
    routes+=",$net"
  done < <(ip -4 route show dev "$PUB_IF" 2>/dev/null | awk '$1 ~ /\// {print $1}')
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
# WireGuard UFW installer v8 (state schema 4); root-owned; data only (never source this file)
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
  local priv
  priv=$(wg genkey)
  {
    say '[Interface]'
    say "Address = ${SERVER4}/24"
    if [[ "$IPV6_ENABLED" != no ]]; then say "Address = ${PREFIX6}::1/64"; fi
    say "ListenPort = $PORT"
    say "PrivateKey = $priv"
  } >"$WG_DIR/$IFACE.conf"
  chmod 600 "$WG_DIR/$IFACE.conf"
}

install_questions() {
  local suggested_if suggested_ip guess_net server4 dns2 allowed answer
  say 'Welcome to the WireGuard installer (UFW edition)!'
  say 'Based on https://github.com/angristan/wireguard-install'
  say ''
  say 'I need to ask you a few questions before starting the setup.'
  say 'You can keep the default options and just press enter if you are ok with them.'
  say ''
  suggested_if=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' | head -1)
  [[ -n "$suggested_if" ]] || die 'No default IPv4 route. Connect this server to the network first.'
  suggested_ip=$(ip -o -4 addr show dev "$suggested_if" scope global | awk '{split($4,a,"/");print a[1];exit}')
  if [[ -n "$suggested_ip" ]] && is_private_dns "$suggested_ip"; then
    say "Note: $suggested_ip is a private address, so this server is probably behind a router."
    say 'Enter your PUBLIC IP or a DNS name instead, and forward the WireGuard UDP port on your router.'
  fi
  prompt ENDPOINT_HOST 'IPv4 or IPv6 public address' "$suggested_ip" valid_endpoint \
    'Please enter an IP address or DNS name.'
  prompt PUB_IF 'Public interface' "$suggested_if" check_pub_if \
    'That network interface does not exist on this server.'
  prompt IFACE 'WireGuard interface name' wg0 check_wg_if \
    'Use up to 15 letters/numbers, different from the public interface and not already in use.'
  # Random, collision-checked VPN network; only generated on this first run.
  guess_net=$(pick_subnet) || die 'Unable to find a free 10.x.y.0/24 range; check existing routes.'
  prompt server4 'Server WireGuard IPv4' "${guess_net%0/24}1" check_server4 \
    'Use an address like 10.x.y.1 whose 10.x.y.0/24 network is not already used on this server.'
  SUBNET4="${server4%1}0/24"
  SERVER4="$server4"
  PORT=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
  PORT=$((49152 + PORT % 16384))
  prompt PORT 'Server WireGuard port [1-65535]' "$PORT" valid_port 'Please enter a port from 1 to 65535.'
  prompt DNS1 'First DNS resolver to use for the clients' 1.1.1.1 check_client_dns \
    'Please enter a usable IPv4 address, e.g. 1.1.1.1.'
  prompt dns2 'Second DNS resolver to use for the clients (optional)' 1.0.0.1 check_client_dns2 \
    'Please enter a usable IPv4 address, or leave it empty.'
  DNS2="${dns2:-$DNS1}"
  say ''
  say 'WireGuard uses a parameter called AllowedIPs to determine what is routed over the VPN.'
  prompt allowed 'Allowed IPs list for generated clients (leave default to route everything)' \
    '0.0.0.0/0,::/0' check_allowed_ips 'Please enter IPv4 ranges like 0.0.0.0/0 or 192.168.1.0/24 (plus ::/0).'
  ROUTES4=$(allowed_ips_to_routes4 "$allowed")
  IPV6_ENABLED=no
  PREFIX6=''
  if has_global_ipv6 "$PUB_IF"; then
    prompt_yn answer 'This server has IPv6. Give VPN clients IPv6 internet access too?' n
    [[ "$answer" == no ]] || IPV6_ENABLED=yes
  fi
  # Full tunnel without IPv6 internet: send client IPv6 into the tunnel and drop
  # it there, so it cannot leak around the VPN.
  if [[ "$IPV6_ENABLED" == no && "$ROUTES4" == *'/0'* ]]; then
    [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1) == 0 ]] ||
      die 'Kernel IPv6 is disabled, so client IPv6 cannot be blocked inside the tunnel. Enable IPv6 in the kernel and rerun.'
    IPV6_ENABLED=block
  fi
  if [[ "$IPV6_ENABLED" != no ]]; then PREFIX6=$(random_ula_prefix); fi
  say ''
  say 'Okay, that was all I needed. We are ready to setup your WireGuard server now.'
  say 'You will be able to generate a client at the end of the installation.'
  press_any_key
}

install_server() {
  [[ ! -e "$STATE_FILE" && ! -e "$WG_DIR/params" ]] || die 'Existing WireGuard installer state detected; refusing to overwrite it.'
  [[ ! -e "$SYSCTL_FILE" ]] || die "Refusing to overwrite an existing $SYSCTL_FILE"
  if { [[ "$INIT_SYSTEM" == systemd ]] && systemctl is-active --quiet nftables 2>/dev/null; } ||
    { [[ "$INIT_SYSTEM" == openrc ]] && rc-service nftables status >/dev/null 2>&1; }; then
    die 'The standalone nftables service is active. Disable it (or remove its rules) before using UFW.'
  fi
  # VPN clients reach this server's services; other LAN devices are blocked
  # unless allowed per client. DNS servers on the LAN are always reachable.
  ALLOW_LAN=no
  ALLOW_HOST=yes
  install_questions
  ALLOW_DNS_ONLY=no
  if needs_lan_dns_exception "$DNS1" || needs_lan_dns_exception "$DNS2"; then
    ALLOW_DNS_ONLY=yes
  fi

  install_packages
  local preexisting_rules suggested_ssh port_item ssh_ok=yes
  local -a arr
  preexisting_rules=$(ufw show added 2>/dev/null) || die 'Cannot inspect existing UFW rules.'
  if [[ "$preexisting_rules" == *"wgufw-$IFACE-"* ]]; then
    die "UFW already has rules from an earlier $IFACE install. Remove them (ufw status numbered) and rerun."
  fi
  FIREWALLD_PREVIOUS_ACTIVE=no
  if firewalld_active; then
    FIREWALLD_PREVIOUS_ACTIVE=yes
    warn 'firewalld is running. It will be turned off and replaced by UFW.'
    warn "These firewalld openings will NOT carry over: services: $(firewall-cmd --list-services 2>/dev/null || echo unknown); ports: $(firewall-cmd --list-ports 2>/dev/null || echo unknown)"
  fi
  # SSH is detected and allowed automatically so enabling UFW cannot lock you out.
  suggested_ssh=$(ssh_ports)
  IFS=',' read -r -a arr <<<"${suggested_ssh:-22}"
  for port_item in "${arr[@]}"; do valid_port "${port_item//[[:space:]]/}" || ssh_ok=no; done
  if [[ "$ssh_ok" == yes && -n "$suggested_ssh" ]]; then SSH_PORTS="$suggested_ssh"; else SSH_PORTS=22; fi

  UFW_PREVIOUS_ACTIVE=no
  if ufw_active; then UFW_PREVIOUS_ACTIVE=yes; fi
  UFW_SERVICE_PREVIOUS_ENABLED=no
  if ufw_service_enabled; then UFW_SERVICE_PREVIOUS_ENABLED=yes; fi
  PREV_ROUTED_POLICY=$(ufw_routed_policy)
  UFW_IPV6_PREVIOUS=$(ufw_ipv6_value)
  UFW_IPV6_CHANGED=no
  if [[ "$IPV6_ENABLED" != no && "$UFW_IPV6_PREVIOUS" != yes ]]; then
    warn 'Turning on UFW IPv6 filtering for this server (needed to keep client IPv6 inside the VPN).'
    UFW_IPV6_CHANGED=yes
  fi
  if [[ "$UFW_PREVIOUS_ACTIVE" == yes && "$PREV_ROUTED_POLICY" != deny && "$PREV_ROUTED_POLICY" != reject ]]; then
    warn "UFW's default for forwarded traffic was '$PREV_ROUTED_POLICY'; changing it to deny so only the VPN rules forward."
  fi
  if [[ "$UFW_PREVIOUS_ACTIVE" == no ]]; then
    say "Enabling UFW. SSH port(s) $SSH_PORTS will be allowed first so you stay connected."
  fi
  PREV_IP_FORWARD=$(sysctl -n net.ipv4.ip_forward)
  PREV_IP6_FORWARD=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)
  PREV_ACCEPT_RA=$(sysctl -n "net.ipv6.conf.${PUB_IF}.accept_ra" 2>/dev/null || echo 0)
  mkdir -p "$WG_DIR"
  chmod 700 "$WG_DIR"
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
  say "WireGuard is installed and running. VPN network: $SUBNET4, UDP port $PORT."
  if is_private_dns "$ENDPOINT_HOST" 2>/dev/null; then
    say "Remember to forward UDP port $PORT on your router to this server."
  fi
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

# Each client's peer block in the server config is wrapped in markers and
# records where its .conf file was saved and whether it may reach the LAN:
#   # BEGIN WG-UFW CLIENT name / # CLIENT-FILE path / # LAN-ACCESS yes|no
client_names() {
  awk '/^# BEGIN WG-UFW CLIENT / {print $5}' "$WG_DIR/$IFACE.conf"
}
client_exists() { # NAME: in the server config, or a file of that name already saved
  grep -Fqx "# BEGIN WG-UFW CLIENT $1" "$WG_DIR/$IFACE.conf" ||
    [[ -e "$CLIENT_DIR/${IFACE}-client-$1.conf" || -L "$CLIENT_DIR/${IFACE}-client-$1.conf" ]]
}
client_meta() { # NAME KEY -> value of "# KEY value" inside the client's block
  awk -v begin="# BEGIN WG-UFW CLIENT $1" -v end="# END WG-UFW CLIENT $1" -v key="# $2 " '
    $0 == begin {inblk=1; next} $0 == end {inblk=0}
    inblk && index($0, key) == 1 {print substr($0, length(key) + 1); exit}
  ' "$WG_DIR/$IFACE.conf"
}
client_addresses() { # NAME -> "IPv4 [IPv6]" from the client's server-side AllowedIPs
  local allowed item ip4='' ip6=''
  local -a arr
  allowed=$(awk -v begin="# BEGIN WG-UFW CLIENT $1" -v end="# END WG-UFW CLIENT $1" '
    $0 == begin {inblk=1; next} $0 == end {inblk=0}
    inblk && /^AllowedIPs[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}
  ' "$WG_DIR/$IFACE.conf")
  IFS=',' read -r -a arr <<<"$allowed"
  for item in "${arr[@]}"; do
    item="${item//[[:space:]]/}"
    case "$item" in
      */32) ip4="${item%/32}" ;;
      */128) ip6="${item%/128}" ;;
    esac
  done
  printf '%s %s\n' "$ip4" "$ip6"
}

# Per-client LAN access. LAN ranges are blocked for every client by the install
# rules; these prepended rules let one client through. Its route to the VPN
# subnet stays denied (and sits on top), so clients still can't reach each other.
client_lan_rules() { # add|delete NAME IPv4 [IPv6]
  local action="$1" name="$2" ip4="$3" ip6="${4:-}" range comment="wgufw-$IFACE-lan-$2"
  if [[ "$action" == add ]]; then
    for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
      ufw route prepend allow in on "$IFACE" from "$ip4" to "$range" comment "$comment" || return 1
    done
    ufw route prepend deny in on "$IFACE" from "$ip4" to "$SUBNET4" comment "$comment" || return 1
    if [[ "$IPV6_ENABLED" == yes && -n "$ip6" ]]; then
      ufw route prepend allow in on "$IFACE" from "$ip6" to fc00::/7 comment "$comment" || return 1
      ufw route prepend deny in on "$IFACE" from "$ip6" to "${PREFIX6}::/64" comment "$comment" || return 1
    fi
  else
    for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
      ufw --force route delete allow in on "$IFACE" from "$ip4" to "$range" >/dev/null 2>&1 || :
    done
    ufw --force route delete deny in on "$IFACE" from "$ip4" to "$SUBNET4" >/dev/null 2>&1 || :
    if [[ -n "$ip6" && -n "${PREFIX6:-}" ]]; then
      ufw --force route delete allow in on "$IFACE" from "$ip6" to fc00::/7 >/dev/null 2>&1 || :
      ufw --force route delete deny in on "$IFACE" from "$ip6" to "${PREFIX6}::/64" >/dev/null 2>&1 || :
    fi
  fi
}

# Delete a client's saved .conf, but only the file this installer wrote for it.
remove_client_file() { # NAME [PATH recorded in its block]
  local name="$1" path="${2:-}"
  [[ -n "$path" ]] || path=$(client_meta "$name" CLIENT-FILE)
  if [[ -z "$path" ]]; then path="$WG_DIR/clients/$name.conf"; fi # v7 and older
  case "${path##*/}" in
    "${IFACE}-client-${name}.conf" | "${name}.conf") ;;
    *) return 0 ;;
  esac
  if [[ -f "$path" && ! -L "$path" ]]; then rm -f -- "$path"; fi
}

add_client() {
  local name lan ip host clientpriv clientpub psk serverpub tmpbackup path endpoint_string routes peer_allowed mtu ip6=''
  command -v wg >/dev/null || die 'WireGuard tools missing.'
  ip link show dev "$IFACE" >/dev/null 2>&1 || die 'WireGuard interface is not up; fix the service first.'
  say ''
  say 'Client configuration'
  say ''
  say "The client name must consist of alphanumeric character(s). It may also include underscores or dashes and can't exceed 15 chars."
  prompt name 'Client name' '' check_new_client_name \
    'That name is not allowed or is already used. Please choose another name.'
  prompt_yn lan "Allow $name to reach devices on your home network (LAN)?" n
  read -r ip host < <(next_client_ip) || die 'No unused client IPv4 addresses remain.'
  [[ -n "$ip" ]] || die 'No unused client IPv4 addresses remain.'
  if [[ "$IPV6_ENABLED" != no ]]; then ip6="${PREFIX6}::$(printf '%x' "$host")"; fi
  clientpriv=$(wg genkey)
  clientpub=$(printf '%s\n' "$clientpriv" | wg pubkey)
  psk=$(wg genpsk)
  serverpub=$(read_server_public_key) || die 'Cannot determine server public key.'
  endpoint_string="$ENDPOINT_HOST"
  if [[ "$endpoint_string" == *:* ]]; then endpoint_string="[$endpoint_string]"; fi
  routes="$ROUTES4"
  if [[ "$lan" == yes ]]; then routes=$(lan_client_routes "$routes"); fi
  routes=$(dns_client_routes "$routes")
  if [[ "$IPV6_ENABLED" != no ]]; then routes="${routes}, ::/0"; fi
  path="$CLIENT_DIR/${IFACE}-client-${name}.conf"
  mtu=$(server_mtu)
  [[ -z "$mtu" || "$mtu" =~ ^[0-9]+$ ]] || mtu=''
  {
    say '[Interface]'
    say "PrivateKey = $clientpriv"
    say "Address = $ip/32"
    if [[ -n "$ip6" ]]; then say "Address = ${ip6}/128"; fi
    say "DNS = $DNS1, $DNS2"
    if [[ -n "$mtu" ]]; then say "MTU = $mtu"; fi
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
  if [[ -n "$ip6" ]]; then peer_allowed+=", ${ip6}/128"; fi
  {
    say ''
    say "# BEGIN WG-UFW CLIENT $name"
    say "# CLIENT-FILE $path"
    say "# LAN-ACCESS $lan"
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
  if [[ "$lan" == yes ]] && ! client_lan_rules add "$name" "$ip" "$ip6" >/dev/null; then
    client_lan_rules delete "$name" "$ip" "$ip6"
    mv -f "$tmpbackup" "$WG_DIR/$IFACE.conf"
    sync_server_config || warn 'Could not restore the previous running peer configuration.'
    rm -f "$path"
    die 'Failed to add the LAN access rules; client not created.'
  fi
  rm -f "$tmpbackup"
  if command -v qrencode >/dev/null; then
    say ''
    say 'Here is your client config file as a QR Code:'
    qrencode -t ansiutf8 -l L <"$path" || warn 'QR output failed; the client file was still created.'
    say ''
  fi
  say "Your client config file is in $path"
  if [[ "$lan" == yes ]]; then say "$name can reach your LAN."; else say "$name can reach the internet and this server, but not your LAN."; fi
}

list_clients() {
  local names
  names=$(client_names)
  if [[ -z "$names" ]]; then
    say ''
    say 'You have no existing clients!'
    return 0
  fi
  printf '%s\n' "$names" | nl -s ') '
}

check_client_number() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= CLIENT_COUNT)); }

revoke_client() {
  local names number name lan ip4 ip6 backup tmp client_file
  names=$(client_names)
  if [[ -z "$names" ]]; then
    say ''
    say 'You have no existing clients!'
    exit 1
  fi
  CLIENT_COUNT=$(printf '%s\n' "$names" | wc -l)
  say ''
  say 'Select the existing client you want to revoke'
  printf '%s\n' "$names" | nl -s ') '
  if ((CLIENT_COUNT == 1)); then
    prompt number 'Select one client [1]' '' check_client_number 'Please enter 1.'
  else
    prompt number "Select one client [1-$CLIENT_COUNT]" '' check_client_number "Please enter a number from 1 to $CLIENT_COUNT."
  fi
  name=$(printf '%s\n' "$names" | sed -n "$((10#$number))p")
  valid_client_name "$name" || die 'Invalid client entry in the server config.'
  lan=$(client_meta "$name" LAN-ACCESS)
  client_file=$(client_meta "$name" CLIENT-FILE)
  read -r ip4 ip6 < <(client_addresses "$name")
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
  rm -f "$backup"
  remove_client_file "$name" "$client_file"
  if [[ "$lan" == yes && -n "$ip4" ]]; then client_lan_rules delete "$name" "$ip4" "$ip6"; fi
  say "Client $name revoked."
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
  local remove name lan ip4 ip6
  say ''
  warn 'This will uninstall WireGuard and remove all the configuration files!'
  say "Please backup the $WG_DIR directory and your client files if you want to keep your configuration files."
  say ''
  prompt_yn remove 'Do you really want to remove WireGuard?' n
  if [[ "$remove" != yes ]]; then
    say ''
    say 'Removal aborted!'
    return 0
  fi
  service_stop
  # Per-client LAN rules and saved client files, recorded in each peer block.
  while IFS= read -r name; do
    if [[ -z "$name" ]] || ! valid_client_name "$name"; then continue; fi
    lan=$(client_meta "$name" LAN-ACCESS)
    read -r ip4 ip6 < <(client_addresses "$name")
    if [[ "$lan" == yes && -n "$ip4" ]]; then client_lan_rules delete "$name" "$ip4" "$ip6"; fi
    remove_client_file "$name"
  done < <(client_names)
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
    fi
  fi
  # Put UFW's IPv6 setting back the way it was before this installer changed it.
  if [[ "$UFW_IPV6_CHANGED" == yes && "$UFW_IPV6_PREVIOUS" != yes && "$(ufw_ipv6_value)" == yes ]]; then
    if [[ "$UFW_IPV6_PREVIOUS" == no ]]; then
      sed -i -E 's/^[[:space:]]*IPV6[[:space:]]*=.*/IPV6=no/' /etc/default/ufw
    else
      sed -i -E '/^[[:space:]]*IPV6[[:space:]]*=/d' /etc/default/ufw
    fi
    ufw --force reload || warn 'UFW IPv6 setting restored but reload failed; check "ufw status".'
    say "Restored UFW's original IPv6 setting."
  fi
  if [[ "${FIREWALLD_PREVIOUS_ACTIVE:-no}" == yes ]]; then
    warn 'firewalld was running before installation and is still turned off; UFW stays in charge.'
  fi
  # Client files from v7 and older lived in /etc/wireguard/clients.
  local client_path client_name
  for client_path in /etc/wireguard/clients/*.conf; do
    [[ -f "$client_path" ]] || continue
    client_name="${client_path##*/}"
    client_name="${client_name%.conf}"
    if valid_client_name "$client_name" && grep -Fqx "# BEGIN WG-UFW CLIENT $client_name" "$WG_DIR/$IFACE.conf"; then
      rm -f -- "$client_path"
    fi
  done
  rmdir /etc/wireguard/clients 2>/dev/null || :
  remove_wire_seek
  [[ -n "$IFACE" ]] || die 'Interface name missing; refusing to delete files.'
  rm -f -- "/etc/wireguard/$IFACE.conf" "$STATE_FILE"
  say ''
  say 'WireGuard uninstalled successfully. UFW stays enabled (your SSH rule is kept).'
}

# ---- MTU finder: wire-seek (https://github.com/yeya/wire-seek, MIT) ----
# Pinned release with built-in checksums: only this exact, verified build runs.
readonly WIRE_SEEK_VERSION=v0.4.0
readonly WIRE_SEEK_BIN=/usr/local/bin/wire-seek
wire_seek_sha256() { # ARCH -> expected sha256 of the release binary
  case "$1" in
    amd64) printf '92fe0fd295fe09f8f08be11a2cff604f812892de76b044e6f7d36cb95059de9d\n' ;;
    arm64) printf '4cd57b8305d6219fbeea01dfa32471c51fd68ce445fa54f2c16431dfa63f8bda\n' ;;
    *) return 1 ;;
  esac
}
wire_seek_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}
wire_seek_ours() { # true if the installed binary is the pinned build
  local arch
  arch=$(wire_seek_arch) || return 1
  [[ -f "$WIRE_SEEK_BIN" ]] && [[ "$(sha256sum "$WIRE_SEEK_BIN" | cut -d' ' -f1)" == "$(wire_seek_sha256 "$arch")" ]]
}
wire_seek_fail() { # TMPFILE MESSAGE
  [[ -n "$1" && -f "$1" ]] && rm -f -- "$1"
  warn "$2"
  return 1
}
ensure_wire_seek() {
  local arch expected tmp url
  wire_seek_ours && return 0
  if [[ -e "$WIRE_SEEK_BIN" ]]; then
    warn "$WIRE_SEEK_BIN exists but is not wire-seek $WIRE_SEEK_VERSION; leaving it alone."
    return 1
  fi
  arch=$(wire_seek_arch) || {
    warn "wire-seek has no build for this CPU ($(uname -m)); it supports amd64 and arm64."
    return 1
  }
  expected=$(wire_seek_sha256 "$arch")
  if [[ "$DISTRO" == alpine ]]; then
    # The release binary is built against glibc; Alpine needs the compatibility layer.
    apk add gcompat >/dev/null || {
      warn 'Could not install gcompat, which wire-seek needs on Alpine.'
      return 1
    }
  fi
  url="https://github.com/yeya/wire-seek/releases/download/${WIRE_SEEK_VERSION}/wire-seek-linux-${arch}"
  tmp=$(mktemp /tmp/wire-seek.XXXXXX)
  say "Downloading wire-seek $WIRE_SEEK_VERSION..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url" || wire_seek_fail "$tmp" 'Download failed. Check this server can reach github.com.' || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url" || wire_seek_fail "$tmp" 'Download failed. Check this server can reach github.com.' || return 1
  else
    wire_seek_fail "$tmp" 'Neither curl nor wget is installed, so wire-seek cannot be downloaded.' || return 1
  fi
  if [[ "$(sha256sum "$tmp" | cut -d' ' -f1)" != "$expected" ]]; then
    wire_seek_fail "$tmp" 'The downloaded wire-seek did not match its known checksum; it was deleted and NOT run.' || return 1
  fi
  install -m 755 "$tmp" "$WIRE_SEEK_BIN"
  rm -f -- "$tmp"
}
remove_wire_seek() { if wire_seek_ours; then rm -f -- /usr/local/bin/wire-seek; fi; }

server_mtu() { # prints the MTU set in the server config, if any
  awk '/^\[Interface\]/ {i=1; next} /^\[/ {i=0} i && /^MTU[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$WG_DIR/$IFACE.conf"
}
set_conf_mtu() { # FILE MTU: set or add "MTU = N" in the [Interface] section
  local file="$1" mtu="$2" tmp
  tmp=$(mktemp "${file}.XXXXXX")
  awk -v mtu="$mtu" '
    /^\[Interface\]/ {print; i=1; next}
    i && /^MTU[[:space:]]*=/ {next}
    i && (/^\[/ || /^$/) && !done {print "MTU = " mtu; done=1; i=0}
    {print}
    END {if (i && !done) print "MTU = " mtu}
  ' "$file" >"$tmp"
  chmod --reference="$file" "$tmp"
  chown --reference="$file" "$tmp"
  mv -f "$tmp" "$file"
}
check_mtu_target() { valid_endpoint "$1"; }

find_best_mtu() {
  local target default_target='1.1.1.1' out mtu apply update name file count=0 endpoint pub
  say ''
  say 'wire-seek finds the best MTU (packet size) for the tunnel by testing the'
  say 'network path from this server to a target. The best target is the public IP'
  say "of one of your clients; 1.1.1.1 measures this server's own internet path."
  ensure_wire_seek || return 0
  # Offer a connected client's public IP as the default target.
  while read -r pub endpoint; do
    [[ "$endpoint" == "(none)" || -z "$endpoint" ]] && continue
    name=$(awk -v key="$pub" '/^# BEGIN WG-UFW CLIENT / {n=$5} /^PublicKey[[:space:]]*=/ {v=$0; sub(/^[^=]*=[[:space:]]*/, "", v); if (v == key) {print n; exit}}' "$WG_DIR/$IFACE.conf")
    endpoint="${endpoint%:*}"
    endpoint="${endpoint#[}"
    endpoint="${endpoint%]}"
    say "  Connected client ${name:-?} is at $endpoint"
    [[ "$default_target" == 1.1.1.1 ]] && default_target="$endpoint"
  done < <(wg show "$IFACE" endpoints 2>/dev/null)
  prompt target 'Target to test' "$default_target" check_mtu_target 'Please enter an IP address or DNS name.'
  say ''
  if ! out=$("$WIRE_SEEK_BIN" -max-mtu 1500 "$target" 2>&1); then
    say "$out"
    say ''
    say 'wire-seek could not finish. The target may not answer pings; try 1.1.1.1 instead.'
    return 0
  fi
  say "$out"
  mtu=$(sed -n -E 's/^[[:space:]]*MTU = ([0-9]+)[[:space:]]*$/\1/p' <<<"$out" | tail -n1)
  if [[ ! "$mtu" =~ ^[0-9]+$ ]] || ((mtu < 1280 || mtu > 1500)); then
    say 'wire-seek did not report a usable MTU (WireGuard needs 1280-1500); nothing changed.'
    return 0
  fi
  say ''
  prompt_yn apply "Use MTU $mtu for this server and for new clients?" y
  [[ "$apply" == yes ]] || return 0
  set_conf_mtu "$WG_DIR/$IFACE.conf" "$mtu"
  ip link set dev "$IFACE" mtu "$mtu" || warn 'Saved, but could not apply the MTU live; it applies on next restart.'
  say "Server MTU set to $mtu. New clients will get MTU = $mtu."
  while IFS= read -r name; do
    file=$(client_meta "$name" CLIENT-FILE)
    [[ -n "$file" && -f "$file" ]] && count=$((count + 1))
  done < <(client_names)
  if ((count > 0)); then
    prompt_yn update "Also update your $count existing client file(s)?" y
    if [[ "$update" == yes ]]; then
      while IFS= read -r name; do
        file=$(client_meta "$name" CLIENT-FILE)
        [[ -n "$file" && -f "$file" ]] || continue
        set_conf_mtu "$file" "$mtu"
        say "  Updated $file"
      done < <(client_names)
      say 'Re-import each updated file (or re-scan its QR code) on its device for the change to take effect.'
    fi
  fi
}

check_menu_option() { [[ "$1" =~ ^[1-6]$ ]]; }

main() {
  require_root
  require_os
  mkdir -p "$WG_DIR"
  CLIENT_DIR=$(client_output_dir)
  if [[ -f "$STATE_FILE" ]]; then
    load_state
    local option
    say 'Welcome to WireGuard-install (UFW edition)!'
    say ''
    say 'It looks like WireGuard is already installed.'
    say ''
    say 'What do you want to do?'
    say '   1) Add a new user'
    say '   2) List all users'
    say '   3) Revoke existing user'
    say '   4) Find the best MTU (wire-seek)'
    say '   5) Uninstall WireGuard'
    say '   6) Exit'
    prompt option 'Select an option [1-6]' '' check_menu_option 'Please enter a number from 1 to 6.'
    case "$option" in
      1) add_client ;;
      2) list_clients ;;
      3) revoke_client ;;
      4) find_best_mtu ;;
      5) remove_server ;;
      6) exit 0 ;;
    esac
  else
    install_server
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
