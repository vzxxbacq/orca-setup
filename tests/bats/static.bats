#!/usr/bin/env bats
# Static checks: shellcheck on every shell script, node --check on every CommonJS file.

load helpers

@test "shellcheck is clean" {
  command -v shellcheck >/dev/null || skip 'shellcheck is not installed'
  cd "$REPO_ROOT"
  run bash -c "git ls-files -co --exclude-standard '*.sh' '*.bash' | xargs shellcheck -x"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "node --check is clean" {
  command -v node >/dev/null || skip 'node is not installed'
  cd "$REPO_ROOT"
  local file
  for file in $(git ls-files -co --exclude-standard '*.cjs'); do
    node --check "$file"
  done
}

@test "tracked files carry no private hosts, addresses or personal paths" {
  cd "$REPO_ROOT"
  run bash -c "git ls-files -co --exclude-standard | grep -v '^tests/bats/static.bats$' | xargs grep -nIE '/Users/[a-z]|/home/[a-z]+/|\\b(10\\.[0-9]+|192\\.168|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]))\\.[0-9]+\\.[0-9]+\\b|[A-Za-z0-9-]\\.local\\b|@gmail\\.com' || true"
  [ -z "$output" ] || { echo "$output"; return 1; }
}
