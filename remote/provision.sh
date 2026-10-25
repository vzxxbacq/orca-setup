#!/usr/bin/env bash
# remote/provision.sh: provision one paired device from the control machine (README section 5, steps 2-5).
# Runs on the control machine, which must hold the client pairing role (README section 5.1). Everything happens
# through the public Orca CLI: the repository reaches the device with `project setup-clone` (or an existing checkout
# there is reused), and setup.sh runs in an Orca terminal on the device whose output is streamed back here.
# Read-only by default: without --apply it changes nothing on the device except opening one terminal there, and runs
# only `./setup.sh --plan`. It never handles passwords, pairing codes or other credentials, and never runs --auth-*.
# A Linux server in Docker (README section 6.7) is recognised from its terminal: Orca's terminals there run inside the
# orca-server container, whose image sets ORCA_SETUP_CONTAINER=orca-server and writes /etc/orca-server-image. That
# container has no sudo and no Docker, so for it --plan and --check run there and --apply is refused before setup.sh
# runs, with a pointer to the host install over SSH.
set -euo pipefail

ORCA_SETUP_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=lib/common.sh
. "$ORCA_SETUP_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$ORCA_SETUP_ROOT/lib/detect.sh"
# shellcheck source=lib/orca-server.sh
. "$ORCA_SETUP_ROOT/lib/orca-server.sh"

REPO_URL=https://github.com/vzxxbacq/orca-setup
PROJECT_ID=github:vzxxbacq/orca-setup
TERMINAL_TITLE='orca-setup provision'
EXIT_REFUSED=100
POLL_SECONDS=${ORCA_SETUP_REMOTE_POLL:-2}
STEP_TIMEOUT=${ORCA_SETUP_REMOTE_TIMEOUT:-7200}

usage() {
  cat <<'EOF'
Usage: remote/provision.sh --environment NAME [--plan | --apply | --check] [--role server]
                           [--pairing-address ADDRESS] [--publish-address IPV4] [--task-source linear]
                           [modules] [--destination DIR | --path DIR] [--fast-forward]

Run on the control machine (pairing role client) for one device saved with `orca environment add`.

  --plan          Show what would happen on the device and run only ./setup.sh --plan there (default).
  --apply         Make the repository available on the device, then run ./setup.sh --plan, --apply and --check
                  there; the exit code is the device's number of missing items.
  --check         Run only ./setup.sh --check on the device; the exit code is its number of missing items.
  --environment NAME
                  The saved environment (paired Orca server) to provision.
  --role server   The device's pairing role. A paired device is dialed by this client, so it is always a server.
  --pairing-address ADDRESS
                  Passed to ./setup.sh --apply (Linux servers: the private address clients dial).
  --publish-address IPV4
                  Passed to ./setup.sh --apply (Linux servers: the device's own private IPv4 address that
                  Docker publishes the Orca port on).
  --task-source linear
                  Passed to ./setup.sh --apply and --check.
  --destination DIR
                  Absolute parent directory on the device for a new clone (--apply, when the device has none).
  --path DIR      Absolute path of an existing orca-setup checkout on the device that Orca does not know yet
                  (--apply registers it with project setup-existing-folder).
  --fast-forward  Allow fast-forwarding an existing checkout that is behind its upstream (never with local changes).

Optional modules are passed to ./setup.sh: --power --containers --apple --android --media --agent-gemini --gpu

Exit status: 0-99 the device's missing items (--check / --apply; capped at 99), 0 for a finished --plan,
100 refused or failed before the device's check finished, 2 usage error. Interactive logins (--auth-*) are
never run here; the ones still pending are listed at the end.
EOF
}

refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit "$EXIT_REFUSED"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit "$EXIT_REFUSED"; }
usage_error() { printf '%s\n' "$*" >&2; usage >&2; exit 2; }

# ---------------------------------------------------------------- arguments

mode=''
environment=''
pairing_address=''
publish_address=''
task_source=''
destination=''
existing_path=''
fast_forward=no
modules=''

set_mode() {
  [ -z "$mode" ] || [ "$mode" = "$1" ] || usage_error 'choose only one of --plan, --apply and --check'
  mode=$1
}

# need_value <flag> <number of arguments left>: the flag is followed by its value.
need_value() { [ "$2" -ge 2 ] || usage_error "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) set_mode plan ;;
    --apply) set_mode apply ;;
    --check) set_mode check ;;
    --environment) need_value "$1" $#; environment=$2; shift ;;
    --environment=*) environment=${1#*=} ;;
    --role) need_value "$1" $#; [ "$2" = server ] || usage_error "--role must be server: a device this client dials accepts runtime pairings (README section 5.1)"; shift ;;
    --role=*) [ "${1#*=}" = server ] || usage_error "--role must be server: a device this client dials accepts runtime pairings (README section 5.1)" ;;
    --pairing-address) need_value "$1" $#; pairing_address=$2; shift ;;
    --pairing-address=*) pairing_address=${1#*=} ;;
    --publish-address) need_value "$1" $#; publish_address=$2; shift ;;
    --publish-address=*) publish_address=${1#*=} ;;
    --task-source) need_value "$1" $#; task_source=$2; shift ;;
    --task-source=*) task_source=${1#*=} ;;
    --destination) need_value "$1" $#; destination=$2; shift ;;
    --destination=*) destination=${1#*=} ;;
    --path) need_value "$1" $#; existing_path=$2; shift ;;
    --path=*) existing_path=${1#*=} ;;
    --fast-forward) fast_forward=yes ;;
    --auth-*) usage_error "provision.sh never runs interactive logins; run ./setup.sh $1 yourself in the Orca terminal on the device." ;;
    --help | -h) usage; exit 0 ;;
    --*)
      case " $ORCA_SETUP_MODULES " in *" ${1#--} "*) modules="$modules $1" ;; *) usage_error "Unknown option: $1" ;; esac ;;
    *) usage_error "Unknown argument: $1" ;;
  esac
  shift
done
mode=${mode:-plan}
modules=${modules# }
[ -n "$environment" ] || usage_error '--environment NAME is required (see: orca environment list).'
case "$task_source" in '' | linear) ;; *) usage_error "unknown task source: $task_source" ;; esac
if [ -n "$pairing_address" ]; then
  problem=$(pairing_address_problem "$pairing_address")
  [ -z "$problem" ] || usage_error "--pairing-address $pairing_address is refused: $problem."
fi
if [ -n "$publish_address" ]; then
  problem=$(publish_address_problem "$publish_address")
  [ -z "$problem" ] || usage_error "--publish-address $publish_address is refused: $problem."
fi
for dir in "$destination" "$existing_path"; do
  [ -z "$dir" ] || [[ "$dir" == /* ]] || usage_error "--destination and --path take an absolute path on the device, not: $dir"
  [[ "$dir" != *[[:cntrl:]]* ]] || usage_error 'paths must not contain control characters'
done
[ -z "$destination" ] || [ -z "$existing_path" ] || usage_error 'choose either --destination (new clone) or --path (existing checkout)'

require_non_root
setup_environment
ORCA_CLI=$(detect_orca_cli)
CLI_NAME=$(basename "$ORCA_CLI")

# ---------------------------------------------------------------- helpers

json() { node "$ORCA_SETUP_ROOT/lib/json.cjs" "$@"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/orca-setup-provision.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

# cli <args...>: run the Orca CLI; its JSON answer goes to stdout. On failure, print the CLI's error message
# (never the raw reply) and return its status.
cli() {
  local status=0 message
  "$ORCA_CLI" "$@" >"$WORK/cli.out" 2>"$WORK/cli.err" || status=$?
  if [ "$status" -ne 0 ]; then
    message=$(json get error.message <"$WORK/cli.out" 2>/dev/null) || message=''
    [ -n "$message" ] || message=$(head -n 3 "$WORK/cli.err" | tr '\n' ' ')
    printf '%s: %s\n' "$CLI_NAME $1 $2" "${message:-failed with status $status}" >&2
    return "$status"
  fi
  cat "$WORK/cli.out"
}

# step_cli <args...>: print a state-changing Orca CLI command (on stderr, since callers capture the JSON answer),
# then run it.
step_cli() {
  printf '+ %s %s\n' "$CLI_NAME" "$*" >&2
  cli "$@"
}

# ---------------------------------------------------------------- preflight

preflight() {
  local role_output role_status=0 detected env_json status_json
  have node || refuse 'node is required on the control machine (./setup.sh --apply --role client installs it).'
  have "$ORCA_CLI" || refuse "the Orca CLI ($ORCA_CLI) is not installed on this machine."
  role_output=$(bash "$ORCA_SETUP_ROOT/orca/role.sh" --expect client 2>&1) || role_status=$?
  detected=$(printf '%s\n' "$role_output" | sed -n '1s/^ROLE //p')
  if [ "$role_status" -ne 0 ] || [ "$detected" != client ]; then
    # Pairing names and the remedies role.sh prints matter only for a dual role.
    if [ "$detected" = dual ]; then printf '%s\n' "$role_output" | sed 's/^ROLE /Pairing role: /' >&2
    else printf '%s\n' "$role_output" | grep -v -e '^  ' -e '^CONFLICT ' | sed 's/^ROLE /Pairing role: /' >&2; fi
    case "$detected" in
      server) refuse "this machine is an Orca server (it accepts runtime pairings); provision.sh runs on a client that saved the device with \`$CLI_NAME environment add\` (README section 5.1)." ;;
      dual) refuse 'this machine holds both pairing roles; remove the pairings listed above first (README section 5.1).' ;;
      none) refuse 'this machine has no saved environments; pair the device first (README section 3.3.2), then rerun.' ;;
      *) refuse 'the pairing role of this machine cannot be determined (see the reason above).' ;;
    esac
  fi
  info "Control machine: pairing role client ($CLI_NAME)"
  env_json=$(cli environment show --environment "$environment" --json) ||
    refuse "no saved environment named $environment on this machine (see: $CLI_NAME environment list)."
  ENV_ID=$(printf '%s' "$env_json" | json get result.environment.id) || ENV_ID=''
  [[ "$ENV_ID" =~ ^[A-Za-z0-9._:-]+$ ]] || refuse "the saved environment $environment has no usable id."
  status_json=$(cli status --environment "$environment" --json) ||
    refuse "the Orca server $environment is not reachable from here (check the private route and that its Orca runs)."
  printf '%s' "$status_json" | json has result.runtime.reachable ||
    refuse "the Orca server $environment answers, but its runtime is not reachable."
  info "Device: $environment (runtime:$ENV_ID), reachable"
}

# ---------------------------------------------------------------- the checkout on the device

CHECKOUT=''
CLONED=no

# find_checkout: the device's existing project setup of this repository, if Orca knows one.
find_checkout() {
  local setups
  setups=$(cli project setups --host "runtime:$ENV_ID" --json) || fail "cannot list the project setups on $environment."
  CHECKOUT=$(printf '%s' "$setups" | json pick result.setups projectId "$PROJECT_ID" path) || CHECKOUT=''
}

# make_checkout: make the repository available on the device (step 2); in --plan and --check only say how.
make_checkout() {
  local result
  find_checkout
  if [ -n "$CHECKOUT" ]; then
    info "Checkout on $environment: $CHECKOUT (existing project setup)"
    return 0
  fi
  if [ -n "$existing_path" ]; then
    if [ "$mode" != apply ]; then
      info "Checkout on $environment: none known to Orca; --apply would register $existing_path:"
      info "  $CLI_NAME project setup-existing-folder --project $PROJECT_ID --host runtime:$ENV_ID --path $existing_path --kind git --json"
      [ "$mode" = plan ] || refuse "--check needs a checkout that Orca knows on $environment; run --apply first."
      info 'Then ./setup.sh --plan runs there. Nothing was changed.'
      exit 0
    fi
    result=$(step_cli project setup-existing-folder --project "$PROJECT_ID" --host "runtime:$ENV_ID" \
      --path "$existing_path" --kind git --json) || fail "could not register $existing_path on $environment."
  else
    if [ "$mode" != apply ]; then
      info "Checkout on $environment: none; --apply would clone the repository there:"
      info "  $CLI_NAME project setup-clone --project $PROJECT_ID --host runtime:$ENV_ID --url $REPO_URL --destination ${destination:-<absolute parent directory on the device>} --json"
      [ "$mode" = plan ] || refuse "--check needs a checkout on $environment; run --apply first."
      info 'Then ./setup.sh --plan runs there. Nothing was changed.'
      exit 0
    fi
    [ -n "$destination" ] ||
      refuse "$environment has no orca-setup checkout yet; pass --destination <absolute parent directory on the device> for the clone (for example the home directory's orca/projects), or --path for an existing one."
    result=$(step_cli project setup-clone --project "$PROJECT_ID" --host "runtime:$ENV_ID" --url "$REPO_URL" \
      --destination "$destination" --json) || fail "could not clone $REPO_URL on $environment."
    CLONED=yes
  fi
  CHECKOUT=$(printf '%s' "$result" | json get result.setup.path) || CHECKOUT=''
  [[ "$CHECKOUT" == /* ]] || fail "the Orca server did not report where the checkout is."
  info "Checkout on $environment: $CHECKOUT"
}

# ---------------------------------------------------------------- the terminal on the device

TERMINAL=''
CURSOR=''
STEP=0
RUN_ID="$$-$RANDOM"

# terminal_read [cursor]: one bounded read of the terminal as JSON.
terminal_read() {
  if [ -n "${1:-}" ]; then cli terminal read --environment "$environment" --terminal "$TERMINAL" --cursor "$1" --json
  else cli terminal read --environment "$environment" --terminal "$TERMINAL" --json; fi
}

# next_cursor <read-json>: where the next read starts.
next_cursor() {
  local value
  value=$(printf '%s' "$1" | json get result.terminal.nextCursor 2>/dev/null) || value=''
  [[ "$value" =~ ^[0-9]+$ ]] || value=$(printf '%s' "$1" | json get result.terminal.latestCursor 2>/dev/null) || value=''
  [[ "$value" =~ ^[0-9]+$ ]] || value=$CURSOR
  printf '%s\n' "$value"
}

open_terminal() {
  local result
  result=$(step_cli terminal create --environment "$environment" --worktree "path:$CHECKOUT" --title "$TERMINAL_TITLE" --json) ||
    fail "could not open an Orca terminal in $CHECKOUT on $environment."
  TERMINAL=$(printf '%s' "$result" | json get result.terminal.handle) || TERMINAL=''
  [[ "$TERMINAL" =~ ^[A-Za-z0-9._:-]+$ ]] || fail 'the Orca server did not return a terminal handle.'
  info "Terminal on $environment: \"$TERMINAL_TITLE\" (handle $TERMINAL) in $CHECKOUT"
  # Whatever the shell printed before the first command (its prompt) is not shown.
  result=$(terminal_read) || fail "cannot read the terminal $TERMINAL on $environment."
  CURSOR=$(next_cursor "$result")
}

sudo_handoff() {
  info "ACTION: sudo on $environment is asking for a password. Answer it in the Orca terminal \"$TERMINAL_TITLE\" (handle $TERMINAL) of $CHECKOUT on $environment, for example after: $CLI_NAME terminal switch --environment $environment --terminal $TERMINAL"
  info "        provision.sh never reads or sends passwords; it keeps waiting (up to ${STEP_TIMEOUT}s per step)."
}

# remote_run <quiet|stream> <command>: run one command line in the device's terminal, stream its output (unless
# quiet), and set STEP_STATUS to its exit status. Its output lines are kept in $WORK/step.log. The command runs
# under sh -c, so the device's login shell may be any shell; the end of the command is a marker line with a
# per-step nonce, which the echoed command line itself cannot match.
remote_run() {
  local show=$1 command=$2 nonce marker read_json line deadline prompted=no
  STEP=$((STEP + 1))
  nonce="$RUN_ID-$STEP"
  marker="orca-setup-done $nonce"
  : >"$WORK/step.log"
  # shellcheck disable=SC2016 # $? is expanded on the device
  cli terminal send --environment "$environment" --terminal "$TERMINAL" \
    --text "sh -c $(shq "$command; printf '%s %s %s\n' orca-setup-done $nonce \"\$?\"")" --enter --json >/dev/null ||
    fail "cannot send to the terminal $TERMINAL on $environment."
  deadline=$((SECONDS + STEP_TIMEOUT))
  STEP_STATUS=''
  while :; do
    read_json=$(terminal_read "$CURSOR") || fail "cannot read the terminal $TERMINAL on $environment."
    CURSOR=$(next_cursor "$read_json")
    while IFS= read -r line; do
      line=${line%"${line##*[![:space:]]}"}
      if [[ "$line" =~ ^"$marker "([0-9]+)$ ]]; then STEP_STATUS=${BASH_REMATCH[1]}; break; fi
      printf '%s\n' "$line" >>"$WORK/step.log"
      [ "$show" = quiet ] || printf '  | %s\n' "$line"
      case "$line" in
        *'[sudo] password for '* | 'Password:'* | *'Sorry, try again.'*)
          [ "$prompted" = yes ] || sudo_handoff
          prompted=yes ;;
        *) [ -z "$line" ] || prompted=no ;;
      esac
    done < <(printf '%s' "$read_json" | json lines result.terminal.tail 2>/dev/null)
    [ -z "$STEP_STATUS" ] || return 0
    case "$(printf '%s' "$read_json" | json get result.terminal.status 2>/dev/null)" in
      exited | closed | dead) fail "the terminal $TERMINAL on $environment ended before the command finished." ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] ||
      fail "no result from the terminal $TERMINAL on $environment after ${STEP_TIMEOUT}s; it is still open there (ORCA_SETUP_REMOTE_TIMEOUT raises the limit)."
    sleep "$POLL_SECONDS"
  done
}

# DEVICE_FORM: host (setup.sh runs on the device itself), or orca-server (a Linux server in Docker: the terminal runs
# inside its orca-server container). The printed key is assembled by printf, so the echoed command line never
# carries it.
DEVICE_FORM=host
probe_device_form() {
  local form
  remote_run quiet "f=host; if [ \"\${ORCA_SETUP_CONTAINER:-}\" = orca-server ] || [ -e /etc/orca-server-image ]; then f=orca-server; fi; printf 'orca-setup-%s %s\\n' form \"\$f\""
  [ "$STEP_STATUS" = 0 ] || fail "cannot inspect the terminal on $environment."
  form=$(sed -n -E 's/^orca-setup-form (host|orca-server)$/\1/p' "$WORK/step.log" | head -n 1)
  DEVICE_FORM=${form:-host}
  [ "$DEVICE_FORM" = orca-server ] || return 0
  info "Device form: a Linux server in Docker; its Orca terminals run inside the $ORCA_SERVER_NAME container (README section 6.7)"
  [ "$mode" != apply ] ||
    refuse "$environment is a Linux server in Docker: its Orca terminals run inside the $ORCA_SERVER_NAME container, which has no sudo and no Docker and cannot change its host. Install or update it on the host over SSH: ./setup.sh --apply --role server --pairing-address <address> (README section 6.7). remote/provision.sh --plan and --check still work$(if [ "$CLONED" = yes ]; then printf ' with the checkout %s it just made' "$CHECKOUT"; fi)."
}

# git_value <key>: a value the checkout verification printed.
git_value() { sed -n "s/^orca-setup-git $1 //p" "$WORK/step.log" | head -n 1; }

# origin_matches <url>: the checkout's origin is this public repository (https or ssh spelling, with or without .git).
origin_matches() {
  local url
  url=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  url=${url%/}
  url=${url%.git}
  case "$url" in
    https://github.com/vzxxbacq/orca-setup | git@github.com:vzxxbacq/orca-setup | ssh://git@github.com/vzxxbacq/orca-setup) return 0 ;;
  esac
  return 1
}

# verify_checkout: an existing checkout must have this repository as origin. Local changes are never touched; a
# checkout behind its upstream is fast-forwarded only with --fast-forward, and --apply refuses to run an old one.
verify_checkout() {
  local here url dirty behind ahead
  here=$(shq "$CHECKOUT")
  remote_run quiet "cd $here && printf 'orca-setup-git url %s\\n' \"\$(git config --get remote.origin.url)\" && printf 'orca-setup-git dirty %s\\n' \"\$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')\" && { git fetch --quiet origin || printf 'orca-setup-git fetch failed\\n'; } && printf 'orca-setup-git behind %s\\n' \"\$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo unknown)\" && printf 'orca-setup-git ahead %s\\n' \"\$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo unknown)\""
  [ "$STEP_STATUS" = 0 ] || fail "cannot inspect the git checkout $CHECKOUT on $environment (is git installed there?)."
  url=$(git_value url)
  origin_matches "$url" || refuse "the checkout $CHECKOUT on $environment has origin ${url:-(none)}, not $REPO_URL; refusing to run it."
  dirty=$(git_value dirty)
  behind=$(git_value behind)
  ahead=$(git_value ahead)
  [ -z "$(git_value fetch)" ] || warn "git fetch failed in $CHECKOUT on $environment; the upstream state may be old."
  info "Checkout state: origin $REPO_URL, ${dirty:-?} changed file(s), ${behind:-unknown} commit(s) behind, ${ahead:-unknown} ahead"
  [ "${dirty:-0}" = 0 ] || warn "the checkout on $environment has local changes; provision.sh never touches them."
  case "$behind" in
    0) return 0 ;;
    unknown | '') warn "the checkout on $environment has no upstream branch; it cannot be compared or fast-forwarded."; return 0 ;;
  esac
  if [ "$fast_forward" != yes ]; then
    [ "$mode" != apply ] || refuse "the checkout on $environment is $behind commit(s) behind its upstream; rerun with --fast-forward to update it (fast-forward only), or update it yourself."
    warn "the checkout on $environment is $behind commit(s) behind its upstream; --apply needs --fast-forward."
    return 0
  fi
  [ "${dirty:-0}" = 0 ] || refuse "--fast-forward refuses a checkout with local changes ($CHECKOUT on $environment)."
  [ "${ahead:-0}" = 0 ] || refuse "the checkout on $environment has local commits; it cannot be fast-forwarded."
  if [ "$mode" != apply ]; then
    info "--apply would fast-forward $CHECKOUT on $environment by $behind commit(s)."
    return 0
  fi
  info "+ git merge --ff-only @{u} in $CHECKOUT on $environment"
  remote_run stream "cd $here && git merge --ff-only '@{u}'"
  [ "$STEP_STATUS" = 0 ] || refuse "the checkout on $environment cannot be fast-forwarded (see above)."
}

# ---------------------------------------------------------------- setup.sh on the device

# setup_line <mode-flag> [--with-address]: the ./setup.sh command line for the device.
setup_line() {
  local line name
  line="cd $(shq "$CHECKOUT") && ./setup.sh $1 --role server"
  # Inside the orca-server container the addresses belong to the host's compose.yaml.
  [ "${2:-}" != --with-address ] || [ -z "$pairing_address" ] || [ "$DEVICE_FORM" = orca-server ] ||
    line="$line --pairing-address $pairing_address"
  [ "${2:-}" != --with-address ] || [ -z "$publish_address" ] || [ "$DEVICE_FORM" = orca-server ] ||
    line="$line --publish-address $publish_address"
  for name in $modules; do line="$line $name"; done
  [ -z "$task_source" ] || line="$line --task-source $task_source"
  printf '%s\n' "$line"
}

run_setup() { # run_setup <label> <command line>
  info "== $1 on $environment"
  remote_run stream "$2"
  info "== $1 on $environment: exit status $STEP_STATUS"
}

# check_and_exit: run ./setup.sh --check --json on the device, report it, and exit with its missing count.
check_and_exit() {
  local line report summary missing name state counted pending=''
  run_setup './setup.sh --check --json' "$(setup_line '--check --json')"
  # The report is the JSON document between the first "{" line and the last "}" line of the step's output.
  report=$(awk '/^\{$/ && !started { started = 1 } started { print } ' "$WORK/step.log" | awk '{ lines[NR] = $0 } /^\}$/ { last = NR } END { for (i = 1; i <= last; i++) print lines[i] }')
  if ! summary=$(printf '%s\n' "$report" | json check-summary 2>/dev/null); then
    fail "the device did not print a --check --json report (exit status $STEP_STATUS); its setup.sh may predate P4: update the checkout (--fast-forward) and rerun."
  fi
  missing=$(printf '%s\n' "$summary" | sed -n 's/^missing //p')
  info ''
  info "Device $environment: $missing missing item(s) (./setup.sh --check on the device)"
  printf '%s\n' "$summary" | sed -n 's/^counted /  counted: /p'
  while read -r line name state counted; do
    [ "$line" = auth ] || continue
    case "$state" in pending | not-selected | not-connected) pending="$pending $name:$counted" ;; esac
  done <<<"$summary"
  info "Interactive logins are never run by provision.sh. Run the pending ones yourself in the Orca terminal \"$TERMINAL_TITLE\" (handle $TERMINAL) on $environment:"
  for line in $pending; do
    if [ "${line#*:}" = 1 ]; then info "  ./setup.sh --auth-${line%%:*}   (counted)"; else info "  ./setup.sh --auth-${line%%:*}   (optional)"; fi
  done
  [ -n "$pending" ] || info '  none pending'
  info '  ./setup.sh --auth-agy   (not detected by --check; run it if agy is not signed in yet)'
  [ "$DEVICE_FORM" != orca-server ] ||
    info "Docker server: Docker, the image, the container and its mounts are checked on the host: ./setup.sh --check there (over SSH)."
  info "The terminal stays open on $environment; close it with: $CLI_NAME terminal close --environment $environment --terminal $TERMINAL"
  [ "$missing" -le 99 ] || missing=99
  exit "$missing"
}

# ---------------------------------------------------------------- main

info "orca-setup remote provisioning ($mode)$(if [ "$mode" = plan ]; then printf '; read-only: only ./setup.sh --plan runs on the device'; fi)"
preflight
make_checkout
open_terminal
probe_device_form
[ "$CLONED" = yes ] || verify_checkout

case "$mode" in
  plan)
    run_setup './setup.sh --plan' "$(setup_line --plan --with-address)"
    [ "$STEP_STATUS" = 0 ] || fail "./setup.sh --plan failed on $environment (exit status $STEP_STATUS)."
    info "Plan only: nothing was installed. Run with --apply to provision $environment."
    info "The terminal stays open on $environment; close it with: $CLI_NAME terminal close --environment $environment --terminal $TERMINAL" ;;
  check) check_and_exit ;;
  apply)
    run_setup './setup.sh --plan' "$(setup_line --plan --with-address)"
    [ "$STEP_STATUS" = 0 ] || fail "./setup.sh --plan failed on $environment (exit status $STEP_STATUS); nothing was applied."
    run_setup './setup.sh --apply' "$(setup_line --apply --with-address)"
    [ "$STEP_STATUS" = 0 ] ||
      fail "./setup.sh --apply failed on $environment (exit status $STEP_STATUS); see the output above, or the terminal $TERMINAL there."
    check_and_exit ;;
esac
