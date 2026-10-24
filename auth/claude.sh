# shellcheck shell=bash
# --auth-claude: add a Claude account to this host's Orca (interactive).
auth_claude_describe() { echo "Add a Claude account to this host's Orca (interactive), unless one is selected."; }
auth_claude() {
  if orca_rpc accounts.list | node "$ORCA_SETUP_ROOT/lib/json.cjs" has claude.activeAccountId; then
    info 'Orca Claude account already selected'
  else
    step "$ORCA_CLI" account add --agent claude
  fi
}
