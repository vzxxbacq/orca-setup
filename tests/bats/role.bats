#!/usr/bin/env bats
# orca/role.sh: pairing roles from saved environments and the runtime device registry.

load helpers

setup() {
  make_sandbox
  fake_orca
  NOW_MS=$(($(date +%s) * 1000))
  DAY_MS=$((24 * 3600 * 1000))
}

# devices <scope:days-ago:name>...: a device registry with fake secrets that must never be printed.
devices() {
  local entry scope days name out='' sep=''
  for entry in "$@"; do
    scope=${entry%%:*}; entry=${entry#*:}; days=${entry%%:*}; name=${entry#*:}
    out="$out$sep{\"deviceId\":\"DEVICE-ID-SECRET\",\"token\":\"TOKEN-SECRET-$name\",\"name\":\"$name\",\"scope\":\"$scope\",\"pairedAt\":1,\"lastSeenAt\":$((NOW_MS - days * DAY_MS))}"
    sep=,
  done
  printf '[%s]\n' "$out" >"$ORCA_USER_DATA_DIR/orca-devices.json"
}

environments() {
  local name out='' sep=''
  for name in "$@"; do out="$out$sep{\"id\":\"env-$name\",\"name\":\"$name\",\"pairingCode\":\"PAIRING-SECRET\"}"; sep=,; done
  printf '{"ok":true,"result":{"environments":[%s]}}\n' "$out" >"$ORCA_USER_DATA_DIR/cli-environments.json"
}

role() { run "$REAL_BASH" "$REPO_ROOT/orca/role.sh" "$@"; }

no_secrets() {
  [[ "$output" != *SECRET* ]]
}

@test "a fresh host has no role" {
  role
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'ROLE none' ]
}

@test "recent runtime clients make a server; mobile pairings do not count" {
  devices runtime:0:laptop runtime:2:desk mobile:0:phone
  role --expect server
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'ROLE server' ]
  [[ "$output" == *'runtime clients seen in the last 30 days: 2 (of 2)'* ]]
  [[ "$output" == *'mobile pairings: 1 (not counted)'* ]]
  [[ "$output" != *laptop* ]]
  no_secrets
}

@test "stale runtime clients are not a role" {
  devices runtime:90:old-laptop mobile:0:phone
  role --expect client
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'ROLE none' ]
}

@test "saved environments make a client" {
  environments mini
  role --expect client
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'ROLE client' ]
  no_secrets
}

@test "a client that is also dialed is a dual role and names the pairings" {
  environments mini
  devices runtime:1:laptop
  role
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = 'ROLE dual' ]
  [[ "$output" == *'saved environment: mini'* ]]
  [[ "$output" == *'runtime client: laptop'* ]]
  no_secrets
}

@test "--expect server refuses saved environments" {
  environments mini
  role --expect server
  [ "$status" -eq 1 ]
  [[ "$output" == *'saved environment: mini'* ]]
  [[ "$output" == *'CONFLICT this host saves environments'* ]]
  no_secrets
}

@test "--expect client refuses recent runtime clients" {
  devices runtime:0:laptop
  role --expect client
  [ "$status" -eq 1 ]
  [[ "$output" == *'runtime client: laptop'* ]]
  [[ "$output" == *'CONFLICT this host accepts runtime clients'* ]]
  no_secrets
}

@test "falls back to the pairing store file when the CLI cannot answer" {
  fake_cmd orca 'exit 1'
  printf '{"version":1,"environments":[{"name":"mini","id":"x"}]}\n' >"$ORCA_USER_DATA_DIR/orca-environments.json"
  role
  [ "${lines[0]}" = 'ROLE client' ]
}

@test "usage errors exit 2" {
  role --expect both
  [ "$status" -eq 2 ]
  role --bogus
  [ "$status" -eq 2 ]
}
