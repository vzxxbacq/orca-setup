#!/usr/bin/env bats
# setup.sh argument handling and the --plan snapshot. Nothing here may install or change anything.

load helpers

setup() {
  make_sandbox
  fake_brew git ripgrep
  fake_present git gh rg jq codex claude curl unzip
  fake_orca
  mkdir -p "$SB/home/.local/bin"
}

teardown() {
  # The plan must never reach a package manager or a state-changing Orca call.
  [ ! -s "$FAKE_LOG" ] || { cat "$FAKE_LOG"; return 1; }
}

snapshot() { # snapshot <name>: compare $output with tests/bats/fixtures/<name>, or rewrite it
  local file=$BATS_TEST_DIRNAME/fixtures/$1
  if [ -n "${UPDATE_SNAPSHOTS:-}" ]; then printf '%s\n' "$output" >"$file"; fi
  "$REAL_DIFF" -u "$file" <(printf '%s\n' "$output")
}

@test "no arguments is --plan" {
  run_setup
  [ "$status" -eq 0 ]
  local default=$output
  run_setup --plan
  [ "$output" = "$default" ]
}

@test "--plan snapshot on macOS" {
  run_setup --plan
  [ "$status" -eq 0 ]
  snapshot plan-macos.txt
}

@test "--plan with a role, modules and a task source" {
  fake_cmd pmset 'printf "AC Power:\n sleep 1\n autorestart 0\n"'
  run_setup --plan --role server --power --media --task-source linear
  [ "$status" -eq 0 ]
  snapshot plan-macos-server-modules.txt
}

@test "refuses to run as root" {
  fake_cmd id 'echo 0'
  run_setup --plan
  [ "$status" -eq 1 ]
  [[ "$output" == *'without sudo'* ]]
}

@test "--apply requires --role" {
  run_setup --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *'--apply requires --role'* ]]
  run_setup --apply --role both
  [ "$status" -eq 1 ]
}

@test "--apply checks the role after the baseline and refuses the other role before any Orca step" {
  printf '{"ok":true,"result":{"environments":[{"name":"mini"}]}}\n' >"$ORCA_USER_DATA/cli-environments.json"
  fake_baseline_present
  run_setup --apply --role server
  [[ "$output" == *'PRESENT tmux'* ]]
  [ "$status" -eq 1 ]
  [[ "$output" == *'saved environment: mini'* ]]
  [[ "$output" == *'already holds the other pairing role'* ]]
}

@test "--apply refuses when the pairing role cannot be determined" {
  echo 'not json' >"$ORCA_USER_DATA/orca-devices.json"
  fake_baseline_present
  run_setup --apply --role client
  [ "$status" -eq 1 ]
  [[ "$output" == *'ROLE unknown'* ]]
  [[ "$output" == *'pairing role cannot be determined'* ]]
}

@test "--check counts an unknown pairing role" {
  echo '{}' >"$ORCA_USER_DATA/orca-devices.json"
  run_setup --check
  [[ "$output" == *'Pairing role: unknown'* ]]
  [[ "$output" == *'Pairing role check: UNREACHABLE'* ]]
}

@test "unknown options exit 2; modes cannot be combined" {
  run_setup --bogus
  [ "$status" -eq 2 ]
  run_setup --auth-bogus
  [ "$status" -eq 2 ]
  run_setup --plan --check
  [ "$status" -eq 1 ]
  run_setup --auth-gh --media
  [ "$status" -eq 1 ]
  [[ "$output" == *'modules run only with --apply'* ]]
  run_setup --task-source jira
  [ "$status" -eq 1 ]
}

@test "--check exit code counts missing items and never prints secrets" {
  run_setup --check
  [ "$status" -gt 0 ]
  [[ "$output" == *"MISSING_ITEMS $status"* ]]
  [[ "$output" == *'PRESENT git'* ]]
  [[ "$output" == *'MISSING tmux'* ]]
  [[ "$output" == *'Orca Codex: selected'* ]]
  [[ "$output" == *'Orca settings: differs (defaultTuiAgent)'* ]]
  [[ "$output" == *'Pairing role: none'* ]]
  [[ "$output" != *acct-secret-id* ]]
}
