# shellcheck shell=bash disable=SC2034,SC2154 # setup.sh and the server libraries consume the public configuration
# A TOML is the user-maintained server input. Only validated, non-secret values enter shell variables.
CONFIG_FILE=''
CONFIG_IMAGE=''
CONFIG_IMAGE_SOURCE=registry
CONFIG_HOME_MOUNT=dedicated
CONFIG_INTERNAL_SSH=no
CONFIG_INLINE_AUTH=no
CONFIG_EXEC_INLINE_AUTH=no
CONFIG_ALLOW=''
CONFIG_LIMITS=''

server_config_python() { python3 "$ORCA_SETUP_ROOT/lib/server-config.py" "$@"; }

server_config_load() {
  local selected key value public problem
  [ "$no_config" = no ] || { [ -z "$config_file" ] || die '--config and --no-config cannot be combined'; return 0; }
  if [ "$action" = auth ]; then
    [ -z "$config_file" ] || die '--config supports --plan, --apply and --check; use --auth-* separately.'
    return 0
  fi
  if [ "${ORCA_SETUP_CONTAINER:-}" = orca-server ]; then
    [ -z "$config_file" ] || die '--config belongs to the Linux Docker host, not an application container.'
    return 0
  fi
  selected=$config_file
  if [ -z "$selected" ] && [ -f "$PWD/orca.toml" ]; then selected=$PWD/orca.toml; fi
  [ -n "$selected" ] || selected=$(server_compose_value config-file)
  [ -n "$selected" ] || return 0
  [ -f "$selected" ] || die 'server TOML is missing; restore it, pass --config FILE, or explicitly use --no-config.'
  CONFIG_FILE=$(CDPATH='' cd -- "$(dirname -- "$selected")" && pwd)/$(basename -- "$selected")
  problem=$(server_path_problem "$CONFIG_FILE")
  [ -z "$problem" ] || die 'the server TOML path must use mount-safe path characters.'
  if ! have python3 || ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    die '--config requires Python 3.11 or newer on the setup host.'
  fi
  public=$(server_config_python public "$CONFIG_FILE") || die 'server TOML validation failed; values were not printed.'
  while IFS=$'\t' read -r key value; do
    case "$key" in
      role) role=${role:-$value} ;;
      pairing_address) pairing_address=${pairing_address:-$value} ;;
      publish_address) publish_address=${publish_address:-$value} ;;
      workdir) workdir=${workdir:-$value} ;;
      task_source) task_source=${task_source:-$value} ;;
      network_mode) network_mode=${network_mode:-$value} ;;
      image) CONFIG_IMAGE=$value ;;
      image_source) CONFIG_IMAGE_SOURCE=$value ;;
      home_mount) CONFIG_HOME_MOUNT=$value ;;
      internal_ssh) CONFIG_INTERNAL_SSH=$value ;;
      proxy_inline_auth) CONFIG_INLINE_AUTH=$value ;;
      executor_proxy_inline_auth) CONFIG_EXEC_INLINE_AUTH=$value ;;
      executor_internet) CONFIG_EXEC_INTERNET=$value ;;
      executor_proxy_type) CONFIG_EXEC_PROXY_TYPE=$value ;;
      executor_proxy_address) CONFIG_EXEC_PROXY_ADDRESS=$value ;;
      executor_proxy_port) CONFIG_EXEC_PROXY_PORT=$value ;;
      executor_proxy_auth_file) CONFIG_EXEC_PROXY_AUTH_FILE=$value ;;
      proxy_type) CONFIG_PROXY_TYPE=$value ;;
      proxy_address) CONFIG_PROXY_ADDRESS=$value ;;
      proxy_port) CONFIG_PROXY_PORT=$value ;;
      proxy_auth_file) CONFIG_PROXY_AUTH_FILE=$value ;;
      dns_address) CONFIG_DNS_ADDRESS=$value ;;
      dns_transport) CONFIG_DNS_TRANSPORT=$value ;;
      dns_tls_name) CONFIG_DNS_TLS_NAME=$value ;;
      executor_dns) CONFIG_EXECUTOR_DNS=$value ;;
      control_subnet) CONFIG_CONTROL_SUBNET=$value ;;
      allow) CONFIG_ALLOW="${CONFIG_ALLOW}${value}"$'\n' ;;
      limits) CONFIG_LIMITS="${CONFIG_LIMITS}${value}"$'\n' ;;
      *) die 'unexpected public TOML field' ;;
    esac
  done <<<"$public"
}

server_config_network_load() {
  NET_PROXY_TYPE=$CONFIG_PROXY_TYPE NET_PROXY_ADDRESS=$CONFIG_PROXY_ADDRESS NET_PROXY_PORT=$CONFIG_PROXY_PORT
  NET_PROXY_AUTH_FILE=$CONFIG_PROXY_AUTH_FILE NET_DNS_ADDRESS=$CONFIG_DNS_ADDRESS NET_DNS_TRANSPORT=$CONFIG_DNS_TRANSPORT
  NET_DNS_TLS_NAME=$CONFIG_DNS_TLS_NAME NET_EXECUTOR_DNS=$CONFIG_EXECUTOR_DNS NET_CONTROL_SUBNET=$CONFIG_CONTROL_SUBNET
  NET_RULES=$CONFIG_ALLOW
  NET_EXEC_INTERNET=$CONFIG_EXEC_INTERNET NET_EXEC_PROXY_TYPE=$CONFIG_EXEC_PROXY_TYPE
  NET_EXEC_PROXY_ADDRESS=$CONFIG_EXEC_PROXY_ADDRESS NET_EXEC_PROXY_PORT=$CONFIG_EXEC_PROXY_PORT
  NET_EXEC_PROXY_AUTH_FILE=$CONFIG_EXEC_PROXY_AUTH_FILE
  network_validate && network_validate_rules "$NET_RULES" || return 1
  if [ "$NET_EXEC_INTERNET" = proxy ]; then
    (NET_PROXY_TYPE=$NET_EXEC_PROXY_TYPE NET_PROXY_ADDRESS=$NET_EXEC_PROXY_ADDRESS NET_PROXY_PORT=$NET_EXEC_PROXY_PORT
      NET_PROXY_AUTH_FILE=$NET_EXEC_PROXY_AUTH_FILE; network_validate) || return 1
  fi
}

server_config_limit_lines() {
  local key value
  while IFS='=' read -r key value; do
    [ -z "$key" ] || printf '    %s: "%s"\n' "$key" "$value"
  done <<<"$CONFIG_LIMITS"
}

server_config_check_mounts() {
  [ "$CONFIG_INLINE_AUTH" = yes ] || [ "$CONFIG_EXEC_INLINE_AUTH" = yes ] || return 0
  local path work_dir=$1 mounts=()
  while IFS=$'\t' read -r path _; do mounts+=("$path"); done < <(server_mounts "$work_dir")
  mounts+=("$(server_home)" "$(server_overlay_dir)" "$(server_network_dir)" "${XDG_DATA_HOME:-$HOME/.local/share}/orca-setup/executor-home")
  server_config_python check-mounts "$CONFIG_FILE" "${mounts[@]}" || die 'move the private TOML outside container data/work mounts.'
}

server_config_secret_volume() {
  printf 'orca-setup-proxy-%s-%s%s\n' "$(id -u)" "$(printf '%s' "$(server_config_dir)" | cksum | cut -d' ' -f1)" "${1:+-executor}"
}

server_config_secret_matches() {
  local kind=${1:-orca} gateway=orca-gateway operation=secret enabled=$CONFIG_INLINE_AUTH
  if [ "$kind" = executor ]; then gateway=executor-gateway; operation=secret-executor; enabled=$CONFIG_EXEC_INLINE_AUTH; fi
  [ "$enabled" = yes ] || return 0
  gateway=$(server_container_name "$gateway")
  [ "$(server_container_state "$gateway")" != '' ] || return 1
  server_config_python "$operation" "$CONFIG_FILE" |
    dk exec --interactive "$gateway" python3 "$ORCA_SERVER_ROOT/docker/proxy-secret.py" check >/dev/null 2>&1
}

server_config_secret_apply() {
  local kind=${1:-orca} volume operation=secret enabled=$CONFIG_INLINE_AUTH
  if [ "$kind" = executor ]; then operation=secret-executor; enabled=$CONFIG_EXEC_INLINE_AUTH; fi
  [ "$enabled" = yes ] || return 0
  if server_config_secret_matches "$kind"; then info "PRESENT private $kind proxy authentication"; return 0; fi
  if [ "$kind" = executor ]; then volume=$(server_config_secret_volume executor); else volume=$(server_config_secret_volume); fi
  if ! dk volume inspect "$volume" >/dev/null 2>&1; then
    dk_step volume create --label org.orca-setup.proxy-secret=true "$volume" >/dev/null
    info '+ create private proxy authentication volume'
  fi
  info '+ synchronize proxy authentication into its private volume (values hidden)'
  # Authentication crosses stdin only. The throwaway publisher has no network, capabilities or host directories.
  server_config_python "$operation" "$CONFIG_FILE" |
    dk run --rm --interactive --network none --read-only --cap-drop ALL --user 0:0 \
      --volume "$volume:/run/secrets" --entrypoint python3 "$SERVER_IMAGE" \
      "$ORCA_SERVER_ROOT/docker/proxy-secret.py" write >/dev/null || die 'private proxy authentication could not be prepared; no direct fallback.'
}
