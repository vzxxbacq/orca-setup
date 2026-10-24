#!/usr/bin/env bats
# audit/readiness.cjs prints names and booleans only: seed every file it reads with fake secrets.

load helpers

setup() {
  make_sandbox
  local h=$HOME
  mkdir -p "$h/.claude" "$h/.gemini" "$h/.dsh" "$h/.pi/agent" "$h/.codex" "$h/.aws" "$h/.config/gh"
  echo '{"env":{"ANTHROPIC_API_KEY":"sk-ant-SECRET1","ANTHROPIC_BASE_URL":"https://SECRET2.example"},"apiKeyHelper":"echo SECRET3","enabledPlugins":{"plugin-a":true}}' >"$h/.claude/settings.json"
  echo '{"mcpServers":{"docs":{"command":"x","env":{"TOKEN":"SECRET4"}}}}' >"$h/.claude.json"
  echo '{"access_token":"ya29.SECRET5","refresh_token":"1//SECRET6","expiry_date":1}' >"$h/.gemini/oauth_creds.json"
  echo '{"mcpServers":{"search":{"headers":{"Authorization":"Bearer SECRET7"}}}}' >"$h/.gemini/settings.json"
  printf 'DEEPSEEK_API_KEY=SECRET8\nexport OTHER_NAME=SECRET9\n' >"$h/.dsh/.env"
  echo '{"openai":{"key":"sk-SECRET10"}}' >"$h/.pi/agent/auth.json"
  printf '[mcp_servers.tracker]\ncommand = "x"\n[mcp_servers.tracker.env]\nAPI_KEY = "SECRET11"\n' >"$h/.codex/config.toml"
  echo '{"tokens":{"access_token":"SECRET12"}}' >"$h/.codex/auth.json"
  printf '[default]\naws_secret_access_key = SECRET13\n' >"$h/.aws/credentials"
  fake_cmd claude 'echo "{\"loggedIn\":true,\"authMethod\":\"oauth\",\"apiProvider\":\"firstParty\",\"email\":\"SECRET14@example.com\"}"'
}

audit() { OPENAI_API_KEY=sk-SECRET15 run node "$REPO_ROOT/audit/readiness.cjs"; }

@test "prints one READINESS_JSON line with names and booleans" {
  audit
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == 'READINESS_JSON {'* ]]
  printf '%s' "${output#READINESS_JSON }" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))'
  [[ "$output" == *'"OPENAI_API_KEY":true'* ]]
  [[ "$output" == *'"loggedIn":true'* ]]
  [[ "$output" == *'"mcpNames":["docs"]'* ]]
  [[ "$output" == *'"homeEnvNames":["DEEPSEEK_API_KEY","OTHER_NAME"]'* ]]
  [[ "$output" == *'"mcpNames":["tracker"]'* ]]
  [[ "$output" == *'"authFile":true'* ]]
  [[ "$output" == *'"awsCredentials":true'* ]]
}

@test "never prints a credential value" {
  audit
  [[ "$output" != *SECRET* ]]
  [[ "$output" != *sk-* ]]
  [[ "$output" != *ya29* ]]
  [[ "$output" != *Bearer* ]]
}
