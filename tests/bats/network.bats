#!/usr/bin/env bats
# Isolated stack lifecycle and policy validation. Packet forwarding is exercised by tests/integration/network.sh.
load helpers

setup() {
  make_sandbox
  fake_linux
  fake_baseline_present
  fake_orca_linux
  fake_docker installed
  touch "$SB/docker/session-group"
  printf ' docker' >"$SB/groups"
  fake_registry ghcr.io/vzxxbacq/orca-server:main aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  fake_ip 203.0.113.10
  cp -R "$REPO_ROOT/manifest" "$SB/manifest"
  export ORCA_SETUP_MANIFEST_DIR=$SB/manifest
  mkdir -p "$SB/manifest/local"
  cat >"$SB/manifest/local/server-network.env" <<'EOF'
proxy_type=socks5
proxy_address=192.0.2.20
proxy_port=1080
EOF
  COMPOSE=$HOME/.config/orca-setup/docker/compose.yaml
}

apply_isolated() { run_setup --apply --role server --pairing-address 203.0.113.10 --network-mode isolated "$@"; }

@test "isolated plan is read-only and lists the elevated sidecars and policy prerequisites" {
  run_setup --plan --role server --network-mode isolated
  [ "$status" -eq 0 ]
  [[ "$output" == *'gateway sidecars run as root with NET_ADMIN'* ]]
  [[ "$output" == *'no direct public fallback'* ]]
  [ ! -d "$HOME/.config/orca-setup" ]
  [ ! -s "$FAKE_LOG" ]
  rm "$SB/manifest/local/server-network.env"
  run_setup --plan --role server --network-mode isolated
  [ "$status" -eq 0 ]
  [[ "$output" == *'missing  valid manifest/local/server-network.env'* ]]
}

@test "invalid isolated policies refuse before Docker, directories or shell evaluation" {
  printf 'proxy_address=$(touch %s)\n' "$SB/evaluated" >"$SB/manifest/local/server-network.env"
  apply_isolated
  [ "$status" -ne 0 ]
  [ ! -e "$SB/evaluated" ]
  [ ! -d "$HOME/.config/orca-setup" ]
  [ ! -s "$FAKE_LOG" ]
  printf 'password=DO-NOT-PRINT\n' >"$SB/manifest/local/server-network.env"
  apply_isolated
  [ "$status" -ne 0 ]
  [[ "$output" != *DO-NOT-PRINT* ]]
}

@test "executor exceptions require canonical private CIDRs and exact protocol/port" {
  local row
  for row in $'public\t0.0.0.0/0\ttcp\t443' $'public\t192.0.2.0/24\ttcp\t443' \
    $'hostbits\t172.20.1.1/24\ttcp\t443' $'wide\t172.20.0.0/16\tall\t443' \
    $'ports\t172.20.0.0/16\ttcp\t1:65535'; do
    printf '%s\n' "$row" >"$SB/manifest/local/server-network-allow.tsv"
    apply_isolated
    [ "$status" -ne 0 ]
    [ ! -s "$FAKE_LOG" ]
  done
}

@test "isolated stack shares work only with the executor and publishes only the private Orca endpoint" {
  printf 'repo\t172.20.0.0/16\ttcp\t443\n' >"$SB/manifest/local/server-network-allow.tsv"
  apply_isolated
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$(cat "$COMPOSE")" != *'@[A-Z_'* ]]
  grep -qF 'network_mode: "service:orca-gateway"' "$COMPOSE"
  grep -qF 'network_mode: "service:executor-gateway"' "$COMPOSE"
  [ "$(grep -c '^    ports:' "$COMPOSE")" -eq 1 ]
  grep -qF '"203.0.113.10:6768:6768/tcp"' "$COMPOSE"
  grep -qF '  network-mode: "isolated"' "$COMPOSE"
  grep -qF '    internal: true' "$COMPOSE"
  grep -qF '      HTTP_PROXY: ""' "$COMPOSE"
  ! sed -n '/^  orca-executor:/,/^networks:/p' "$COMPOSE" | grep -qE '\.orca|\.codex|\.claude|manifest-local'
  [ "$(cat "$HOME/.config/orca-setup/docker/network/orca-resolv.conf" | head -n 1)" = 'nameserver 127.0.0.1' ]
  [ -d "$HOME/.local/share/orca-setup/executor-home/orca" ]
}

@test "isolated mode persists, applies idempotently, and policy changes recreate donor namespaces" {
  apply_isolated
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local old
  old=$(cat "$COMPOSE")
  : >"$FAKE_LOG"
  run_setup --apply --role server --pairing-address 203.0.113.10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$COMPOSE")" = "$old" ]
  ! grep -q '^docker compose ' "$FAKE_LOG"
  printf 'repo\t172.20.0.0/16\ttcp\t443\n' >"$SB/manifest/local/server-network-allow.tsv"
  run_setup --apply --role server --pairing-address 203.0.113.10
  [ "$status" -eq 0 ]
  [ "$(cat "$COMPOSE")" != "$old" ]
  grep -q 'up --detach --force-recreate --remove-orphans' "$FAKE_LOG"
}

@test "a missing or unhealthy sidecar cannot be mistaken for a current running stack" {
  apply_isolated
  [ "$status" -eq 0 ]
  : >"$FAKE_LOG"
  touch "$SB/docker/missing-executor-gateway"
  apply_isolated
  [ "$status" -eq 0 ]
  grep -q 'up --detach --force-recreate' "$FAKE_LOG"
}

@test "isolated check reports policy drift and unhealthy gateways without changing the stack" {
  apply_isolated
  [ "$status" -eq 0 ]
  : >"$FAKE_LOG"
  run_setup --check --json
  [[ "$output" == *'"name": "Isolated network policy", "state": "present"'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'"network-mode": "isolated"'* ]]
  touch "$SB/docker/unhealthy-orca-gateway"
  printf 'proxy_port=8080\n' >>"$SB/manifest/local/server-network.env"
  run_setup --check --json
  [[ "$output" == *'STALE (network policy differs'* ]]
  [[ "$output" == *'UNREACHABLE (a gateway/executor is unhealthy'* ]]
  ! grep -q '^docker compose ' "$FAKE_LOG"
}

@test "changing topology explicitly stops the old port owner; an absent policy never enables direct fallback" {
  apply_isolated
  [ "$status" -eq 0 ]
  : >"$FAKE_LOG"
  rm "$SB/manifest/local/server-network.env"
  run_setup --apply --role server --pairing-address 203.0.113.10
  [ "$status" -ne 0 ]
  ! grep -q '^docker compose ' "$FAKE_LOG"
  run_setup --apply --role server --pairing-address 203.0.113.10 --network-mode direct
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q ' down$' "$FAKE_LOG"
  grep -q 'up --detach --remove-orphans' "$FAKE_LOG"
  ! grep -q network_mode "$COMPOSE"
}

@test "direct to isolated migration releases the published port before starting the gateway" {
  run_setup --apply --role server --pairing-address 203.0.113.10
  [ "$status" -eq 0 ]
  : >"$FAKE_LOG"
  apply_isolated
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local actions
  actions=$(grep '^docker compose ' "$FAKE_LOG")
  [[ "${actions%%$'\n'*}" == *' down' ]]
  [[ "$actions" == *'up --detach --force-recreate --remove-orphans'* ]]
}

@test "generated resolver drift is reported without being silently repaired by check" {
  apply_isolated
  [ "$status" -eq 0 ]
  local resolver=$HOME/.config/orca-setup/docker/network/orca-resolv.conf
  printf 'nameserver 192.0.2.99\n' >"$resolver"
  run_setup --check --json
  [[ "$output" == *'STALE (network policy differs'* ]]
  [ "$(cat "$resolver")" = 'nameserver 192.0.2.99' ]
}

@test "network mode belongs to Linux server hosts and accepts only documented choices" {
  run_setup --plan --role client --network-mode isolated
  [ "$status" -ne 0 ]
  run_setup --plan --network-mode transparent
  [ "$status" -ne 0 ]
  export ORCA_SETUP_CONTAINER=orca-server
  run_setup --plan --role server --network-mode isolated
  [ "$status" -ne 0 ]
}

@test "proxy authentication is referenced outside the overlay, never read or copied by setup" {
  local auth=$SB/proxy-auth.json
  printf 'invalid JSON: FAKE-AUTH-SENTINEL\n' >"$auth"
  chmod 600 "$auth"
  printf 'proxy_auth_file=%s\n' "$auth" >>"$SB/manifest/local/server-network.env"
  apply_isolated
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *FAKE-AUTH-SENTINEL* ]]
  ! grep -q FAKE-AUTH-SENTINEL "$COMPOSE" "$HOME/.config/orca-setup/docker/network/policy.env"
  grep -qF "    file: \"$auth\"" "$COMPOSE"
  [ "$(grep -c '^      - orca_proxy_auth$' "$COMPOSE")" -eq 1 ]
  ! sed -n '/^  executor-gateway:/,/^networks:/p' "$COMPOSE" | grep -q orca_proxy_auth
  [ ! -f "$HOME/.config/orca-setup/docker/manifest-local/proxy-auth.json" ]
}

@test "authentication files inside a checkout or overlay are refused before changes" {
  printf '{}\n' >"$SB/manifest/local/proxy-auth.json"
  printf 'proxy_auth_file=%s\n' "$SB/manifest/local/proxy-auth.json" >>"$SB/manifest/local/server-network.env"
  apply_isolated
  [ "$status" -ne 0 ]
  [ ! -s "$FAKE_LOG" ]
}
