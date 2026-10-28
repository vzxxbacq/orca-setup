# shellcheck shell=bash disable=SC2154 # setup.sh and lib/orca-server.sh supply the server options
# Optional isolated topology. All firewall changes happen in dedicated container network namespaces.
# shellcheck source=lib/network-policy.sh
. "$ORCA_SETUP_ROOT/lib/network-policy.sh"

server_network_load() {
  if [ -n "${CONFIG_FILE:-}" ]; then
    server_config_network_load || return 1
  else
    network_read_env "$ORCA_SETUP_MANIFEST_DIR/server-network.env" || return 1
    network_read_env "$ORCA_SETUP_MANIFEST_DIR/local/server-network.env" || return 1
    network_validate || return 1
    NET_RULES=$(manifest_rows server-network-allow.tsv) || return 1
    network_validate_rules "$NET_RULES" || return 1
    NET_EXEC_INTERNET=blocked NET_EXEC_PROXY_TYPE=$NET_PROXY_TYPE NET_EXEC_PROXY_ADDRESS=$NET_PROXY_ADDRESS
    NET_EXEC_PROXY_PORT=$NET_PROXY_PORT NET_EXEC_PROXY_AUTH_FILE=''
  fi
  if [ "$NET_EXEC_INTERNET" = proxy ] && [ -n "$NET_EXEC_PROXY_AUTH_FILE" ] && [ "${CONFIG_EXEC_INLINE_AUTH:-no}" != yes ]; then
    case "$NET_EXEC_PROXY_AUTH_FILE" in "$ORCA_SETUP_ROOT"/* | "$ORCA_SETUP_MANIFEST_DIR"/*)
      echo 'executor proxy_auth_file must be outside the checkout and manifest overlay' >&2; return 1 ;;
    esac
    [ -f "$NET_EXEC_PROXY_AUTH_FILE" ] || { echo 'executor proxy_auth_file is absent or cannot be accessed' >&2; return 1; }
  fi
  if [ -n "$NET_PROXY_AUTH_FILE" ] && [ "${CONFIG_INLINE_AUTH:-no}" != yes ]; then
    case "$NET_PROXY_AUTH_FILE" in "$ORCA_SETUP_ROOT"/* | "$ORCA_SETUP_MANIFEST_DIR"/*)
      echo 'proxy_auth_file must be provisioned outside the checkout and manifest overlay' >&2; return 1 ;;
    esac
    [ -f "$NET_PROXY_AUTH_FILE" ] || { echo 'external proxy_auth_file is absent or cannot be accessed' >&2; return 1; }
  fi
  return 0
}

server_network_dir() { printf '%s/network\n' "$(server_config_dir)"; }

server_network_content() {
  if [ "${CONFIG_INTERNAL_SSH:-no}" = yes ] && { [ "$1" = policy.env ] || [ "$1" = executor-policy.env ]; }; then
    printf 'internal_ssh=yes\n'
  fi
  case "$1" in
    policy.env) printf 'proxy_type=%s\nproxy_address=%s\nproxy_port=%s\ndns_address=%s\ndns_transport=%s\ndns_tls_name=%s\nexecutor_dns=%s\ncontrol_subnet=%s\nproxy_auth_file=%s\n' \
      "$NET_PROXY_TYPE" "$NET_PROXY_ADDRESS" "$NET_PROXY_PORT" "$NET_DNS_ADDRESS" "$NET_DNS_TRANSPORT" "$NET_DNS_TLS_NAME" \
      "$NET_EXECUTOR_DNS" "$NET_CONTROL_SUBNET" "$NET_PROXY_AUTH_FILE" ;;
    executor-policy.env)
      local kind=$NET_PROXY_TYPE address=$NET_PROXY_ADDRESS port=$NET_PROXY_PORT auth=''
      if [ "$NET_EXEC_INTERNET" = proxy ]; then
        kind=$NET_EXEC_PROXY_TYPE address=$NET_EXEC_PROXY_ADDRESS port=$NET_EXEC_PROXY_PORT auth=$NET_EXEC_PROXY_AUTH_FILE
      fi
      printf 'proxy_type=%s\nproxy_address=%s\nproxy_port=%s\ndns_address=%s\ndns_transport=%s\ndns_tls_name=%s\nexecutor_dns=%s\ncontrol_subnet=%s\nproxy_auth_file=%s\nexecutor_mode=%s\n' \
        "$kind" "$address" "$port" "$NET_DNS_ADDRESS" "$NET_DNS_TRANSPORT" "$NET_DNS_TLS_NAME" "$NET_EXECUTOR_DNS" "$NET_CONTROL_SUBNET" "$auth" "$NET_EXEC_INTERNET" ;;
    allow.tsv) printf '%s\n' "$NET_RULES" ;;
    orca-resolv.conf) printf 'nameserver 127.0.0.1\noptions timeout:3 attempts:2\n' ;;
    executor-resolv.conf)
      local resolver=${NET_EXECUTOR_DNS:-127.0.0.1}
      if [ "$NET_EXEC_INTERNET" = direct ] && [ -z "$NET_EXECUTOR_DNS" ]; then resolver=$NET_DNS_ADDRESS; fi
      printf 'nameserver %s\noptions timeout:2 attempts:1\n' "$resolver" ;;
  esac
}

server_network_files_current() {
  local file dir
  dir=$(server_network_dir)
  for file in policy.env executor-policy.env allow.tsv orca-resolv.conf executor-resolv.conf; do
    [ -r "$dir/$file" ] && [ "$(cat "$dir/$file")" = "$(server_network_content "$file")" ] || return 1
  done
}

server_network_apply() {
  [ "$NETWORK_MODE" = isolated ] || return 0
  server_config_secret_apply
  server_config_secret_apply executor
  local dir content file current
  dir=$(server_network_dir)
  mkdir -p "$dir"
  # Approved credential-free data must be readable by gateways with DAC capabilities dropped.
  # shellcheck disable=SC2012 # only the fixed permission columns are read; no filename is parsed
  [ "$(ls -ld "$dir" | cut -c 8-10)" = r-x ] || chmod 755 "$dir"
  for file in policy.env executor-policy.env allow.tsv orca-resolv.conf executor-resolv.conf; do
    content=$(server_network_content "$file")
    current=''; [ ! -f "$dir/$file" ] || current=$(cat "$dir/$file")
    if [ ! -f "$dir/$file" ] || [ "$current" != "$content" ]; then
      info "+ write $(tilde "$dir/$file") (network policy; values not printed)"
      printf '%s\n' "$content" >"$dir/$file"
      # The resolver files are also mounted into non-root application containers.
      chmod 644 "$dir/$file"
    fi
  done
  mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/orca-setup/executor-home"
  case "$WORKDIR" in
    "$HOME"/*) mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/orca-setup/executor-home/${WORKDIR#"$HOME"/}" ;;
  esac
}

server_network_server_lines() { # <publish-address>
  if [ "$NETWORK_MODE" = direct ]; then
    printf '    ports:\n      - "%s:%s:%s/tcp"\n' "$1" "$ORCA_SERVER_PORT" "$ORCA_SERVER_PORT"
  else
    printf '    network_mode: "service:orca-gateway"\n'
    printf '    depends_on:\n      orca-gateway:\n        condition: service_healthy\n        restart: true\n'
    printf '      orca-executor:\n        condition: service_healthy\n'
  fi
}

server_network_image_supports_executor() {
  [ "$(dk image inspect --format '{{index .Config.Labels "org.orca-setup.executor-network"}}' "$1" 2>/dev/null)" = 1 ]
}

server_network_helpers_current() { # all sidecars and applications must share the current donor namespaces
  [ "$NETWORK_MODE" = isolated ] || return 0
  local config=$1 name donor app expected actual container
  for name in orca-gateway executor-gateway orca-executor; do
    container=$(server_container_name "$name")
    [ "$(server_container_state "$container")" = "running $config" ] || return 1
    [ "$(dk container inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null)" = healthy ] || return 1
    if [ "$name" != orca-executor ]; then
      dk exec "$container" "$ORCA_SERVER_ROOT/docker/gateway.sh" check >/dev/null 2>&1 || return 1
    fi
  done
  for app in orca-server orca-executor; do
    if [ "$app" = orca-server ]; then donor=orca-gateway; else donor=executor-gateway; fi
    donor=$(server_container_name "$donor")
    app=$(server_container_name "$app")
    expected=$(dk container inspect --format '{{.Id}}' "$donor" 2>/dev/null) || return 1
    actual=$(dk container inspect --format '{{.HostConfig.NetworkMode}}' "$app" 2>/dev/null) || return 1
    [ "$actual" = "container:$expected" ] || return 1
  done
}

server_network_plan() {
  [ "$NETWORK_MODE" = isolated ] || return 0
  info '  isolated Orca TCP and DNS through an existing HTTP CONNECT/SOCKS5 endpoint; no direct public fallback'
  info '           separate executor: shared workdir only; public access defaults to blocked and may be direct or proxied'
  info '           gateway sidecars run as root with NET_ADMIN; Orca and the executor keep your UID:GID and no capabilities'
  info '           IPv6 and non-DNS public UDP blocked; no custom host firewall or Docker daemon proxy setting is installed'
  if server_network_load >/dev/null 2>&1; then
    info "  executor public access: $NET_EXEC_INTERNET (private CIDR/port rules stay direct)"
    [ "$NET_EXEC_INTERNET" = blocked ] || info '           executor direct/proxy requires an updated image; use --apply --upgrade-image if the image is older'
    if [ -n "${CONFIG_FILE:-}" ]; then
      info "  policy   $(tilde "$CONFIG_FILE") (single TOML; validated; values not printed)"
      [ "$CONFIG_INLINE_AUTH" != yes ] || info '  secret   synchronize inline proxy authentication through stdin into a private Docker volume; mounted only by orca-gateway'
    else
      info '  policy   manifest/local/server-network.env and server-network-allow.tsv (validated; values not printed)'
    fi
    info '  write    network policy/resolver files and executor-home when missing or changed; start gateways before applications'
  else
    if [ -n "${CONFIG_FILE:-}" ]; then
      info '  missing  valid TOML network policy or external authentication file; --apply refuses before changing anything'
    else
      info '  missing  valid manifest/local/server-network.env (see manifest/local.example); --apply refuses before changing anything'
    fi
  fi
}

server_network_check() {
  [ "$NETWORK_MODE" = isolated ] || return 0
  if ! server_network_load >/dev/null 2>&1; then
    report 'MISSING (invalid or absent local network policy; no direct fallback)' 'Isolated network policy'
  elif ! server_network_files_current || [ "$(server_compose_config)" != "$(server_compose \
    "$(sed -n 's/^    image: "\(.*\)"$/\1/p' "$(server_compose_file)" | head -n 1)" \
    "$WORKDIR" "${pairing_address:-$(server_compose_value pairing-address)}" "$PUBLISH_ADDRESS" | \
    sed -n 's/^      org.orca-setup.config: "\(.*\)"$/\1/p' | head -n 1)" ]; then
    report 'STALE (network policy differs; run --apply --role server)' 'Isolated network policy'
  else
    report present 'Isolated network policy'
  fi
  if [ "${CONFIG_INLINE_AUTH:-no}" = yes ]; then
    if [ -n "$DOCKER_VIA" ] && server_config_secret_matches; then
      report present 'Private proxy authentication'
    else
      report 'STALE (private authentication differs or the gateway is unreachable; run --apply)' 'Private proxy authentication'
    fi
  fi
  if [ "${CONFIG_EXEC_INLINE_AUTH:-no}" = yes ]; then
    if [ -n "$DOCKER_VIA" ] && server_config_secret_matches executor; then
      report present 'Private executor proxy authentication'
    else
      report 'STALE (private authentication differs or executor gateway is unreachable; run --apply)' 'Private executor proxy authentication'
    fi
  fi
  if [ "${NET_EXEC_INTERNET:-blocked}" != blocked ] && [ -n "$DOCKER_VIA" ]; then
    local image
    image=$(sed -n 's/^    image: "\(.*\)"$/\1/p' "$(server_compose_file)" | head -n 1)
    if server_network_image_supports_executor "$image"; then
      report present 'Executor network image support'
    else
      report 'UNSUPPORTED (image predates executor networking; run --apply --upgrade-image)' 'Executor network image support'
    fi
  fi
  if [ -n "$DOCKER_VIA" ] && server_network_helpers_current "$(server_compose_config)"; then
    report 'healthy (namespace firewall checks; provider egress IP is not inferred)' 'Isolated network gateways'
  else
    report 'UNREACHABLE (a gateway/executor is unhealthy or a namespace is stale; run --apply --role server)' 'Isolated network gateways'
  fi
}
