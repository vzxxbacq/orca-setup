#!/usr/bin/env bats
# manifest/ format, contents and the local overlay merge.

load helpers

setup() {
  make_sandbox
  # shellcheck source=../../lib/common.sh
  . "$REPO_ROOT/lib/common.sh"
  # shellcheck source=../../lib/manifest.sh
  . "$REPO_ROOT/lib/manifest.sh"
}

use_copy() {
  cp -R "$REPO_ROOT/manifest" "$SB/manifest"
  ORCA_SETUP_MANIFEST_DIR=$SB/manifest
}

@test "every tool row has five non-empty tab-separated fields and a unique key" {
  local file
  for file in baseline.tsv agents.tsv; do
    run awk -F'\t' '!/^[[:space:]]*(#|$)/ && (NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "") { print FILENAME ": " $0 }' "$REPO_ROOT/manifest/$file"
    [ -z "$output" ]
    run bash -c "awk -F'\t' '!/^[[:space:]]*(#|\$)/ { print \$1 }' '$REPO_ROOT/manifest/$file' | sort | uniq -d"
    [ -z "$output" ]
  done
}

@test "groups are baseline or a known optional module" {
  run bash -c "cat '$REPO_ROOT/manifest/baseline.tsv' '$REPO_ROOT/manifest/agents.tsv' | awk -F'\t' '!/^[[:space:]]*(#|\$)/ { print \$3 }' | sort -u"
  [ "$output" = "$(printf '%s\n' agent-gemini android apple baseline containers media)" ]
}

@test "agent packages match README section 3.2" {
  run manifest_select agents.tsv macos baseline
  [ "$output" = "$(printf '%s\t%s\t%s\n' \
    codex codex npm:@openai/codex \
    claude claude npm:@anthropic-ai/claude-code \
    dsh dsh npm:@deepseek-ai/dsh \
    dsh-tui dsh-tui npm:@deepseek-harness-tui/dsh-tui \
    pi pi npm:@earendil-works/pi-coding-agent \
    bun bun npm:bun \
    omp omp npm:@oh-my-pi/pi-coding-agent \
    grok grok installer:https://x.ai/cli/install.sh \
    agy agy installer:https://antigravity.google/cli/install.sh)" ]
  run manifest_select agents.tsv macos agent-gemini
  [ "$output" = "$(printf 'gemini\tgemini\tnpm:@google/gemini-cli')" ]
}

@test "platform columns: rows marked - are skipped" {
  run manifest_select baseline.tsv macos baseline
  [[ "$output" != *build-essential* ]]
  [[ "$output" == *$'pkg-config\tpkg-config\tbrew:pkgconf'* ]]
  run manifest_select baseline.tsv debian baseline
  [[ "$output" == *$'build-essential\tcc\tapt:build-essential'* ]]
  run manifest_select baseline.tsv debian apple
  [ -z "$output" ]
}

@test "skills per platform: orca-emulator is macOS-only" {
  run skills_for macos
  [ "$output" = "$(printf 'universal,claude-code,codex\torca-cli orca-linear computer-use orca-emulator')" ]
  run skills_for linux
  [ "$output" = "$(printf 'universal,claude-code,codex\torca-cli orca-linear computer-use')" ]
}

@test "local overlay replaces rows in place and appends new ones" {
  use_copy
  mkdir -p "$SB/manifest/local"
  printf 'jq\tjq\tbaseline\tbrew:jq-fork\tapt:jq\ninternal-cli\tinternal\tbaseline\tbrew:internal\t-\n' >"$SB/manifest/local/baseline.tsv"
  run manifest_select baseline.tsv macos baseline
  [[ "$output" == *$'jq\tjq\tbrew:jq-fork'* ]]
  [[ "$output" != *$'brew:jq\n'* ]]
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "$(printf 'internal-cli\tinternal\tbrew:internal')" ]
  [ "$(printf '%s\n' "$output" | grep -c '^jq')" -eq 1 ]
  # Order is kept: jq stays between ripgrep and tmux.
  [ "$(printf '%s\n' "$output" | cut -f1 | grep -A1 '^ripgrep$' | tail -n 1)" = jq ]
}

@test "the shipped example overlay merges cleanly" {
  use_copy
  cp -R "$SB/manifest/local.example" "$SB/manifest/local"
  run manifest_select baseline.tsv macos baseline
  [ "$status" -eq 0 ]
  [[ "$output" == *$'example-cli\texample-cli\tbrew:example-org/tap/example-cli'* ]]
  run node "$REPO_ROOT/lib/json.cjs" settings
  [ "$status" -eq 0 ]
}

@test "orca-settings.json: defaults, opt-in task source and local overlay" {
  run node "$REPO_ROOT/lib/json.cjs" settings
  [ "$output" = '{"defaultTuiAgent":"codex","agentStatusHooksEnabled":true}' ]
  run node "$REPO_ROOT/lib/json.cjs" settings linear
  [ "$output" = '{"defaultTuiAgent":"codex","agentStatusHooksEnabled":true,"defaultTaskSource":"linear","visibleTaskProviders":["linear"]}' ]
  use_copy
  mkdir -p "$SB/manifest/local"
  echo '{"settings":{"defaultTuiAgent":"claude"}}' >"$SB/manifest/local/orca-settings.json"
  ORCA_SETUP_MANIFEST_DIR=$SB/manifest run node "$REPO_ROOT/lib/json.cjs" settings
  [ "$output" = '{"defaultTuiAgent":"claude","agentStatusHooksEnabled":true}' ]
}
