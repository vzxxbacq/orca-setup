#!/usr/bin/env bash
# orca-setup: turn this device into an Orca development machine. Run on the target device itself.
# Read-only by default: with no arguments it only prints the plan. No SSH setup, no credential
# import, no automatic agent launch. See README.md.
set -euo pipefail

ORCA_SETUP_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$ORCA_SETUP_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$ORCA_SETUP_ROOT/lib/detect.sh"
# shellcheck source=lib/manifest.sh
. "$ORCA_SETUP_ROOT/lib/manifest.sh"
# shellcheck source=lib/pkg-macos.sh
. "$ORCA_SETUP_ROOT/lib/pkg-macos.sh"
# shellcheck source=lib/pkg-debian.sh
. "$ORCA_SETUP_ROOT/lib/pkg-debian.sh"
# shellcheck source=lib/npm-tools.sh
. "$ORCA_SETUP_ROOT/lib/npm-tools.sh"
# shellcheck source=lib/rows.sh
. "$ORCA_SETUP_ROOT/lib/rows.sh"
# shellcheck source=lib/docker-host.sh
. "$ORCA_SETUP_ROOT/lib/docker-host.sh"
# shellcheck source=lib/orca-server.sh
. "$ORCA_SETUP_ROOT/lib/orca-server.sh"
for file in "$ORCA_SETUP_ROOT"/modules/*.sh "$ORCA_SETUP_ROOT"/auth/*.sh; do
  # shellcheck source=/dev/null
  . "$file"
done

MODULES=$ORCA_SETUP_MODULES
AUTHS=$ORCA_SETUP_AUTHS
TASK_SOURCES='linear'

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--plan | --apply | --check [--json]] [--role client|server] [--pairing-address ADDRESS]
                  [--workdir DIR] [--upgrade-image] [modules] [--task-source linear]
       ./setup.sh --auth-gh | --auth-codex | --auth-claude | --auth-agy | --auth-linear

  --plan         Print what --apply would do on this device (default; read-only).
  --apply        Install missing baseline tools and agents, install Orca skills, align Orca defaults,
                 then run the selected modules. Requires --role.
  --check        Read-only readiness report; the exit code is the number of missing items.
  --json         With --check: print the report as one JSON document instead (names, states, counts and
                 versions only, never credential values); the exit code is the same.
  --role R       Pairing role of this device: client (dials servers) or server (is dialed).
  --pairing-address ADDRESS
                 Linux servers: the private IPv4 address or host name clients dial (Tailscale, LAN,
                 WireGuard). Required for --apply --role server on Linux; never 127.0.0.1 or a wildcard.
  --workdir DIR  Linux servers: the absolute directory for projects/ and workspaces/, mounted into the Orca
                 server container (default ~/orca, or the one the last --apply used).
  --upgrade-image
                 Linux servers, with --apply: pull the newest Orca server image and re-create the container
                 when it changed (otherwise the digest locked by the first --apply is kept).
  --task-source linear
                 Also make Linear Orca's task source (--apply), and require it to be connected (--check).

Optional modules (installed only together with --apply; --check also checks the ones given):
  --power --containers --apple --android --media --agent-gemini --gpu

Interactive authentication (run one or more on their own):
  --auth-gh --auth-codex --auth-claude --auth-agy --auth-linear
EOF
}

# ---------------------------------------------------------------- arguments

action=''
role=''
pairing_address=''
workdir=''
upgrade_image=no
task_source=''
modules=''
auths=''
check_json=no

set_action() {
  [ -z "$action" ] || [ "$action" = "$1" ] || die "choose only one of --plan, --apply, --check and --auth-*"
  action=$1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) set_action plan ;;
    --apply) set_action apply ;;
    --check) set_action check ;;
    --json) check_json=yes ;;
    --role | --role=*)
      if [ "$1" = --role ]; then [ $# -ge 2 ] || die '--role needs client or server'; role=$2; shift; else role=${1#--role=}; fi
      case "$role" in client | server) ;; *) die "--role must be client or server, not: $role" ;; esac ;;
    --pairing-address | --pairing-address=*)
      if [ "$1" = --pairing-address ]; then [ $# -ge 2 ] || die '--pairing-address needs an address'; pairing_address=$2; shift
      else pairing_address=${1#--pairing-address=}; fi ;;
    --workdir | --workdir=*)
      if [ "$1" = --workdir ]; then [ $# -ge 2 ] || die '--workdir needs a directory'; workdir=$2; shift; else workdir=${1#--workdir=}; fi
      [ -n "$workdir" ] || die '--workdir needs a directory' ;;
    --upgrade-image) upgrade_image=yes ;;
    --task-source | --task-source=*)
      if [ "$1" = --task-source ]; then [ $# -ge 2 ] || die '--task-source needs a value'; task_source=$2; shift; else task_source=${1#--task-source=}; fi
      case " $TASK_SOURCES " in *" $task_source "*) ;; *) die "unknown task source: $task_source" ;; esac ;;
    --auth-*)
      name=${1#--auth-}
      case " $AUTHS " in *" $name "*) ;; *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;; esac
      [ -z "$action" ] || [ "$action" = auth ] || die "choose only one of --plan, --apply, --check and --auth-*"
      action=auth
      auths="$auths $name" ;;
    --help | -h) usage; exit 0 ;;
    --*)
      name=${1#--}
      case " $MODULES " in *" $name "*) modules="$modules $name" ;; *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;; esac ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
action=${action:-plan}
modules=${modules# }
auths=${auths# }
[ "$action" != auth ] || [ -z "$modules" ] || die "modules run only with --apply (or show with --plan, or check with --check): $modules"
[ "$action" != apply ] || [ -n "$role" ] || die '--apply requires --role client or --role server (README section 5.1).'
[ "$check_json" = no ] || [ "$action" = check ] || die '--json works only with --check.'
[ "$upgrade_image" = no ] || [ "$action" = apply ] || [ "$action" = plan ] || die '--upgrade-image works only with --apply (or --plan).'
[ -z "$workdir" ] || [ "$action" != auth ] || die '--workdir does not apply to --auth-*.'

require_non_root
setup_environment

OS=$(detect_os)
ARCH=$(detect_arch)
SUPPORT=$(detect_support)
ORCA_CLI=$(detect_orca_cli)
PLATFORM=''
[ "$OS" = macos ] && PLATFORM=macos
[ "$OS" = linux ] && [ "$(detect_linux_family)" = debian ] && PLATFORM=debian

# in_container: this runs inside the Orca server container (docker/Dockerfile sets ORCA_SETUP_CONTAINER), where the
# image provides the tools and the host's Docker, image and mounts are out of reach.
in_container() { [ "${ORCA_SETUP_CONTAINER:-}" = orca-server ]; }

# linux_role: the role the Linux Orca checks assume: --role, else server inside the Orca server container or when
# its compose.yaml exists, else client.
linux_role() {
  if [ -n "$role" ]; then echo "$role"
  elif in_container || [ -e "$(server_compose_file)" ]; then echo server
  else echo client; fi
}

if [ -n "$pairing_address" ]; then
  [ "$PLATFORM" = debian ] || die '--pairing-address is for Linux servers; on macOS choose the address in Orca: Settings > Remote Orca Servers.'
  [ "$role" != client ] || die '--pairing-address is for --role server; a client never serves or advertises an address.'
  ! in_container || die "--pairing-address belongs to the Docker host: run ./setup.sh there (over SSH), not inside the $ORCA_SERVER_NAME container."
  problem=$(pairing_address_problem "$pairing_address")
  [ -z "$problem" ] || die "--pairing-address $pairing_address is refused: $problem. Use the private address clients dial (README section 1)."
fi
if in_container; then
  [ "$role" != client ] || die "the $ORCA_SERVER_NAME container is a server; --role client does not apply here."
  [ -z "$workdir" ] && [ "$upgrade_image" = no ] ||
    die "--workdir and --upgrade-image belong to the Docker host: run ./setup.sh there (over SSH), not inside the $ORCA_SERVER_NAME container."
fi

# SERVER_HOST=yes: a Linux host whose Orca server runs in Docker (README section 6.7). WORKDIR is its --workdir.
SERVER_HOST=no
WORKDIR=''
if [ "$PLATFORM" = debian ] && ! in_container && [ "$(linux_role)" = server ]; then SERVER_HOST=yes; fi
# An unsupported device is refused by every mode, with its reason, before anything here matters.
if [ "$SERVER_HOST" = yes ] && [ "$action" != auth ] && [ "$SUPPORT" = supported ]; then
  case "$workdir" in \~) workdir=$HOME ;; \~/*) workdir=$HOME/${workdir#\~/} ;; esac
  while [ "$workdir" != / ] && [ "${workdir%/}" != "$workdir" ]; do workdir=${workdir%/}; done
  WORKDIR=${workdir:-$(server_compose_value workdir)}
  WORKDIR=${WORKDIR:-$HOME/orca}
  problem=$(server_path_problem "$HOME")
  [ -z "$problem" ] || die "your home directory $HOME cannot be mounted into the Orca server container: $problem."
  problem=$(server_mounts_problem)
  [ -z "$problem" ] || die "manifest/server-mounts.tsv (or its local overlay): $problem."
  problem=$(server_workdir_problem "$WORKDIR")
  [ -z "$problem" ] || die "--workdir $WORKDIR is refused: $problem."
elif [ "$SERVER_HOST" = no ] && { [ -n "$workdir" ] || [ "$upgrade_image" = yes ]; }; then
  [ "$PLATFORM" = debian ] || die '--workdir and --upgrade-image are for Linux servers (Orca in Docker); macOS runs the desktop app.'
  die '--workdir and --upgrade-image are for --role server on Linux; a client runs no Orca server.'
fi

# ---------------------------------------------------------------- helpers

orca_rpc() {
  local params=${2:-}
  [ -n "$params" ] || params='{}'
  bash "$ORCA_SETUP_ROOT/orca/orca-rpc.sh" local "$1" "$params" 2>/dev/null
}

json() { node "$ORCA_SETUP_ROOT/lib/json.cjs" "$@"; }

# Each modules/<name>.sh defines module_<name>_describe and may define module_<name>_plan, _apply and _check
# (run after the module's manifest rows) and module_<name>_skip <plan|apply|check>, which returns 0 and sets
# MODULE_SKIP_REASON when the module does not apply to this device (it is then skipped with a notice, not an error).
module_function() { printf 'module_%s_%s\n' "${1//-/_}" "$2"; }

MODULE_SKIP_REASON=''
# module_skipped <name> <mode>: the module is skipped on this device; the reason is in MODULE_SKIP_REASON.
module_skipped() {
  MODULE_SKIP_REASON=''
  if in_container; then
    case "$1" in
      power | containers | gpu) MODULE_SKIP_REASON="it belongs to the Docker host (./setup.sh there), not to the $ORCA_SERVER_NAME container"; return 0 ;;
    esac
  fi
  has_function "$(module_function "$1" skip)" && "$(module_function "$1" skip)" "$2"
}

has_function() { declare -F "$1" >/dev/null; }

# The PATH block in ~/.profile and ~/.zshrc (Linux): $1 = plan|apply|check.
process_path_block() {
  local file
  for file in $(path_block_files); do
    if path_block_present "$HOME/$file"; then
      case "$1" in plan) printf '  present  PATH block in ~/%s\n' "$file" ;; *) printf 'PRESENT PATH block in ~/%s\n' "$file" ;; esac
      [ "$1" != check ] || record 0 "PATH block in ~/$file" present
      continue
    fi
    case "$1" in
      plan) printf '  add      PATH block in ~/%-11s puts ~/.local/bin and ~/.grok/bin on PATH (marked block)\n' "$file" ;;
      apply) path_block_add "$HOME/$file" ;;
      check) printf 'MISSING PATH block in ~/%s\n' "$file"; missing=$((missing + 1)); record 1 "PATH block in ~/$file" MISSING ;;
    esac
  done
}

# Desired Orca settings for this run, as JSON.
desired_settings() { json settings "${task_source:--}"; }

# Skills that `orca skills install` would add: "targets<TAB>skill ..." lines limited to missing skills.
missing_skill_lines() {
  local targets skills missing
  while IFS=$'\t' read -r targets skills; do
    missing=$(pending_skills "$targets" "$skills" | tr '\n' ' ')
    missing=${missing% }
    [ -z "$missing" ] || printf '%s\t%s\n' "$targets" "$missing"
  done < <(skills_for "$OS")
}

# pending_skills <targets> <skill ...>: the skills not installed yet, one per line. The local dry-run plan of
# `orca skills install` answers without a runtime; `orca skills installed` (which asks the runtime) is the fallback
# for builds without --dry-run. When neither answers, every skill is pending. An installed copy that is merely
# older than this Orca build counts as installed: --apply never upgrades.
pending_skills() {
  local answer
  if have node; then
    # shellcheck disable=SC2046,SC2086 # one argument per line / a space-separated list; names contain no whitespace
    if answer=$("$ORCA_CLI" $(skills_args "$1" "$2") --dry-run --json 2>/dev/null) &&
      answer=$(printf '%s' "$answer" | json skills-pending $2 2>/dev/null); then
      [ -z "$answer" ] || printf '%s\n' "$answer"
      return 0
    fi
    # shellcheck disable=SC2086 # a space-separated list
    if answer=$("$ORCA_CLI" skills installed --json 2>/dev/null) && answer=$(printf '%s' "$answer" | json missing $2 2>/dev/null); then
      [ -z "$answer" ] || printf '%s\n' "$answer"
      return 0
    fi
  fi
  # shellcheck disable=SC2086
  printf '%s\n' $2
}

# skills_args <targets> <skill ...>: arguments for `orca skills install`, one per line.
skills_args() {
  local targets=$1 skill
  printf '%s\n' skills install
  for skill in $2; do printf -- '--skill\n%s\n' "$skill"; done
  printf -- '--agent\n%s\n' "$targets"
}

# ---------------------------------------------------------------- plan

print_role_plan() {
  local detected
  detected=$(bash "$ORCA_SETUP_ROOT/orca/role.sh" 2>/dev/null | head -n 1) || true
  detected=${detected#ROLE }
  # On a fresh Linux device the check needs the Node.js that the baseline installs; a Docker server host never gets
  # it, so --apply checks the role inside the image.
  if [ "$detected" = unknown ] && [ "$PLATFORM" = debian ] && ! have node; then
    if [ "$SERVER_HOST" = yes ]; then detected='checked inside the orca-server image by --apply'
    else detected='unknown until Node.js is installed'; fi
  fi
  case "$role" in
    '') info "Pairing role: not chosen (required for --apply); detected: ${detected:-unknown}" ;;
    server) info "Pairing role: server (detected: ${detected:-unknown}); accepts runtime pairings, never saves environments" ;;
    client) info "Pairing role: client (detected: ${detected:-unknown}); saves environments, never prints a runtime pairing code" ;;
  esac
}

print_orca_plan() {
  local lines desired current drift targets skills
  info 'Orca (--apply):'
  if ! is_present "$(manifest_select baseline.tsv "$PLATFORM" baseline | awk -F'\t' '$1 == "orca" { print $2 }')"; then
    info '  skills and settings follow once Orca is installed and running'
    return 0
  fi
  lines=$(missing_skill_lines)
  if [ -z "$lines" ]; then
    info "  present  skills $(skills_for "$OS" | cut -f2 | paste -sd ' ' -)"
  else
    while IFS=$'\t' read -r targets skills; do
      info "  install  skills $skills"
      info "           $ORCA_CLI $(skills_args "$targets" "$skills" | paste -sd ' ' -)"
    done <<<"$lines"
  fi
  if ! have node; then
    info '  settings from manifest/orca-settings.json once Node.js is installed'
    return 0
  fi
  desired=$(desired_settings)
  if current=$(orca_rpc settings.get); then
    drift=$(printf '%s' "$current" | json get settings | json diff "$desired" | tr '\n' ' ')
    drift=${drift% }
    if [ -z "$drift" ]; then info "  aligned  settings $desired"; else info "  update   settings ${drift}: $desired"; fi
  elif [ "$PLATFORM" = debian ] && [ "$role" != server ]; then
    info "  settings only while an Orca runtime runs on this device (a Linux client has none): $desired"
  else
    info "  update   settings (Orca runtime not reachable): $desired"
  fi
  if [ -z "$task_source" ]; then info '  task source: unchanged (opt in with --task-source linear)'; fi
}

print_module_plan() {
  local name selected plan_rows
  plan_rows=$(mktemp "${TMPDIR:-/tmp}/orca-setup-plan.XXXXXX")
  info 'Optional modules (add to --apply):'
  for name in $MODULES; do
    selected=''
    case " $modules " in *" $name "*) selected=' [selected]' ;; esac
    printf '  --%-13s %s%s\n' "$name" "$("$(module_function "$name" describe)")" "$selected"
    [ -n "$selected" ] || continue
    if [ "$SERVER_HOST" = yes ]; then
      case "$name" in
        containers) info '    part of the Linux server baseline (Docker Engine above)'; continue ;;
        media | android | agent-gemini) info '    built into the orca-server image; nothing to install on this host'; continue ;;
      esac
    fi
    if module_skipped "$name" plan; then info "    skip: $MODULE_SKIP_REASON"; continue; fi
    # Through a file, not a pipe: the plan's apt state (lists refreshed, repositories shown) must outlive the call.
    process_group plan "$name" "$(group_manifest "$name")" >"$plan_rows"
    sed 's/^/  /' "$plan_rows"
    if has_function "$(module_function "$name" plan)"; then "$(module_function "$name" plan)"; fi
  done
  rm -f -- "$plan_rows"
}

# device_note: where this report comes from, for the Device line of --plan and --check.
device_note() {
  if [ "$SERVER_HOST" = yes ]; then printf ' (in the %s container)' "$ORCA_SERVER_NAME"
  elif in_container; then printf ' (inside the %s container)' "$ORCA_SERVER_NAME"; fi
}

do_plan() {
  local name
  info 'orca-setup plan (read-only; nothing is changed)'
  info "Device: $(detect_distro) $ARCH, package manager: $(detect_pkg_manager), desktop: $(detect_desktop), Orca CLI: $ORCA_CLI$(device_note)"
  [ "$SUPPORT" = supported ] || die "$(detect_unsupported_reason) --apply refuses this device."
  print_role_plan
  if in_container; then
    info "Docker host: Docker, the image and the mounts are planned on the host: ./setup.sh --plan --role server there (over SSH)"
  elif [ "$PLATFORM" = debian ]; then
    if have sudo; then info 'sudo: present; --apply runs only the sudo commands listed below as root'
    else info 'sudo: missing; --apply needs it for the sudo commands listed below'; fi
  elif have brew; then
    info 'Homebrew: present'
  else
    info 'Homebrew: missing; install it from https://brew.sh first (--apply stops without it)'
  fi
  if [ "$SERVER_HOST" = yes ]; then
    server_plan "$WORKDIR"
  else
    if in_container; then info 'Baseline tools (in the image):'; else info 'Baseline tools (--apply):'; fi
    process_group plan baseline baseline.tsv
    if in_container; then info 'Agent CLIs (in the image):'; else info 'Agent CLIs (--apply):'; fi
    process_group plan baseline agents.tsv
  fi
  if [ "$PLATFORM" = debian ] && [ "$SERVER_HOST" = no ] && ! in_container; then
    info 'PATH (--apply):'
    process_path_block plan
    info 'Pairing role check (--apply): after the baseline install, before any Orca step'
    case "$role" in
      client) info 'Orca client: Orca and its CLI only; no server unit and no pairing offer on this device' ;;
      *) info 'Orca server: --role server --pairing-address <ip-or-host> runs it in Docker instead (README section 6.7)' ;;
    esac
  fi
  [ "$SERVER_HOST" = yes ] || print_orca_plan
  print_module_plan
  info 'Authentication (interactive, run on their own):'
  for name in $AUTHS; do printf '  --auth-%-8s %s\n' "$name" "$("auth_${name}_describe")"; done
  info '  --check         Show baseline and authentication readiness, without printing credentials.'
  info 'Existing installations and user configuration are preserved. SSH is never configured.'
}

# ---------------------------------------------------------------- apply

apply_orca() {
  local targets skills desired current drift
  have node || die 'node is missing after the baseline install.'
  ORCA_CLI=$(detect_orca_cli) # Orca may have been installed by the baseline step
  while IFS=$'\t' read -r targets skills <&3; do
    [ -n "$targets" ] || continue
    # shellcheck disable=SC2046 # one argument per line; manifest names contain no whitespace
    step "$ORCA_CLI" $(skills_args "$targets" "$skills")
  done 3< <(missing_skill_lines)
  desired=$(desired_settings)
  if ! current=$(orca_rpc settings.get); then
    if [ "$PLATFORM" = debian ] && [ "$role" = client ]; then
      info 'SKIP Orca settings: no Orca runtime runs on this client (they apply once Orca runs here; rerun --apply then)'
      return 0
    fi
    [ "$PLATFORM" != debian ] || die "the Orca server does not answer settings.get; see: docker logs $ORCA_SERVER_NAME (on the host)"
    step "$ORCA_CLI" open
    current=$(orca_rpc settings.get) || die 'Orca runtime is not reachable; open Orca and rerun --apply.'
  fi
  drift=$(printf '%s' "$current" | json get settings | json diff "$desired")
  if [ -z "$drift" ]; then
    info 'PRESENT Orca settings'
  else
    info "+ orca-rpc settings.update ($(printf '%s' "$drift" | tr '\n' ' '| sed 's/ $//'))"
    printf '%s' "$desired" | bash "$ORCA_SETUP_ROOT/orca/orca-rpc.sh" local settings.update >/dev/null
  fi
}

# The pairing role only matters to Orca, so it is checked after the baseline (which brings Node.js to a fresh
# Linux device) and before any Orca step.
apply_role_check() {
  local role_status=0
  bash "$ORCA_SETUP_ROOT/orca/role.sh" --expect "$role" || role_status=$?
  case "$role_status" in
    0) ;;
    1) die "this device already holds the other pairing role; remove the pairings listed above before --apply --role $role." ;;
    *) die 'the pairing role cannot be determined (see the reason above); refusing --apply.' ;;
  esac
}

# container_apply: --apply inside the Orca server container, as the host's setup.sh runs it through docker exec: the
# role check (unless the host ran it before starting the container), then skills and settings. The image holds the
# tools, and the modules belong to the host or to the image.
container_apply() {
  [ "$role" = server ] || die "the $ORCA_SERVER_NAME container is a server; use --apply --role server."
  [ -z "$modules" ] || info "NOTE modules run on the Docker host or are built into the image; ignored here: $modules"
  [ "${ORCA_SETUP_ROLE_CHECKED:-}" = 1 ] || apply_role_check
  apply_orca
}

do_apply() {
  local name
  [ "$SUPPORT" = supported ] || die "unsupported device: $(detect_unsupported_reason)"
  if in_container; then container_apply; return; fi
  if [ "$SERVER_HOST" = yes ]; then server_apply "$WORKDIR"; return; fi
  if [ "$PLATFORM" = debian ]; then
    have sudo || die 'sudo is required for the apt steps; install it and add your user to the sudo group.'
  else
    have brew || die 'Install Homebrew first: https://brew.sh'
  fi
  process_group apply baseline baseline.tsv
  process_group apply baseline agents.tsv
  if [ "$PLATFORM" = debian ]; then
    process_path_block apply
    require_orca_libraries
  fi
  apply_role_check
  apply_orca
  for name in $modules; do
    if module_skipped "$name" apply; then info "SKIP module $name: $MODULE_SKIP_REASON"; continue; fi
    info "MODULE $name"
    process_group apply "$name" "$(group_manifest "$name")"
    if has_function "$(module_function "$name" apply)"; then "$(module_function "$name" apply)"; fi
  done
  info 'BASELINE_DONE'
}

# ---------------------------------------------------------------- check

missing=0
# Every reported item, for --check --json: "counted<TAB>label<TAB>state" (counted is 1 or 0).
CHECK_ITEMS=()
# Interactive logins: "name<TAB>state<TAB>counted"; versions: "tool<TAB>version".
CHECK_AUTH=()
CHECK_VERSIONS=()
AUDIT_LINE=''

# record <counted> <label> <state>: remember one item for --check --json.
record() { CHECK_ITEMS+=("$1"$'\t'"$2"$'\t'"$3"); }

# Items a Docker server host collects (REPORT_COLLECT=yes) for the report the container prints:
# "counted<TAB>label<TAB>state".
REPORT_COLLECT=no
HOST_ITEMS=()

# report <state> <label>: print "label: state"; PENDING, MISSING, UNREACHABLE, CONFLICT, INACTIVE, OFF, STALE and
# WRONG states count as missing.
report() {
  local counted=0
  case "$1" in PENDING* | MISSING* | CONFLICT* | UNREACHABLE* | INACTIVE* | OFF* | STALE* | WRONG*) counted=1 ;; esac
  if [ "$REPORT_COLLECT" = yes ]; then HOST_ITEMS+=("$counted"$'\t'"$2"$'\t'"$1"); return 0; fi
  printf '%s: %s\n' "$2" "$1"
  missing=$((missing + counted))
  record "$counted" "$2" "$1"
}

# auth_state <name> <complete|pending|not-selected|not-connected> <counted 1|0>: an interactive login's state; the name
# is the setup.sh --auth-<name> that completes it.
auth_state() { CHECK_AUTH+=("$1"$'\t'"$2"$'\t'"$3"); }

check_tools() { # check_tools <manifest> <group>
  local name check method
  while IFS=$'\t' read -r name check method; do
    if [ "$REPORT_COLLECT" = yes ]; then
      if row_present "$check" "$method"; then report present "$name"; else report MISSING "$name"; fi
    elif row_present "$check" "$method"; then printf 'PRESENT %s\n' "$name"; record 0 "$name" present
    else printf 'MISSING %s\n' "$name"; missing=$((missing + 1)); record 1 "$name" MISSING; fi
  done < <(platform_rows "$1" "$2")
}

check_versions() {
  local tool version
  for tool in node pnpm python3.12 uv bun; do
    have "$tool" || continue
    version=$("$tool" --version 2>/dev/null | head -n 1) || version=unknown
    printf 'VERSION %s %s\n' "$tool" "$version"
    CHECK_VERSIONS+=("$tool"$'\t'"$version")
  done
}

# orca_release_repo: the GitHub repository Orca's Linux .deb comes from (manifest/baseline.tsv).
orca_release_repo() {
  manifest_select baseline.tsv debian baseline | awk -F'\t' '$1 == "orca" { split($3, part, ":"); print part[2] }'
}

# check_orca_version: the installed Orca version and the latest stable release. Reported, never counted, and
# never acted on: setup.sh does not upgrade Orca (README section 3.3.1).
check_orca_version() {
  local installed available repo
  installed=$("$ORCA_CLI" --version 2>/dev/null | grep -Eo '[0-9]+[.][0-9]+[.][0-9]+[^ ]*' | head -n 1) || installed=''
  available=''
  repo=$(orca_release_repo)
  if [ -n "$repo" ] && have curl && have node; then
    available=$(curl -q -fsS --connect-timeout 5 --max-time 15 -H 'Accept: application/vnd.github+json' \
      "$GITHUB_API/repos/$repo/releases/latest" 2>/dev/null | json get tag_name 2>/dev/null) || available=''
    available=${available#v}
    [[ "$available" =~ ^[0-9]+[.][0-9]+[.][0-9]+[^[:space:]]*$ ]] || available=''
  fi
  installed=${installed:-unknown}
  available=${available:-unknown}
  if [ "$installed" != unknown ] && [ "$available" != unknown ] && [ "$installed" != "$available" ]; then
    printf 'VERSION orca %s (latest release %s; reported only, setup.sh never upgrades Orca)\n' "$installed" "$available"
  else
    printf 'VERSION orca %s (latest release %s)\n' "$installed" "$available"
  fi
  CHECK_VERSIONS+=("orca"$'\t'"$installed" "orca-latest"$'\t'"$available")
}

check_orca() {
  local status accounts settings lines targets skills reachable=yes
  if have "$ORCA_CLI"; then printf 'PRESENT orca CLI (%s)\n' "$(basename "$ORCA_CLI")"; record 0 'orca CLI' present
  else printf 'MISSING orca CLI\n'; missing=$((missing + 1)); record 1 'orca CLI' MISSING; return 0; fi
  check_orca_version
  if status=$("$ORCA_CLI" status --json 2>/dev/null) && printf '%s' "$status" | json has result.runtime.reachable; then
    report reachable 'Orca runtime'
  elif [ "$PLATFORM" = debian ] && [ "$(linux_role)" = client ]; then
    # A Linux client dials servers; it needs no runtime of its own. Skills are local files, so they are still checked.
    report 'not running (client; not counted)' 'Orca runtime'
    reachable=no
  else
    report UNREACHABLE 'Orca runtime'
    return 0
  fi
  lines=$(missing_skill_lines)
  if [ -z "$lines" ]; then report installed 'Orca skills'; else
    while IFS=$'\t' read -r targets skills; do report "MISSING $skills" 'Orca skills'; done <<<"$lines"
  fi
  [ "$reachable" = yes ] || return 0
  if accounts=$(orca_rpc accounts.list); then
    if printf '%s' "$accounts" | json has codex.activeAccountId; then report selected 'Orca Codex'; auth_state codex complete 0
    else report PENDING 'Orca Codex'; auth_state codex pending 1; fi
    if printf '%s' "$accounts" | json has claude.activeAccountId; then report selected 'Orca Claude'; auth_state claude complete 0
    else report 'not selected' 'Orca Claude'; auth_state claude not-selected 0; fi
  else
    report 'PENDING (accounts.list failed)' 'Orca accounts'
    auth_state codex pending 1
  fi
  if settings=$(orca_rpc settings.get); then
    lines=$(printf '%s' "$settings" | json get settings | json diff "$(desired_settings)" | tr '\n' ' ')
    lines=${lines% }
    if [ -z "$lines" ]; then report aligned 'Orca settings'; else report "differs (${lines}); --apply aligns them" 'Orca settings'; fi
  fi
  if [ "$task_source" = linear ] || [ "$(printf '%s' "${settings:-}" | json get settings.defaultTaskSource 2>/dev/null)" = linear ]; then
    if orca_rpc linear.status | json has connected; then report connected 'Linear'; auth_state linear complete 0
    elif [ "$task_source" = linear ]; then report PENDING 'Linear'; auth_state linear pending 1
    else report 'not connected (task source is linear; add --task-source linear to require it)' 'Linear'; auth_state linear not-connected 0; fi
  fi
}

# check_module <name>: a requested module's manifest rows and its own items; a skipped module counts nothing.
check_module() {
  if module_skipped "$1" check; then report "skipped ($MODULE_SKIP_REASON; not counted)" "Module $1"; return 0; fi
  check_tools "$(group_manifest "$1")" "$1"
  if has_function "$(module_function "$1" check)"; then "$(module_function "$1" check)"; fi
}

# The role check reads local pairing stores, so it runs even when the Orca runtime is unreachable.
DETECTED_ROLE=unknown
check_role() {
  local role_output role_status=0
  if [ -n "$role" ]; then role_output=$(bash "$ORCA_SETUP_ROOT/orca/role.sh" --expect "$role") || role_status=$?
  else role_output=$(bash "$ORCA_SETUP_ROOT/orca/role.sh") || role_status=$?; fi
  DETECTED_ROLE=$(printf '%s\n' "$role_output" | sed -n '1s/^ROLE //p')
  printf '%s\n' "$role_output" | sed '1s/^ROLE /Pairing role: /'
  case "$role_status" in
    0) ;;
    1) report CONFLICT 'Pairing role check' ;;
    *) report UNREACHABLE 'Pairing role check' ;;
  esac
}

# The Docker host's items inside the container (ORCA_SETUP_HOST_ITEMS, "counted<TAB>label<TAB>state" lines, and
# ORCA_SETUP_HOST_DEVICE and ORCA_SETUP_HOST_SERVER), when the host's setup.sh --check asks the container for the
# combined report. Without them the host cannot be seen from here.
SERVER_FIELDS=()
container_host_items() {
  local counted label state key value
  if [ -z "${ORCA_SETUP_HOST_ITEMS:-}" ]; then
    report 'not visible from inside the container (run ./setup.sh --check on the host; not counted)' 'Docker host'
    SERVER_FIELDS=("host"$'\t'"not-checked")
    return 0
  fi
  while IFS=$'\t' read -r counted label state; do
    [ -n "$label" ] || continue
    [ "$counted" = 1 ] || counted=0
    printf '%s: %s\n' "$label" "$state"
    missing=$((missing + counted))
    record "$counted" "$label" "$state"
  done <<<"$ORCA_SETUP_HOST_ITEMS"
  while IFS=$'\t' read -r key value; do
    [ -z "$key" ] || SERVER_FIELDS+=("$key"$'\t'"$value")
  done <<<"${ORCA_SETUP_HOST_SERVER:-}"
}

# The distribution the report names: the Docker host's when it asked the container for the report.
report_distro() {
  if in_container && [ -n "${ORCA_SETUP_HOST_DEVICE:-}" ]; then printf '%s\n' "$ORCA_SETUP_HOST_DEVICE"; else detect_distro; fi
}

check_body() {
  local name
  if in_container && [ -n "${ORCA_SETUP_HOST_DEVICE:-}" ]; then
    info "Device: $(report_distro) $ARCH (Docker host; the $ORCA_SERVER_NAME container runs $(detect_distro)), Orca CLI: $ORCA_CLI"
  else
    info "Device: $(detect_distro) $ARCH, package manager: $(detect_pkg_manager), Orca CLI: $ORCA_CLI$(device_note)"
  fi
  ! in_container || container_host_items
  check_tools baseline.tsv baseline
  check_tools agents.tsv baseline
  if [ "$PLATFORM" = debian ] && ! in_container; then process_path_block check; fi
  for name in $modules; do check_module "$name"; done
  check_versions
  if have gh && gh auth status --hostname github.com >/dev/null 2>&1; then report PASS 'GitHub auth'; auth_state gh complete 0
  else report PENDING 'GitHub auth'; auth_state gh pending 1; fi
  check_orca
  check_role
  if have node; then
    if AUDIT_LINE=$(node "$ORCA_SETUP_ROOT/audit/readiness.cjs"); then printf '%s\n' "$AUDIT_LINE"
    else AUDIT_LINE=''; report 'MISSING (audit failed)' 'Readiness audit'; fi
  fi
}

# print_check_json: the report as one JSON document. Labels, states, names, counts and versions only; the audit is
# the READINESS_JSON object, which holds names and booleans only.
print_check_json() {
  local entry counted label state name value audit sep
  audit=${AUDIT_LINE#READINESS_JSON }
  [ -n "$audit" ] || audit=null
  printf '{\n  "schema": "orca-setup-check/1",\n'
  printf '  "device": {"os": %s, "distro": %s, "arch": %s},\n' "$(json_string "$OS")" "$(json_string "$(report_distro)")" "$(json_string "$ARCH")"
  printf '  "role": {"requested": %s, "detected": %s},\n' "$(if [ -n "$role" ]; then json_string "$role"; else echo null; fi)" "$(json_string "${DETECTED_ROLE:-unknown}")"
  # A Linux server in Docker (README section 6.7) adds what its host reported: image, newest digest, container state
  # and workdir.
  if in_container || [ "$SERVER_HOST" = yes ]; then
    printf '  "server": {"form": "docker"'
    for entry in ${SERVER_FIELDS[@]+"${SERVER_FIELDS[@]}"}; do
      IFS=$'\t' read -r name value <<<"$entry"
      printf ', %s: %s' "$(json_string "$name")" "$(json_string "$value")"
    done
    printf '},\n'
  fi
  printf '  "modules": ['
  sep=''
  for name in $modules; do printf '%s%s' "$sep" "$(json_string "$name")"; sep=', '; done
  printf '],\n  "missing": %s,\n  "items": [' "$missing"
  sep=''
  for entry in ${CHECK_ITEMS[@]+"${CHECK_ITEMS[@]}"}; do
    IFS=$'\t' read -r counted label state <<<"$entry"
    printf '%s\n    {"name": %s, "state": %s, "counted": %s}' "$sep" "$(json_string "$label")" "$(json_string "$state")" \
      "$(if [ "$counted" = 1 ]; then echo true; else echo false; fi)"
    sep=','
  done
  printf '\n  ],\n  "auth": ['
  sep=''
  for entry in ${CHECK_AUTH[@]+"${CHECK_AUTH[@]}"}; do
    IFS=$'\t' read -r name state counted <<<"$entry"
    printf '%s\n    {"name": %s, "state": %s, "counted": %s}' "$sep" "$(json_string "$name")" "$(json_string "$state")" \
      "$(if [ "$counted" = 1 ]; then echo true; else echo false; fi)"
    sep=','
  done
  printf '\n  ],\n  "versions": {'
  sep=''
  for entry in ${CHECK_VERSIONS[@]+"${CHECK_VERSIONS[@]}"}; do
    IFS=$'\t' read -r name value <<<"$entry"
    printf '%s%s: %s' "$sep" "$(json_string "$name")" "$(json_string "$value")"
    sep=', '
  done
  printf '},\n  "audit": %s\n}\n' "$audit"
}

# server_host_report: the host's collected items as a report of their own, when the container cannot add its part.
server_host_report() {
  local entry label state
  info "Device: $(detect_distro) $ARCH, package manager: $(detect_pkg_manager), Orca CLI: $ORCA_CLI$(device_note)"
  for entry in ${HOST_ITEMS[@]+"${HOST_ITEMS[@]}"}; do
    IFS=$'\t' read -r _ label state <<<"$entry"
    report "$state" "$label"
  done
  report "UNREACHABLE (the $ORCA_SERVER_NAME container is not running; ./setup.sh --apply --role server starts it)" \
    'Container checks (tools, logins, Orca)'
}

# server_host_check: --check on a Docker server host. The host's items (Docker, the docker group, the image, the
# container, the mounts, and the host modules) are collected, then the container's setup.sh prints the one combined
# report with them and with its own tools, logins and Orca, and its exit code is the total. Without a running
# container only the host's items can be reported.
server_host_check() {
  local name status=0 args=()
  REPORT_COLLECT=yes
  server_check_host "$WORKDIR"
  for name in $modules; do
    case "$name" in power | gpu | apple) check_module "$name" ;; esac
  done
  REPORT_COLLECT=no
  if [ "$SERVER_CONTAINER" = running ]; then
    while IFS= read -r name; do args+=("$name"); done < <(server_setup_args yes --check)
    [ "$check_json" = no ] || args+=(--json)
    server_exec_setup --env "ORCA_SETUP_HOST_ITEMS=$(printf '%s\n' ${HOST_ITEMS[@]+"${HOST_ITEMS[@]}"})" \
      --env "ORCA_SETUP_HOST_DEVICE=$(detect_distro)" \
      --env "ORCA_SETUP_HOST_SERVER=$(printf '%s\n' ${SERVER_INFO[@]+"${SERVER_INFO[@]}"})" -- "${args[@]}" || status=$?
    exit "$status"
  fi
  SERVER_FIELDS=(${SERVER_INFO[@]+"${SERVER_INFO[@]}"})
  if [ "$check_json" = yes ]; then
    server_host_report >/dev/null
    print_check_json
  else
    server_host_report
    info "MISSING_ITEMS $missing"
  fi
  [ "$missing" -le 255 ] || missing=255
  exit "$missing"
}

do_check() {
  [ "$SUPPORT" = supported ] || die "unsupported device: $(detect_unsupported_reason)"
  [ "$SERVER_HOST" = no ] || server_host_check
  if [ "$check_json" = yes ]; then
    check_body >/dev/null
    print_check_json
  else
    check_body
    info "MISSING_ITEMS $missing"
  fi
  [ "$missing" -le 255 ] || missing=255
  exit "$missing"
}

# ---------------------------------------------------------------- auth

do_auth() {
  local name
  [ "$SUPPORT" = supported ] || die "unsupported device: $(detect_unsupported_reason)"
  # On a Docker server every login happens inside the container, where the agents and Orca run.
  # shellcheck disable=SC2086 # a space-separated list of names
  if [ "$SERVER_HOST" = yes ]; then server_auth $auths; return; fi
  for name in $auths; do "auth_${name}"; done
}

case "$action" in
  plan) do_plan ;;
  apply) do_apply ;;
  check) do_check ;;
  auth) do_auth ;;
esac
