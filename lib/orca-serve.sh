# shellcheck shell=bash
# Orca server on Linux (--role server): a systemd user unit running `orca-ide serve --supervise`, plus linger so it
# survives logout. The unit is rendered from orca/systemd/orca-serve.service. It runs with --no-pairing and setup.sh
# never asks for a pairing offer, so no pairing URL is ever printed, logged or written by these scripts.
# Needs lib/common.sh and as_root from lib/pkg-debian.sh.

ORCA_SERVE_PORT=6768
ORCA_SERVE_UNIT=orca-serve.service
ORCA_SERVE_MARKER='# orca-setup: Orca server for this user'
ORCA_SERVE_ENV_KEYS='ORCA_TERMINAL_PROCESS_CEILING ORCA_TERMINAL_MEMORY_MAX ORCA_TERMINAL_MEMORY_SWAP_MAX'

serve_unit_path() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$ORCA_SERVE_UNIT"; }

# tilde <path>: the path with $HOME shown as ~ (for messages only).
# shellcheck disable=SC2088 # a literal ~ for display
tilde() { case "$1" in "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;; *) printf '%s\n' "$1" ;; esac; }

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

# serve_env_lines: Environment= lines for the optional terminal limits, read from manifest/orca-serve.env and
# overridden key by key from manifest/local/orca-serve.env. Unknown keys and malformed values stop the run.
serve_env_lines() {
  local base="$ORCA_SETUP_MANIFEST_DIR/orca-serve.env" overlay="$ORCA_SETUP_MANIFEST_DIR/local/orca-serve.env" key value
  [ -r "$overlay" ] || overlay=/dev/null
  while IFS='=' read -r key value; do
    case " $ORCA_SERVE_ENV_KEYS " in *" $key "*) ;; *) die "orca-serve.env: unknown key $key (allowed: $ORCA_SERVE_ENV_KEYS)" ;; esac
    case "$key" in
      ORCA_TERMINAL_PROCESS_CEILING) [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 64 ] || die "orca-serve.env: $key must be a number, 64 or more" ;;
      *) [[ "$value" =~ ^[0-9]+[KMGT]?$ ]] || die "orca-serve.env: $key must be a size such as 16G or 0" ;;
    esac
    printf 'Environment=%s=%s\n' "$key" "$value"
  done < <(awk '
    /^[[:space:]]*(#|$)/ { next }
    { sub(/[[:space:]]+$/, ""); key = $0; sub(/=.*/, "", key)
      if (!(key in line)) order[++n] = key; line[key] = $0 }
    END { for (i = 1; i <= n; i++) print line[order[i]] }
  ' "$base" "$overlay")
}

# serve_command: absolute path of the Orca CLI the unit starts: the .deb's /usr/bin/orca-ide (a link that survives
# upgrades), else the CLI found on PATH. Never a shim that a running server writes into ~/.local/bin, which would
# change the unit between runs. ORCA_SETUP_DEB_CLI overrides the .deb path (tests).
serve_command() {
  local deb=${ORCA_SETUP_DEB_CLI:-/usr/bin/orca-ide} path
  if [ -z "${ORCA_CLI_COMMAND:-}" ] && [ -x "$deb" ]; then printf '%s\n' "$deb"; return; fi
  path=$(command -v "$ORCA_CLI" 2>/dev/null) || path=''
  case "$path" in /*) printf '%s\n' "$path" ;; *) printf '%s\n' "$deb" ;; esac
}

# serve_unit_render <command> <pairing-address>: the unit file content.
serve_unit_render() {
  local env_lines
  env_lines=$(serve_env_lines) || return 1
  # Values go through ENVIRON: awk -v would interpret backslashes and cannot hold several lines everywhere.
  SERVE_CMD=$1 SERVE_ADDRESS=$2 SERVE_PORT=$ORCA_SERVE_PORT SERVE_ENV=$env_lines awk '
    /^@ENVIRONMENT@$/ { if (ENVIRON["SERVE_ENV"] != "") print ENVIRON["SERVE_ENV"]; next }
    { line = $0
      out = ""
      while (match(line, /@(ORCA_IDE|PORT|PAIRING_ADDRESS)@/)) {
        key = substr(line, RSTART + 1, RLENGTH - 2)
        value = key == "ORCA_IDE" ? ENVIRON["SERVE_CMD"] : key == "PORT" ? ENVIRON["SERVE_PORT"] : ENVIRON["SERVE_ADDRESS"]
        out = out substr(line, 1, RSTART - 1) value
        line = substr(line, RSTART + RLENGTH)
      }
      print out line }
  ' "$ORCA_SETUP_ROOT/orca/systemd/orca-serve.service"
}

# The user's systemd manager. A session started without one (sudo -u, CI) still finds it through linger.
user_systemctl() {
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemctl --user "$@"
}

# user_step <systemctl args>: print, then run a state-changing systemctl --user command.
user_step() {
  printf '+ systemctl --user %s\n' "$*"
  user_systemctl "$@"
}

# linger_state: yes | no | unknown (loginctl missing or not answering).
linger_state() {
  local value
  value=$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null) || value=''
  case "$value" in yes | no) echo "$value" ;; *) echo unknown ;; esac
}

# serve_unit_state: missing | foreign (a unit setup.sh did not write) | current | stale (differs from the render).
serve_unit_state() { # <rendered>
  local path
  path=$(serve_unit_path)
  if [ ! -e "$path" ]; then echo missing
  elif [ "$(head -n 1 "$path")" != "$ORCA_SERVE_MARKER" ]; then echo foreign
  elif [ "$(cat "$path")" = "$1" ]; then echo current
  else echo stale
  fi
}

serve_plan() { # <pairing-address or empty>
  local address=$1 user rendered path state
  user=$(id -un)
  path=$(serve_unit_path)
  info 'Orca server (--apply --role server):'
  if [ -z "$address" ]; then
    info '  missing  --pairing-address <ip-or-host>: the private address clients dial (README section 1); --apply requires it'
  else
    info "  address  $address (advertised to clients; port $ORCA_SERVE_PORT)"
  fi
  if [ "$(linger_state)" = yes ]; then info "  present  linger for $user"
  else
    info "  enable   linger for $user (the user's services keep running after logout)"
    info "           sudo loginctl enable-linger $user"
  fi
  rendered=$(serve_unit_render "$(serve_command)" "${address:-<pairing-address>}")
  state=$(serve_unit_state "$rendered")
  case "$state" in
    foreign) info "  keep     $(tilde "$path") (not written by orca-setup; left unchanged)" ;;
    current) info "  present  $(tilde "$path")" ;;
    *)
      if [ "$state" = missing ]; then info "  write    $(tilde "$path")"; else info "  update   $(tilde "$path") (then restart it)"; fi
      grep -E '^(ExecStart|Environment=ORCA_)' <<<"$rendered" | sed 's/^/             /' ;;
  esac
  info "  start    systemctl --user enable $ORCA_SERVE_UNIT, start it, wait until \`$ORCA_CLI status\` reaches the runtime"
  info '  pairing  setup.sh never creates or prints a pairing link; pair clients from a terminal (README section 3.3.2)'
}

# serve_apply <pairing-address>: linger, the unit, and a running server. Re-running changes nothing when all
# three are in place.
serve_apply() {
  local address=$1 user rendered path state changed=no waited=0 limit=${ORCA_SETUP_SERVE_WAIT:-120}
  user=$(id -un)
  path=$(serve_unit_path)
  { have systemctl && have loginctl; } || die 'systemd (systemctl, loginctl) is required for --role server on Linux.'
  if [ "$(linger_state)" = yes ]; then info "PRESENT linger for $user"; else as_root loginctl enable-linger "$user"; fi
  # Linger starts the user manager; give it a moment before talking to it.
  until user_systemctl show-environment >/dev/null 2>&1; do
    [ "$waited" -lt 10 ] || die "systemctl --user cannot reach $user's service manager (is XDG_RUNTIME_DIR set?)."
    sleep 1
    waited=$((waited + 1))
  done
  rendered=$(serve_unit_render "$(serve_command)" "$address") || exit 1
  state=$(serve_unit_state "$rendered")
  case "$state" in
    foreign) info "PRESENT $ORCA_SERVE_UNIT (not written by orca-setup; left unchanged)" ;;
    current) info "PRESENT $ORCA_SERVE_UNIT" ;;
    *)
      info "+ write $path"
      mkdir -p "$(dirname "$path")"
      printf '%s\n' "$rendered" >"$path"
      changed=yes
      user_step daemon-reload ;;
  esac
  if user_systemctl is-enabled --quiet "$ORCA_SERVE_UNIT"; then info "PRESENT $ORCA_SERVE_UNIT enabled"
  else user_step enable "$ORCA_SERVE_UNIT"; fi
  if ! user_systemctl is-active --quiet "$ORCA_SERVE_UNIT"; then user_step start "$ORCA_SERVE_UNIT"
  elif [ "$changed" = yes ]; then user_step restart "$ORCA_SERVE_UNIT"
  else info "PRESENT $ORCA_SERVE_UNIT active"; fi
  waited=0
  until "$ORCA_CLI" status --json 2>/dev/null | node "$ORCA_SETUP_ROOT/lib/json.cjs" has result.runtime.reachable; do
    [ "$waited" -lt "$limit" ] ||
      die "the Orca runtime is not reachable ${limit}s after starting $ORCA_SERVE_UNIT; see: systemctl --user status $ORCA_SERVE_UNIT"
    sleep 2
    waited=$((waited + 2))
  done
}

# serve_check: report the unit and linger (uses report and missing from setup.sh).
serve_check() {
  local path state
  path=$(serve_unit_path)
  if [ ! -e "$path" ]; then
    report 'MISSING (run --apply --role server)' 'Orca serve unit'
  else
    state=$(user_systemctl is-active "$ORCA_SERVE_UNIT" 2>/dev/null) || true
    if [ "$state" = active ]; then report active 'Orca serve unit'; else report "INACTIVE (${state:-unknown})" 'Orca serve unit'; fi
  fi
  case "$(linger_state)" in
    yes) report on 'Linger' ;;
    no) report 'OFF (the server stops at logout; run --apply --role server)' 'Linger' ;;
    *) report 'UNREACHABLE (loginctl did not answer)' 'Linger' ;;
  esac
}
