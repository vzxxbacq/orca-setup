#!/usr/bin/env bash
# Real packet tests, only on a disposable GitHub-hosted VM after linux.sh server. No live proxy or AI credentials.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] && [ "$(id -u)" -ne 0 ] ||
  { echo 'network.sh runs only on a disposable GitHub-hosted VM as its regular user.' >&2; exit 1; }
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d)
host_home_probe=$HOME/.orca-setup-home-probe-$$
fail() { echo "FAIL: $*" >&2; exit 1; }
old_compose=${XDG_CONFIG_HOME:-$HOME/.config}/orca-setup/docker/compose.yaml
# The preceding direct-network test prepared Orca's public native-runtime artifacts. Preserve only those downloads:
# the synthetic proxy cannot serve GitHub release binaries, and no profile, settings or login data is copied.
old_artifacts=${XDG_DATA_HOME:-$HOME/.local/share}/orca-setup/home/.config/orca/orcad-artifacts
[ -d "$old_artifacts" ] || fail 'the preceding direct-network test did not prepare native runtime artifacts'
mkdir -p "$work/native-artifacts"
cp -R "$old_artifacts"/. "$work/native-artifacts/"
[ ! -f "$old_compose" ] || docker compose --file "$old_compose" down
export XDG_CONFIG_HOME=$work/config XDG_DATA_HOME=$work/data ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS=1
export ORCA_SETUP_MANIFEST_DIR=$work/manifest
compose=$XDG_CONFIG_HOME/orca-setup/docker/compose.yaml
# Resolve the same stable names used by setup without duplicating the namespace algorithm.
# shellcheck source=lib/orca-server.sh
. "$repo/lib/orca-server.sh"
server_name=$(server_container_name orca-server)
gateway_name=$(server_container_name orca-gateway)
executor_gateway_name=$(server_container_name executor-gateway)
executor_name=$(server_container_name orca-executor)
mkdir -p "$XDG_DATA_HOME/orca-setup/home/.config/orca/orcad-artifacts"
cp -R "$work/native-artifacts"/. "$XDG_DATA_HOME/orca-setup/home/.config/orca/orcad-artifacts/"
cleanup() {
  [ ! -f "$compose" ] || docker compose --file "$compose" logs --no-color --tail 20 >&2 || true
  [ ! -f "$compose" ] || docker compose --file "$compose" down || true
  [ ! -f "$work/secret-volume" ] || docker volume rm "$(cat "$work/secret-volume")" >/dev/null || true
  [ ! -f "$work/executor-secret-volume" ] || docker volume rm "$(cat "$work/executor-secret-volume")" >/dev/null || true
  docker rm -f orca-network-fixture >/dev/null 2>&1 || true
  [ ! -f "$work/test-address-added" ] || sudo ip address del 198.51.100.10/32 dev docker0 || true
  [ ! -f "$host_home_probe" ] || rm "$host_home_probe"
  rm -rf "$work"
}
trap cleanup EXIT
cp -R "$repo/manifest" "$work/manifest"
mkdir -p "$work/manifest/local" "$work/projects"
printf '{"username":"fixture-user","password":"fixture-password"}\n' | sudo tee "$work/proxy-auth.json" >/dev/null
sudo chmod 600 "$work/proxy-auth.json"
bridge_address=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')
[ -n "$bridge_address" ] || fail 'no Docker bridge gateway'
sudo ip address add 198.51.100.10/32 dev docker0
touch "$work/test-address-added"
docker run --detach --name orca-network-fixture --entrypoint python3 \
  --publish "$bridge_address:18080:1080" --publish "$bridge_address:18083:1081" \
  --publish "$bridge_address:18087:1082" --publish '198.51.100.10:18086:8080' \
  --publish "$bridge_address:18081:8080" --publish "$bridge_address:18082:8080" \
  --publish "$bridge_address:53:8053/tcp" --publish "$bridge_address:53:8053/udp" \
  --publish "$bridge_address:18084:8090/udp" --publish "$bridge_address:18085:8090/udp" \
  --env "TEST_LAN_ADDRESS=$bridge_address" \
  --volume "$repo/tests/integration/network-fixture.py:/fixture.py:ro" "$ORCA_SETUP_IMAGE" /fixture.py
for _ in {1..30}; do
  if [ "$(curl --noproxy '*' -fsS --max-time 1 "http://$bridge_address:18081/" 2>/dev/null || true)" = direct ]; then break; fi
  sleep 1
done
[ "$(curl --noproxy '*' -fsS --max-time 3 "http://$bridge_address:18081/")" = direct ] || fail 'fixture not ready'
printf 'origin\t%s/32\ttcp\t18081\necho\t%s/32\tudp\t18085\n' "$bridge_address" "$bridge_address" \
  >"$work/manifest/local/server-network-allow.tsv"

request() { docker exec "$1" curl --noproxy '*' -fsS --max-time 5 "$2"; }
execute() { docker exec "$server_name" orca-exec --cwd "$work/projects" -- "$@"; }
for scenario in socks5 socks5-auth http-connect; do
  args=(--no-config --apply --role server --pairing-address 127.0.0.2 --workdir "$work/projects" --network-mode isolated)
  protocol=${scenario%-auth}
  auth_file=''
  if [ "$scenario" = socks5-auth ]; then
    auth_file=$work/proxy-auth.json
    docker exec orca-network-fixture touch /tmp/require-auth
  else
    docker exec orca-network-fixture rm -f /tmp/require-auth
  fi
  if [ "$protocol" = socks5 ]; then port=18080; else port=18083; fi
  cat >"$work/manifest/local/server-network.env" <<EOF
proxy_type=$protocol
proxy_address=$bridge_address
proxy_port=$port
proxy_auth_file=$auth_file
dns_address=198.51.100.53
dns_transport=tcp
executor_dns=$bridge_address
EOF
  if [ "$scenario" = socks5-auth ]; then
    # The same real auth/packet checks also cover the single-TOML stdin-to-volume path.
    cat >"$work/server.toml" <<EOF
[server]
pairing_address = "127.0.0.2"
workdir = "$work/projects"
[proxy]
type = "socks5"
address = "$bridge_address"
port = $port
username = "fixture-user"
password = "fixture-password"
[dns]
address = "198.51.100.53"
transport = "tcp"
[executor]
dns = "$bridge_address"
[[executor.allow]]
name = "origin"
cidr = "$bridge_address/32"
port = 18081
[[executor.allow]]
name = "echo"
cidr = "$bridge_address/32"
protocol = "udp"
port = 18085
EOF
    chmod 600 "$work/server.toml"
    args=(--config "$work/server.toml" --apply)
  fi
  "$repo/setup.sh" "${args[@]}"
  if [ "$scenario" = socks5-auth ]; then
    docker inspect "$gateway_name" --format '{{range .Mounts}}{{if eq .Destination "/run/secrets"}}{{.Name}}{{end}}{{end}}' >"$work/secret-volume"
    ! grep -q fixture-password "$compose" "$XDG_CONFIG_HOME/orca-setup/docker/network/policy.env" || fail 'proxy credentials leaked'
  fi
  docker compose --file "$compose" config --quiet
  # Explicitly bypass environment proxies: transparent routing must still use the proxy, even to a private IP.
  [ "$(request "$server_name" "http://$bridge_address:18081/")" = proxied ] || fail 'Orca escaped its proxy'
  [ "$(request "$server_name" 'http://egress.example:8080/')" = proxied ] || fail 'proxied DNS/TCP failed'
  [ "$(execute curl --noproxy '*' -fsS --max-time 5 'http://internal.example:18081/')" = direct ] || fail 'executor did not use LAN directly'
  if request "$executor_name" "http://$bridge_address:18082/"; then fail 'unlisted LAN port was reachable'; fi
  if request "$executor_name" 'http://198.51.100.10:8080/'; then fail 'executor could reach the public Internet'; fi
  [ "$(docker port "$gateway_name")" = '6768/tcp -> 127.0.0.2:6768' ] || fail 'incorrect Orca port binding'
  [ -z "$(docker port "$executor_name")" ] || fail 'executor published a port'
  docker exec "$executor_name" test ! -e "$HOME/.codex"
  docker exec "$executor_name" test ! -e "$HOME/.orca"
  execute python3 -c 'import os,pathlib; pathlib.Path("result").write_text("shared"); assert not any(k.lower().endswith("_proxy") for k in os.environ)'
  [ "$(cat "$work/projects/result")" = shared ] || fail 'workdir is not shared'
  [ "$(stat -c %u "$work/projects/result")" = "$(id -u)" ] || fail 'executor wrote as another user'
  code=0
  execute python3 -c 'raise SystemExit(7)' || code=$?
  [ "$code" = 7 ] || fail 'remote exit status was lost'
  code=0
  docker exec "$server_name" orca-exec --cwd /tmp -- true || code=$?
  [ "$code" = 125 ] || fail 'executor accepted a cwd outside its workdir'
  # An upstream outage must neither allow direct fallback nor break private control or LAN execution.
  docker exec orca-network-fixture touch /tmp/no-proxy
  if request "$server_name" "http://$bridge_address:18081/"; then fail 'Orca fell back to direct after proxy failure'; fi
  [ "$(request "$executor_name" "http://$bridge_address:18081/")" = direct ] || fail 'proxy outage broke LAN execution'
  curl --noproxy '*' -sS --max-time 5 -o /dev/null http://127.0.0.2:6768/ || fail 'proxy outage broke private Orca control'
  docker exec orca-network-fixture rm /tmp/no-proxy
  # Reapplying an unchanged isolated policy must keep all container identities.
  docker compose --file "$compose" ps --all --quiet | sort >"$work/before"
  "$repo/setup.sh" "${args[@]}" >"$work/second.log"
  ! grep -q '^+ ' "$work/second.log" || fail 'second isolated apply changed state'
  docker compose --file "$compose" ps --all --quiet | sort >"$work/after"
  diff -u "$work/before" "$work/after"
done

# Exercise UDP policy against a reachable echo service, and verify that embedded Docker DNS cannot bypass Orca DNS.
docker exec --env "TEST_LAN_ADDRESS=$bridge_address" "$executor_name" python3 -c '
import os,socket
host=os.environ["TEST_LAN_ADDRESS"]
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
 s.settimeout(2); s.sendto(b"allowed",(host,18085)); assert s.recv(100)==b"allowed"
 try:
  s.sendto(b"blocked",(host,18084)); s.recv(100)
 except OSError: pass
 else: raise AssertionError("unlisted UDP port was reachable")
'
docker exec "$server_name" python3 -c '
import socket
from pathlib import Path
assert Path("/proc/sys/net/ipv6/conf/all/disable_ipv6").read_text().strip()=="1"
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
 s.settimeout(2)
 try:
  s.sendto(bytes.fromhex("12340100000100000000000001610000010001"),("127.0.0.11",53)); s.recv(4096)
 except OSError: pass
 else: raise AssertionError("Docker embedded DNS bypass was available")
'
# Firewall changes are visible as an unhealthy gateway instead of silently passing readiness.
docker exec "$gateway_name" iptables -A OUTPUT -j ACCEPT
if docker exec "$gateway_name" /opt/orca-setup/docker/gateway.sh check; then fail 'firewall drift was not detected'; fi
"$repo/setup.sh" "${args[@]}"
echo 'isolated networking: SOCKS5, HTTP CONNECT, proxied DNS, LAN allow rules, no fallback and recovery passed'

# A second SOCKS5 listener accepts different fake credentials, proving that the executor proxy is independent.
cat >"$work/executor.toml" <<EOF
[server]
pairing_address = "127.0.0.2"
workdir = "$work/projects"
[proxy]
type = "socks5"
address = "$bridge_address"
port = 18080
[dns]
address = "198.51.100.53"
transport = "tcp"
[executor]
internet = "proxy"
[executor.proxy]
type = "socks5"
address = "$bridge_address"
port = 18087
username = "executor-fixture"
password = "executor-password"
[[executor.allow]]
name = "origin"
cidr = "$bridge_address/32"
protocol = "tcp"
port = 18081
EOF
chmod 600 "$work/executor.toml"
args=(--config "$work/executor.toml" --apply)
"$repo/setup.sh" "${args[@]}"
docker inspect "$executor_gateway_name" --format '{{range .Mounts}}{{if eq .Destination "/run/secrets"}}{{.Name}}{{end}}{{end}}' >"$work/executor-secret-volume"
docker compose --file "$compose" config --quiet
[ "$(execute curl --noproxy '*' -fsS --max-time 5 'http://198.51.100.10:18086/')" = proxied ] || fail 'executor proxy was bypassed'
[ "$(execute curl --noproxy '*' -fsS --max-time 5 'http://egress.example:18086/')" = proxied ] || fail 'executor proxied DNS failed'
[ "$(execute curl --noproxy '*' -fsS --max-time 5 'http://internal.example:18081/')" = direct ] || fail 'executor private allow rule was not direct'
if request "$executor_name" "http://$bridge_address:18082/"; then fail 'executor proxy reached unlisted LAN port'; fi
docker exec orca-network-fixture touch /tmp/no-proxy
if request "$executor_name" 'http://198.51.100.10:18086/'; then fail 'executor proxy failure fell back to direct'; fi
# With no executor.dns configured, DNS itself uses the unavailable proxy. Verify the
# permitted LAN route by IP, without accidentally requiring a direct DNS fallback.
[ "$(execute curl --noproxy '*' -fsS --max-time 5 "http://$bridge_address:18081/")" = direct ] || fail 'executor proxy failure broke permitted LAN access'
docker exec orca-network-fixture rm /tmp/no-proxy

# Switch only the executor to public direct networking; its private exceptions still apply.
python3 - "$work/executor.toml" "$bridge_address" <<'PY'
from pathlib import Path
import json
import sys
p = Path(sys.argv[1]); s = p.read_text().replace('internet = "proxy"', 'internet = "direct"\ndns = ' + json.dumps(sys.argv[2]))
start = s.index('[executor.proxy]'); end = s.index('[[executor.allow]]', start)
p.write_text(s[:start] + s[end:])
PY
"$repo/setup.sh" "${args[@]}"
[ "$(execute curl --noproxy '*' -fsS --max-time 5 'http://198.51.100.10:18086/')" = direct ] || fail 'executor direct mode did not use the direct route'
if request "$executor_name" "http://$bridge_address:18082/"; then fail 'executor direct mode reached unlisted LAN port'; fi
echo 'executor networking: independent authenticated proxy, direct public access, private allow rules and no fallback passed'

# The user's complete home is writable in Orca; the executor still sees only its own home and the shared workdir.
mkdir -p "$HOME/.config/orca/orcad-artifacts"
cp -R "$work/native-artifacts"/. "$HOME/.config/orca/orcad-artifacts/"
python3 - "$work/executor.toml" "$HOME/orca" <<'PY'
from pathlib import Path
import json
import sys
p = Path(sys.argv[1]); s = p.read_text()
start = s.index('workdir = '); end = s.index('\n', start)
s = s[:start] + 'workdir = ' + json.dumps(sys.argv[2]) + '\nhome_mount = "host"' + s[end:]
p.write_text(s)
PY
"$repo/setup.sh" "${args[@]}"
docker exec --env "TEST_HOME_FILE=$host_home_probe" "$server_name" sh -c 'printf persisted >"$TEST_HOME_FILE"'
[ "$(cat "$host_home_probe")" = persisted ] || fail 'host home write did not persist'
docker exec "$server_name" orca-exec --cwd "$HOME/orca" -- python3 -c 'from pathlib import Path; Path("host-mount-result").write_text("shared")'
[ "$(docker exec "$server_name" cat "$HOME/orca/host-mount-result")" = shared ] || fail 'executor result was not visible in Orca'
docker exec "$executor_name" test ! -e "$host_home_probe" || fail 'executor could see a host home file outside the shared workdir'
docker exec "$gateway_name" iptables -A OUTPUT -j ACCEPT
"$repo/setup.sh" "${args[@]}"
[ "$(docker exec "$server_name" cat "$host_home_probe")" = persisted ] || fail 'host home write did not survive recreation'
echo 'host home mount: shared workdir, separate executor home and persistence across recreation passed'
