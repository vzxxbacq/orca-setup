#!/usr/bin/env bats
# Linux (Ubuntu 24.04 / Debian 12, x86_64): --plan, --apply and --check against fake apt, sudo and gpg.
# Nothing here runs apt or sudo for real.

load helpers

GH_FPRS=2C6106201985B60E6C7AC87323F3D4EA75716059,7F38BBB59D064DBCB3D84D725612B36462313325

setup() {
  make_sandbox
  fake_linux
  fake_present git curl
}

snapshot() { # snapshot <name>: compare $output (sandbox paths shown as <sandbox>) with a fixture, or rewrite it
  local file=$BATS_TEST_DIRNAME/fixtures/$1 normalized=${output//$SB/<sandbox>}
  if [ -n "${UPDATE_SNAPSHOTS:-}" ]; then printf '%s\n' "$normalized" >"$file"; fi
  "$REAL_DIFF" -u "$file" <(printf '%s\n' "$normalized")
}

no_calls() { [ ! -s "$FAKE_LOG" ] || { cat "$FAKE_LOG"; return 1; }; }

# Everything but the apt packages and gh is present (Orca too, with its skills), so --apply only reaches the fakes.
apply_ready() {
  local name
  for name in npm pnpm python3.12 uv ruff codex claude dsh dsh-tui pi bun omp grok agy; do fake_present "$name"; done
  fake_orca_linux
  fake_library libgbm.so.1
  fake_library libasound.so.2
  fake_gpg
  # shellcheck disable=SC2016 # expanded by the stub
  fake_cmd curl 'out=""; prev=""; for a; do [ "$prev" = -o ] && out=$a; prev=$a; done; echo "FAKEKEY ${FAKE_KEY_FPRS//,/ }" >"$out"'
  export FAKE_KEY_FPRS=$GH_FPRS
}

# ------------------------------------------------------------------ detection and refusal

@test "--plan snapshot on a fresh Ubuntu 24.04" {
  run_setup --plan
  [ "$status" -eq 0 ]
  snapshot plan-linux.txt
  no_calls
}

@test "--plan lists every sudo command and nothing runs as root" {
  rm "$SB/bin/node" # a fresh device: Node.js comes from the NodeSource repository
  run_setup --plan --role server
  [ "$status" -eq 0 ]
  [[ "$output" == *'detected: unknown until Node.js is installed'* ]]
  [[ "$output" == *'sudo: present; --apply runs only the sudo commands listed below as root'* ]]
  # One apt-get update before the first package, one after each repository is added.
  [ "$(grep -c 'sudo env DEBIAN_FRONTEND=noninteractive apt-get update' <<<"$output")" -eq 3 ]
  [[ "$output" == *'sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libgbm1'* ]]
  [[ "$output" == *'sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates'* ]]
  [[ "$output" == *"sudo install -m 0644 <verified key> $SB/apt/keyrings/nodesource.gpg"* ]]
  [[ "$output" == *"deb [arch=amd64 signed-by=$SB/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"* ]]
  # Every root command is printed as "sudo ...", indented under the item that needs it.
  [ -z "$(grep 'sudo' <<<"$output" | grep -v -e '^           sudo ' -e '^sudo: present')" ]
  no_calls
}

@test "--plan with everything present lists no sudo command" {
  apply_ready
  local name
  for name in git-lfs gh rg jq tmux cmake pkg-config cc unzip; do fake_present "$name"; done
  echo ca-certificates >>"$FAKE_DPKG"
  run_setup --plan
  [ "$status" -eq 0 ]
  [ -z "$(grep -e '^ *sudo ' -e '^  install  ' <<<"$output")" ]
  [[ "$output" == *'present  orca'* ]]
  [[ "$output" == *'present  skills orca-cli orca-linear computer-use'* ]]
  no_calls
}

@test "Debian 12 is supported" {
  fake_os_release debian 12
  run_setup --plan
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'Device: debian 12 x86_64, package manager: apt, desktop: no, Orca CLI: orca-ide' ]
}

@test "Linux arm64 is refused by --plan, --apply and --check" {
  fake_uname Linux aarch64
  local mode
  for mode in --plan '--apply --role server' --check; do
    # shellcheck disable=SC2086 # mode holds several words
    run_setup $mode
    [ "$status" -eq 1 ]
    [[ "$output" == *'Linux on arm64 is not supported: x86_64 only (no arm64).'* ]]
  done
  no_calls
}

@test "other distributions and releases are refused" {
  fake_os_release fedora 41
  run_setup --plan
  [ "$status" -eq 1 ]
  [[ "$output" == *'fedora 41 is not supported: only Ubuntu 24.04 and Debian 12 (x86_64).'* ]]
  fake_os_release ubuntu 22.04 debian
  run_setup --apply --role server
  [ "$status" -eq 1 ]
  [[ "$output" == *'ubuntu 22.04 is not supported'* ]]
  no_calls
}

@test "--apply needs sudo on Linux" {
  rm "$SB/bin/sudo"
  run_setup --apply --role server
  [ "$status" -eq 1 ]
  [[ "$output" == *'sudo is required for the apt steps'* ]]
  no_calls
}

@test "--auth-agy and --auth-linear wait for P3 on Linux" {
  run_setup --auth-agy
  [ "$status" -eq 1 ]
  [[ "$output" == *'--auth-agy on Linux arrives in P3'* ]]
  run_setup --auth-gh --auth-linear
  [ "$status" -eq 1 ]
  no_calls
}

# ------------------------------------------------------------------ apply

@test "--apply installs apt packages first, verifies the gh key, then a second run changes nothing" {
  apply_ready
  run_setup --apply --role client
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'PRESENT orca'* ]]
  [[ "$output" == *'SKIP Orca settings: no Orca runtime runs on this client'* ]]
  [[ "$output" == *'ROLE none'* ]]
  [ "${lines[${#lines[@]} - 1]}" = BASELINE_DONE ]
  # Root commands, in order: apt packages (one update first), then the gh repository and gh.
  run cat "$FAKE_LOG"
  [ "${lines[0]}" = 'sudo env DEBIAN_FRONTEND=noninteractive apt-get update' ]
  [ "${lines[1]}" = 'sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git-lfs' ]
  [ "$(grep -n 'apt-get install.* ca-certificates$' "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n 'keyrings$' "$FAKE_LOG" | cut -d: -f1)" ]
  [[ "$output" == *"sudo install -m 0644 "*"/key $SB/apt/keyrings/githubcli-archive-keyring.gpg"* ]]
  [[ "$output" == *"sudo install -m 0644 "*"/source.list $SB/apt/sources.list.d/github-cli.list"* ]]
  [ "${lines[${#lines[@]} - 1]}" = 'sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh' ]
  [ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.profile")" -eq 1 ]
  [ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.zshrc")" -eq 1 ]

  : >"$FAKE_LOG"
  run_setup --apply --role client
  [ "$status" -eq 0 ]
  no_calls
  # Only PRESENT items, deferred items and the role report: no step ("+ ...") at all.
  [ -z "$(grep -v -e '^PRESENT ' -e '^SKIP ' -e '^ROLE ' -e '^saved environments: ' -e '^runtime clients ' \
    -e '^mobile pairings: ' -e '^BASELINE_DONE$' <<<"$output")" ] || { echo "$output"; return 1; }
  [ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.profile")" -eq 1 ]
}

@test "--apply refuses a gh key whose fingerprint is not in the manifest, before trusting it" {
  apply_ready
  for name in git-lfs rg jq tmux cmake pkg-config cc unzip; do fake_present "$name"; done
  echo ca-certificates >>"$FAKE_DPKG"
  export FAKE_KEY_FPRS=2C6106201985B60E6C7AC87323F3D4EA75716059,0000000000000000000000000000000000000000
  run_setup --apply --role client
  [ "$status" -eq 1 ]
  [[ "$output" == *'unexpected signing key 0000000000000000000000000000000000000000'* ]]
  [[ "$output" == *'the gh signing key does not match manifest/apt-repos.tsv'* ]]
  no_calls
}

@test "--apply runs the role check after the baseline and refuses the other role" {
  apply_ready
  for name in git-lfs gh rg jq tmux cmake pkg-config cc unzip; do fake_present "$name"; done
  echo ca-certificates >>"$FAKE_DPKG"
  printf '{"environments":[{"name":"control"}]}\n' >"$ORCA_USER_DATA/orca-environments.json"
  run_setup --apply --role server --pairing-address 203.0.113.10
  [ "$status" -eq 1 ]
  [[ "$output" == *'PRESENT git'* ]]
  [[ "$output" == *'already holds the other pairing role'* ]]
  [[ "$output" != *BASELINE_DONE* ]]
}

# ------------------------------------------------------------------ check

@test "--check on a Linux client does not count the runtime and reports the PATH block" {
  apply_ready
  for name in git-lfs gh rg jq tmux cmake pkg-config cc unzip; do fake_present "$name"; done
  echo ca-certificates >>"$FAKE_DPKG"
  fake_cmd gh 'exit 1' # not logged in
  run_setup --check
  [[ "$output" == *'PRESENT orca CLI (orca-ide)'* ]]
  [[ "$output" == *'Orca runtime: not running (client; not counted)'* ]]
  [[ "$output" == *'Orca skills: installed'* ]]
  [[ "$output" != *'Orca serve unit'* ]]
  [[ "$output" == *'MISSING PATH block in ~/.profile'* ]]
  [[ "$output" == *'GitHub auth: PENDING'* ]]
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  printf '\n# >>> orca-setup PATH >>>\n' >"$HOME/.profile"
  printf '# >>> orca-setup PATH >>>\n' >"$HOME/.zshrc"
  run_setup --check
  [ "$status" -eq 1 ]
  [[ "$output" == *'MISSING_ITEMS 1'* ]]
}

@test "a missing check command falls back to dpkg; a - check uses dpkg only" {
  . "$REPO_ROOT/lib/common.sh"
  . "$REPO_ROOT/lib/pkg-debian.sh"
  run ! debian_installed apt:ca-certificates
  echo ca-certificates >>"$FAKE_DPKG"
  debian_installed apt:ca-certificates
  debian_installed apt-repo:nodesource:ca-certificates
  run ! debian_installed npm:ca-certificates
}

# ------------------------------------------------------------------ fingerprints

@test "key_matches accepts only keys made of expected primary keys" {
  . "$REPO_ROOT/lib/common.sh"
  . "$REPO_ROOT/lib/pkg-debian.sh"
  fake_gpg
  echo "FAKEKEY 2C6106201985B60E6C7AC87323F3D4EA75716059" >"$SB/one"
  echo "FAKEKEY 2C6106201985B60E6C7AC87323F3D4EA75716059 7F38BBB59D064DBCB3D84D725612B36462313325" >"$SB/both"
  echo "FAKEKEY 2C6106201985B60E6C7AC87323F3D4EA75716059 1111111111111111111111111111111111111111" >"$SB/extra"
  echo "FAKEKEY" >"$SB/empty"
  echo "garbage" >"$SB/garbage"
  [ "$(key_fingerprints "$SB/both")" = "$(printf '%s\n' 2C6106201985B60E6C7AC87323F3D4EA75716059 7F38BBB59D064DBCB3D84D725612B36462313325)" ]
  key_matches "$SB/one" "$GH_FPRS"
  key_matches "$SB/both" "$GH_FPRS"
  run ! key_matches "$SB/extra" "$GH_FPRS"
  run ! key_matches "$SB/empty" "$GH_FPRS"
  run ! key_matches "$SB/garbage" "$GH_FPRS"
  run ! key_matches "$SB/one" 7F38BBB59D064DBCB3D84D725612B36462313325
}

@test "key_matches with real gpg and a generated key" {
  local real_path=/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin real_gpg home fpr status=0
  real_gpg=$(PATH=$real_path command -v gpg) || skip 'gpg is not installed'
  fake_cmd gpg "exec '$real_gpg' \"\$@\""
  . "$REPO_ROOT/lib/common.sh"
  . "$REPO_ROOT/lib/pkg-debian.sh"
  # Key generation needs gpg-agent from the real PATH and a short socket path.
  home=$(mktemp -d /tmp/orca-setup-gpg.XXXXXX)
  {
    PATH=$real_path GNUPGHOME=$home gpg --batch --quiet --passphrase '' \
      --quick-gen-key 'orca-setup test <test@example.invalid>' ed25519 sign never &&
      PATH=$real_path GNUPGHOME=$home gpg --batch --armor --export >"$SB/test.asc" &&
      fpr=$(PATH=$real_path GNUPGHOME=$home gpg --batch --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')
  } || status=$?
  PATH=$real_path GNUPGHOME=$home gpgconf --kill gpg-agent 2>/dev/null || true
  rm -rf -- "$home"
  [ "$status" -eq 0 ]
  [ "$(key_fingerprints "$SB/test.asc")" = "$fpr" ]
  key_matches "$SB/test.asc" "AAAA,$fpr"
  run ! key_matches "$SB/test.asc" "$GH_FPRS"
}

# ------------------------------------------------------------------ PATH block

@test "the PATH block is added once and keeps the rest of the file" {
  . "$REPO_ROOT/lib/common.sh"
  printf 'export EDITOR=vi\n' >"$HOME/.profile"
  path_block_add "$HOME/.profile"
  path_block_add "$HOME/.profile"
  path_block_add "$HOME/.zshrc"
  [ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.profile")" -eq 1 ]
  [ "$(grep -c '^# <<< orca-setup PATH <<<$' "$HOME/.profile")" -eq 1 ]
  [ "$(head -n 1 "$HOME/.profile")" = 'export EDITOR=vi' ]
  [ -f "$HOME/.zshrc" ]
  # The block is idempotent when sourced repeatedly and puts the user tool directories first exactly once.
  run env -i HOME="$HOME" PATH=/usr/bin:/bin "$REAL_BASH" -c '. "$HOME/.profile"; . "$HOME/.profile"; printf "%s" "$PATH"'
  [ "$output" = "$HOME/.local/bin:$HOME/.grok/bin:/usr/bin:/bin" ]
}
