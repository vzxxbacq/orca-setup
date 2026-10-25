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
  [ "$output" = "$(printf '%s\n' agent-gemini android apple baseline containers image media)" ]
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

@test "Linux column: every baseline row has a known Debian method" {
  run bash -c "cat '$REPO_ROOT/manifest/baseline.tsv' '$REPO_ROOT/manifest/agents.tsv' | awk -F'\t' '!/^[[:space:]]*(#|\$)/ && \$3 == \"baseline\" && \$5 !~ /^(apt|apt-repo|npm|installer|uv-python|uv-tool|orca-deb):[^:]/ && \$5 != \"-\" { print }'"
  [ -z "$output" ]
  run manifest_select baseline.tsv debian baseline
  [[ "$output" == *$'gh\tgh\tapt-repo:gh:gh'* ]]
  [[ "$output" == *$'node\tnode\tapt-repo:nodesource:nodejs'* ]]
  [[ "$output" == *$'gnupg\tgpg\tapt:gnupg'* ]]
  [[ "$output" == *$'python\tpython3.12\tuv-python:3.12'* ]]
  [[ "$output" == *$'ruff\truff\tuv-tool:ruff'* ]]
}

@test "Linux column: every baseline agent is supported on Linux x86_64 (none is macOS-only)" {
  [ "$(manifest_select agents.tsv debian baseline | cut -f1)" = "$(manifest_select agents.tsv macos baseline | cut -f1)" ]
  run manifest_select agents.tsv debian baseline
  [[ "$output" == *$'agy\tagy\tinstaller:https://antigravity.google/cli/install.sh'* ]]
}

@test "apt-repos.tsv: eight fields, uppercase 40-hex fingerprints, and every apt-repo method resolves" {
  run awk -F'\t' '!/^[[:space:]]*(#|$)/ && NF != 8 { print }' "$REPO_ROOT/manifest/apt-repos.tsv"
  [ -z "$output" ]
  run bash -c "awk -F'\t' '!/^[[:space:]]*(#|\$)/ { print \$3 }' '$REPO_ROOT/manifest/apt-repos.tsv' | tr ',' '\n' | grep -vxE '[0-9A-F]{40}'"
  [ -z "$output" ]
  local repo
  for repo in $(manifest_rows baseline.tsv | cut -f5 | sed -n 's/^apt-repo:\([^:]*\):.*/\1/p'); do
    manifest_rows apt-repos.tsv | cut -f1 | grep -qx "$repo"
  done
  [ "$(manifest_rows apt-repos.tsv | cut -f1,2)" = "$(printf '%s\t%s\n' \
    gh https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    nodesource https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    docker 'https://download.docker.com/linux/{distro}/gpg')" ]
  # Docker's key, as printed in Docker's own Ubuntu and Debian install guides.
  [ "$(manifest_rows apt-repos.tsv | awk -F'\t' '$1 == "docker" { print $3 }')" = 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ]
}

@test "optional modules: every Linux method is known, and apt-conflicts.tsv names known repositories" {
  run bash -c "cat '$REPO_ROOT/manifest/baseline.tsv' '$REPO_ROOT/manifest/agents.tsv' | awk -F'\t' '!/^[[:space:]]*(#|\$)/ && \$3 != \"baseline\" && \$5 !~ /^(apt|apt-repo|npm|github-release):[^:]/ && \$5 != \"-\" { print }'"
  [ -z "$output" ]
  run manifest_select baseline.tsv debian media
  [[ "$output" == *$'marksman\tmarksman\tgithub-release:artempyanykh/marksman:marksman-linux-x64:marksman'* ]]
  [ "$(manifest_select baseline.tsv debian containers | cut -f3 | paste -sd ' ' -)" = \
    'apt-repo:docker:docker-ce apt-repo:docker:docker-ce-cli apt-repo:docker:containerd.io apt-repo:docker:docker-buildx-plugin apt-repo:docker:docker-compose-plugin' ]
  [ -z "$(manifest_select baseline.tsv debian apple)" ]
  # macOS keeps one Docker row: Docker Desktop.
  [ "$(manifest_select baseline.tsv macos containers | cut -f3)" = cask:docker-desktop ]
  local repo
  for repo in $(manifest_rows apt-conflicts.tsv | cut -f1); do
    manifest_rows apt-repos.tsv | cut -f1 | grep -qx "$repo"
  done
  [[ "$(manifest_rows apt-conflicts.tsv | awk -F'\t' '$1 == "docker" { print $2 }')" == *'docker.io'*'podman-docker'*'podman'* ]]
}

@test "apt_repo_row fills in the distribution and its release code name" {
  . "$REPO_ROOT/lib/detect.sh"
  . "$REPO_ROOT/lib/pkg-debian.sh"
  fake_os_release ubuntu 24.04 debian
  [ "$(apt_repo_row docker | cut -f2,6,7 | tr '\t' ' ')" = 'https://download.docker.com/linux/ubuntu/gpg https://download.docker.com/linux/ubuntu noble' ]
  fake_os_release debian 12
  [ "$(apt_repo_row docker | cut -f2,6,7 | tr '\t' ' ')" = 'https://download.docker.com/linux/debian/gpg https://download.docker.com/linux/debian bookworm' ]
  [ "$(apt_repo_row gh | cut -f7)" = stable ]
}

@test "Debian install order: apt, repositories, installers, npm, then uv-managed tools" {
  . "$REPO_ROOT/lib/pkg-debian.sh"
  [ "$(manifest_select baseline.tsv debian baseline | debian_order | cut -f1 | paste -sd ' ' -)" = 'git git-lfs ripgrep jq tmux cmake pkg-config build-essential curl unzip ca-certificates gnupg libgbm libasound gh node uv pnpm python ruff orca' ]
}

@test "server manifests: mounts are relative directories plus {workdir}; host rows exist; limits ship empty" {
  run awk -F'\t' '!/^[[:space:]]*(#|$)/ && (NF != 2 || $1 ~ /^\// || $1 ~ /\.\./ || $2 == "") { print }' "$REPO_ROOT/manifest/server-mounts.tsv"
  [ -z "$output" ]
  [ "$(manifest_rows server-mounts.tsv | cut -f1 | head -n 1)" = '{workdir}' ]
  manifest_rows server-mounts.tsv | cut -f1 | grep -qx .orca
  manifest_rows server-mounts.tsv | cut -f1 | grep -qx .claude
  # No single file is mounted: Claude's .claude.json moves into ~/.claude (CLAUDE_CONFIG_DIR).
  ! manifest_rows server-mounts.tsv | cut -f1 | grep -q '\.json$'
  local name
  for name in $(manifest_rows server-host.tsv | cut -f1); do
    manifest_select baseline.tsv debian baseline | cut -f1 | grep -qx "$name"
  done
  [ -z "$(awk '!/^[[:space:]]*(#|$)/' "$REPO_ROOT/manifest/server-limits.env")" ]
  # The image rows are Linux-only.
  [ "$(manifest_select baseline.tsv debian image | cut -f1 | paste -sd ' ' -)" = 'xvfb nss-extrausers' ]
  [ -z "$(manifest_select baseline.tsv macos image)" ]
}
