#!/usr/bin/env bash
# Firewall owner for a dedicated container network namespace, never the host's namespace.
# Applications join it without NET_ADMIN. Rules remain installed if the proxy dies: there is no direct fallback.
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=lib/network-policy.sh
. "$ROOT/lib/network-policy.sh"

load_policy() {
  local directory=${1:-/etc/orca-network} mode=${2:-orca}
  NET_EXEC_MODE=blocked
  if [ "$mode" = executor ] && [ -r "$directory/executor-policy.env" ]; then
    network_read_env "$directory/executor-policy.env"
  else
    network_read_env "$directory/policy.env"
  fi
  network_validate
  NET_RULES=$(cat "${1:-/etc/orca-network}/allow.tsv")
  network_validate_rules "$NET_RULES"
}

private_ranges() {
  printf '%s%s\n' 10 .0.0.0/8 172 .16.0.0/12 192 .168.0.0/16 100 .64.0.0/10 169 .254.0.0/16 127 .0.0.0/8
}

rules() {
  local mode=$1 name cidr protocol port
  cat <<'EOF'
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
EOF
  # Replace Docker's embedded-DNS NAT in this namespace as well: 127.0.0.11 must not be a DNS escape hatch.
  if [ "$mode" = orca ] || { [ "$mode" = executor ] && [ "$NET_EXEC_MODE" = proxy ]; }; then
    printf '%s\n' '-A OUTPUT -d 127.0.0.1/32 -j RETURN'
    printf -- '-A OUTPUT -p tcp -d %s/32 --dport %s -j RETURN\n' "$NET_PROXY_ADDRESS" "$NET_PROXY_PORT"
    if [ "$mode" = orca ]; then
      printf -- '-A OUTPUT -p tcp -d %s/32 --dport 7777 -j RETURN\n' "$NET_EXECUTOR_IP"
      if [ "${NET_INTERNAL_SSH:-no}" = yes ]; then
        printf -- '-A OUTPUT -p tcp -d %s/32 --dport 2222 -j RETURN\n' "$NET_EXECUTOR_IP"
      fi
    else
      while IFS= read -r cidr; do printf -- '-A OUTPUT -d %s -j RETURN\n' "$cidr"; done < <(private_ranges)
    fi
    printf '%s\n' '-A OUTPUT -p tcp -j REDIRECT --to-ports 12345'
  fi
  cat <<'EOF'
COMMIT
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -i lo -d 127.0.0.1/32 -j ACCEPT
# OUTPUT REDIRECT changes the destination before filtering, but the hook's output interface can still be eth0.
# Match the redirected loopback destination without an interface constraint; it cannot route to the public Internet.
-A OUTPUT -d 127.0.0.1/32 -j ACCEPT
EOF
  if [ "${NET_INTERNAL_SSH:-no}" = yes ]; then
    local self=$NET_ORCA_IP peer=$NET_EXECUTOR_IP
    if [ "$mode" = executor ]; then self=$NET_EXECUTOR_IP; peer=$NET_ORCA_IP; fi
    printf -- '-A INPUT -p tcp -s %s/32 -d %s/32 --dport 2222 -j ACCEPT\n' "$peer" "$self"
    printf -- '-A OUTPUT -p tcp -d %s/32 --dport 2222 -j ACCEPT\n' "$peer"
  fi
  if [ "$mode" = orca ]; then
    printf '%s\n' '-A INPUT -p tcp --dport 6768 -j ACCEPT'
    printf -- '-A OUTPUT -p tcp -d %s/32 --dport %s -j ACCEPT\n' "$NET_PROXY_ADDRESS" "$NET_PROXY_PORT"
    printf -- '-A OUTPUT -p tcp -d %s/32 --dport 7777 -j ACCEPT\n' "$NET_EXECUTOR_IP"
  else
    # The executor health probe connects to its own control address on lo (the server does not bind all interfaces).
    printf -- '-A INPUT -i lo -p tcp -s %s/32 -d %s/32 --dport 7777 -j ACCEPT\n' "$NET_EXECUTOR_IP" "$NET_EXECUTOR_IP"
    printf -- '-A OUTPUT -o lo -p tcp -d %s/32 --dport 7777 -j ACCEPT\n' "$NET_EXECUTOR_IP"
    printf -- '-A INPUT -p tcp -s %s/32 --dport 7777 -j ACCEPT\n' "$NET_ORCA_IP"
    printf -- '-A OUTPUT -p tcp -d %s/32 --dport 6768 -j ACCEPT\n' "$NET_ORCA_IP"
    if [ -n "$NET_EXECUTOR_DNS" ]; then
      for protocol in tcp udp; do
        printf -- '-A OUTPUT -p %s -d %s/32 --dport 53 -j ACCEPT\n' "$protocol" "$NET_EXECUTOR_DNS"
      done
    fi
    while IFS=$'\t' read -r name cidr protocol port; do
      [ -n "$name" ] || continue
      printf -- '-A OUTPUT -p %s -d %s --dport %s -j ACCEPT\n' "$protocol" "$cidr" "$port"
    done <<<"$NET_RULES"
    if [ "$NET_EXEC_MODE" = proxy ]; then
      printf -- '-A OUTPUT -p tcp -d %s/32 --dport %s -j ACCEPT\n' "$NET_PROXY_ADDRESS" "$NET_PROXY_PORT"
    elif [ "$NET_EXEC_MODE" = direct ]; then
      # Explicit private allow rules precede these denies; public IPv4 can use the host route.
      while IFS= read -r cidr; do printf -- '-A OUTPUT -d %s -j REJECT\n' "$cidr"; done < <(private_ranges)
      printf '%s\n' '-A OUTPUT -d 0.0.0.0/8 -j REJECT' '-A OUTPUT -d 224.0.0.0/4 -j REJECT' '-A OUTPUT -j ACCEPT'
    fi
  fi
  printf 'COMMIT\n'
}

firewall_digest() {
  { iptables-save -t nat; iptables-save -t filter; ip6tables-save -t filter; } |
    sed -E '/^#/d; s/\[[0-9]+:[0-9]+\]/[0:0]/g' | sha256sum | cut -d' ' -f1
}

policy_digest() {
  { sha256sum /etc/orca-network/policy.env /etc/orca-network/allow.tsv
    if [ -f /etc/orca-network/executor-policy.env ]; then sha256sum /etc/orca-network/executor-policy.env; fi
    if [ -f /run/secrets/orca_proxy_auth ]; then sha256sum /run/secrets/orca_proxy_auth; fi
  } | sha256sum | cut -d' ' -f1
}

check() {
  [ -r /tmp/network-ready ] && [ -r /tmp/network-digest ] || return 1
  [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 1 ] || return 1
  [ "$(firewall_digest)" = "$(cat /tmp/network-digest)" ] || return 1
  [ "$(policy_digest)" = "$(cat /tmp/network-policy-digest)" ] || return 1
  local pid
  while read -r pid; do [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null || return 1; done </tmp/network-ready
}

case "${1:-}" in
  check) check; exit ;;
  rules)
    case "${2:-}" in orca | executor) ;; *) exit 2 ;; esac
    load_policy "${3:-/etc/orca-network}" "$2"
    rules "$2"
    exit ;;
  orca | executor) mode=$1 ;;
  *) echo 'Usage: gateway.sh orca|executor|check|rules MODE [POLICY_DIR]' >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo 'Only the dedicated network gateway runs as root.' >&2; exit 1; }
umask 077
load_policy /etc/orca-network "$mode"
rm -f /tmp/network-ready /tmp/network-digest
# Close first; any subsequent failure leaves the namespace blocked. Applications start only after the healthcheck.
iptables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
ip6tables-restore --wait 5 <<'EOF'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
COMMIT
EOF
rules "$mode" >/tmp/network-rules
iptables-restore --wait 5 </tmp/network-rules
firewall_digest >/tmp/network-digest
policy_digest >/tmp/network-policy-digest

if [ "$mode" = executor ] && [ "$NET_EXEC_MODE" != proxy ]; then
  : >/tmp/network-ready
  exec sleep infinity
fi

policy=/etc/orca-network/policy.env
[ "$mode" != executor ] || policy=/etc/orca-network/executor-policy.env
python3 "$ROOT/docker/proxy-config.py" "$policy" /tmp/redsocks.conf
redsocks -t -c /tmp/redsocks.conf
pids=()
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  rm -f /tmp/network-ready
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT
while :; do
  redsocks -c /tmp/redsocks.conf &
  pids+=("$!")
  python3 "$ROOT/docker/dns-forwarder.py" "$NET_DNS_ADDRESS" "$NET_DNS_TRANSPORT" "$NET_DNS_TLS_NAME" &
  pids+=("$!")
  for _ in {1..50}; do
    alive=yes
    for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null || alive=no; done
    [ "$alive" = yes ] || break
    if ss -H -lnt 'sport = :12345' | grep -q . && ss -H -lnt 'sport = :53' | grep -q .; then
      printf '%s\n' "${pids[@]}" >/tmp/network-ready
      break
    fi
    sleep 0.1
  done
  if [ -f /tmp/network-ready ]; then wait -n "${pids[@]}" || true; fi
  # Keep the namespace, private control connection and firewall while restarting only the failed workers.
  cleanup
  pids=()
  sleep 1
done
