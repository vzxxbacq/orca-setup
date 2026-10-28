# shellcheck shell=bash disable=SC2154 # setup.sh sets pairing_address, publish_address, PUBLISH_*, upgrade_image, task_source, modules
# The Linux server (--role server, README section 6.7): Orca and every agent run in the orca-server container from
# ghcr.io/vzxxbacq/orca-server; the host gets Docker Engine only (lib/docker-host.sh). The container runs as the
# user's UID:GID with the user's home path as HOME, on its compose project's bridge network with port 6768 published
# on one private host address only (the publish address), with a read-only root filesystem; its home is a dedicated
# host directory, and the work, Orca data and agent directories of manifest/server-mounts.tsv are bind-mounted at the
# same paths. The image digest is locked in image.lock; only --upgrade-image moves it.
# The server runs with --no-pairing; unattended setup never asks for a pairing offer. The explicit TUI pairing
# action is implemented separately in server-manage.py. Uses setup.sh's pairing_address, publish_address, PUBLISH_ADDRESS,
# PUBLISH_PROBLEM, workdir, upgrade_image, task_source, modules, check_json and report.

ORCA_SERVER_PORT=6768
ORCA_SERVER_NAME=orca-server # resolved for the current deployment by setup.sh
ORCA_SERVER_IMAGE=ghcr.io/vzxxbacq/orca-server:main
ORCA_SERVER_ROOT=/opt/orca-setup # this repository's scripts in the image
# Modules the image has built in, and modules that only the host can run.
ORCA_SERVER_IMAGE_MODULES='media android agent-gemini'
LEGACY_SERVE_UNIT_MARKER='# orca-setup: Orca server for this user'

server_config_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/orca-setup/docker"; }
server_compose_file() { printf '%s/compose.yaml\n' "$(server_config_dir)"; }
server_lock_file() { printf '%s/image.lock\n' "$(server_config_dir)"; }
# Keep existing project names; new deployments use a stable user/path namespace.
server_project_name() {
  local file project digest
  file=$(server_compose_file)
  if [ -r "$file" ] && [ "$(head -n 1 "$file")" = '# orca-setup: Orca server container for this user' ]; then
    project=$(sed -n 's/^name: \([a-z0-9][a-z0-9_-]*\)$/\1/p' "$file" | head -n 1)
    if [ -n "$project" ]; then printf '%s\n' "$project"; return; fi
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$(server_config_dir)" | sha256sum) || return 1
  else
    digest=$(printf '%s' "$(server_config_dir)" | shasum -a 256) || return 1
  fi
  printf 'orca-%s-%.12s\n' "$(id -u)" "$digest"
}

server_container_name() { # <Compose service>
  local project
  project=$(server_project_name)
  if [ "$project" = orca-server ]; then printf '%s\n' "$1"
  else printf '%s-%s\n' "$project" "${1#orca-}"; fi
}

# The container's home directory on the host.
server_home() { printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/orca-setup/home"; }
# ORCA_SETUP_IMAGE replaces the published image for tests and CI only.
server_image_source() { printf '%s\n' "${CONFIG_IMAGE:-${ORCA_SETUP_IMAGE:-$ORCA_SERVER_IMAGE}}"; }

# tilde <path>: the path with $HOME shown as ~ (for messages only).
# shellcheck disable=SC2088 # a literal ~ for display
tilde() { case "$1" in "$HOME") printf '~\n' ;; "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;; *) printf '%s\n' "$1" ;; esac; }

# pairing_address_problem <address>: why clients could not dial this address; prints nothing when it is usable.
# Accepts an IPv4 address or a host name. Loopback, wildcard and unspecified addresses are refused; tests may
# allow 127.0.0.2-127.255.255.254 with ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS=1 (never 127.0.0.1).
pairing_address_problem() {
  local address=$1 octet a b c d
  case "$address" in
    '') echo 'it is empty'; return ;;
    localhost | localhost. | *.localhost | *.localhost.) echo 'it is a loopback name that only reaches the server itself'; return ;;
    '*' | :: | '[::]' | ::1 | '[::1]') echo 'it is a wildcard or loopback address'; return ;;
  esac
  if [[ "$address" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for octet in "${BASH_REMATCH[@]:1}"; do
      [ "$((10#$octet))" -le 255 ] || { echo 'it is not a valid IPv4 address'; return; }
    done
    a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]})) c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
    if [ "$a" -eq 0 ]; then echo 'it is the wildcard (unspecified) address'
    elif [ "$a" -eq 255 ] && [ "$b" -eq 255 ] && [ "$c" -eq 255 ] && [ "$d" -eq 255 ]; then echo 'it is the broadcast address'
    elif [ "$a" -eq 127 ]; then
      if [ "${ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS:-}" != 1 ] || [ "$address" = 127.0.0.1 ] || [ "$d" -eq 0 ] || [ "$d" -eq 255 ]; then
        echo 'it is a loopback address that only reaches the server itself'
      fi
    fi
    return
  fi
  # A name whose last label is numeric would be read as a malformed IP address.
  if [[ "${address%.}" =~ (^|\.)[0-9]+$ ]]; then
    echo 'it is not a valid IPv4 address'
  elif [ "${#address}" -gt 253 ] || ! [[ "$address" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$ ]]; then
    echo 'it is neither an IPv4 address nor a host name'
  fi
}

# ipv4_shaped <value>: four dot-separated numbers, i.e. meant as an IPv4 address rather than a host name.
ipv4_shaped() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# publish_address_problem <address>: why Docker must not publish the server's port on this host address; prints
# nothing when it may. Only an IPv4 address in its plain form (as `ip` lists it); loopback, wildcard, broadcast and
# multicast addresses are refused, with the same test-only loopback override as the pairing address.
publish_address_problem() {
  local problem
  [[ "$1" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] ||
    { echo 'it is not an IPv4 address (four decimal numbers without leading zeros)'; return; }
  problem=$(pairing_address_problem "$1")
  [ -z "$problem" ] || { echo "$problem"; return; }
  [ "${1%%.*}" -lt 224 ] || [ "${1%%.*}" -gt 239 ] || echo 'it is a multicast address'
}

# publish_address_local_problem <address>: why Docker could not bind the port on this address; empty when one of the
# host's network interfaces has it (ip -4 -o addr show). With the test-only loopback override any 127.0.0.0/8
# address will do: the kernel answers all of them on lo.
publish_address_local_problem() {
  case "$1" in 127.*) [ "${ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS:-}" != 1 ] || return 0 ;; esac
  have ip || { echo 'it cannot be checked: the ip command (iproute2) is missing'; return; }
  ip -4 -o addr show 2>/dev/null | awk -v address="$1" '
    { for (i = 1; i < NF; i++) if ($i == "inet") { split($(i + 1), cidr, "/"); if (cidr[1] == address) found = 1 } }
    END { exit !found }' || echo 'it is not assigned to a network interface of this host'
}

# ---------------------------------------------------------------- paths and mounts

# server_path_problem <path>: why a path cannot be mounted at the same place in the container; empty when it can.
server_path_problem() {
  case "$1" in /*) ;; *) echo 'it is not an absolute path'; return ;; esac
  [[ "$1" =~ ^/[A-Za-z0-9._/+@-]*$ ]] || { echo 'it has characters other than letters, digits and ._/+@-'; return; }
  case "$1/" in */./* | */../* | *//*) echo 'it has an empty, . or .. component'; return ;; esac
}

# server_workdir_problem <dir>: why --workdir cannot be <dir>; empty when it can.
server_workdir_problem() {
  local dir=$1 problem path
  problem=$(server_path_problem "$dir")
  [ -z "$problem" ] || { echo "$problem"; return; }
  case "$HOME/" in "$dir"/*) echo 'it is or contains your home directory'; return ;; esac
  case "$dir/" in
    "$HOME"/orca/?*) echo 'it is inside ~/orca; use ~/orca itself'; return ;;
    "$(server_home)"/* | "$(server_config_dir)"/*) echo "it is inside orca-setup's own directories"; return ;;
    /bin/* | /boot/* | /dev/* | /etc/* | /lib/* | /lib64/* | /proc/* | /run/* | /sbin/* | /sys/* | /usr/* | /var/run/* | \
      /opt/orca-setup/* | /opt/orca-agents/* | /opt/Orca/*)
      echo 'it is a system directory, or one the image needs'; return ;;
  esac
  # Every other mount (by its manifest key, so a workdir equal to one of them is caught too).
  while IFS=$'\t' read -r path _; do
    [ "$path" != '{workdir}' ] || continue
    path=$HOME/$path
    case "$dir/" in "$path"/*) echo "it is or is inside $(tilde "$path"), which is mounted for another purpose"; return ;; esac
    case "$path/" in "$dir"/*) echo "it contains $(tilde "$path"), which is mounted for another purpose"; return ;; esac
  done < <(manifest_rows server-mounts.tsv)
}

# server_mounts_problem: why a row of manifest/server-mounts.tsv (or its local overlay) cannot be mounted; empty when
# every row can. setup.sh checks this before anything else, so a bad local row stops the run.
server_mounts_problem() {
  local path
  while IFS=$'\t' read -r path _; do
    case "$path" in
      '{workdir}') continue ;;
      /* | *..* | '') echo "$path must be a path relative to the home directory"; return ;;
    esac
    [ -z "$(server_path_problem "$HOME/$path")" ] || { echo "$path cannot be mounted: $(server_path_problem "$HOME/$path")"; return; }
  done < <(manifest_rows server-mounts.tsv)
}

# server_mounts <workdir>: "absolute path<TAB>contents" for every directory of manifest/server-mounts.tsv (checked
# by server_mounts_problem first).
server_mounts() {
  local path contents
  while IFS=$'\t' read -r path contents; do
    case "$path" in '{workdir}') path=$1 ;; *) path=$HOME/$path ;; esac
    printf '%s\t%s\n' "$path" "$contents"
  done < <(manifest_rows server-mounts.tsv)
}

# server_dirs <workdir>: "path<TAB>description" of every host directory the container needs, in creation order.
server_dirs() {
  local path contents
  if [ "${CONFIG_HOME_MOUNT:-dedicated}" = host ]; then
    printf '%s\t%s\n' "$1" 'shared work directory' "$1/projects" 'project checkouts' "$1/workspaces" "Orca's worktrees"
    printf '%s\t%s\n' "$HOME/.orca" 'Orca user data and pairing role' "$HOME" 'your full host home directory (writable in Orca)'
    printf '%s\t%s\n' "$(server_overlay_dir)" 'a copy of manifest/local/, read-only in the container'
    return
  fi
  while IFS=$'\t' read -r path contents; do
    printf '%s\t%s\n' "$path" "$contents"
    [ "$path" != "$1" ] || printf '%s\t%s\n' "$path/projects" 'project checkouts' "$path/workspaces" "Orca's worktrees"
  done < <(server_mounts "$1")
  printf '%s\t%s\n' "$(server_home)" "the container's home directory (files written there persist)"
  printf '%s\t%s\n' "$(server_overlay_dir)" "a copy of manifest/local/, read-only in the container"
}

# server_mount_points <workdir>: the mount points inside the container's home, which must exist (as yours) before
# Docker starts the container, or Docker would create them as root.
server_mount_points() {
  local path
  while IFS=$'\t' read -r path _; do
    case "$path" in "$HOME"/*) printf '%s/%s\n' "$(server_home)" "${path#"$HOME"/}" ;; esac
  done < <(server_mounts "$1")
}

# Orca's workspace directory on a headless server is its own default, ~/orca/workspaces (upstream
# getDefaultWorkspaceDir(homedir())): neither the paired settings.update RPC nor the CLI can change it. With another
# --workdir, ~/orca in the container's home is a link to it.
server_orca_link() { printf '%s/orca\n' "$(server_home)"; }

server_host_workdir_link_matches() {
  [ -L "$HOME/orca" ] && [ -d "$HOME/orca" ] && [ -d "$1" ] &&
    [ "$(CDPATH='' cd -- "$HOME/orca" && pwd -P)" = "$(CDPATH='' cd -- "$1" && pwd -P)" ]
}

# ---------------------------------------------------------------- compose.yaml

# server_compose_value <key>: an option recorded in the rendered compose.yaml (x-orca-setup), empty without one.
server_compose_value() {
  local file
  file=$(server_compose_file)
  if [ ! -r "$file" ] && [ "$1" = config-file ]; then file="$(server_config_dir)/compose.uninstalled.yaml"; fi
  [ -r "$file" ] || return 0
  sed -n "s/^  $1: \"\\(.*\\)\"\$/\\1/p" "$file" | head -n 1
}

# server_publish_address: the host address port 6768 is published on. --publish-address; else the recorded one, which
# is kept unless it was the default (the recorded pairing address) and --pairing-address now names another; else the
# pairing address (given, else recorded) when it is an IPv4 address. Empty when there is none: clients may resolve a
# host name to an address this host never sees (a VPN mapping), so a host name needs --publish-address.
server_publish_address() {
  local recorded recorded_pairing pairing
  if [ -n "$publish_address" ]; then printf '%s\n' "$publish_address"; return; fi
  recorded=$(server_compose_value publish-address)
  recorded_pairing=$(server_compose_value pairing-address)
  if [ -n "$recorded" ] &&
    { [ "$recorded" != "$recorded_pairing" ] || [ -z "$pairing_address" ] || [ "$pairing_address" = "$recorded_pairing" ]; }; then
    printf '%s\n' "$recorded"
    return
  fi
  pairing=${pairing_address:-$recorded_pairing}
  if ipv4_shaped "$pairing"; then printf '%s\n' "$pairing"; fi
}

# server_publish_source: where PUBLISH_ADDRESS came from (for messages).
server_publish_source() {
  if [ -n "$publish_address" ]; then echo '--publish-address'
  elif [ "$PUBLISH_ADDRESS" = "$(server_compose_value publish-address)" ]; then echo "recorded in $(tilde "$(server_compose_file)")"
  else echo 'the pairing address'; fi
}

# server_limit_lines: service options for the optional container limits, read from manifest/server-limits.env and
# overridden key by key from manifest/local/server-limits.env. Unknown keys and malformed values stop the run.
server_limit_lines() {
  if [ -n "${CONFIG_FILE:-}" ]; then server_config_limit_lines; return; fi
  local base="$ORCA_SETUP_MANIFEST_DIR/server-limits.env" overlay="$ORCA_SETUP_MANIFEST_DIR/local/server-limits.env" key value
  [ -r "$overlay" ] || overlay=/dev/null
  while IFS='=' read -r key value; do
    case "$key" in
      mem_limit | memswap_limit) [[ "$value" =~ ^[0-9]+[bkmg]?$ ]] || die "server-limits.env: $key must be a size such as 16g" ;;
      pids_limit) [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 64 ] || die "server-limits.env: $key must be a number, 64 or more" ;;
      cpus) [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "server-limits.env: $key must be a number such as 4 or 2.5" ;;
      *) die "server-limits.env: unknown key $key (allowed: mem_limit memswap_limit pids_limit cpus)" ;;
    esac
    printf '    %s: "%s"\n' "$key" "$value"
  done < <(awk '
    /^[[:space:]]*(#|$)/ { next }
    { sub(/[[:space:]]+$/, ""); key = $0; sub(/=.*/, "", key)
      if (!(key in line)) order[++n] = key; line[key] = $0 }
    END { for (i = 1; i <= n; i++) print line[order[i]] }
  ' "$base" "$overlay")
}

server_volume() { # <host path> <container path> [ro]
  printf '      - type: bind\n        source: "%s"\n        target: "%s"\n' "$1" "$2"
  [ "${3:-}" != ro ] || printf '        read_only: true\n'
  printf '        bind:\n          create_host_path: false\n'
}

# The host's manifest/local/ (README section 3.7) as the container's own /opt/orca-setup/manifest/local (read-only):
# the image has no overlay, and the setup.sh inside the container applies the Orca settings and skills.
server_overlay_dir() { printf '%s/manifest-local\n' "$(server_config_dir)"; }

# server_compose_render <image> <workdir> <pairing-address> <publish-address> <config>: the compose.yaml content.
server_compose_render() {
  local volumes limits path server_network executor_volumes='' network_dir='' policy_sum=''
  local mode=${NETWORK_MODE:-direct} server_hostname server_environment='' auth_service='' auth_definition='' auth_volume=''
  local executor_auth_volume='' executor_auth_service='' executor_caps='["NET_ADMIN"]' volumes_definition='' secrets_definition=''
  volumes=$(
    if [ "${CONFIG_HOME_MOUNT:-dedicated}" = host ]; then
      server_volume "$HOME" "$HOME"
      if [[ "$2" != "$HOME/"* ]]; then server_volume "$2" "$2"; fi
    else
      server_volume "$(server_home)" "$HOME"
      while IFS=$'\t' read -r path _; do server_volume "$path" "$path"; done < <(server_mounts "$2")
    fi
    server_volume "$(server_config_dir)/orca-service.py" /opt/orca-service.py ro
    server_volume "$(server_overlay_dir)" "$ORCA_SERVER_ROOT/manifest/local" ro) || return 1
  if [ "${CONFIG_INTERNAL_SSH:-no}" = yes ]; then
    volumes="$volumes
$(server_volume "$(server_config_dir)/ssh/orca" /run/orca-ssh ro)"
  fi
  limits=$(server_limit_lines) || return 1
  if [ "$mode" = isolated ]; then
    server_network_load || return 1
    network_dir=$(server_network_dir)
    volumes="$volumes
$(server_volume "$network_dir/orca-resolv.conf" /etc/resolv.conf ro)"
    executor_volumes=$(server_volume "${XDG_DATA_HOME:-$HOME/.local/share}/orca-setup/executor-home" "$HOME"
      server_volume "$2" "$2"
      server_volume "$network_dir/executor-resolv.conf" /etc/resolv.conf ro)
    if [ "${CONFIG_INTERNAL_SSH:-no}" = yes ]; then
      executor_volumes="$executor_volumes
$(server_volume "$(server_config_dir)/ssh/executor" /run/orca-ssh ro)"
    fi
    policy_sum=$(printf '%s\n' "$NET_PROXY_TYPE" "$NET_PROXY_ADDRESS" "$NET_PROXY_PORT" "$NET_DNS_ADDRESS" \
      "$NET_DNS_TRANSPORT" "$NET_DNS_TLS_NAME" "$NET_EXECUTOR_DNS" "$NET_CONTROL_SUBNET" "$NET_RULES" "$NET_PROXY_AUTH_FILE" \
      "$NET_EXEC_INTERNET" "$NET_EXEC_PROXY_TYPE" "$NET_EXEC_PROXY_ADDRESS" "$NET_EXEC_PROXY_PORT" "$NET_EXEC_PROXY_AUTH_FILE" | \
      cksum | awk '{ print $1 "-" $2 }')
    if [ "${CONFIG_INLINE_AUTH:-no}" = yes ]; then
      auth_volume=$'      - type: volume\n        source: orca_proxy_auth\n        target: /run/secrets\n        read_only: true'
      volumes_definition=$(printf '  orca_proxy_auth:\n    external: true\n    name: "%s"' "$(server_config_secret_volume)")
    elif [ -n "$NET_PROXY_AUTH_FILE" ]; then
      auth_service=$'    secrets:\n      - orca_proxy_auth'
      secrets_definition=$(printf '  orca_proxy_auth:\n    file: "%s"' "$NET_PROXY_AUTH_FILE")
    fi
    if [ "$NET_EXEC_INTERNET" = proxy ]; then
      executor_caps='["NET_ADMIN", "NET_BIND_SERVICE"]'
      if [ "${CONFIG_EXEC_INLINE_AUTH:-no}" = yes ]; then
        executor_auth_volume=$'      - type: volume\n        source: executor_proxy_auth\n        target: /run/secrets\n        read_only: true'
        volumes_definition="${volumes_definition}${volumes_definition:+$'\n'}$(printf '  executor_proxy_auth:\n    external: true\n    name: "%s"' "$(server_config_secret_volume executor)")"
      elif [ -n "$NET_EXEC_PROXY_AUTH_FILE" ]; then
        executor_auth_service=$'    secrets:\n      - source: executor_proxy_auth\n        target: orca_proxy_auth'
        secrets_definition="${secrets_definition}${secrets_definition:+$'\n'}$(printf '  executor_proxy_auth:\n    file: "%s"' "$NET_EXEC_PROXY_AUTH_FILE")"
      fi
    fi
    [ -z "$volumes_definition" ] || auth_definition=$(printf 'volumes:\n%s' "$volumes_definition")
    [ -z "$secrets_definition" ] || auth_definition="${auth_definition}${auth_definition:+$'\n'}$(printf 'secrets:\n%s' "$secrets_definition")"
    server_network=$(server_network_server_lines "$4")
    server_hostname=''
    server_environment=$(printf '      ORCA_EXECUTOR_HOST: "%s"\n' "$NET_EXECUTOR_IP"
      printf '      %s: ""\n' HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy)
  else
    server_network=$(printf '    ports:\n      - "%s:%s:%s/tcp"' "$4" "$ORCA_SERVER_PORT" "$ORCA_SERVER_PORT")
    server_hostname=$(printf '    hostname: "%s"' "$(uname -n)")
  fi
  # Values go through ENVIRON: awk -v would interpret backslashes and cannot hold several lines everywhere.
  RENDER_PROCESS_MANAGER=$(cksum < "$ORCA_SETUP_ROOT/docker/orca-service.py" | awk '{ print $1 "-" $2 }') RENDER_INTERNAL_SSH=${CONFIG_INTERNAL_SSH:-no} RENDER_IMAGE=$1 RENDER_WORKDIR=$2 RENDER_PAIRING_ADDRESS=$3 RENDER_PUBLISH_ADDRESS=$4 RENDER_CONFIG=$5 \
    RENDER_PORT=$ORCA_SERVER_PORT RENDER_HOSTNAME=$(uname -n) RENDER_UID=$(id -u) RENDER_GID=$(id -g) RENDER_HOME=$HOME \
    RENDER_USER=$(id -un) RENDER_VOLUMES=$volumes RENDER_LIMITS=$limits RENDER_NETWORK_MODE=$mode \
    RENDER_SERVER_NETWORK=$server_network RENDER_NETWORK_DIR=$network_dir RENDER_EXECUTOR_VOLUMES=$executor_volumes \
    RENDER_CONTROL_SUBNET=${NET_CONTROL_SUBNET:-} RENDER_ORCA_IP=${NET_ORCA_IP:-} RENDER_EXECUTOR_IP=${NET_EXECUTOR_IP:-} \
    RENDER_SERVER_HOSTNAME=$server_hostname RENDER_SERVER_ENVIRONMENT=$server_environment \
    RENDER_PROXY_AUTH_SERVICE=$auth_service RENDER_PROXY_AUTH_DEFINITION=$auth_definition RENDER_PROXY_AUTH_VOLUME=$auth_volume \
    RENDER_EXECUTOR_PROXY_AUTH_VOLUME=$executor_auth_volume RENDER_EXECUTOR_PROXY_AUTH_SERVICE=$executor_auth_service RENDER_EXECUTOR_CAPS=$executor_caps \
    RENDER_PROJECT=$(server_project_name) RENDER_SERVER_NAME=$(server_container_name orca-server) \
    RENDER_GATEWAY_NAME=$(server_container_name orca-gateway) RENDER_EXECUTOR_GATEWAY_NAME=$(server_container_name executor-gateway) \
    RENDER_EXECUTOR_NAME=$(server_container_name orca-executor) RENDER_CONFIG_FILE=${CONFIG_FILE:-} \
    RENDER_EXECUTOR_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/orca-setup/executor-home" RENDER_POLICY_SUM=$policy_sum awk '
    /^@VOLUMES@$/ { print ENVIRON["RENDER_VOLUMES"]; next }
    /^@LIMITS@$/ { if (ENVIRON["RENDER_LIMITS"] != "") print ENVIRON["RENDER_LIMITS"]; next }
    /^@NETWORK_SERVICES@$/ { next }
    { line = $0
      out = ""
      while (match(line, /@[A-Z_]+@/)) {
        out = out substr(line, 1, RSTART - 1) ENVIRON["RENDER_" substr(line, RSTART + 1, RLENGTH - 2)]
        line = substr(line, RSTART + RLENGTH)
      }
      print out line }
  ' "$ORCA_SETUP_ROOT/docker/compose.yaml" <(if [ "$mode" = isolated ]; then cat "$ORCA_SETUP_ROOT/docker/compose-isolated.yaml"; fi)
}

# server_compose <image> <workdir> <pairing-address> <publish-address>: the compose.yaml content, labelled with a
# checksum of itself, which the container keeps as org.orca-setup.config: a container created from another file is
# re-created.
server_compose() {
  local draft config
  draft=$(server_compose_render "$1" "$2" "$3" "$4" -) || return 1
  config=$(printf '%s\n' "$draft" | cksum | awk '{ print $1 "-" $2 }')
  server_compose_render "$1" "$2" "$3" "$4" "$config"
}

# ---------------------------------------------------------------- image.lock

server_lock_value() {
  [ -r "$(server_lock_file)" ] || return 0
  sed -n "s/^$1=//p" "$(server_lock_file)" | head -n 1
}

# server_lock_write <source> <image> [<local image> <local source>]
server_lock_write() {
  local file
  file=$(server_lock_file)
  info "+ write $(tilde "$file") ($2${3:+, built: $3})"
  mkdir -p "$(dirname "$file")"
  {
    printf '# orca-setup: the Orca server image this host runs (README section 6.7). --apply keeps it; only\n'
    printf '# ./setup.sh --apply --role server --upgrade-image replaces it with the newest one.\n'
    printf 'source=%s\nimage=%s\n' "$1" "$2"
    [ -z "${3:-}" ] || printf 'local=%s\nlocal-source=%s\n' "$3" "$4"
  } >"$file"
}

# image_repository <reference>: the reference without its tag or digest.
image_repository() {
  local ref=${1%@*}
  case "${ref##*/}" in *:*) ref=${ref%:*} ;; esac
  printf '%s\n' "$ref"
}

# image_repo_digest <reference>: "<repository>@sha256:<digest>" of a pulled image, from its RepoDigests.
image_repo_digest() {
  dk image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1" 2>/dev/null |
    awk -v repo="$(image_repository "$1")" 'index($0, repo "@sha256:") == 1 && $0 ~ /@sha256:[0-9a-f]+$/ && length($0) == length(repo) + 72 { print; exit }'
}

# The optional organization image: manifest/local/Dockerfile, built FROM the locked image (build argument
# ORCA_SERVER_IMAGE). Its tag names a checksum of the base image and of every file next to the Dockerfile, so a
# change there builds it again.
server_local_dockerfile() { printf '%s\n' "$ORCA_SETUP_MANIFEST_DIR/local/Dockerfile"; }

server_local_files() { # <dir>: every file below it, in a stable order
  local entry
  for entry in "$1"/* "$1"/.[!.]*; do
    if [ -d "$entry" ] && [ ! -L "$entry" ]; then server_local_files "$entry"
    elif [ -f "$entry" ]; then printf '%s\n' "$entry"; fi
  done | LC_ALL=C sort
}

# server_tree_sum <dir>: a checksum of every file below the directory, names and contents (the same for a missing or
# an empty one).
server_tree_sum() {
  local file
  [ ! -d "$1" ] || while IFS= read -r file; do printf '%s\n' "${file#"$1"/}"; cat "$file"; done < <(server_local_files "$1")
}

server_local_tag() { # <base image>
  { printf '%s\n' "$1"; server_tree_sum "$(dirname "$(server_local_dockerfile)")"; } |
    cksum | awk '{ print "orca-setup/orca-server-local:" $1 "-" $2 }'
}

# server_overlay_apply: copy manifest/local/ to server_overlay_dir when they differ (an empty directory without one).
server_overlay_apply() {
  local source="$ORCA_SETUP_MANIFEST_DIR/local" target
  target=$(server_overlay_dir)
  if [ -d "$target" ] && [ "$(server_tree_sum "$source" | cksum)" = "$(server_tree_sum "$target" | cksum)" ]; then return 0; fi
  if [ -d "$source" ]; then info "+ copy manifest/local to $(tilde "$target") (the container's overlay)"
  else info "+ mkdir -p $(tilde "$target") (the container's overlay; there is no manifest/local)"; fi
  rm -rf -- "$target"
  mkdir -p "$target"
  [ ! -d "$source" ] || cp -R "$source"/. "$target"/
}

# server_image_apply: pull or keep the locked image (and build the local one); sets SERVER_IMAGE for compose.yaml.
server_image_apply() {
  local source locked base tag dir
  source=$(server_image_source)
  locked=$(server_lock_value image)
  if [ "${CONFIG_IMAGE_SOURCE:-registry}" = local ]; then
    if [ -n "$locked" ] && [ "$upgrade_image" != yes ] && [ "$(server_lock_value source)" = "local:$source" ]; then
      dk image inspect "$locked" >/dev/null 2>&1 || die 'the locked local image is missing; load it again or explicitly use --upgrade-image.'
      info "PRESENT local image $locked"
    else
      base=$(dk image inspect --format '{{.Id}}' "$source" 2>/dev/null) || die 'the configured local image is missing; build or docker load it first.'
      [[ "$base" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'the local image has no valid content ID.'
      if [ "$base" != "$locked" ] || [ "$(server_lock_value source)" != "local:$source" ]; then
        server_lock_write "local:$source" "$base"
      fi
      locked=$base
    fi
    SERVER_IMAGE=$locked
    return 0
  fi
  if [ -n "$locked" ] && [ "$upgrade_image" != yes ] && [ "$(server_lock_value source)" = "$source" ]; then
    if dk image inspect "$locked" >/dev/null 2>&1; then info "PRESENT image $locked"
    else
      # The locked digest itself, not a newer image.
      dk_step pull "$locked" || die "could not pull the locked image $locked."
    fi
    base=$locked
  else
    dk_step pull "$source" || die "could not pull $source."
    base=$(image_repo_digest "$source")
    [ -n "$base" ] || die "$source has no registry digest after docker pull; refusing to lock it."
    if [ "$base" = "$locked" ]; then info "PRESENT image $base (the newest $source)"
    else server_lock_write "$source" "$base"; fi
  fi
  SERVER_IMAGE=$base
  [ -z "${CONFIG_FILE:-}" ] || return 0
  [ -r "$(server_local_dockerfile)" ] || return 0
  tag=$(server_local_tag "$base")
  dir=$(dirname "$(server_local_dockerfile)")
  if [ "$(server_lock_value local)" = "$tag" ] && dk image inspect "$tag" >/dev/null 2>&1; then
    info "PRESENT image $tag (built from manifest/local/Dockerfile)"
  else
    dk_step build --pull=false --build-arg "ORCA_SERVER_IMAGE=$base" --tag "$tag" --file "$(server_local_dockerfile)" "$dir" ||
      die 'could not build manifest/local/Dockerfile.'
    server_lock_write "$source" "$base" "$tag" "${tag##*:}"
  fi
  SERVER_IMAGE=$tag
}

server_image_plan() {
  local source locked
  source=$(server_image_source)
  locked=$(server_lock_value image)
  info 'Image (--apply):'
  if [ "${CONFIG_IMAGE_SOURCE:-registry}" = local ]; then
    info "  local    $source (must already exist in Docker; no registry or pull)"
    info '           lock its content ID; --upgrade-image explicitly adopts the current local tag'
    return 0
  fi
  [ -z "${ORCA_SETUP_IMAGE:-}" ] || info "  source   $source (ORCA_SETUP_IMAGE: for tests and CI only)"
  if [ -n "$locked" ] && [ "$upgrade_image" != yes ] && [ "$(server_lock_value source)" = "$source" ]; then
    info "  present  $locked (locked in $(tilde "$(server_lock_file)"); --upgrade-image pulls the newest one)"
  elif [ "$upgrade_image" = yes ]; then
    info "  upgrade  pull $source; when its digest differs, lock it and re-create the container"
  else
    info "  pull     $source and lock its digest in $(tilde "$(server_lock_file)")"
    info '           re-runs keep the locked digest; only --upgrade-image pulls a newer one'
  fi
  [ -n "${CONFIG_FILE:-}" ] || [ ! -r "$(server_local_dockerfile)" ] ||
    info '  build    manifest/local/Dockerfile FROM that image (docker build), and run the result instead'
}

# ---------------------------------------------------------------- the container

# server_container_state: "<status> <config label>" of the container; empty when there is none.
server_container_state() {
  dk container inspect --format '{{.State.Status}} {{index .Config.Labels "org.orca-setup.config"}}' "${1:-$ORCA_SERVER_NAME}" 2>/dev/null
}

# The label the rendered compose.yaml asks for.
server_compose_config() {
  [ -r "$(server_compose_file)" ] || return 0
  sed -n 's/^      org.orca-setup.config: "\(.*\)"$/\1/p' "$(server_compose_file)" | head -n 1
}

server_runtime_reachable() {
  dk exec "$ORCA_SERVER_NAME" sh -c "orca-ide status --json 2>/dev/null | node $ORCA_SERVER_ROOT/lib/json.cjs has result.runtime.reachable" \
    >/dev/null 2>&1
}

# server_dirs_apply <workdir>: every directory the container needs, as yours.
server_dirs_apply() {
  local path created=0 link points
  while IFS=$'\t' read -r path _; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -d "$path" ] || die "$(tilde "$path") exists but is not a directory; the container mounts it."
      [ -O "$path" ] || die "$(tilde "$path") is not yours; the container (running as you) could not use it. Fix its owner and rerun."
      continue
    fi
    step mkdir -p "$path"
    created=$((created + 1))
  done < <(server_dirs "$1")
  if [ "${CONFIG_HOME_MOUNT:-dedicated}" = host ]; then
    if [ "$1" != "$HOME/orca" ]; then
      server_host_workdir_link_matches "$1" ||
        die 'host home mounting with a custom workdir requires an existing ~/orca symlink to that workdir; existing home data was not changed.'
    fi
    [ "$created" -gt 0 ] || info 'PRESENT directories for the container (owned by you)'
    return
  fi
  link=$(server_orca_link)
  if [ "$1" = "$HOME/orca" ]; then
    if [ -L "$link" ]; then step rm "$link"; created=$((created + 1)); fi
  elif [ "$(readlink "$link" 2>/dev/null)" != "$1" ]; then
    if [ -L "$link" ] || { [ -d "$link" ] && rmdir "$link" 2>/dev/null; }; then rm -f "$link"; fi
    [ ! -e "$link" ] || die "$(tilde "$link") holds files; with --workdir $1 it must become a link to it. Move them there and rerun."
    step ln -s "$1" "$link"
    created=$((created + 1))
  fi
  # The mount points inside the container's home, in one step.
  points=()
  while IFS= read -r path; do [ -d "$path" ] || points+=("$path"); done < <(server_mount_points "$1")
  if [ "${#points[@]}" -gt 0 ]; then step mkdir -p "${points[@]}"; created=$((created + 1)); fi
  [ "$created" -gt 0 ] || info 'PRESENT directories for the container (owned by you)'
}

server_dirs_plan() {
  local path description state
  info "Directories (--apply; owned by $(id -un), at the same path in the container):"
  while IFS=$'\t' read -r path description; do
    if [ ! -e "$path" ]; then state='create  '
    elif [ ! -d "$path" ]; then state='refuse  '; description='exists but is not a directory'
    elif [ ! -O "$path" ]; then state='refuse  '; description='is not yours'
    else state='present '; fi
    info "  $state $(tilde "$path") ($description)"
  done < <(server_dirs "$1")
  [ "${CONFIG_HOME_MOUNT:-dedicated}" = host ] || [ "$1" = "$HOME/orca" ] ||
    info "  link     $(tilde "$(server_orca_link)") -> $1 (Orca's workspace directory stays ~/orca/workspaces in the container)"
}

# server_role_check: the pairing role (README section 5.1) from ~/.orca, read-only, inside the image (the host has
# neither Node.js nor Orca); before the container starts.
server_role_check() {
  local status=0
  dk run --rm --network none --read-only --tmpfs /tmp --user "$(id -u):$(id -g)" --env "HOME=$HOME" \
    --volume "$HOME/.orca:$HOME/.orca:ro" "$SERVER_IMAGE" "$ORCA_SERVER_ROOT/orca/role.sh" --expect server || status=$?
  case "$status" in
    0) ;;
    1) die 'this device already holds the other pairing role; remove the pairings listed above before --apply --role server.' ;;
    *) die 'the pairing role cannot be determined (see the reason above); refusing --apply.' ;;
  esac
}

# server_setup_args <with modules: yes|no> <mode flags...>: arguments for the setup.sh inside the container, one per
# line: the flags, --role server, the modules built into the image (with yes) and the task source.
server_setup_args() {
  local name with_modules=$1
  shift
  printf '%s\n' "$@" --role server
  if [ "$with_modules" = yes ]; then
    for name in $modules; do
      case " $ORCA_SERVER_IMAGE_MODULES " in *" $name "*) printf -- '--%s\n' "$name" ;; esac
    done
  fi
  [ -z "$task_source" ] || printf -- '--task-source\n%s\n' "$task_source"
}

server_container_apply() { # <workdir>
  local compose rendered state config arg waited=0 limit=${ORCA_SETUP_SERVE_WAIT:-120} args=()
  compose=$(server_compose_file)
  mkdir -p "$(dirname "$compose")"
  [ ! -L "$(dirname "$compose")/orca-service.py" ] || die 'process manager file must not be a symbolic link.'
  if [ ! -f "$(dirname "$compose")/orca-service.py" ] || [ "$(cat "$ORCA_SETUP_ROOT/docker/orca-service.py")" != "$(cat "$(dirname "$compose")/orca-service.py")" ]; then
    info "+ write $(tilde "$(dirname "$compose")/orca-service.py") (container process manager)"
    cat "$ORCA_SETUP_ROOT/docker/orca-service.py" >"$(dirname "$compose")/orca-service.py"
    chmod 644 "$(dirname "$compose")/orca-service.py"
  fi
  rendered=$(server_compose "$SERVER_IMAGE" "$1" "$pairing_address" "$PUBLISH_ADDRESS") || exit 1
  config=$(printf '%s\n' "$rendered" | sed -n 's/^      org.orca-setup.config: "\(.*\)"$/\1/p' | head -n 1)
  if [ -f "$compose" ] && [ "$NETWORK_MODE" != "$NETWORK_PREVIOUS_MODE" ]; then
    # Release the private published port before moving it between Orca and its gateway. Bind mounts are retained.
    dk_step compose --file "$compose" --project-name "$(server_project_name)" down || die 'could not stop the previous network topology.'
  fi
  if [ -f "$compose" ] && [ "$(cat "$compose")" = "$rendered" ]; then info "PRESENT $(tilde "$compose")"
  else
    info "+ write $(tilde "$compose")"
    mkdir -p "$(dirname "$compose")"
    printf '%s\n' "$rendered" >"$compose"
  fi
  state=$(server_container_state) || state=''
  if [ "$state" = "running $config" ] && server_network_helpers_current "$config"; then
    info "PRESENT container $ORCA_SERVER_NAME running"
  else
    if [ "$NETWORK_MODE" = isolated ]; then
      # Applications must join the new donor namespaces when a gateway is replaced or restarted.
      dk_step compose --file "$compose" --project-name "$(server_project_name)" up --detach --force-recreate --remove-orphans ||
        die "could not start the isolated stack; check gateway logs and use --upgrade-image if the image predates isolation."
    else
      if [ "$NETWORK_PREVIOUS_MODE" = isolated ]; then
        dk_step compose --file "$compose" --project-name "$(server_project_name)" up --detach --remove-orphans || die "docker compose could not start $ORCA_SERVER_NAME."
      else
        dk_step compose --file "$compose" --project-name "$(server_project_name)" up --detach || die "docker compose could not start $ORCA_SERVER_NAME."
      fi
    fi
  fi
  until server_runtime_reachable; do
    [ "$waited" -lt "$limit" ] ||
      die "the Orca runtime in $ORCA_SERVER_NAME is not reachable ${limit}s after it started; see: docker logs $ORCA_SERVER_NAME"
    sleep 2
    waited=$((waited + 2))
  done
  # Skills and settings, by the scripts in the image (the role was checked before the container started).
  while IFS= read -r arg; do args+=("$arg"); done < <(server_setup_args no --apply)
  dk exec --env ORCA_SETUP_ROLE_CHECKED=1 "$ORCA_SERVER_NAME" "$ORCA_SERVER_ROOT/setup.sh" "${args[@]}" ||
    die "the Orca skills or settings could not be applied inside $ORCA_SERVER_NAME (see above)."
}

# ---------------------------------------------------------------- plan, apply

# The systemd user unit of the native Linux server that orca-setup wrote before P5 (README section 6.7): its Orca
# would share ~/.orca and port 6768 with the container.
legacy_serve_unit() {
  local path=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/orca-serve.service
  [ -r "$path" ] && [ "$(head -n 1 "$path")" = "$LEGACY_SERVE_UNIT_MARKER" ] && printf '%s\n' "$path"
}

legacy_serve_unit_steps() { # <unit path>
  printf 'systemctl --user disable --now orca-serve.service && rm %s && systemctl --user daemon-reload' "$(tilde "$1")"
}

server_plan() { # <workdir>
  local legacy
  info 'Orca server in Docker (--apply --role server; README section 6.7):'
  if [ -z "$pairing_address" ]; then
    info '  missing  --pairing-address <ip-or-host>: the private address clients dial (README section 1); --apply requires it'
  else
    info "  address  $pairing_address (advertised to clients)"
  fi
  if [ -z "$PUBLISH_ADDRESS" ]; then
    info "  missing  --publish-address <ipv4>: this host's private IPv4 address that Docker publishes port $ORCA_SERVER_PORT on (default: an IPv4 --pairing-address); --apply requires one"
  elif [ -n "$PUBLISH_PROBLEM" ]; then
    info "  refuse   publishing port $ORCA_SERVER_PORT on $PUBLISH_ADDRESS ($(server_publish_source)): $PUBLISH_PROBLEM; pass --publish-address <ipv4>"
  else
    info "  publish  $PUBLISH_ADDRESS:$ORCA_SERVER_PORT ($(server_publish_source)); port $ORCA_SERVER_PORT is not reachable on this host's other addresses"
  fi
  info "  workdir  $(tilde "$1") (projects/ and workspaces/; Orca's workspace directory is ~/orca/workspaces)"
  info '  host     only Docker Engine is installed here; Orca, its CLI and every agent run in the container'
  if legacy=$(legacy_serve_unit); then
    info "  remove   the native server unit an earlier orca-setup wrote ($(tilde "$legacy")); --apply stops until it is gone:"
    info "           $(legacy_serve_unit_steps "$legacy")"
  fi
  docker_plan
  server_dirs_plan "$1"
  server_image_plan
  server_network_plan
  if [ "${CONFIG_INTERNAL_SSH:-no}" = yes ]; then
    info "  ssh      initialize deployment-only identities in $(tilde "$(server_config_dir)/ssh"); mount each identity only in its container"
    info '           allow mutual control-network SSH on port 2222; no host ports; remote commands use the destination network'
  fi
  info 'Container (--apply):'
  info "  write    $(tilde "$(server_config_dir)/orca-service.py") (persistent process manager; mounted read-only)"
  info '  check    the pairing role, read-only inside the image, before the container starts'
  if [ -f "$(server_compose_file)" ]; then info "  render   $(tilde "$(server_compose_file)") (rewritten when it differs)"
  else info "  write    $(tilde "$(server_compose_file)")"; fi
  if [ "${CONFIG_HOME_MOUNT:-dedicated}" = host ]; then
    info "           $ORCA_SERVER_NAME: user $(id -u):$(id -g), full host home $(tilde "$HOME"), host name $(uname -n),"
  else
    info "           $ORCA_SERVER_NAME: user $(id -u):$(id -g), home $(tilde "$HOME") from $(tilde "$(server_home)"), host name $(uname -n),"
  fi
  info '           read-only root filesystem with a tmpfs /tmp, restart unless-stopped, no sudo and no Docker inside'
  info "  network  the compose project's bridge network; only port $ORCA_SERVER_PORT is published, on ${PUBLISH_ADDRESS:-the publish address} alone"
  info "           Docker's bridge networking turns on IPv4 forwarding and adds its own iptables rules; when it turns"
  info '           forwarding on itself it also sets the iptables FORWARD policy to DROP (README section 8)'
  info "  start    docker compose up --detach (when not running as rendered); wait until \`orca-ide status\` in it reaches the runtime"
  info "  orca     skills and settings inside it: docker exec $ORCA_SERVER_NAME $ORCA_SERVER_ROOT/setup.sh $(server_setup_args no --apply | paste -sd ' ' -)"
  info '  pairing  TUI maintenance pairing shows a link/QR; Orca sessions may stop, containers stay running (README section 3.3.2)'
}

server_internal_ssh_ready() {
  dk exec "$(server_container_name orca-server)" ssh -o ConnectTimeout=5 executor true >/dev/null 2>&1 &&
    dk exec "$(server_container_name orca-executor)" ssh -o ConnectTimeout=5 orca true >/dev/null 2>&1
}

server_internal_ssh_apply() {
  [ "${CONFIG_INTERNAL_SSH:-no}" = yes ] || return 0
  local supported directory
  supported=$(dk image inspect --format '{{index .Config.Labels "org.orca-setup.internal-ssh"}}' "$SERVER_IMAGE") || return 1
  [ "$supported" = 1 ] || die 'internal SSH requires a newer image with shell/SSH support; select a compatible image before applying.'
  directory="$(server_config_dir)/ssh"
  [ ! -L "$directory" ] || die 'SSH identity directory must not be a symbolic link.'
  mkdir -p "$directory"
  case "$(cd "$directory" && pwd -P)/" in
    "$ORCA_SETUP_ROOT/"*) die 'SSH identities must be outside the source checkout; choose an external XDG_CONFIG_HOME.' ;;
  esac
  chmod 700 "$directory"
  info '+ initialize persistent deployment-only SSH identities (values hidden; existing identities retained)'
  dk run --rm --network none --read-only --tmpfs /tmp --user "$(id -u):$(id -g)" --env HOME=/tmp \
    --volume "$directory:/identities" "$SERVER_IMAGE" python3 /opt/orca-setup/docker/ssh-identity.py \
    /identities "$(id -un)" "$NET_ORCA_IP" "$NET_EXECUTOR_IP" || die 'internal SSH initialization failed.'
}

server_apply() { # <workdir>
  local legacy name
  if [ "$NETWORK_MODE" = isolated ]; then
    server_network_load || die 'isolated networking requires a valid local network policy; nothing has been changed.'
  fi
  [ -n "$pairing_address" ] ||
    die '--apply --role server on Linux requires --pairing-address <ip-or-host>, the private address clients dial (README section 3.3.2).'
  [ -n "$PUBLISH_ADDRESS" ] ||
    die "--pairing-address $pairing_address is a host name, so --apply --role server also needs --publish-address <ipv4>: this host's own private IPv4 address that Docker publishes port $ORCA_SERVER_PORT on (README section 3.3.2)."
  [ -z "$PUBLISH_PROBLEM" ] ||
    die "port $ORCA_SERVER_PORT cannot be published on $PUBLISH_ADDRESS ($(server_publish_source)): $PUBLISH_PROBLEM. Pass --publish-address <ipv4>, this host's own private IPv4 address that clients reach (README section 3.3.2)."
  if legacy=$(legacy_serve_unit); then
    die "the native Orca server unit an earlier orca-setup wrote is still installed ($(tilde "$legacy")); its Orca would share ~/.orca and port $ORCA_SERVER_PORT with the container. Remove it first: $(legacy_serve_unit_steps "$legacy")"
  fi
  docker_apply
  server_dirs_apply "$1"
  server_overlay_apply
  server_image_apply
  if [ "$NETWORK_MODE" = isolated ] && [ "$NET_EXEC_INTERNET" != blocked ] &&
    ! server_network_image_supports_executor "$SERVER_IMAGE"; then
    die 'the selected image does not support executor direct/proxy networking; build a newer image or explicitly use --upgrade-image.'
  fi
  server_role_check
  server_internal_ssh_apply
  server_network_apply
  server_container_apply "$1"
  if [ "${CONFIG_INTERNAL_SSH:-no}" = yes ]; then
    server_internal_ssh_ready || die 'internal SSH did not become ready in both directions; inspect the container SSH service.'
    info 'PRESENT mutual internal SSH (non-root, port 2222, no host publication)'
  fi
  for name in $modules; do
    case "$name" in
      containers) info 'PRESENT module containers (Docker Engine is part of the Linux server baseline)' ;;
      media | android | agent-gemini) info "PRESENT module $name (built into the orca-server image)" ;;
      *)
        if module_skipped "$name" apply; then info "SKIP module $name: $MODULE_SKIP_REASON"; continue; fi
        info "MODULE $name"
        process_group apply "$name" "$(group_manifest "$name")"
        if has_function "$(module_function "$name" apply)"; then "$(module_function "$name" apply)"; fi ;;
    esac
  done
  info 'BASELINE_DONE'
}

# ---------------------------------------------------------------- check

# server_newest_digest <reference>: the registry's current digest for the reference, without pulling it. buildx
# prints the descriptor as indented JSON; the index's own digest comes before those of its manifests.
server_newest_digest() {
  dk buildx imagetools inspect --format '{{json .Manifest}}' "$1" 2>/dev/null |
    grep -o '"digest": *"sha256:[0-9a-f]\{64\}"' | head -n 1 | sed 's/.*"\(sha256:[0-9a-f]*\)"$/\1/'
}

# server_published: the container's network mode on the first line, then "<host ip>|<host port>|<port>/<protocol>"
# for every port it publishes (a running container's actual bindings).
server_published() {
  local endpoint_container=$ORCA_SERVER_NAME
  [ "$NETWORK_MODE" != isolated ] || endpoint_container=$(server_container_name orca-gateway)
  # shellcheck disable=SC2016 # a Go template, not shell expansions
  dk container inspect --format '{{.HostConfig.NetworkMode}}{{println}}{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{.HostIp}}|{{.HostPort}}|{{$port}}{{println}}{{end}}{{end}}' \
    "$endpoint_container" 2>/dev/null
}

# server_check_endpoint: where the running container publishes; anything but port 6768 on the publish address alone
# (the host network, another or a wildcard address, other ports) is counted. Sets SERVER_ENDPOINT.
server_check_endpoint() {
  local published bindings
  published=$(server_published) || published=''
  bindings=$(printf '%s\n' "$published" | sed 1d | grep . || true)
  SERVER_ENDPOINT=$(printf '%s\n' "$bindings" | awk -F'|' -v port="$ORCA_SERVER_PORT/tcp" 'NF == 3 {
    host = ($1 == "") ? "*" : (($1 ~ /:/) ? "[" $1 "]" : $1)
    printf "%s%s:%s", sep, host, $2; if ($3 != port) printf " (to %s)", $3; sep = ", " }')
  if [ "$(printf '%s\n' "$published" | head -n 1)" = host ]; then
    SERVER_ENDPOINT=host
    report "WRONG (it runs on the host network: port $ORCA_SERVER_PORT answers on every host address; --apply re-creates it)" 'Published endpoint'
  elif [ -n "$PUBLISH_ADDRESS" ] && [ "$bindings" = "$PUBLISH_ADDRESS|$ORCA_SERVER_PORT|$ORCA_SERVER_PORT/tcp" ]; then
    report "$SERVER_ENDPOINT (not reachable on this host's other addresses)" 'Published endpoint'
  elif [ -n "$PUBLISH_ADDRESS" ]; then
    report "WRONG (published on ${SERVER_ENDPOINT:-nothing}; expected $PUBLISH_ADDRESS:$ORCA_SERVER_PORT only; --apply re-creates it)" 'Published endpoint'
  else
    report "WRONG (published on ${SERVER_ENDPOINT:-nothing}; no publish address is recorded: run --apply --role server with --publish-address)" 'Published endpoint'
  fi
  SERVER_ENDPOINT=${SERVER_ENDPOINT:-none}
}

# server_check_host <workdir>: the host's items (report from setup.sh). Sets SERVER_CONTAINER (the container's
# status, or missing / unknown) and SERVER_INFO ("key<TAB>value" lines for --check --json).
server_check_host() {
  local path state locked newest config
  SERVER_INFO=()
  docker_check
  locked=$(server_lock_value image)
  if [ -z "$locked" ]; then report 'MISSING (no image.lock; run --apply --role server)' 'Orca server image'
  else
    report "locked ($locked)" 'Orca server image'
    newest=''
    if [ -n "$DOCKER_VIA" ]; then
      case "$(server_lock_value source)" in
        local:*) newest=$(dk image inspect --format '{{.Id}}' "$(server_lock_value source | cut -c 7-)" 2>/dev/null) || newest='' ;;
        *) newest=$(server_newest_digest "$(server_lock_value source)") || newest='' ;;
      esac
    fi
    if [ -z "$newest" ] && [[ "$(server_lock_value source)" = local:* ]]; then
      report 'unknown (the local image tag is absent or Docker did not answer; not counted)' 'Newest image'
    elif [ -z "$newest" ]; then report 'unknown (the registry did not answer, or docker buildx is missing; not counted)' 'Newest image'
    elif [ "$newest" = "${locked##*@}" ]; then report 'same as image.lock' 'Newest image'
    else report "newer one available ($newest; --apply --role server --upgrade-image switches; not counted)" 'Newest image'; fi
    SERVER_INFO+=("image"$'\t'"$locked" "newest"$'\t'"${newest:-unknown}")
  fi
  SERVER_CONTAINER=unknown
  if [ -z "$DOCKER_VIA" ]; then report 'UNREACHABLE (Docker does not answer)' 'Orca server container'
  else
    state=$(server_container_state) || state=''
    config=$(server_compose_config)
    SERVER_CONTAINER=${state%% *}
    if [ -z "$state" ]; then SERVER_CONTAINER=missing; report 'MISSING (run --apply --role server)' 'Orca server container'
    elif [ "${state#* }" != "$config" ]; then report 'STALE (not created from the current compose.yaml; --apply re-creates it)' 'Orca server container'
    elif [ "$SERVER_CONTAINER" = running ]; then report running 'Orca server container'
    else report "INACTIVE ($SERVER_CONTAINER; --apply starts it)" 'Orca server container'; fi
  fi
  SERVER_ENDPOINT=none
  [ "$SERVER_CONTAINER" != running ] || server_check_endpoint
  SERVER_INFO+=("container"$'\t'"$SERVER_CONTAINER" "endpoint"$'\t'"$SERVER_ENDPOINT" "workdir"$'\t'"$1")
  if [ "$NETWORK_MODE" = isolated ]; then
    SERVER_INFO+=("network-mode"$'\t'isolated)
    server_network_check
    if [ "${CONFIG_INTERNAL_SSH:-no}" = yes ]; then
      if server_internal_ssh_ready; then report healthy 'Mutual internal SSH'
      else report UNREACHABLE 'Mutual internal SSH'; fi
    fi
  fi
  while IFS=$'\t' read -r path _; do
    if [ ! -e "$path" ]; then report MISSING "Mount $(tilde "$path")"
    elif [ ! -d "$path" ]; then report 'MISSING (not a directory)' "Mount $(tilde "$path")"
    elif [ ! -O "$path" ]; then report "WRONG OWNER (uid $(stat -c %u "$path" 2>/dev/null || echo unknown))" "Mount $(tilde "$path")"
    else report ok "Mount $(tilde "$path")"; fi
  done < <(server_dirs "$1")
}

# server_exec_setup <docker exec flags...> -- <setup.sh args...>: run the image's setup.sh inside the container.
server_exec_setup() {
  local flags=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do flags+=("$1"); shift; done
  shift
  dk exec ${flags[@]+"${flags[@]}"} "$ORCA_SERVER_NAME" "$ORCA_SERVER_ROOT/setup.sh" "$@"
}

# server_auth <name...>: the interactive logins, inside the container (README section 3.4).
server_auth() {
  local name flags=(--interactive) args=()
  docker_connect || die "Docker does not answer; the logins run inside the $ORCA_SERVER_NAME container (see ./setup.sh --check)."
  [ "$(server_container_state | cut -d' ' -f1)" = running ] ||
    die "the $ORCA_SERVER_NAME container is not running; start it with ./setup.sh --apply --role server --pairing-address <address>."
  [ ! -t 0 ] || [ ! -t 1 ] || flags+=(--tty)
  # agy prints its sign-in URL only in an SSH session (README section 3.4).
  for name in SSH_CONNECTION SSH_TTY; do [ -z "${!name:-}" ] || flags+=(--env "$name"); done
  for name in "$@"; do args+=("--auth-$name"); done
  info "+ docker exec ${flags[*]} $ORCA_SERVER_NAME $ORCA_SERVER_ROOT/setup.sh ${args[*]}"
  server_exec_setup "${flags[@]}" -- "${args[@]}"
}
