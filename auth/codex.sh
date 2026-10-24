# shellcheck shell=bash
# --auth-codex: add a Codex account to this host's Orca with device authentication.
auth_codex_describe() { echo "Add a Codex account to this host's Orca using device authentication."; }
auth_codex() {
  if orca_rpc accounts.list | node "$ORCA_SETUP_ROOT/lib/json.cjs" has codex.activeAccountId; then
    info 'Orca Codex account already selected'
  else
    step "$ORCA_CLI" account add --agent codex
  fi
}
