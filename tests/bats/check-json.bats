#!/usr/bin/env bats
# setup.sh --check --json (P4): one JSON document with names, states, counts and versions, never credential values;
# and the Orca version report (installed vs latest release), which never upgrades anything.

load helpers

setup() {
  make_sandbox
  fake_brew git ripgrep
  fake_present git gh rg jq codex claude curl unzip
  fake_orca
  mkdir -p "$SB/home/.local/bin"
}

teardown() {
  [ ! -s "$FAKE_LOG" ] || { cat "$FAKE_LOG"; return 1; }
}

# validate: $output is a check report; prints "<missing> <counted items>".
validate() {
  printf '%s' "$output" | "$REAL_NODE" -e '
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const fail = m => { console.error(m); process.exit(1); };
    if (r.schema !== "orca-setup-check/1") fail("schema");
    if (!Number.isInteger(r.missing)) fail("missing");
    for (const list of [r.items, r.auth]) for (const i of list) {
      if (typeof i.name !== "string" || typeof i.state !== "string" || typeof i.counted !== "boolean") fail(JSON.stringify(i));
    }
    for (const v of Object.values(r.versions)) if (typeof v !== "string") fail("version");
    console.log(r.missing, r.items.filter(i => i.counted).length);
  '
}

@test "--check --json prints one JSON document whose missing count is the exit code" {
  run_setup --check --json --media
  local status_was=$status summary
  [ "$status_was" -gt 0 ]
  [[ "${lines[0]}" == '{' ]]
  summary=$(validate)
  [ "$summary" = "$status_was $status_was" ]
  [[ "$output" == *'"name": "tmux", "state": "MISSING", "counted": true'* ]]
  [[ "$output" == *'"name": "git", "state": "present", "counted": false'* ]]
  [[ "$output" == *'"name": "Orca Codex", "state": "selected", "counted": false'* ]]
  [[ "$output" == *'"modules": ["media"]'* ]]
  [[ "$output" == *'"role": {"requested": null, "detected": "none"}'* ]]
  [[ "$output" == *'"audit": {'* ]]
  [[ "$output" != *MISSING_ITEMS* ]]
  [[ "$output" != *READINESS_JSON* ]]
}

@test "--check --json lists the interactive logins" {
  fake_cmd gh 'exit 1'
  run_setup --check --json --role server
  validate >/dev/null
  [[ "$output" == *'{"name": "gh", "state": "pending", "counted": true}'* ]]
  [[ "$output" == *'{"name": "codex", "state": "complete", "counted": false}'* ]]
  [[ "$output" == *'{"name": "claude", "state": "not-selected", "counted": false}'* ]]
  [[ "$output" == *'"role": {"requested": "server", "detected": "none"}'* ]]
}

@test "--json works only with --check" {
  run_setup --plan --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'--json works only with --check'* ]]
  run_setup --apply --role client --json
  [ "$status" -eq 1 ]
}

@test "--check --json never prints a credential value" {
  local h=$HOME
  mkdir -p "$h/.claude" "$h/.gemini" "$h/.codex" "$h/.aws" "$h/.dsh"
  echo '{"env":{"ANTHROPIC_API_KEY":"sk-ant-SECRET1"},"apiKeyHelper":"echo SECRET3"}' >"$h/.claude/settings.json"
  echo '{"access_token":"ya29.SECRET5","refresh_token":"1//SECRET6","expiry_date":1}' >"$h/.gemini/oauth_creds.json"
  echo '{"tokens":{"access_token":"SECRET12"}}' >"$h/.codex/auth.json"
  printf '[default]\naws_secret_access_key = SECRET13\n' >"$h/.aws/credentials"
  printf 'DEEPSEEK_API_KEY=SECRET8\n' >"$h/.dsh/.env"
  OPENAI_API_KEY=sk-SECRET15 GITHUB_TOKEN=ghp_SECRET16 run_setup --check --json
  validate >/dev/null
  [[ "$output" == *'"OPENAI_API_KEY":true'* ]]
  [[ ! "$output" =~ SECRET[0-9] ]]
  [[ "$output" != *sk-* ]]
  [[ "$output" != *ya29* ]]
  [[ "$output" != *ghp_* ]]
  [[ "$output" != *acct-secret-id* ]]
}

@test "--check reports the installed and the latest Orca version, never upgrading" {
  # shellcheck disable=SC2016 # expanded by the stub
  fake_cmd curl 'case "$*" in *api.github.com/repos/stablyai/orca/releases/latest*) echo "{\"tag_name\":\"v1.2.4\",\"draft\":false}" ;; *) exit 22 ;; esac'
  run_setup --check
  [[ "$output" == *'VERSION orca 1.2.3 (latest release 1.2.4; reported only, setup.sh never upgrades Orca)'* ]]
  run_setup --check --json
  [[ "$output" == *'"orca": "1.2.3", "orca-latest": "1.2.4"'* ]]
}

@test "--check reports an unknown latest version when GitHub cannot be read" {
  fake_cmd curl 'exit 6'
  run_setup --check
  [[ "$output" == *'VERSION orca 1.2.3 (latest release unknown)'* ]]
}
