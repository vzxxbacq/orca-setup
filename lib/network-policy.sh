# shellcheck shell=bash disable=SC2034 # parsed NET_* variables are consumed by the host renderer and gateway
# Credential-free network policy parsing, shared by the host renderer and the gateway. Never source an env file.

network_ipv4() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
  local part
  local IFS=.
  for part in $1; do [ "$part" -le 255 ] || return 1; done
  [ "${1%%.*}" -gt 0 ] && [ "${1%%.*}" -lt 224 ] && [ "${1%%.*}" -ne 127 ]
}

network_private_cidr() {
  local address=${1%/*} prefix=${1##*/}
  [[ "$1" == */* ]] && [[ "$prefix" =~ ^([89]|[12][0-9]|3[0-2])$ ]] && network_ipv4 "$address" || return 1
  awk -v ip="$address" -v bits="$prefix" 'BEGIN {
    split(ip, a, "."); n = ((a[1]*256+a[2])*256+a[3])*256+a[4]; size = 2^(32-bits)
    private = (a[1] == 10 && bits >= 8) || (a[1] == 172 && a[2] >= 16 && a[2] <= 31 && bits >= 12) ||
      (a[1] == 192 && a[2] == 168 && bits >= 16) || (a[1] == 100 && a[2] >= 64 && a[2] <= 127 && bits >= 10)
    exit !(private && n % size == 0)
  }'
}

network_read_env() { # <file>; values deliberately never appear in validation errors
  local key value
  [ -r "$1" ] || { echo 'network policy file is missing or unreadable' >&2; return 1; }
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in '' | \#*) continue ;; esac
    case "$key" in
      proxy_type) NET_PROXY_TYPE=$value ;;
      proxy_address) NET_PROXY_ADDRESS=$value ;;
      proxy_port) NET_PROXY_PORT=$value ;;
      dns_address) NET_DNS_ADDRESS=$value ;;
      dns_transport) NET_DNS_TRANSPORT=$value ;;
      dns_tls_name) NET_DNS_TLS_NAME=$value ;;
      executor_dns) NET_EXECUTOR_DNS=$value ;;
      control_subnet) NET_CONTROL_SUBNET=$value ;;
      proxy_auth_file) NET_PROXY_AUTH_FILE=$value ;;
      executor_mode) NET_EXEC_MODE=$value ;;
      internal_ssh) NET_INTERNAL_SSH=$value ;;
      *) echo 'network policy contains an unknown key (only the documented keys are allowed)' >&2; return 1 ;;
    esac
  done <"$1"
}

network_validate() {
  case "${NET_INTERNAL_SSH:-no}" in yes | no) ;; *) echo 'internal_ssh must be yes or no' >&2; return 1 ;; esac
  case "${NET_EXEC_MODE:-blocked}" in blocked | direct | proxy) ;; *) echo 'executor_mode must be blocked, direct or proxy' >&2; return 1 ;; esac
  if [ -n "${NET_PROXY_AUTH_FILE:-}" ]; then
    [[ "$NET_PROXY_AUTH_FILE" =~ ^/[A-Za-z0-9._/+@-]+$ ]] ||
      { echo 'proxy_auth_file must be an absolute path without shell or YAML syntax' >&2; return 1; }
    case "$NET_PROXY_AUTH_FILE/" in */../* | */./* | *//*) echo 'proxy_auth_file must have canonical path components' >&2; return 1 ;; esac
  fi
  case "$NET_PROXY_TYPE" in socks5 | http-connect) ;; *) echo 'proxy_type must be socks5 or http-connect' >&2; return 1 ;; esac
  network_ipv4 "$NET_PROXY_ADDRESS" || { echo 'proxy_address must be a reachable unicast IPv4 literal (no credentials or loopback)' >&2; return 1; }
  [[ "$NET_PROXY_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$NET_PROXY_PORT" -le 65535 ] ||
    { echo 'proxy_port must be between 1 and 65535' >&2; return 1; }
  network_ipv4 "$NET_DNS_ADDRESS" || { echo 'dns_address must be a unicast IPv4 literal' >&2; return 1; }
  case "${NET_DNS_TRANSPORT:-tcp}" in tcp | https) ;; *) echo 'dns_transport must be tcp or https' >&2; return 1 ;; esac
  if [ "${NET_DNS_TRANSPORT:-tcp}" = https ]; then
    [[ "${NET_DNS_TLS_NAME:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [ "${#NET_DNS_TLS_NAME}" -le 253 ] ||
      { echo 'dns_tls_name must be a valid TLS server name' >&2; return 1; }
  fi
  [ -z "$NET_EXECUTOR_DNS" ] || network_private_cidr "$NET_EXECUTOR_DNS/32" ||
    { echo 'executor_dns must be empty or a private IPv4 literal' >&2; return 1; }
  if ! [[ "$NET_CONTROL_SUBNET" == */24 ]] || ! network_private_cidr "$NET_CONTROL_SUBNET"; then
    echo 'control_subnet must be a canonical private IPv4 /24' >&2; return 1
  fi
  NET_ORCA_IP=${NET_CONTROL_SUBNET%.0/24}.2
  NET_EXECUTOR_IP=${NET_CONTROL_SUBNET%.0/24}.3
  # No recursive upstream or resolver in this stack's own control network.
  case "$NET_PROXY_ADDRESS" in "${NET_CONTROL_SUBNET%.0/24}".*) echo 'proxy_address overlaps control_subnet' >&2; return 1 ;; esac
  case "$NET_DNS_ADDRESS" in "${NET_CONTROL_SUBNET%.0/24}".*) echo 'dns_address overlaps control_subnet' >&2; return 1 ;; esac
  case "$NET_EXECUTOR_DNS" in "${NET_CONTROL_SUBNET%.0/24}".*) echo 'executor_dns overlaps control_subnet' >&2; return 1 ;; esac
}

network_validate_rules() { # <rows>: name<TAB>canonical private CIDR<TAB>tcp|udp<TAB>port
  local name cidr protocol port extra
  while IFS=$'\t' read -r name cidr protocol port extra; do
    case "$name" in '' | \#*) continue ;; esac
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] && [ -z "$extra" ] && network_private_cidr "$cidr" &&
      { [ "$protocol" = tcp ] || [ "$protocol" = udp ]; } &&
      [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] ||
      { echo 'executor allow rules require a name, canonical private CIDR, tcp/udp and a single port' >&2; return 1; }
  done <<<"$1"
}
