# shellcheck shell=bash
# --auth-linear: open Linear's API settings and hand a hidden key straight to Orca. The key is read by
# auth/linear-login.cjs without echo and passed on stdin to orca/orca-rpc.sh (linear.connect); it never reaches an
# argument list, the output, a log or a file of this repository.
LINEAR_API_SETTINGS_URL=https://linear.app/settings/api
auth_linear_describe() {
  if [ "$PLATFORM" = debian ] && [ "$(detect_desktop)" = no ]; then
    echo "Print Linear's API settings URL (open it on any device); read a key without echoing or logging it."
  else echo "Open Linear's API settings and read a key without echoing or logging it."; fi
}
auth_linear() {
  local status
  if status=$(orca_rpc linear.status) && printf '%s' "$status" | node "$ORCA_SETUP_ROOT/lib/json.cjs" has connected; then
    info 'Linear already connected'
    return 0
  fi
  if [ "$PLATFORM" = debian ]; then
    # The key is stored by this device's Orca runtime; a client without one has nowhere to keep it.
    [ -n "$status" ] ||
      die "the Orca runtime on this device does not answer; a Linux client has none (connect Linear on its server), and on a server see: docker logs $ORCA_SERVER_NAME (on the host)."
    if [ "$(detect_desktop)" = yes ] && have xdg-open; then xdg-open "$LINEAR_API_SETTINGS_URL" >/dev/null 2>&1 || true; fi
    info "Create a personal API key at $LINEAR_API_SETTINGS_URL"
  elif [ "$(detect_desktop)" = yes ] && have open; then
    open "$LINEAR_API_SETTINGS_URL"
  else
    info "Create a personal API key at $LINEAR_API_SETTINGS_URL"
  fi
  node "$ORCA_SETUP_ROOT/auth/linear-login.cjs"
}
