#!/usr/bin/env bats
# Exercise the TOML host entry point and its private stdin publisher with a fake Docker daemon.
load helpers

setup() {
  make_sandbox
  fake_linux
  fake_baseline_present
  fake_orca_linux
  fake_docker installed
  ln -sf "$REAL_PYTHON" "$SB/bin/python3"
  touch "$SB/docker/session-group"
  printf ' docker' >"$SB/groups"
  fake_registry ghcr.io/vzxxbacq/orca-server:main aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  fake_ip 203.0.113.10
  CONFIG=$SB/orca.toml
  COMPOSE=$HOME/.config/orca-setup/docker/compose.yaml
  cat >"$CONFIG" <<'EOF'
[server]
pairing_address = "server.example.com"
publish_address = "203.0.113.10"
workdir = "./work"
[network]
mode = "isolated"
[proxy]
type = "socks5"
address = "192.0.2.20"
port = 1080
username = "fixture-user"
password = "FAKE-CONFIG-AUTH-SENTINEL"
[[executor.allow]]
name = "git"
cidr = "172.20.1.10/32"
port = 443
[limits]
mem_limit = "8g"
cpus = 2
EOF
  chmod 600 "$CONFIG"
}

apply_config() { run_setup --config "$CONFIG" --apply "$@"; }

@test "one TOML supplies role, addresses, rules and limits without plan mutations or secret output" {
  run_setup --config "$CONFIG"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'single TOML'* ]]
  [[ "$output" != *FAKE-CONFIG-AUTH-SENTINEL* ]]
  [ ! -s "$FAKE_LOG" ]
  [ ! -d "$HOME/.config/orca-setup" ]
  apply_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local resolved
  resolved=$(cd "$SB/work" && pwd -P)
  grep -qF "  workdir: \"$resolved\"" "$COMPOSE"
  grep -qF '    mem_limit: "8g"' "$COMPOSE"
  grep -qF '    cpus: "2"' "$COMPOSE"
  grep -qF $'git\t172.20.1.10/32\ttcp\t443' "$HOME/.config/orca-setup/docker/network/allow.tsv"
  grep -qF '    external: true' "$COMPOSE"
  [ "$(grep -c '        source: orca_proxy_auth' "$COMPOSE")" -eq 1 ]
  ! sed -n '/^  executor-gateway:/,/^networks:/p' "$COMPOSE" | grep -qF /run/secrets
  ! grep -qE 'FAKE-CONFIG-AUTH-SENTINEL|fixture-user' "$COMPOSE" "$FAKE_LOG" "$HOME/.config/orca-setup/docker/network/policy.env"
  [[ "$output" != *FAKE-CONFIG-AUTH-SENTINEL* ]]
}

@test "recorded TOML is reused, unchanged authentication is idempotent, changes reconcile the gateway" {
  apply_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  : >"$FAKE_LOG"
  run_setup --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -qE '^docker (compose|run .*proxy-secret)' "$FAKE_LOG"
  sed 's/FAKE-CONFIG-AUTH-SENTINEL/FAKE-ROTATED-AUTH-SENTINEL/' "$CONFIG" >"$CONFIG.new"
  chmod 600 "$CONFIG.new"
  cp "$CONFIG.new" "$CONFIG"
  run_setup --check --json
  [[ "$output" == *'STALE (private authentication differs'* ]] || { echo "$output"; return 1; }
  ! grep -q '^docker compose' "$FAKE_LOG"
  run_setup --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'up --detach --force-recreate' "$FAKE_LOG"
  ! grep -qE 'FAKE-ROTATED-AUTH-SENTINEL|FAKE-CONFIG-AUTH-SENTINEL' "$COMPOSE" "$FAKE_LOG"
}

@test "unsafe permissions and malformed TOML refuse before Docker or any output of credentials" {
  chmod 644 "$CONFIG"
  apply_config
  [ "$status" -ne 0 ]
  [[ "$output" == *'mode 0600 or 0400'* ]]
  [[ "$output" != *FAKE-CONFIG-AUTH-SENTINEL* ]]
  [ ! -s "$FAKE_LOG" ]
  [ ! -d "$HOME/.config/orca-setup" ]
  chmod 600 "$CONFIG"
  printf '\nwrong_key = "FAKE-CONFIG-AUTH-SENTINEL"\n' >>"$CONFIG"
  apply_config
  [ "$status" -ne 0 ]
  [[ "$output" != *FAKE-CONFIG-AUTH-SENTINEL* ]]
  [ ! -s "$FAKE_LOG" ]
}

@test "inline credentials cannot be inside the executor shared workdir" {
  mkdir -p "$SB/work"
  sed "s|workdir = \"./work\"|workdir = \"$SB/work\"|" "$CONFIG" >"$SB/work/orca.toml"
  CONFIG=$SB/work/orca.toml
  chmod 600 "$CONFIG"
  apply_config
  [ "$status" -ne 0 ]
  [[ "$output" == *'outside application data mounts and the shared workdir'* ]]
  [[ "$output" != *FAKE-CONFIG-AUTH-SENTINEL* ]]
  [ ! -s "$FAKE_LOG" ]
  [ ! -d "$HOME/.config/orca-setup" ]
}

@test "missing recorded config fails closed; explicit no-config and public CLI overrides work" {
  apply_config --publish-address 203.0.113.10 --pairing-address override.example.com
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF '  pairing-address: "override.example.com"' "$COMPOSE"
  rm "$CONFIG"
  : >"$FAKE_LOG"
  run_setup --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *'server TOML is missing'* ]]
  [ ! -s "$FAKE_LOG" ]
  run_setup --no-config --apply --role server --pairing-address 203.0.113.10 --network-mode direct
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q network_mode "$COMPOSE"
  grep -qF '  config-file: ""' "$COMPOSE"
}

@test "local image source locks content without registry and moves only with explicit upgrade" {
  sed '/\[server\]/a\
image = "orca-example:local"\
image_source = "local"
' "$CONFIG" >"$CONFIG.new"
  cp "$CONFIG.new" "$CONFIG"
  local first=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local second=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  printf '%s\n' "$first" >"$SB/docker/images/orca-example_local"
  printf '%s\n' "$first" >"$SB/docker/images/sha256_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  apply_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF "image: \"$first\"" "$COMPOSE"
  ! grep -q '^docker pull' "$FAKE_LOG"
  printf '%s\n' "$second" >"$SB/docker/images/orca-example_local"
  printf '%s\n' "$second" >"$SB/docker/images/sha256_cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  apply_config
  [ "$status" -eq 0 ]
  grep -qF "image: \"$first\"" "$COMPOSE"
  apply_config --upgrade-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF "image: \"$second\"" "$COMPOSE"
  ! grep -q '^docker pull' "$FAKE_LOG"
}

@test "host home is mounted for Orca while the executor retains only its separate home and workdir" {
  mkdir -p "$SB/work"
  mkdir -p "$HOME/.local/share/orca-setup/home/.agents"
  printf 'existing data\n' >"$HOME/.local/share/orca-setup/home/.agents/preserved"
  local resolved
  resolved=$(cd "$SB/work" && pwd -P)
  ln -s "$resolved" "$HOME/orca"
  sed '/\[server\]/a\
home_mount = "host"
' "$CONFIG" >"$CONFIG.new"
  cp "$CONFIG.new" "$CONFIG"
  apply_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local main executor
  main=$(sed -n '/^  orca-server:/,/^  orca-gateway:/p' "$COMPOSE")
  executor=$(sed -n '/^  orca-executor:/,/^networks:/p' "$COMPOSE")
  [[ "$main" == *"source: \"$HOME\""* ]]
  [[ "$main" == *"target: \"$HOME\""* ]]
  [[ "$main" != *"source: \"$HOME/.local/share/orca-setup/home\""* ]]
  [[ "$executor" == *"source: \"$HOME/.local/share/orca-setup/executor-home\""* ]]
  [[ "$executor" != *"source: \"$HOME\""* ]]
  [ "$(cat "$HOME/.local/share/orca-setup/home/.agents/preserved")" = 'existing data' ]
}

@test "host home with a custom workdir refuses to replace an existing host orca directory" {
  mkdir -p "$HOME/orca"
  printf 'existing data\n' >"$HOME/orca/preserved"
  sed '/\[server\]/a\
home_mount = "host"
' "$CONFIG" >"$CONFIG.new"
  cp "$CONFIG.new" "$CONFIG"
  apply_config
  [ "$status" -ne 0 ]
  [[ "$output" == *'requires an existing ~/orca symlink'* ]]
  [ "$(cat "$HOME/orca/preserved")" = 'existing data' ]
  [ ! -s "$FAKE_LOG" ]
}

@test "executor proxy uses an independent protected authentication volume and keeps secrets out of Compose" {
  python3 - "$CONFIG" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().replace('[[executor.allow]]', '''[executor]
internet = "proxy"
[executor.proxy]
type = "socks5"
address = "192.0.2.21"
port = 1081
username = "separate-fixture"
password = "FAKE-EXECUTOR-AUTH-SENTINEL"
[[executor.allow]]''')
p.write_text(s)
PY
  apply_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF 'executor_mode=proxy' "$HOME/.config/orca-setup/docker/network/executor-policy.env"
  grep -qF 'proxy_address=192.0.2.21' "$HOME/.config/orca-setup/docker/network/executor-policy.env"
  grep -qF 'source: executor_proxy_auth' "$COMPOSE"
  grep -qF 'cap_add: ["NET_ADMIN", "NET_BIND_SERVICE"]' "$COMPOSE"
  ! grep -qE 'FAKE-EXECUTOR-AUTH-SENTINEL|FAKE-CONFIG-AUTH-SENTINEL|separate-fixture' "$COMPOSE" "$FAKE_LOG"
  : >"$FAKE_LOG"
  apply_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^docker compose ' "$FAKE_LOG"
  python3 - "$CONFIG" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); p.write_text(p.read_text().replace('FAKE-EXECUTOR-AUTH-SENTINEL', 'FAKE-ROTATED-EXECUTOR-AUTH'))
PY
  run_setup --config "$CONFIG" --check --json
  [[ "$output" == *'STALE (private authentication differs or executor gateway is unreachable'* ]]
  apply_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'up --detach --force-recreate' "$FAKE_LOG"
  ! grep -qE 'FAKE-EXECUTOR-AUTH-SENTINEL|FAKE-ROTATED-EXECUTOR-AUTH' "$COMPOSE" "$FAKE_LOG"
}

@test "TUI refuses noninteractive use without writing files or invoking Docker" {
  run_setup --tui --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *'requires an interactive terminal'* ]]
  [ ! -d "$HOME/.config/orca-setup" ]
  [ ! -s "$FAKE_LOG" ]
}

@test "executor direct mode uses direct DNS and is included in policy drift" {
  python3 - "$CONFIG" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); p.write_text(p.read_text().replace('[[executor.allow]]', '[executor]\ninternet = "direct"\n[[executor.allow]]'))
PY
  apply_config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF 'executor_mode=direct' "$HOME/.config/orca-setup/docker/network/executor-policy.env"
  grep -qF 'nameserver 1.1.1.1' "$HOME/.config/orca-setup/docker/network/executor-resolv.conf"
  ! sed -n '/^  executor-gateway:/,/^  orca-executor:/p' "$COMPOSE" | grep -qF /run/secrets
}

@test "old images refuse executor internet modes before replacing a running stack" {
  python3 - "$CONFIG" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); p.write_text(p.read_text().replace('[[executor.allow]]', '[executor]\ninternet = "direct"\n[[executor.allow]]'))
PY
  export FAKE_EXEC_NETWORK_VERSION=0
  apply_config
  [ "$status" -ne 0 ]
  [[ "$output" == *'does not support executor direct/proxy networking'* ]]
  ! grep -q '^docker compose ' "$FAKE_LOG"
}

@test "mutual SSH is explicit, planned without writes, and refused on an older locked image" {
  export FAKE_SSH_VERSION=0
  export FAKE_EXEC_NETWORK_VERSION=1
  sed '/\[server\]/a\
internal_ssh = true
' "$CONFIG" >"$CONFIG.new"
  cp "$CONFIG.new" "$CONFIG"
  run_setup --config "$CONFIG"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'mutual control-network SSH on port 2222'* ]]
  [ ! -d "$HOME/.config/orca-setup/docker/ssh" ]
  [ ! -s "$FAKE_LOG" ]
  apply_config
  [ "$status" -ne 0 ]
  [[ "$output" == *'internal SSH requires a newer image'* ]]
  [ ! -d "$HOME/.config/orca-setup/docker/ssh" ]
  ! grep -q 'ssh-identity.py' "$FAKE_LOG"
  ! grep -q 'docker compose .*up' "$FAKE_LOG"
}
