#!/usr/bin/env bats
# Orca on Linux (P2): the .deb install, the pairing address and the Linux client, against fake curl, sudo and Orca.
# Nothing here runs apt or sudo. The Linux server runs in Docker and has its own tests (server-docker.bats).

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
  . "$REPO_ROOT/lib/orca-server.sh"
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

# ------------------------------------------------------------------ plan

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

@test "--apply --role client installs no unit and asks for no linger" {
  ready
  run_setup --apply --role client
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  no_secret
  no_calls
  [ ! -e "$HOME/.config/orca-setup/docker/compose.yaml" ]
  [[ "$output" == *'SKIP Orca settings: no Orca runtime runs on this client'* ]]
  [[ "$output" != *orca-serve* ]]
}

