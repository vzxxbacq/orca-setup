#!/usr/bin/env bats
# remote/provision.sh against a fake Orca CLI that plays the control machine's pairing store and one paired server.
# The fake server's terminal runs each command for real, in a git checkout cloned from a local bare repository that
# stands in for the public GitHub repository (git's url.<base>.insteadOf), and whose setup.sh is a stub.

load helpers

URL=https://github.com/vzxxbacq/orca-setup

setup() {
  local util ln links=()
  ln=$(command -v ln)
  for util in git sh; do links+=("$(command -v "$util")"); done
  make_sandbox
  for util in "${links[@]}"; do "$ln" -sf "$util" "$SB/bin/${util##*/}"; done
  export R=$SB/remote ORCA_SETUP_REMOTE_POLL=0 ORCA_SETUP_REMOTE_TIMEOUT=30
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  mkdir -p "$R" "$SB/device"
  # This machine saved one environment: the client role.
  printf '{"ok":true,"result":{"environments":[{"name":"lab"}]}}\n' >"$ORCA_USER_DATA/cli-environments.json"
  printf 'lab env-0001\n' >"$R/environments"
  touch "$R/reachable"
  upstream
  git config --global "url.$SB/upstream.git.insteadOf" "$URL"
  fake_remote_orca
  check_report 2 'GitHub auth' PENDING 'Orca Codex' PENDING
  echo 2 >"$R/check-status"
}

teardown() {
  # No output may carry the pairing secret the fake environment and status replies hold.
  [[ "${output:-}" != *FAKE-PAIRING-SECRET* ]] && [[ "${output:-}" != *'orca://pair'* ]] || { echo "$output"; return 1; }
}

# upstream: the stand-in for the public repository, holding a stub setup.sh that logs its arguments.
upstream() {
  local work=$SB/upstream-work
  mkdir -p "$work"
  cat >"$work/setup.sh" <<SH
#!$REAL_BASH
echo "setup.sh \$*" >>"$R/setup-calls"
case " \$* " in
  *" --check "*) cat "$R/check.json"; exit "\$(cat "$R/check-status")" ;;
  *" --apply "*)
    echo '+ sudo env DEBIAN_FRONTEND=noninteractive apt-get update'
    [ ! -e "$R/ask-sudo" ] || printf '[sudo] password for builder: \n'
    echo BASELINE_DONE
    exit "\$(cat "$R/apply-status" 2>/dev/null || echo 0)" ;;
  *) echo 'orca-setup plan (read-only; nothing is changed)' ;;
esac
SH
  chmod +x "$work/setup.sh"
  git -C "$work" init -q -b main
  git -C "$work" add setup.sh
  git -C "$work" commit -q -m 'stub setup.sh'
  git clone -q --bare "$work" "$SB/upstream.git"
}

# upstream_commit: one more commit upstream (an existing checkout falls behind).
upstream_commit() {
  echo "change $RANDOM" >>"$SB/upstream-work/NOTES"
  git -C "$SB/upstream-work" add NOTES
  git -C "$SB/upstream-work" commit -q -m 'upstream change'
  git -C "$SB/upstream-work" push -q "$SB/upstream.git" main
}

# existing_checkout [url]: a checkout on the device that Orca already knows as a project setup.
existing_checkout() {
  git clone -q "$URL" "$SB/device/orca-setup"
  [ -z "${1:-}" ] || git -C "$SB/device/orca-setup" remote set-url origin "$1"
  printf '{"ok":true,"result":{"setups":[{"id":"s1","projectId":"github:vzxxbacq/orca-setup","hostId":"runtime:env-0001","path":"%s","setupState":"ready"}]}}\n' \
    "$SB/device/orca-setup" >"$R/setups.json"
}

# check_report <missing> [<label> <state>]...: the device's --check --json answer, with the given counted items.
check_report() {
  local missing=$1 items='' sep=''
  shift
  while [ $# -ge 2 ]; do items="$items$sep{\"name\": \"$1\", \"state\": \"$2\", \"counted\": true}"; sep=','; shift 2; done
  cat >"$R/check.json" <<JSON
{
  "schema": "orca-setup-check/1",
  "missing": $missing,
  "items": [
    {"name": "git", "state": "present", "counted": false}${items:+,}
    $items
  ],
  "auth": [
    {"name": "gh", "state": "pending", "counted": true},
    {"name": "codex", "state": "pending", "counted": true},
    {"name": "claude", "state": "not-selected", "counted": false}
  ],
  "versions": {"orca": "1.2.3"},
  "audit": {"environment": {"OPENAI_API_KEY": true}}
}
JSON
}

fake_remote_orca() {
  # shellcheck disable=SC2016 # the stub body expands when the stub runs
  fake_cmd orca '
flag() { local want=$1 prev=""; shift; for a; do [ "$prev" = "--$want" ] && { printf "%s" "$a"; return 0; }; prev=$a; done; return 1; }
echo "orca $*" >>"$R/calls"
case "$1 $2" in
  "environment list") cat "$ORCA_USER_DATA/cli-environments.json" ;;
  "environment show")
    id=$(awk -v n="$(flag environment "$@")" "\$1 == n { print \$2 }" "$R/environments")
    [ -n "$id" ] || { echo "{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"Unknown environment\"}}"; exit 1; }
    echo "{\"ok\":true,\"result\":{\"environment\":{\"id\":\"$id\",\"name\":\"lab\",\"pairing\":\"orca://pair?code=FAKE-PAIRING-SECRET\"}}}" ;;
  "status --environment")
    [ -e "$R/reachable" ] || { echo "connect ECONNREFUSED" >&2; exit 1; }
    echo "{\"ok\":true,\"result\":{\"runtime\":{\"reachable\":true},\"pairing\":{\"url\":\"orca://pair?code=FAKE-PAIRING-SECRET\"}}}" ;;
  "project setups") cat "$R/setups.json" 2>/dev/null || echo "{\"ok\":true,\"result\":{\"setups\":[]}}" ;;
  "project setup-clone")
    dest=$(flag destination "$@")
    git clone -q "$(flag url "$@")" "$dest/orca-setup" >&2 || exit 1
    printf "{\"ok\":true,\"result\":{\"setups\":[{\"projectId\":\"%s\",\"path\":\"%s\"}]}}\n" "$(flag project "$@")" "$dest/orca-setup" >"$R/setups.json"
    printf "{\"ok\":true,\"result\":{\"project\":{\"id\":\"%s\"},\"setup\":{\"path\":\"%s\"},\"repo\":{\"id\":\"r1\"}}}\n" "$(flag project "$@")" "$dest/orca-setup" ;;
  "project setup-existing-folder")
    printf "{\"ok\":true,\"result\":{\"project\":{\"id\":\"%s\"},\"setup\":{\"path\":\"%s\"},\"repo\":{\"id\":\"r1\"}}}\n" "$(flag project "$@")" "$(flag path "$@")" ;;
  "terminal create")
    wt=$(flag worktree "$@")
    printf "%s\n" "${wt#path:}" >"$R/term-cwd"
    printf "builder@device:~$ \n" >"$R/term-out"
    echo "{\"ok\":true,\"result\":{\"terminal\":{\"handle\":\"term_fake1\"}}}" ;;
  "terminal send")
    text=$(flag text "$@")
    printf "builder@device:~$ %s\n" "$text" >>"$R/term-out"
    # A Linux server in Docker: the terminal runs inside its orca-server container.
    if [ -e "$R/docker-server" ]; then form=orca-server; else form=; fi
    (cd "$(cat "$R/term-cwd")" && ORCA_SETUP_CONTAINER=$form "'"$REAL_BASH"'" -c "$text") >>"$R/term-out" 2>&1 </dev/null
    echo "{\"ok\":true,\"result\":{}}" ;;
  "terminal read")
    cursor=$(flag cursor "$@") || cursor=0
    "'"$REAL_NODE"'" -e "
      const lines = require(\"fs\").readFileSync(process.argv[1], \"utf8\").split(\"\\n\"); lines.pop();
      const from = Number(process.argv[2]);
      console.log(JSON.stringify({ok: true, result: {terminal: {handle: \"term_fake1\", status: \"running\", tail: lines.slice(from).map(l => l + \"\\r\"), nextCursor: String(lines.length)}}}));
    " "$R/term-out" "$cursor" ;;
  *) echo "unexpected: orca $*" >&2; exit 1 ;;
esac'
}

provision() { run "$REAL_BASH" "$REPO_ROOT/remote/provision.sh" "$@"; }

# changed_device: any state-changing call reached the fake server.
changed_device() { grep -qE '^orca (project setup-clone|project setup-existing-folder)' "$R/calls" 2>/dev/null; }

@test "refuses on a host that is a server, before asking any server" {
  rm "$ORCA_USER_DATA/cli-environments.json"
  printf '[{"scope":"runtime","name":"laptop","lastSeenAt":%s000}]\n' "$(date +%s)" >"$ORCA_USER_DATA/orca-devices.json"
  provision --environment lab --apply --destination /srv
  [ "$status" -eq 100 ]
  [[ "$output" == *'REFUSED: this machine is an Orca server'* ]]
  [[ "$output" != *laptop* ]]
  run grep -vE '^orca environment list' "$R/calls"
  [ -z "$output" ]
}

@test "refuses on a host without saved environments and on a dual role" {
  rm "$ORCA_USER_DATA/cli-environments.json"
  provision --environment lab
  [ "$status" -eq 100 ]
  [[ "$output" == *'no saved environments; pair the device first'* ]]
  printf '{"ok":true,"result":{"environments":[{"name":"lab"}]}}\n' >"$ORCA_USER_DATA/cli-environments.json"
  printf '[{"scope":"runtime","name":"laptop","lastSeenAt":%s000}]\n' "$(date +%s)" >"$ORCA_USER_DATA/orca-devices.json"
  provision --environment lab
  [ "$status" -eq 100 ]
  [[ "$output" == *'holds both pairing roles'* ]]
}

@test "refuses an unknown or unreachable environment" {
  provision --environment nowhere
  [ "$status" -eq 100 ]
  [[ "$output" == *'no saved environment named nowhere'* ]]
  rm "$R/reachable"
  provision --environment lab
  [ "$status" -eq 100 ]
  [[ "$output" == *'the Orca server lab is not reachable'* ]]
  run grep -E '^orca (project|terminal)' "$R/calls"
  [ -z "$output" ]
}

@test "usage: --environment is required; --role client, --auth-* and relative paths are refused" {
  provision
  [ "$status" -eq 2 ]
  provision --environment lab --role client
  [ "$status" -eq 2 ]
  [[ "$output" == *'--role must be server'* ]]
  provision --environment lab --auth-gh
  [ "$status" -eq 2 ]
  [[ "$output" == *'never runs interactive logins'* ]]
  provision --environment lab --apply --destination srv
  [ "$status" -eq 2 ]
  provision --environment lab --pairing-address 127.0.0.1
  [ "$status" -eq 2 ]
  provision --environment lab --pairing-address devbox.example.net --publish-address devbox.example.net
  [ "$status" -eq 2 ]
  [[ "$output" == *'--publish-address devbox.example.net is refused: it is not an IPv4 address'* ]]
  provision --environment lab --bogus
  [ "$status" -eq 2 ]
}

@test "--plan without a checkout on the device shows the clone and changes nothing" {
  provision --environment lab
  [ "$status" -eq 0 ]
  [[ "$output" == *"project setup-clone --project github:vzxxbacq/orca-setup --host runtime:env-0001 --url $URL --destination <absolute parent directory on the device> --json"* ]]
  [[ "$output" == *'Nothing was changed.'* ]]
  if changed_device; then cat "$R/calls"; return 1; fi
  run grep -c '^orca terminal' "$R/calls"
  [ "$output" -eq 0 ]
}

@test "--plan (the default) runs only ./setup.sh --plan in an existing checkout" {
  existing_checkout
  provision --environment lab --pairing-address 203.0.113.10 --gpu
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checkout on lab: $SB/device/orca-setup (existing project setup)"* ]]
  [[ "$output" == *'Terminal on lab: "orca-setup provision" (handle term_fake1)'* ]]
  [[ "$output" == *'  | orca-setup plan (read-only; nothing is changed)'* ]]
  [[ "$output" == *'Plan only: nothing was installed.'* ]]
  run cat "$R/setup-calls"
  [ "$output" = 'setup.sh --plan --role server --pairing-address 203.0.113.10 --gpu' ]
  if changed_device; then cat "$R/calls"; return 1; fi
}

@test "an existing checkout of another repository is refused" {
  existing_checkout "$SB/elsewhere.git"
  provision --environment lab
  [ "$status" -eq 100 ]
  [[ "$output" == *"has origin $SB/elsewhere.git, not "* ]]
  [ ! -e "$R/setup-calls" ]
}

@test "local changes are never touched: --plan warns, --fast-forward refuses" {
  existing_checkout
  echo '# local edit' >>"$SB/device/orca-setup/setup.sh"
  upstream_commit
  provision --environment lab
  [ "$status" -eq 0 ]
  [[ "$output" == *'has local changes; provision.sh never touches them'* ]]
  provision --environment lab --apply --fast-forward
  [ "$status" -eq 100 ]
  [[ "$output" == *'--fast-forward refuses a checkout with local changes'* ]]
  grep -q 'local edit' "$SB/device/orca-setup/setup.sh"
  run grep -c -- --apply "$R/setup-calls"
  [ "$output" -eq 0 ]
}

@test "a checkout behind its upstream: --apply needs --fast-forward, which fast-forwards only" {
  existing_checkout
  upstream_commit
  provision --environment lab --apply
  [ "$status" -eq 100 ]
  [[ "$output" == *'1 commit(s) behind its upstream; rerun with --fast-forward'* ]]
  [ "$(git -C "$SB/device/orca-setup" rev-parse HEAD)" != "$(git -C "$SB/upstream.git" rev-parse main)" ]
  provision --environment lab --apply --fast-forward
  [ "$status" -eq 2 ]
  [[ "$output" == *'+ git merge --ff-only @{u} in '* ]]
  [ "$(git -C "$SB/device/orca-setup" rev-parse HEAD)" = "$(git -C "$SB/upstream.git" rev-parse main)" ]
}

@test "--apply clones, then runs --plan, --apply and --check --json, and exits with the device's missing count" {
  provision --environment lab --apply --pairing-address devbox.example.net --publish-address 203.0.113.10 \
    --destination "$SB/device" --gpu --task-source linear
  [ "$status" -eq 2 ]
  [[ "$output" == *"+ orca project setup-clone --project github:vzxxbacq/orca-setup --host runtime:env-0001 --url $URL --destination $SB/device --json"* ]]
  [ -x "$SB/device/orca-setup/setup.sh" ]
  run cat "$R/setup-calls"
  [ "${lines[0]}" = 'setup.sh --plan --role server --pairing-address devbox.example.net --publish-address 203.0.113.10 --gpu --task-source linear' ]
  [ "${lines[1]}" = 'setup.sh --apply --role server --pairing-address devbox.example.net --publish-address 203.0.113.10 --gpu --task-source linear' ]
  [ "${lines[2]}" = 'setup.sh --check --json --role server --gpu --task-source linear' ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "the summary lists the counted items and the pending logins, which are never run" {
  provision --environment lab --apply --destination "$SB/device"
  [ "$status" -eq 2 ]
  [[ "$output" == *'Device lab: 2 missing item(s)'* ]]
  [[ "$output" == *'  counted: GitHub auth: PENDING'* ]]
  [[ "$output" == *'  counted: Orca Codex: PENDING'* ]]
  [[ "$output" == *'  ./setup.sh --auth-gh   (counted)'* ]]
  [[ "$output" == *'  ./setup.sh --auth-codex   (counted)'* ]]
  [[ "$output" == *'  ./setup.sh --auth-claude   (optional)'* ]]
  run grep -c -- '--auth-' "$R/setup-calls"
  [ "$output" -eq 0 ]
}

@test "--apply without a checkout or --destination is refused before anything changes" {
  provision --environment lab --apply
  [ "$status" -eq 100 ]
  [[ "$output" == *'pass --destination <absolute parent directory on the device>'* ]]
  if changed_device; then cat "$R/calls"; return 1; fi
}

@test "--path registers an existing checkout with project setup-existing-folder" {
  git clone -q "$URL" "$SB/device/mine"
  provision --environment lab --apply --path "$SB/device/mine"
  [ "$status" -eq 2 ]
  [[ "$output" == *"+ orca project setup-existing-folder --project github:vzxxbacq/orca-setup --host runtime:env-0001 --path $SB/device/mine --kind git --json"* ]]
  [[ "$output" == *'Checkout state: origin '* ]]
}

@test "a sudo prompt on the device is handed to the user with the terminal to answer it in" {
  touch "$R/ask-sudo"
  provision --environment lab --apply --destination "$SB/device"
  [ "$status" -eq 2 ]
  [[ "$output" == *'  | [sudo] password for builder:'* ]]
  [[ "$output" == *'ACTION: sudo on lab is asking for a password. Answer it in the Orca terminal "orca-setup provision" (handle term_fake1)'* ]]
  [[ "$output" == *'never reads or sends passwords'* ]]
  run grep -E '^orca terminal send' "$R/calls"
  [[ "$output" != *password* ]]
}

@test "--check runs only the device's --check --json and exits with its missing count" {
  existing_checkout
  check_report 0
  echo 0 >"$R/check-status"
  provision --environment lab --check
  [ "$status" -eq 0 ]
  [[ "$output" == *'Device lab: 0 missing item(s)'* ]]
  run cat "$R/setup-calls"
  [ "$output" = 'setup.sh --check --json --role server' ]
  check_report 5 a MISSING b MISSING c MISSING d MISSING e MISSING
  echo 5 >"$R/check-status"
  provision --environment lab --check
  [ "$status" -eq 5 ]
}

@test "--check without a checkout on the device is refused" {
  provision --environment lab --check
  [ "$status" -eq 100 ]
  [[ "$output" == *'--check needs a checkout on lab; run --apply first.'* ]]
}

@test "a failing --apply on the device stops before the check" {
  echo 3 >"$R/apply-status"
  provision --environment lab --apply --destination "$SB/device"
  [ "$status" -eq 100 ]
  [[ "$output" == *'./setup.sh --apply failed on lab (exit status 3)'* ]]
  run grep -c -- --check "$R/setup-calls"
  [ "$output" -eq 0 ]
}

@test "a device whose setup.sh has no --check --json is reported, not guessed" {
  existing_checkout
  echo 'MISSING_ITEMS 4' >"$R/check.json"
  echo 4 >"$R/check-status"
  provision --environment lab --check
  [ "$status" -eq 100 ]
  [[ "$output" == *'did not print a --check --json report (exit status 4)'* ]]
}

@test "a Linux server in Docker: --plan and --check run in its container, --apply is refused before setup.sh" {
  existing_checkout
  touch "$R/docker-server"
  provision --environment lab --pairing-address 203.0.113.10 --publish-address 203.0.113.10
  [ "$status" -eq 0 ]
  [[ "$output" == *'Device form: a Linux server in Docker; its Orca terminals run inside the orca-server container'* ]]
  # The addresses belong to the host's compose.yaml, so the plan inside the container does not get them.
  [ "$(cat "$R/setup-calls")" = 'setup.sh --plan --role server' ]
  provision --environment lab --check
  [ "$status" -eq 2 ]
  [[ "$output" == *'Docker server: Docker, the image, the container and its mounts are checked on the host'* ]]
  : >"$R/setup-calls"
  provision --environment lab --apply --pairing-address 203.0.113.10
  [ "$status" -eq 100 ]
  [[ "$output" == *'REFUSED: lab is a Linux server in Docker'* ]]
  [[ "$output" == *'./setup.sh --apply --role server --pairing-address <address>'* ]]
  [ ! -s "$R/setup-calls" ]
}

@test "a Linux server in Docker without a checkout: --apply makes the checkout, then refuses before setup.sh" {
  touch "$R/docker-server"
  provision --environment lab --apply --destination "$SB/device"
  [ "$status" -eq 100 ]
  [[ "$output" == *"still work with the checkout $SB/device/orca-setup it just made"* ]]
  [ ! -e "$R/setup-calls" ]
}
