#!/usr/bin/env bats
# The Linux server in Docker (P5, README section 6.7): Docker Engine on the host, the docker group and sg, the
# directories, the publish address, compose.yaml, the image lock, the container, the logins and the combined --check,
# against fake apt, sudo, gpg, docker, sg, ip and Orca. Nothing here runs apt, sudo or Docker for real.

load helpers

ADDRESS=203.0.113.10 # documentation range (RFC 5737)
DOCKER_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
IMAGE=ghcr.io/vzxxbacq/orca-server
D1=1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a
D2=2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b

setup() {
  make_sandbox
  fake_linux
  # The host has a shell's usual tools, but none of the baseline (no Node.js, agents or Orca); those exist for what
  # runs "inside the container" (docker exec), which shares this sandbox.
  fake_present curl
  fake_gpg
  # shellcheck disable=SC2016 # the stub body expands when the stub runs
  fake_cmd curl 'out=""; prev=""; for a; do [ "$prev" = -o ] && out=$a; prev=$a; done; echo "FAKEKEY ${FAKE_KEY_FPRS//,/ }" >"$out"'
  export FAKE_KEY_FPRS=$DOCKER_FPR
  echo ca-certificates >>"$FAKE_DPKG"
  fake_docker
  fake_registry "$IMAGE:main" "$D1"
  # The host's own addresses: the pairing address is one of them, so it is the default publish address.
  fake_ip "$ADDRESS"
  COMPOSE=$HOME/.config/orca-setup/docker/compose.yaml
  LOCK=$HOME/.config/orca-setup/docker/image.lock
  PROJECT_NAME=$(. "$REPO_ROOT/lib/orca-server.sh"; server_project_name)
  SERVER_NAME=$(. "$REPO_ROOT/lib/orca-server.sh"; server_container_name orca-server)
  # No systemd unless a test boots the fake one (the machine running the tests may have it).
  export ORCA_SETUP_SYSTEMD_RUN_DIR=$SB/no-systemd
}

# systemd as the host's init system: the fake systemctl reports units the fake sudo masked ($SB/masked) as masked.
fake_systemd() {
  mkdir -p "$SB/run-systemd"
  export ORCA_SETUP_SYSTEMD_RUN_DIR=$SB/run-systemd
  # shellcheck disable=SC2016 # the stub body expands when the stub runs
  fake_cmd systemctl 'case "$1" in is-enabled) grep -qxF -- "$2" "$SB/masked" 2>/dev/null && { echo masked; exit 1; }; echo static ;; *) echo "systemctl $*" >>"$FAKE_LOG"; exit 1 ;; esac'
}

no_calls() { [ ! -s "$FAKE_LOG" ] || { cat "$FAKE_LOG"; return 1; }; }

# No output may carry a pairing URL or code; the fake CLI puts one into every status reply.
no_secret() {
  [[ "$output" != *FAKE-PAIRING-SECRET* ]] && [[ "$output" != *'orca://pair'* ]] || { echo "$output"; return 1; }
}

snapshot() { # snapshot <name>: compare $output (sandbox paths shown as <sandbox>) with a fixture, or rewrite it
  local file=$BATS_TEST_DIRNAME/fixtures/$1 normalized=${output//$SB/<sandbox>}
  normalized=${normalized//$SERVER_NAME/<server-container>}
  if [ -n "${UPDATE_SNAPSHOTS:-}" ]; then printf '%s\n' "$normalized" >"$file"; fi
  "$REAL_DIFF" -u "$file" <(printf '%s\n' "$normalized")
}

# What runs inside the container: every baseline tool and agent, Orca with its skills (fake_orca_linux).
image_tools() {
  fake_baseline_present
  fake_orca_linux
}

# A host whose working Docker came from another source, reachable from this session.
existing_docker() {
  cp "$SB/docker-stub" "$SB/bin/docker"
  touch "$SB/docker/session-group"
  printf ' docker' >"$SB/groups"
}

apply_server() { run_setup --apply --role server --pairing-address "$ADDRESS" "$@"; }

# The second run may print only PRESENT, SKIP and NOTE items and the role report.
only_present() {
  [ -z "$(grep -v -e '^PRESENT ' -e '^SKIP ' -e '^NOTE ' -e '^MODULE ' -e '^ROLE ' -e '^saved environments: ' \
    -e '^runtime clients ' -e '^mobile pairings: ' -e '^BASELINE_DONE$' <<<"$output")" ] || { echo "$output"; return 1; }
}

# ------------------------------------------------------------------ plan

@test "--plan --role server on a fresh host: Docker Engine, the docker group, directories, image and container" {
  run_setup --plan --role server --pairing-address "$ADDRESS" --media --power
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  snapshot plan-linux-server.txt
  no_secret
  no_calls
  # Only Docker's packages, its repository and the group need root; nothing else is installed on the host.
  [ -z "$(grep 'sudo' <<<"$output" | grep -v -e '^ \{11,\}sudo ' -e '^sudo: present' -e '^  --' -e 'no sudo')" ]
  [ "$(grep -c '^ \{11,\}sudo ' <<<"$output")" -eq 10 ]
  [[ "$output" != *nodejs* ]]
  [[ "$output" != *'orca-ide_<version>_amd64.deb'* ]]
  [[ "$output" != *'npm '* ]]
}

@test "--plan --role server with a working Docker from another source lists no sudo command but the group" {
  existing_docker
  run_setup --plan --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ]
  [[ "$output" == *'present  Docker version 27.3.1, build fake from another source, with Compose 2.29.7; used as it is'* ]]
  [[ "$output" == *'present  builder in the docker group'* ]]
  [ -z "$(grep -e '^ *sudo ' <<<"$output")" ] || { echo "$output"; return 1; }
  no_calls
}

# ------------------------------------------------------------------ Docker Engine

@test "--apply --role server on a fresh host installs Docker Engine, joins the group and reaches Docker through sg" {
  image_tools
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  no_secret
  [ "${lines[${#lines[@]} - 1]}" = BASELINE_DONE ]
  [ "$(cat "$SB/apt/sources.list.d/docker.list")" = "deb [arch=amd64 signed-by=$SB/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" ]
  local package
  for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    grep -qxF "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $package" "$FAKE_LOG"
  done
  [[ "$output" == *'+ sudo usermod -aG docker builder'* ]]
  [[ "$output" == *'NOTE docker runs through "sg docker" in this session'* ]]
  [ -s "$SB/sg.log" ]
  # The order: Docker, the image, the role check, the container, then Orca inside it.
  run grep -n -e '^docker pull ' -e '^docker run ' -e '^docker compose ' -e '^docker exec .*setup.sh --apply' "$FAKE_LOG"
  [[ "${lines[0]}" == *"docker pull $IMAGE:main" ]]
  [[ "${lines[1]}" == *"docker run $IMAGE@sha256:$D1 /opt/orca-setup/orca/role.sh --expect server" ]]
  [[ "${lines[2]}" == *"docker compose --file $COMPOSE --project-name $PROJECT_NAME up --detach" ]]
  [[ "${lines[3]}" == *'docker exec /opt/orca-setup/setup.sh --apply --role server' ]]
  # The settings were aligned by the setup.sh inside the container.
  [ "$(cat "$SB/orca-settings.json")" = '{"defaultTuiAgent":"codex","agentStatusHooksEnabled":true}' ]
  grep -qx "image=$IMAGE@sha256:$D1" "$LOCK"
  grep -qx "source=$IMAGE:main" "$LOCK"
}

@test "a second --apply --role server changes nothing" {
  image_tools
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  : >"$FAKE_LOG"
  cp "$COMPOSE" "$SB/compose-1"
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  no_secret
  only_present
  [[ "$output" == *"PRESENT image $IMAGE@sha256:$D1"* ]]
  [[ "$output" == *"PRESENT container $SERVER_NAME running"* ]]
  [[ "$output" == *'PRESENT Orca settings'* ]]
  "$REAL_DIFF" "$SB/compose-1" "$COMPOSE"
  # Only reads: the role check and the in-container checks; no pull, build or compose.
  [ -z "$(grep -e 'pull' -e 'compose' -e 'build' -e '^sudo ' "$FAKE_LOG")" ] || { cat "$FAKE_LOG"; return 1; }
}

@test "an existing working Docker from another source is used as it is" {
  image_tools
  existing_docker
  echo docker.io >>"$FAKE_DPKG"
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'PRESENT docker (Docker version 27.3.1, build fake; from another source, used as it is)'* ]]
  [[ "$output" == *'PRESENT builder in the docker group'* ]]
  [[ "$output" != *'sg docker'* ]]
  [ -z "$(grep '^sudo ' "$FAKE_LOG")" ] || { cat "$FAKE_LOG"; return 1; }
  [ ! -e "$SB/apt/sources.list.d/docker.list" ]
}

@test "Docker packages without a docker command are refused in --plan without stopping it" {
  echo containerd >>"$FAKE_DPKG"
  run_setup --plan --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'refuse   Docker packages from another source are installed (containerd), but there is no docker command'* ]]
  [[ "$output" == *'Directories (--apply'* ]]
  no_calls
}

@test "a Docker that answers without the docker group (rootless) is used without joining it" {
  image_tools
  cp "$SB/docker-stub" "$SB/bin/docker"
  touch "$SB/docker/session-group"
  run_setup --plan --role server --pairing-address "$ADDRESS"
  [[ "$output" == *'present  Docker answers builder without the docker group'* ]]
  [[ "$output" != *usermod* ]]
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'PRESENT Docker answers builder without the docker group'* ]]
  ! grep -q usermod "$FAKE_LOG"
}

@test "Podman is refused, as the docker command or on its own" {
  image_tools
  cp "$SB/docker-stub" "$SB/bin/docker"
  touch "$SB/docker/podman"
  run_setup --plan --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ]
  [[ "$output" == *'refuse   Podman is installed as the docker command; the Orca server needs Docker Engine'* ]]
  apply_server
  [ "$status" -eq 1 ]
  [[ "$output" == *'Podman is installed as the docker command; the Orca server needs Docker Engine. Remove Podman'* ]]
  rm "$SB/bin/docker"
  fake_present podman
  apply_server
  [ "$status" -eq 1 ]
  [[ "$output" == *'Podman is installed; the Orca server needs Docker Engine'* ]]
  no_calls
}

@test "a Docker that does not work is refused with the reason" {
  image_tools
  existing_docker
  rm "$SB/docker/compose"
  apply_server
  [ "$status" -eq 1 ]
  [[ "$output" == *'Docker cannot run the Orca server: the Docker Compose plugin (docker compose) is missing.'* ]]
  touch "$SB/docker/compose"
  rm "$SB/docker/daemon"
  apply_server
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker cannot run the Orca server: Docker's daemon does not answer (is the docker service running?)."* ]]
  # Docker's packages from another source without a docker command.
  rm "$SB/bin/docker"
  echo containerd >>"$FAKE_DPKG"
  apply_server
  [ "$status" -eq 1 ]
  [[ "$output" == *'there is no docker command'* ]]
  [ -z "$(grep -e '^sudo ' -e '^docker ' "$FAKE_LOG")" ] || { cat "$FAKE_LOG"; return 1; }
}

# ------------------------------------------------------------------ compose.yaml

@test "compose.yaml: your UID:GID and home, one published port, read-only, tmpfs /tmp, init, no pairing, same-path mounts" {
  image_tools
  existing_docker
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(head -n 1 "$COMPOSE")" = '# orca-setup: Orca server container for this user' ]
  ! grep -q '@[A-Z_]*@' "$COMPOSE"
  grep -qxF "    image: \"$IMAGE@sha256:$D1\"" "$COMPOSE"
  grep -qxF '    pull_policy: never' "$COMPOSE"
  grep -qF 'command: ["python3", "/opt/orca-service.py", "run", "bash"' "$COMPOSE"
  grep -qF '"serve", "--supervise", "--no-pairing"' "$COMPOSE"
  [ -f "$HOME/.config/orca-setup/docker/orca-service.py" ]
  # The compose project's bridge network, with exactly one published port: 6768, on the publish address only (by
  # default the IPv4 pairing address), recorded like the pairing address; the host's name, not the container's id.
  run ! grep -q network_mode "$COMPOSE"
  [ "$(grep -c '^    ports:$' "$COMPOSE")" -eq 1 ]
  [ "$(sed -n '/^    ports:$/,/^    [a-z]/p' "$COMPOSE" | grep '^      - ')" = "      - \"$ADDRESS:6768:6768/tcp\"" ]
  [ "$(grep -c '6768/tcp' "$COMPOSE")" -eq 1 ]
  grep -qxF "  publish-address: \"$ADDRESS\"" "$COMPOSE"
  grep -qxF "  pairing-address: \"$ADDRESS\"" "$COMPOSE"
  grep -qxF '    hostname: "fakehost"' "$COMPOSE"
  grep -qxF '    restart: unless-stopped' "$COMPOSE"
  grep -qxF '    init: true' "$COMPOSE"
  grep -qxF '    user: "1000:1000"' "$COMPOSE"
  grep -qxF '    read_only: true' "$COMPOSE"
  grep -qxF '      - /tmp:exec,mode=1777' "$COMPOSE"
  grep -qxF '    cap_drop: ["ALL"]' "$COMPOSE"
  grep -qxF '    security_opt: ["no-new-privileges:true"]' "$COMPOSE"
  grep -qxF "      HOME: \"$HOME\"" "$COMPOSE"
  grep -qxF "      CLAUDE_CONFIG_DIR: \"$HOME/.claude\"" "$COMPOSE"
  grep -qxF "  workdir: \"$HOME/orca\"" "$COMPOSE"
  # The container's home comes from its own host directory; every other mount is the same path on both sides.
  grep -qxF "        source: \"$HOME/.local/share/orca-setup/home\"" "$COMPOSE"
  [ "$(grep -A1 "source: \"$HOME/.local/share/orca-setup/home\"" "$COMPOSE" | tail -n 1)" = "        target: \"$HOME\"" ]
  local dir
  for dir in orca .orca .codex .claude .config/gh .gemini .grok .dsh .pi .omp; do
    grep -qxF "        source: \"$HOME/$dir\"" "$COMPOSE"
    [ "$(grep -A1 "source: \"$HOME/$dir\"" "$COMPOSE" | tail -n 1)" = "        target: \"$HOME/$dir\"" ]
    [ -d "$HOME/$dir" ]
    [ -d "$HOME/.local/share/orca-setup/home/$dir" ]
  done
  [ -d "$HOME/orca/projects" ] && [ -d "$HOME/orca/workspaces" ]
  [ "$(grep -c 'create_host_path: false' "$COMPOSE")" -eq "$(grep -c '      - type: bind' "$COMPOSE")" ]
  # No single file is mounted: Claude's .claude.json lives in ~/.claude through CLAUDE_CONFIG_DIR.
  [[ "$(cat "$COMPOSE")" != *'.claude.json"'* ]]
  [[ "$(cat "$COMPOSE")" != *mem_limit* ]]
  # The host's manifest/local/, read-only, and a log that leaves with its container.
  [ "$(grep -A2 "source: \"$HOME/.config/orca-setup/docker/manifest-local\"" "$COMPOSE" | tail -n 2 | paste -sd ' ' -)" = \
    '        target: "/opt/orca-setup/manifest/local"         read_only: true' ]
  grep -qxF '      driver: json-file' "$COMPOSE"
}

@test "the host's manifest/local/ reaches the container as its overlay, and bad mount rows stop the run" {
  image_tools
  existing_docker
  cp -R "$REPO_ROOT/manifest" "$SB/manifest"
  export ORCA_SETUP_MANIFEST_DIR=$SB/manifest
  mkdir -p "$SB/manifest/local"
  echo '{"settings":{"defaultTuiAgent":"claude"}}' >"$SB/manifest/local/orca-settings.json"
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'+ copy manifest/local to ~/.config/orca-setup/docker/manifest-local'* ]]
  "$REAL_DIFF" "$SB/manifest/local/orca-settings.json" "$HOME/.config/orca-setup/docker/manifest-local/orca-settings.json"
  apply_server
  [ "$status" -eq 0 ]
  only_present
  echo '{"settings":{"defaultTuiAgent":"codex"}}' >"$SB/manifest/local/orca-settings.json"
  apply_server
  [[ "$output" == *'+ copy manifest/local to'* ]]
  grep -q codex "$HOME/.config/orca-setup/docker/manifest-local/orca-settings.json"
  : >"$FAKE_LOG"
  printf '/data\tdata\n' >"$SB/manifest/local/server-mounts.tsv"
  apply_server
  [ "$status" -eq 1 ]
  [[ "$output" == *'manifest/server-mounts.tsv (or its local overlay): /data must be a path relative to the home directory'* ]]
  no_calls
}

@test "container limits come from manifest/local/server-limits.env; unknown keys and bad values stop the render" {
  . "$REPO_ROOT/lib/common.sh"
  cp -R "$REPO_ROOT/manifest" "$SB/manifest"
  export ORCA_SETUP_MANIFEST_DIR=$SB/manifest
  . "$REPO_ROOT/lib/manifest.sh"
  . "$REPO_ROOT/lib/orca-server.sh"
  ORCA_SETUP_ROOT=$REPO_ROOT
  mkdir -p "$SB/manifest/local"
  printf 'mem_limit=8g\npids_limit=4096\nmem_limit=16g\ncpus=2.5\n' >"$SB/manifest/local/server-limits.env"
  run server_compose "$IMAGE@sha256:$D1" "$HOME/orca" "$ADDRESS" "$ADDRESS"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'    mem_limit: "16g"\n    pids_limit: "4096"\n    cpus: "2.5"\n'* ]]
  printf 'pids_limit=8\n' >"$SB/manifest/local/server-limits.env"
  run server_compose "$IMAGE@sha256:$D1" "$HOME/orca" "$ADDRESS" "$ADDRESS"
  [ "$status" -ne 0 ]
  [[ "$output" == *'must be a number, 64 or more'* ]]
  printf 'privileged=true\n' >"$SB/manifest/local/server-limits.env"
  run server_compose "$IMAGE@sha256:$D1" "$HOME/orca" "$ADDRESS" "$ADDRESS"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unknown key privileged'* ]]
}

@test "--workdir is mounted at its own path, recorded, and Orca's ~/orca links to it" {
  image_tools
  existing_docker
  local dir
  for dir in relative/dir / "$HOME" "$HOME/orca/inner" /etc/orca "$HOME/.codex/work" "$HOME/.codex" "$HOME/.orca" "$HOME/.config" "/srv/my dir"; do
    run_setup --plan --role server --pairing-address "$ADDRESS" --workdir "$dir"
    [ "$status" -eq 1 ] || { echo "accepted: $dir"; return 1; }
    [[ "$output" == *"--workdir"*"is refused"* ]] || [[ "$output" == *'--workdir needs'* ]]
  done
  apply_server --workdir "$SB/data/orca/"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF "  workdir: \"$SB/data/orca\"" "$COMPOSE"
  grep -qxF "        source: \"$SB/data/orca\"" "$COMPOSE"
  [ -d "$SB/data/orca/workspaces" ]
  [ "$(readlink "$HOME/.local/share/orca-setup/home/orca")" = "$SB/data/orca" ]
  [ ! -e "$HOME/orca" ]
  # A re-run without --workdir keeps the recorded one.
  apply_server
  [ "$status" -eq 0 ]
  only_present
  # Back to the default: the link becomes the mount point again.
  apply_server --workdir '~/orca'
  [ "$status" -eq 0 ]
  [ -d "$HOME/.local/share/orca-setup/home/orca" ] && [ ! -L "$HOME/.local/share/orca-setup/home/orca" ]
  grep -qxF "  workdir: \"$HOME/orca\"" "$COMPOSE"
}

@test "--workdir and --upgrade-image are for Linux servers only" {
  run_setup --plan --role client --workdir "$SB/data"
  [ "$status" -eq 1 ]
  [[ "$output" == *'are for --role server on Linux'* ]]
  run_setup --check --role server --upgrade-image
  [ "$status" -eq 1 ]
  [[ "$output" == *'--upgrade-image works only with --apply'* ]]
  fake_uname Darwin arm64
  run_setup --plan --role server --workdir "$SB/data"
  [ "$status" -eq 1 ]
  [[ "$output" == *'are for Linux servers'* ]]
  no_calls
}

# ------------------------------------------------------------------ publish address

# publish_problem <address>: the refusal of setup.sh's address check, without the host lookup.
publish_problem() { (. "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/orca-server.sh"; publish_address_problem "$1"); }

@test "--publish-address defaults to an IPv4 pairing address of this host and is required for a host name" {
  run_setup --plan --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"publish  $ADDRESS:6768 (the pairing address); port 6768 is not reachable on this host's other addresses"* ]]
  [[ "$output" == *"network  the compose project's bridge network; only port 6768 is published, on $ADDRESS alone"* ]]
  run_setup --plan --role server --pairing-address devbox.example.net
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'missing  --publish-address <ipv4>'* ]]
  run_setup --apply --role server --pairing-address devbox.example.net
  [ "$status" -eq 1 ]
  [[ "$output" == *'--pairing-address devbox.example.net is a host name, so --apply --role server also needs --publish-address <ipv4>'* ]]
  # An IPv4 pairing address this host does not have (clients reach it through a VPN mapping) is no default either.
  run_setup --plan --role server --pairing-address 198.51.100.7
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'refuse   publishing port 6768 on 198.51.100.7 (the pairing address): it is not assigned to a network interface of this host; pass --publish-address <ipv4>'* ]]
  run_setup --apply --role server --pairing-address 198.51.100.7
  [ "$status" -eq 1 ]
  [[ "$output" == *'port 6768 cannot be published on 198.51.100.7 (the pairing address): it is not assigned to a network interface of this host.'* ]]
  run_setup --plan --role server --pairing-address devbox.example.net --publish-address "$ADDRESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"publish  $ADDRESS:6768 (--publish-address)"* ]]
  no_calls
}

@test "--publish-address must be an IPv4 address of this host; names, loopback, wildcard, broadcast and multicast are refused" {
  local address
  for address in devbox.example.net 127.0.0.1 127.0.0.2 0.0.0.0 255.255.255.255 224.0.0.251 239.1.2.3 256.1.1.1 \
    203.0.113.010 1.2.3 '' 'a b' ::1 "$ADDRESS:6768"; do
    run_setup --plan --role server --pairing-address "$ADDRESS" --publish-address "$address"
    [ "$status" -eq 1 ] || { echo "accepted: $address"; return 1; }
    [[ "$output" == *"--publish-address $address is refused: "* ]] || [[ "$output" == *'--publish-address needs'* ]] ||
      { echo "$output"; return 1; }
  done
  [[ "$(publish_problem 224.0.0.251)" == *multicast* ]]
  run_setup --plan --role server --pairing-address "$ADDRESS" --publish-address 198.51.100.7
  [ "$status" -eq 1 ]
  [[ "$output" == *'--publish-address 198.51.100.7 is refused: it is not assigned to a network interface of this host.'* ]]
  echo 198.51.100.7 >>"$SB/ip-addresses"
  run_setup --plan --role server --pairing-address "$ADDRESS" --publish-address=198.51.100.7
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'publish  198.51.100.7:6768 (--publish-address)'* ]]
  # Without ip the address cannot be checked, so it is refused.
  rm "$SB/bin/ip"
  run_setup --plan --role server --pairing-address "$ADDRESS" --publish-address 198.51.100.7
  [ "$status" -eq 1 ]
  [[ "$output" == *'--publish-address 198.51.100.7 is refused: it cannot be checked: the ip command (iproute2) is missing.'* ]]
  no_calls
}

@test "--publish-address is for Linux server hosts only; the CI loopback override allows 127.0.0.2, never 127.0.0.1" {
  run_setup --plan --role client --publish-address "$ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'--publish-address is for --role server'* ]]
  run_setup --auth-gh --publish-address "$ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'--publish-address does not apply to --auth-*'* ]]
  ORCA_SETUP_CONTAINER=orca-server run_setup --plan --role server --publish-address "$ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'--publish-address belongs to the Docker host'* ]]
  # lo answers every 127.0.0.0/8 address, so the override needs no interface for it.
  ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS=1 run_setup --plan --role server --pairing-address 127.0.0.2
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'publish  127.0.0.2:6768 (the pairing address)'* ]]
  ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS=1 run_setup --plan --role server --pairing-address 127.0.0.2 --publish-address 127.0.0.1
  [ "$status" -eq 1 ]
  [[ "$output" == *'--publish-address 127.0.0.1 is refused: it is a loopback address'* ]]
  fake_uname Darwin arm64
  run_setup --plan --publish-address "$ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'--publish-address is for Linux servers'* ]]
  no_calls
}

@test "the publish address is recorded: a re-run keeps it, another one re-creates the container, a default follows the pairing address" {
  image_tools
  existing_docker
  echo 192.0.2.10 >>"$SB/ip-addresses"
  run_setup --apply --role server --pairing-address devbox.example.net --publish-address "$ADDRESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF "  publish-address: \"$ADDRESS\"" "$COMPOSE"
  grep -qxF "      - \"$ADDRESS:6768:6768/tcp\"" "$COMPOSE"
  # A re-run without --publish-address keeps it.
  : >"$FAKE_LOG"
  run_setup --apply --role server --pairing-address devbox.example.net
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  only_present
  run ! grep -q compose "$FAKE_LOG"
  run_setup --plan --role server --pairing-address devbox.example.net
  [[ "$output" == *"publish  $ADDRESS:6768 (recorded in ~/.config/orca-setup/docker/compose.yaml)"* ]]
  # Another address re-creates the container.
  : >"$FAKE_LOG"
  run_setup --apply --role server --pairing-address devbox.example.net --publish-address 192.0.2.10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF '      - "192.0.2.10:6768:6768/tcp"' "$COMPOSE"
  grep -qx "docker compose --file $COMPOSE --project-name $PROJECT_NAME up --detach" "$FAKE_LOG"
  [ "$(sed -n 2p "$SB/docker/ports")" = '192.0.2.10|6768|6768/tcp' ]
  # A given address stays when the pairing address changes; a default (the pairing address) follows it.
  run_setup --apply --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF '  publish-address: "192.0.2.10"' "$COMPOSE"
  run_setup --apply --role server --pairing-address "$ADDRESS" --publish-address "$ADDRESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run_setup --apply --role server --pairing-address 192.0.2.10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF '  publish-address: "192.0.2.10"' "$COMPOSE"
  grep -qxF '      - "192.0.2.10:6768:6768/tcp"' "$COMPOSE"
}

# ------------------------------------------------------------------ image.lock

@test "compose rendering refuses an incomplete mount inventory" {
  . "$REPO_ROOT/lib/orca-server.sh"
  server_mounts() { printf '/partial\tpartial inventory\n'; return 1; }
  run server_compose_render image "$HOME/orca" "$ADDRESS" "$ADDRESS" config
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "image.lock: re-runs keep the digest; --upgrade-image pulls the newest one and re-creates the container" {
  image_tools
  existing_docker
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  fake_registry "$IMAGE:main" "$D2"
  : >"$FAKE_LOG"
  apply_server
  [ "$status" -eq 0 ]
  only_present
  grep -qx "image=$IMAGE@sha256:$D1" "$LOCK"
  ! grep -q pull "$FAKE_LOG"
  # --plan says what --upgrade-image would do, without pulling.
  run_setup --plan --role server --pairing-address "$ADDRESS" --upgrade-image
  [[ "$output" == *"upgrade  pull $IMAGE:main; when its digest differs, lock it and re-create the container"* ]]
  ! grep -q pull "$FAKE_LOG"
  apply_server --upgrade-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "image=$IMAGE@sha256:$D2" "$LOCK"
  grep -qxF "    image: \"$IMAGE@sha256:$D2\"" "$COMPOSE"
  grep -qx "docker pull $IMAGE:main" "$FAKE_LOG"
  grep -qx "docker compose --file $COMPOSE --project-name $PROJECT_NAME up --detach" "$FAKE_LOG"
  # The newest is already locked: nothing to re-create.
  : >"$FAKE_LOG"
  apply_server --upgrade-image
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRESENT image $IMAGE@sha256:$D2 (the newest $IMAGE:main)"* ]]
  ! grep -q compose "$FAKE_LOG"
}

@test "a locked image that is not on the host is pulled by its digest, never upgraded" {
  image_tools
  existing_docker
  apply_server
  [ "$status" -eq 0 ]
  fake_registry "$IMAGE:main" "$D2"
  rm "$SB/docker/images/"*
  : >"$FAKE_LOG"
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep pull "$FAKE_LOG")" = "docker pull $IMAGE@sha256:$D1" ]
  grep -qx "image=$IMAGE@sha256:$D1" "$LOCK"
}

@test "ORCA_SETUP_IMAGE replaces the published image (tests and CI only)" {
  image_tools
  existing_docker
  fake_registry localhost:5000/orca-server:ci "$D2"
  ORCA_SETUP_IMAGE=localhost:5000/orca-server:ci run_setup --plan --role server --pairing-address "$ADDRESS"
  [[ "$output" == *'source   localhost:5000/orca-server:ci (ORCA_SETUP_IMAGE: for tests and CI only)'* ]]
  ORCA_SETUP_IMAGE=localhost:5000/orca-server:ci apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "image=localhost:5000/orca-server@sha256:$D2" "$LOCK"
}

@test "manifest/local/Dockerfile is built FROM the locked image and runs instead" {
  image_tools
  existing_docker
  cp -R "$REPO_ROOT/manifest" "$SB/manifest"
  export ORCA_SETUP_MANIFEST_DIR=$SB/manifest
  mkdir -p "$SB/manifest/local"
  printf 'ARG ORCA_SERVER_IMAGE\nFROM ${ORCA_SERVER_IMAGE}\n' >"$SB/manifest/local/Dockerfile"
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run grep '^docker build ' "$FAKE_LOG"
  [[ "$output" == "docker build --pull=false --build-arg ORCA_SERVER_IMAGE=$IMAGE@sha256:$D1 --tag orca-setup/orca-server-local:"*" --file $SB/manifest/local/Dockerfile $SB/manifest/local" ]]
  local tag
  tag=$(sed -n 's/^local=//p' "$LOCK")
  grep -qxF "    image: \"$tag\"" "$COMPOSE"
  : >"$FAKE_LOG"
  apply_server
  [ "$status" -eq 0 ]
  only_present
  ! grep -q build "$FAKE_LOG"
  printf 'RUN true\n' >>"$SB/manifest/local/Dockerfile"
  apply_server
  [ "$status" -eq 0 ]
  grep -q '^docker build ' "$FAKE_LOG"
  [ "$(sed -n 's/^local=//p' "$LOCK")" != "$tag" ]
}

# ------------------------------------------------------------------ guards

@test "the pairing role is checked inside the image before the container starts" {
  image_tools
  existing_docker
  printf '{"environments":[{"name":"control"}]}\n' >"$ORCA_USER_DATA/orca-environments.json"
  apply_server
  [ "$status" -eq 1 ]
  [[ "$output" == *'saved environment: control'* ]]
  [[ "$output" == *'already holds the other pairing role'* ]]
  ! grep -q 'compose' "$FAKE_LOG"
}

@test "--apply --role server requires --pairing-address and refuses a leftover native server unit" {
  run_setup --apply --role server
  [ "$status" -eq 1 ]
  [[ "$output" == *'--apply --role server on Linux requires --pairing-address'* ]]
  mkdir -p "$HOME/.config/systemd/user"
  printf '# orca-setup: Orca server for this user\n[Service]\n' >"$HOME/.config/systemd/user/orca-serve.service"
  run_setup --plan --role server --pairing-address "$ADDRESS"
  [[ "$output" == *'remove   the native server unit an earlier orca-setup wrote'* ]]
  apply_server
  [ "$status" -eq 1 ]
  [[ "$output" == *'systemctl --user disable --now orca-serve.service && rm ~/.config/systemd/user/orca-serve.service'* ]]
  no_calls
}

@test "the runtime never becoming reachable stops --apply" {
  image_tools
  existing_docker
  # shellcheck disable=SC2016
  fake_cmd orca-ide 'exit 1'
  export ORCA_SETUP_SERVE_WAIT=0
  apply_server
  [ "$status" -eq 1 ]
  [[ "$output" == *"the Orca runtime in $SERVER_NAME is not reachable 0s after it started; see: docker logs $SERVER_NAME"* ]]
  [[ "$output" != *BASELINE_DONE* ]]
}

# ------------------------------------------------------------------ logins

@test "--auth-* runs inside the container through docker exec" {
  image_tools
  existing_docker
  apply_server
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016
  fake_cmd gh '[ "$1 $2" = "auth status" ] && exit 1; echo "gh $* GH_BROWSER=${GH_BROWSER:-unset} container=${ORCA_SETUP_CONTAINER:-}" >>"$FAKE_LOG"'
  : >"$FAKE_LOG"
  SSH_CONNECTION='198.51.100.1 50000 198.51.100.2 22' run_setup --auth-gh
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"+ docker exec --interactive --env SSH_CONNECTION $SERVER_NAME /opt/orca-setup/setup.sh --auth-gh"* ]]
  grep -qx 'gh auth login --hostname github.com --git-protocol https --web GH_BROWSER=true container=orca-server' "$FAKE_LOG"
  echo exited >"$SB/docker/container"
  run_setup --auth-codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"the $SERVER_NAME container is not running"* ]]
}

# ------------------------------------------------------------------ check

@test "--check combines the host's items with the container's report" {
  image_tools
  existing_docker
  fake_systemd
  apply_server --power
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'+ sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target'* ]]
  fake_cmd gh 'exit 1' # not logged in
  run_setup --check --role server --media --power
  no_secret
  [[ "$output" == *'Sleep targets: masked'* ]]
  [[ "$output" == *'Docker: working (Engine 27.3.1, Compose 2.29.7)'* ]]
  [[ "$output" == *'docker group: member'* ]]
  [[ "$output" == *"Orca server image: locked ($IMAGE@sha256:$D1)"* ]]
  [[ "$output" == *'Newest image: same as image.lock'* ]]
  [[ "$output" == *'Orca server container: running'* ]]
  [[ "$output" == *"Published endpoint: $ADDRESS:6768 (not reachable on this host's other addresses)"* ]]
  [[ "$output" == *'Mount ~/orca: ok'* ]]
  [[ "$output" == *'Mount ~/.local/share/orca-setup/home: ok'* ]]
  [[ "$output" == *'PRESENT codex'* ]]
  [[ "$output" == *'MISSING poppler'* ]]
  [[ "$output" == *'Orca runtime: reachable'* ]]
  [[ "$output" == *'Orca Codex: PENDING'* ]]
  [[ "$output" == *'GitHub auth: PENDING'* ]]
  [[ "$output" != *'PATH block'* ]]
  [[ "$output" == *"MISSING_ITEMS $status"* ]]
  # GitHub, Codex and the four media rows of the image (they are missing in this fake one).
  [ "$status" -eq 6 ] || { echo "$output"; return 1; }
  fake_registry "$IMAGE:main" "$D2"
  run_setup --check --json --role server
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  printf '%s' "$output" | "$REAL_NODE" -e '
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const fail = m => { console.error(m); process.exit(1); };
    if (r.schema !== "orca-setup-check/1" || r.missing !== 2) fail("schema or missing");
    if (r.server.form !== "docker" || !r.server.image.endsWith(process.argv[1]) || r.server.newest !== "sha256:" + process.argv[2]) fail("server");
    if (r.server.container !== "running" || r.server.endpoint !== "203.0.113.10:6768") fail("container");
    if (!r.items.some(i => i.name === "Docker" && !i.counted)) fail("Docker item");
    if (!r.items.some(i => i.name === "Newest image" && i.state.startsWith("newer one available") && !i.counted)) fail("newest");
    if (r.device.distro !== "ubuntu 24.04") fail("device");
  ' "$D1" "$D2"
}

@test "--check without a running container reports the host's items and counts the container" {
  image_tools
  existing_docker
  apply_server
  [ "$status" -eq 0 ]
  echo "exited $(sed -n 's/^      org.orca-setup.config: "\(.*\)"$/\1/p' "$COMPOSE")" >"$SB/docker/container"
  run_setup --check
  [[ "$output" == *'Orca server container: INACTIVE (exited; --apply starts it)'* ]]
  [[ "$output" == *"Container checks (tools, logins, Orca): UNREACHABLE (the $SERVER_NAME container is not running"* ]]
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  echo 'running 0-0' >"$SB/docker/container"
  run_setup --check --json
  [[ "$output" == *'"name": "Orca server container", "state": "STALE (not created from the current compose.yaml; --apply re-creates it)", "counted": true'* ]]
  [[ "$output" == *'"server": {"form": "docker"'* ]]
  rm "$SB/docker/daemon"
  run_setup --check
  [[ "$output" == *'Docker: UNREACHABLE'* ]]
  [[ "$output" == *'Orca server container: UNREACHABLE (Docker does not answer)'* ]]
  rm -rf "$HOME/.codex"
  run_setup --check
  [[ "$output" == *'Mount ~/.codex: MISSING'* ]]
}

@test "--check counts a container published on another address, on every address or on the host network" {
  image_tools
  existing_docker
  apply_server
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  fake_cmd gh 'exit 1' # not logged in
  run_setup --check
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  # Also on every address: counted.
  printf 'orca-server_default\n%s|6768|6768/tcp\n0.0.0.0|6768|6768/tcp\n::|6768|6768/tcp\n' "$ADDRESS" >"$SB/docker/ports"
  run_setup --check
  [[ "$output" == *"Published endpoint: WRONG (published on $ADDRESS:6768, 0.0.0.0:6768, [::]:6768; expected $ADDRESS:6768 only; --apply re-creates it)"* ]]
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  printf 'orca-server_default\n198.51.100.7|6768|6768/tcp\n%s|8080|8080/tcp\n' "$ADDRESS" >"$SB/docker/ports"
  run_setup --check
  [[ "$output" == *"Published endpoint: WRONG (published on 198.51.100.7:6768, $ADDRESS:8080 (to 8080/tcp); expected $ADDRESS:6768 only"* ]]
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  printf 'orca-server_default\n' >"$SB/docker/ports"
  run_setup --check
  [[ "$output" == *"Published endpoint: WRONG (published on nothing; expected $ADDRESS:6768 only"* ]]
  # A container from before the publish address, on the host network.
  printf 'host\n' >"$SB/docker/ports"
  run_setup --check --json
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [[ "$output" == *'"name": "Published endpoint", "state": "WRONG (it runs on the host network: port 6768 answers on every host address; --apply re-creates it)", "counted": true'* ]]
  [[ "$output" == *'"endpoint": "host"'* ]]
  # A stopped container publishes nothing; only its state counts.
  echo "exited $(sed -n 's/^      org.orca-setup.config: "\(.*\)"$/\1/p' "$COMPOSE")" >"$SB/docker/container"
  run_setup --check --json
  [[ "$output" != *'Published endpoint'* ]]
  [[ "$output" == *'"endpoint": "none"'* ]]
}

@test "--check --role server before --apply counts what is missing, and changes nothing" {
  run_setup --check --role server
  [[ "$output" == *'Docker: MISSING (run --apply --role server)'* ]]
  [[ "$output" == *'docker group: MISSING'* ]]
  [[ "$output" == *'Orca server image: MISSING (no image.lock'* ]]
  [[ "$output" == *'Mount ~/orca: MISSING'* ]]
  [ "$status" -gt 4 ]
  [ ! -e "$HOME/orca" ]
  [ ! -e "$HOME/.config/orca-setup" ]
  no_calls
}

# ------------------------------------------------------------------ inside the container

@test "inside the container, setup.sh checks and plans the image, and leaves the host to the host" {
  image_tools
  fake_cmd gh 'exit 1' # not logged in
  export ORCA_SETUP_CONTAINER=orca-server
  touch "$SB/runtime-up"
  run_setup --plan --role server --power
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'(inside the orca-server container)'* ]]
  [[ "$output" == *'Docker host: Docker, the image and the mounts are planned on the host'* ]]
  [[ "$output" == *'Baseline tools (in the image):'* ]]
  [[ "$output" == *'skip: it belongs to the Docker host'* ]]
  [[ "$output" != *'PATH (--apply)'* ]]
  [[ "$output" != *'sudo: '* ]]
  no_secret
  run_setup --check --role server
  [[ "$output" == *'Docker host: not visible from inside the container (run ./setup.sh --check on the host; not counted)'* ]]
  [[ "$output" == *'Orca runtime: reachable'* ]]
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  run_setup --check --json --role server
  [[ "$output" == *'"server": {"form": "docker", "host": "not-checked"}'* ]]
  run_setup --plan --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'--pairing-address belongs to the Docker host'* ]]
  run_setup --apply --role client
  [ "$status" -eq 1 ]
  [[ "$output" == *'the orca-server container is a server'* ]]
  no_calls
}

@test "new deployment names are stable, scoped by user/config directory, and used by the rendered server" {
  . "$REPO_ROOT/lib/orca-server.sh"
  first=$(server_project_name)
  [[ "$first" =~ ^orca-1000-[a-f0-9]{12}$ ]]
  [ "$(server_project_name)" = "$first" ]
  [ ! -e "$(server_config_dir)" ]
  other=$(XDG_CONFIG_HOME=$SB/another-config server_project_name)
  [ "$other" != "$first" ]
  image_tools
  apply_server
  [ "$status" -eq 0 ]
  grep -qx "name: $first" "$COMPOSE"
  grep -qx "    container_name: $first-server" "$COMPOSE"
  [ "$(server_project_name)" = "$first" ]
}

@test "legacy deployment names are preserved; archived config is reused after uninstall" {
  mkdir -p "$(dirname "$COMPOSE")"
  printf '# orca-setup: Orca server container for this user\nname: orca-server\nx-orca-setup:\n  config-file: "%s"\n' "$SB/custom.toml" >"$COMPOSE"
  . "$REPO_ROOT/lib/orca-server.sh"
  [ "$(server_project_name)" = orca-server ]
  [ "$(server_container_name orca-server)" = orca-server ]
  [ "$(server_container_name executor-gateway)" = executor-gateway ]
  cp "$COMPOSE" "$(dirname "$COMPOSE")/compose.uninstalled.yaml"
  rm "$COMPOSE"
  [ "$(server_compose_value config-file)" = "$SB/custom.toml" ]
  [ "$(server_project_name)" != orca-server ]
}
