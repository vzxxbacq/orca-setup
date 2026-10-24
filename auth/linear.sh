# shellcheck shell=bash
# --auth-linear: open Linear's API settings and hand a hidden key straight to Orca.
LINEAR_API_SETTINGS_URL=https://linear.app/settings/api
auth_linear_describe() { echo "Open Linear's API settings and read a key without echoing or logging it."; }
auth_linear() {
  if orca_rpc linear.status | node "$ORCA_SETUP_ROOT/lib/json.cjs" has connected; then
    info 'Linear already connected'
    return 0
  fi
  if [ "$(detect_desktop)" = yes ] && have open; then
    open "$LINEAR_API_SETTINGS_URL"
  else
    info "Create a personal API key at $LINEAR_API_SETTINGS_URL"
  fi
  node "$ORCA_SETUP_ROOT/auth/linear-login.cjs"
}
