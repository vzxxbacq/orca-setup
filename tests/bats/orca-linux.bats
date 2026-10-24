#!/usr/bin/env bats
# Orca on Linux (P2): the .deb install, the pairing address, the systemd user unit, and client versus server
# behaviour, against fake curl, sudo, systemctl, loginctl and Orca. Nothing here runs apt, sudo or systemd.

load helpers

ADDRESS=203.0.113.10 # documentation range (RFC 5737)

setup() {
  make_sandbox
  fake_linux
}

no_calls() { [ ! -s "$FAKE_LOG" ] || { cat "$FAKE_LOG"; return 1; }; }

snapshot() { # snapshot <name>: compare $output (sandbox paths shown as <sandbox>) with a fixture, or rewrite it
  local file=$BATS_TEST_DIRNAME/fixtures/$1 normalized=${output//$SB/<sandbox>}
  if [ -n "${UPDATE_SNAPSHOTS:-}" ]; then printf '%s\n' "$normalized" >"$file"; fi
  "$REAL_DIFF" -u "$file" <(printf '%s\n' "$normalized")
}

# No output may carry a pairing URL or code; the fake CLI puts one into every status reply.
no_secret() {
  [[ "$output" != *FAKE-PAIRING-SECRET* ]] && [[ "$output" != *'orca://pair'* ]] || { echo "$output"; return 1; }
}

# Every baseline tool, agent and Orca itself is present, with its skills, and the PATH block is in place.
ready() {
  fake_baseline_present
  fake_orca_linux
  echo ca-certificates >>"$FAKE_DPKG"
  printf '# >>> orca-setup PATH >>>\n' >"$HOME/.profile"
  printf '# >>> orca-setup PATH >>>\n' >"$HOME/.zshrc"
}

unit_file() { printf '%s\n' "$HOME/.config/systemd/user/orca-serve.service"; }

# ------------------------------------------------------------------ the .deb

# fake_release <prerelease> <asset name> <digest|null> [url]: the GitHub API answer, plus a package whose bytes
# double as its control fields for the fake dpkg-deb.
fake_release() {
  local url=${4:-https://github.com/stablyai/orca/releases/download/v1.2.3/$2} digest=$3
  printf 'Package: %s\nArchitecture: amd64\n' "${FAKE_PACKAGE:-orca-ide}" >"$SB/payload.deb"
  [ "$digest" != auto ] || digest="\"sha256:$("$REAL_NODE" -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$SB/payload.deb")\""
  printf '{"tag_name":"v1.2.3","draft":false,"prerelease":%s,"assets":[{"name":"%s","digest":%s,"browser_download_url":"%s"},{"name":"orca-ide_1.2.3_arm64.deb","digest":null,"browser_download_url":"x"}]}\n' \
    "$1" "$2" "$digest" "$url" >"$SB/release.json"
  # shellcheck disable=SC2016 # the stub bodies expand when the stubs run
  fake_cmd curl 'out=""; prev=""; for a; do [ "$prev" = -o ] && out=$a; prev=$a; done
case "$*" in *api.github.com/repos/stablyai/orca/releases/latest*) cp "$SB/release.json" "$out" ;; *) cp "$SB/payload.deb" "$out" ;; esac'
  # shellcheck disable=SC2016
  fake_cmd sha256sum 'read -r want file; have=$("'"$REAL_NODE"'" -e "process.stdout.write(require(\"crypto\").createHash(\"sha256\").update(require(\"fs\").readFileSync(process.argv[1])).digest(\"hex\"))" "$file"); [ "$have" = "$want" ]'
  # shellcheck disable=SC2016
  fake_cmd dpkg-deb '[ "$1" = -f ] && sed -n "s/^$3: //p" "$2"'
}

deb_install() {
  . "$REPO_ROOT/lib/common.sh"
  . "$REPO_ROOT/lib/pkg-debian.sh"
  run github_deb_install stablyai/orca orca-ide
}

@test "the .deb is installed only after its digest and control fields check out" {
  fake_release false orca-ide_1.2.3_amd64.deb auto
  deb_install
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'stablyai/orca v1.2.3: orca-ide_1.2.3_amd64.deb'* ]]
  [[ "$output" == *'verified orca-ide_1.2.3_amd64.deb (sha256 '* ]]
  run cat "$FAKE_LOG"
  [ "${lines[0]}" = 'sudo env DEBIAN_FRONTEND=noninteractive apt-get update' ]
  [[ "${lines[1]}" == 'sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends '*/orca-ide_1.2.3_amd64.deb ]]
}

@test "a .deb that does not match its digest is refused before apt sees it" {
  fake_release false orca-ide_1.2.3_amd64.deb '"sha256:0000000000000000000000000000000000000000000000000000000000000000"'
  deb_install
  [ "$status" -eq 1 ]
  [[ "$output" == *'does not match the sha256 digest GitHub records'* ]]
  no_calls
}

@test "a release without a digest, a prerelease or a foreign URL is refused" {
  fake_release false orca-ide_1.2.3_amd64.deb null
  deb_install
  [ "$status" -eq 1 ]
  [[ "$output" == *'GitHub records no sha256 digest'* ]]
  fake_release true orca-ide_1.2.3_amd64.deb auto
  deb_install
  [ "$status" -eq 1 ]
  [[ "$output" == *'has no single orca-ide_<version>_amd64.deb'* ]]
  fake_release false orca-ide_1.2.3_amd64.deb auto https://example.com/orca-ide_1.2.3_amd64.deb
  deb_install
  [ "$status" -eq 1 ]
  [[ "$output" == *'unexpected download URL'* ]]
  fake_release false orca-ide-nightly_1.2.3_amd64.deb auto
  deb_install
  [ "$status" -eq 1 ]
  no_calls
}

@test "a .deb whose control fields name another package is refused" {
  FAKE_PACKAGE=something-else fake_release false orca-ide_1.2.3_amd64.deb auto
  deb_install
  [ "$status" -eq 1 ]
  [[ "$output" == *'is not the orca-ide package for amd64'* ]]
  no_calls
}

# ------------------------------------------------------------------ pairing address

@test "pairing addresses: private IPv4 and host names pass; loopback, wildcards and junk are refused" {
  . "$REPO_ROOT/lib/common.sh"
  . "$REPO_ROOT/lib/orca-serve.sh"
  local address
  for address in "$ADDRESS" 198.51.100.7 devbox devbox.example.net devbox.tailnet-name.ts.net.; do
    [ -z "$(pairing_address_problem "$address")" ] || { echo "refused: $address"; return 1; }
  done
  for address in '' 127.0.0.1 127.0.0.2 127.1.2.3 0.0.0.0 0.1.2.3 255.255.255.255 '*' :: '[::]' ::1 localhost \
    devbox.localhost 256.1.1.1 1.2.3.4.5 'a b' http://devbox devbox:6768 -devbox 'devbox;id' '$(id)' ws://x; do
    [ -n "$(pairing_address_problem "$address")" ] || { echo "accepted: $address"; return 1; }
  done
  [[ "$(pairing_address_problem 127.0.0.1)" == *loopback* ]]
  [[ "$(pairing_address_problem 0.0.0.0)" == *wildcard* ]]
  # The test-only override allows 127.0.0.2 and friends, never 127.0.0.1.
  export ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS=1
  [ -z "$(pairing_address_problem 127.0.0.2)" ]
  [ -n "$(pairing_address_problem 127.0.0.1)" ]
  [ -n "$(pairing_address_problem 0.0.0.0)" ]
}

@test "setup.sh validates --pairing-address before doing anything" {
  ready
  run_setup --apply --role server
  [ "$status" -eq 1 ]
  [[ "$output" == *'--apply --role server on Linux requires --pairing-address'* ]]
  run_setup --plan --role server --pairing-address 127.0.0.1
  [ "$status" -eq 1 ]
  [[ "$output" == *'--pairing-address 127.0.0.1 is refused: it is a loopback address'* ]]
  run_setup --apply --role server --pairing-address=0.0.0.0
  [ "$status" -eq 1 ]
  run_setup --apply --role client --pairing-address "$ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'--pairing-address is for --role server'* ]]
  fake_uname Darwin arm64
  run_setup --plan --pairing-address "$ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'--pairing-address is for Linux servers'* ]]
  no_calls
}

# ------------------------------------------------------------------ unit

@test "the unit renders the supervised server, the address and the optional terminal limits" {
  . "$REPO_ROOT/lib/common.sh"
  cp -R "$REPO_ROOT/manifest" "$SB/manifest"
  export ORCA_SETUP_MANIFEST_DIR=$SB/manifest
  . "$REPO_ROOT/lib/orca-serve.sh"
  run serve_unit_render /usr/bin/orca-ide "$ADDRESS"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '# orca-setup: Orca server for this user' ]
  [[ "$output" == *"ExecStart=/usr/bin/orca-ide serve --supervise --no-pairing --port 6768 --pairing-address $ADDRESS"* ]]
  [[ "$output" == *'Environment=PATH=%h/.local/bin:%h/.grok/bin:'* ]]
  [[ "$output" == *'KillMode=process'* ]]
  [[ "$output" != *'@'* ]]
  [[ "$output" != *'Environment=ORCA_'* ]]
  mkdir -p "$SB/manifest/local"
  printf '# limits\nORCA_TERMINAL_MEMORY_MAX=8G\nORCA_TERMINAL_MEMORY_SWAP_MAX=0\nORCA_TERMINAL_MEMORY_MAX=16G\n' >"$SB/manifest/local/orca-serve.env"
  run serve_unit_render /usr/bin/orca-ide "$ADDRESS"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^Environment=ORCA_' <<<"$output")" -eq 2 ]
  [[ "$output" == *$'Environment=ORCA_TERMINAL_MEMORY_MAX=16G\nEnvironment=ORCA_TERMINAL_MEMORY_SWAP_MAX=0\nRestart=on-failure'* ]]
  printf 'ORCA_TERMINAL_PROCESS_CEILING=8\n' >"$SB/manifest/local/orca-serve.env"
  run serve_unit_render /usr/bin/orca-ide "$ADDRESS"
  [ "$status" -ne 0 ]
  [[ "$output" == *'must be a number, 64 or more'* ]]
  printf 'LD_PRELOAD=/tmp/x.so\n' >"$SB/manifest/local/orca-serve.env"
  run serve_unit_render /usr/bin/orca-ide "$ADDRESS"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unknown key LD_PRELOAD'* ]]
}

@test "the unit starts the .deb CLI, not a shim a running server puts on PATH" {
  . "$REPO_ROOT/lib/common.sh"
  . "$REPO_ROOT/lib/orca-serve.sh"
  ORCA_CLI=orca-ide
  fake_present orca-ide
  [ "$(serve_command)" = "$SB/bin/orca-ide" ]
  mkdir -p "$SB/usr/bin"
  printf '#!/bin/sh\n' >"$SB/usr/bin/orca-ide"
  chmod +x "$SB/usr/bin/orca-ide"
  export ORCA_SETUP_DEB_CLI=$SB/usr/bin/orca-ide
  [ "$(serve_command)" = "$SB/usr/bin/orca-ide" ]
}

@test "the rendered unit passes systemd-analyze verify" {
  local real
  real=$(PATH=/usr/bin:/bin command -v systemd-analyze) || skip 'systemd-analyze is not installed'
  . "$REPO_ROOT/lib/common.sh"
  . "$REPO_ROOT/lib/orca-serve.sh"
  fake_present orca-ide
  serve_unit_render "$SB/bin/orca-ide" "$ADDRESS" >"$SB/orca-serve.service"
  run env PATH=/usr/bin:/bin "$real" verify --man=no "$SB/orca-serve.service"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ------------------------------------------------------------------ plan

@test "--plan --role server lists the .deb, linger with its sudo command, and the unit" {
  fake_baseline_present
  rm -f "$SB/bin/orca-ide"
  echo ca-certificates >>"$FAKE_DPKG"
  # Orca is not installed yet, so the unit names the CLI the .deb will put there.
  [ ! -e /usr/bin/orca-ide ] || skip 'this machine has /usr/bin/orca-ide'
  export ORCA_SETUP_DEB_CLI=/usr/bin/orca-ide
  run_setup --plan --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ]
  snapshot plan-linux-server.txt
  no_secret
  no_calls
}

@test "--plan --role client shows no unit, no linger and no sudo outside the .deb" {
  ready
  run_setup --plan --role client
  [ "$status" -eq 0 ]
  [[ "$output" == *'Orca client: Orca and its CLI only; no server unit and no pairing offer on this device'* ]]
  [[ "$output" != *linger* ]]
  [[ "$output" != *'orca-serve.service'* ]]
  [ -z "$(grep '^ *sudo ' <<<"$output")" ]
  no_secret
  no_calls
}

# ------------------------------------------------------------------ apply and check

@test "--apply --role server enables linger, writes and starts the unit, then a second run changes nothing" {
  ready
  run_setup --apply --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  no_secret
  [ "${lines[${#lines[@]} - 1]}" = BASELINE_DONE ]
  run cat "$FAKE_LOG"
  [ "$output" = "sudo loginctl enable-linger builder
systemctl --user daemon-reload
systemctl --user enable orca-serve.service
systemctl --user start orca-serve.service" ]
  grep -qxF "ExecStart=$SB/bin/orca-ide serve --supervise --no-pairing --port 6768 --pairing-address $ADDRESS" "$(unit_file)"
  [ "$(cat "$SB/orca-settings.json")" = '{"defaultTuiAgent":"codex","agentStatusHooksEnabled":true}' ]

  : >"$FAKE_LOG"
  run_setup --apply --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ]
  no_calls
  no_secret
  [ -z "$(grep -e '^+ ' <<<"$output")" ] || { echo "$output"; return 1; }
  [[ "$output" == *'PRESENT linger for builder'* ]]
  [[ "$output" == *'PRESENT orca-serve.service active'* ]]
  [[ "$output" == *'PRESENT Orca settings'* ]]

  # A new address rewrites the unit and restarts the running server.
  run_setup --apply --role server --pairing-address 198.51.100.7
  [ "$status" -eq 0 ]
  grep -q -- '--pairing-address 198.51.100.7$' "$(unit_file)"
  run cat "$FAKE_LOG"
  [ "$output" = "systemctl --user daemon-reload
systemctl --user restart orca-serve.service" ]
}

@test "--apply --role server keeps a unit that orca-setup did not write" {
  ready
  mkdir -p "$(dirname "$(unit_file)")"
  printf '[Service]\nExecStart=/usr/bin/orca-ide serve --supervise --no-pairing\n' >"$(unit_file)"
  echo yes >"$SB/linger"
  run_setup --apply --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'PRESENT orca-serve.service (not written by orca-setup; left unchanged)'* ]]
  [ "$(head -n 1 "$(unit_file)")" = '[Service]' ]
}

@test "--apply --role server stops when the runtime never becomes reachable" {
  ready
  # shellcheck disable=SC2016
  fake_cmd systemctl '[ "$2" = is-enabled ] || [ "$2" = is-active ] && exit 3; echo "systemctl $*" >>"$FAKE_LOG"'
  export ORCA_SETUP_SERVE_WAIT=0
  run_setup --apply --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'the Orca runtime is not reachable 0s after starting orca-serve.service'* ]]
  [[ "$output" != *BASELINE_DONE* ]]
}

@test "--apply --role client installs no unit and asks for no linger" {
  ready
  run_setup --apply --role client
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  no_secret
  no_calls
  [ ! -e "$(unit_file)" ]
  [[ "$output" == *'SKIP Orca settings: no Orca runtime runs on this client'* ]]
  [[ "$output" != *orca-serve* ]]
}

@test "--check on a server counts the unit, linger and the runtime, and prints no secret" {
  ready
  run_setup --apply --role server --pairing-address "$ADDRESS"
  [ "$status" -eq 0 ]
  run_setup --check --role server
  no_secret
  [[ "$output" == *'Orca serve unit: active'* ]]
  [[ "$output" == *'Linger: on'* ]]
  [[ "$output" == *'Orca runtime: reachable'* ]]
  [[ "$output" == *'Orca skills: installed'* ]]
  [[ "$output" == *'Orca settings: aligned'* ]]
  [[ "$output" == *'Orca Codex: PENDING'* ]]
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  # Without --role the unit file marks the device as a server.
  run_setup --check
  [ "$status" -eq 1 ]
  [[ "$output" == *'Orca serve unit: active'* ]]

  rm "$SB/runtime-up"
  echo no >"$SB/linger"
  run_setup --check --role server
  no_secret
  [[ "$output" == *'Orca serve unit: INACTIVE (inactive)'* ]]
  [[ "$output" == *'Linger: OFF'* ]]
  [[ "$output" == *'Orca runtime: UNREACHABLE'* ]]
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
}

@test "--check --role server before --apply reports the missing unit" {
  ready
  run_setup --check --role server
  [[ "$output" == *'Orca serve unit: MISSING (run --apply --role server)'* ]]
  [[ "$output" == *'Linger: OFF'* ]]
  [[ "$output" == *'Orca runtime: UNREACHABLE'* ]]
  [ "$status" -eq 3 ]
  no_calls
}
