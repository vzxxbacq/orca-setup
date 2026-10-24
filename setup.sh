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
# shellcheck source=lib/npm-tools.sh
. "$ORCA_SETUP_ROOT/lib/npm-tools.sh"
for file in "$ORCA_SETUP_ROOT"/modules/*.sh "$ORCA_SETUP_ROOT"/auth/*.sh; do
  # shellcheck source=/dev/null
  . "$file"
done

MODULES='power containers apple android media agent-gemini'
AUTHS='gh codex claude agy linear'
TASK_SOURCES='linear'

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--plan | --apply | --check] [--role client|server] [modules] [--task-source linear]
       ./setup.sh --auth-gh | --auth-codex | --auth-claude | --auth-agy | --auth-linear

  --plan         Print what --apply would do on this device (default; read-only).
  --apply        Install missing baseline tools and agents, install Orca skills, align Orca defaults,
                 then run the selected modules. Requires --role.
  --check        Read-only readiness report; the exit code is the number of missing items.
  --role R       Pairing role of this device: client (dials servers) or server (is dialed).
  --task-source linear
                 Also make Linear Orca's task source (--apply), and require it to be connected (--check).

Optional modules (run only together with --apply):
  --power --containers --apple --android --media --agent-gemini

Interactive authentication (run one or more on their own):
  --auth-gh --auth-codex --auth-claude --auth-agy --auth-linear
EOF
}

# ---------------------------------------------------------------- arguments

action=''
role=''
task_source=''
modules=''
auths=''

set_action() {
  [ -z "$action" ] || [ "$action" = "$1" ] || die "choose only one of --plan, --apply, --check and --auth-*"
  action=$1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) set_action plan ;;
    --apply) set_action apply ;;
    --check) set_action check ;;
    --role | --role=*)
      if [ "$1" = --role ]; then [ $# -ge 2 ] || die '--role needs client or server'; role=$2; shift; else role=${1#--role=}; fi
      case "$role" in client | server) ;; *) die "--role must be client or server, not: $role" ;; esac ;;
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
case "$action" in auth | check) [ -z "$modules" ] || die "modules run only with --apply (or show with --plan): $modules" ;; esac
[ "$action" != apply ] || [ -n "$role" ] || die '--apply requires --role client or --role server (README section 5.1).'

require_non_root
setup_environment

OS=$(detect_os)
ARCH=$(detect_arch)
SUPPORT=$(detect_support)
ORCA_CLI=$(detect_orca_cli)
PLATFORM=''
[ "$OS" = macos ] && PLATFORM=macos
[ "$OS" = linux ] && [ "$(detect_linux_family)" = debian ] && PLATFORM=debian

# ---------------------------------------------------------------- helpers

orca_rpc() {
  local params=${2:-}
  [ -n "$params" ] || params='{}'
  bash "$ORCA_SETUP_ROOT/orca/orca-rpc.sh" local "$1" "$params" 2>/dev/null
}

json() { node "$ORCA_SETUP_ROOT/lib/json.cjs" "$@"; }

module_function() { printf 'module_%s_%s\n' "${1//-/_}" "$2"; }

has_function() { declare -F "$1" >/dev/null; }

# Which manifest a group lives in.
group_manifest() {
  case "$1" in agent-*) echo agents.tsv ;; *) echo baseline.tsv ;; esac
}

method_label() {
  case "$1" in
    brew:*) printf 'brew formula %s' "${1#brew:}" ;;
    cask:*) printf 'brew cask %s' "${1#cask:}" ;;
    npm:*) printf 'npm %s -> ~/.local' "${1#npm:}" ;;
    installer:*) printf 'official installer %s' "${1#installer:}" ;;
    os) printf 'shipped with macOS (Command Line Tools)' ;;
    *) printf '%s' "$1" ;;
  esac
}

# row_present <check> <method>: detected through the check command, or through the package manager.
row_present() {
  is_present "$1" && return 0
  case "$2" in brew:* | cask:*) macos_installed "$2" ;; *) return 1 ;; esac
}

# Print or apply one manifest group; $1 = plan|apply, $2 = group, $3 = manifest file.
process_group() {
  local mode=$1 group=$2 file=$3 name check method
  while IFS=$'\t' read -r name check method <&3; do
    if row_present "$check" "$method"; then
      if [ "$mode" = plan ]; then printf '  present  %s\n' "$name"; else printf 'PRESENT %s\n' "$name"; fi
      continue
    fi
    if [ "$mode" = plan ]; then
      if [ "$method" = os ]; then printf '  missing  %-22s %s\n' "$name" "$(method_label "$method")"
      else printf '  install  %-22s %s\n' "$name" "$(method_label "$method")"; fi
      continue
    fi
    case "$method" in
      npm:*) npm_install "${method#npm:}" ;;
      installer:*) run_installer "${method#installer:}" ;;
      *) macos_install "$method" ;;
    esac
    is_present "$check" || macos_installed "$method" || die "$name is still missing after installation"
  done 3< <(manifest_select "$file" "$PLATFORM" "$group")
}

# Desired Orca settings for this run, as JSON.
desired_settings() { json settings "${task_source:--}"; }

# Skills that `orca skills install` would add: "targets<TAB>skill ..." lines limited to missing skills.
missing_skill_lines() {
  local installed targets skills missing
  installed=''
  if have node; then installed=$("$ORCA_CLI" skills installed --json 2>/dev/null) || installed=''; fi
  while IFS=$'\t' read -r targets skills; do
    # shellcheck disable=SC2086 # skills is a space-separated list
    if [ -n "$installed" ]; then missing=$(printf '%s' "$installed" | json missing $skills | tr '\n' ' '); else missing="$skills"; fi
    missing=${missing% }
    [ -z "$missing" ] || printf '%s\t%s\n' "$targets" "$missing"
  done < <(skills_for "$PLATFORM")
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
    info "  present  skills $(skills_for "$PLATFORM" | cut -f2 | paste -sd ' ' -)"
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
  else
    info "  update   settings (Orca runtime not reachable): $desired"
  fi
  if [ -z "$task_source" ]; then info '  task source: unchanged (opt in with --task-source linear)'; fi
}

print_module_plan() {
  local name selected
  info 'Optional modules (add to --apply):'
  for name in $MODULES; do
    selected=''
    case " $modules " in *" $name "*) selected=' [selected]' ;; esac
    printf '  --%-13s %s%s\n' "$name" "$("$(module_function "$name" describe)")" "$selected"
    [ -n "$selected" ] || continue
    process_group plan "$name" "$(group_manifest "$name")" | sed "s/^/  /"
    if has_function "$(module_function "$name" plan)"; then "$(module_function "$name" plan)"; fi
  done
}

do_plan() {
  local name
  info 'orca-setup plan (read-only; nothing is changed)'
  info "Device: $(detect_distro) $ARCH, package manager: $(detect_pkg_manager), desktop: $(detect_desktop), Orca CLI: $ORCA_CLI"
  case "$SUPPORT" in
    planned)
      info 'Linux packaging is not implemented in P0 (planned for P1; Orca on Linux in P2): --apply would stop here.'
      return 0 ;;
    unsupported)
      info "This device is not supported (macOS arm64/x86_64; Ubuntu 24.04 / Debian 12 x86_64 planned)."
      return 0 ;;
  esac
  print_role_plan
  if have brew; then
    info 'Homebrew: present'
  else
    info 'Homebrew: missing; install it from https://brew.sh first (--apply stops without it)'
  fi
  info 'Baseline tools (--apply):'
  process_group plan baseline baseline.tsv
  info 'Agent CLIs (--apply):'
  process_group plan baseline agents.tsv
  print_orca_plan
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

do_apply() {
  local name role_status
  [ "$SUPPORT" = supported ] || die "--apply is not implemented for this device in P0 ($(detect_distro) $ARCH)."
  have brew || die 'Install Homebrew first: https://brew.sh'
  role_status=0
  bash "$ORCA_SETUP_ROOT/orca/role.sh" --expect "$role" || role_status=$?
  case "$role_status" in
    0) ;;
    1) die "this device already holds the other pairing role; remove the pairings listed above before --apply --role $role." ;;
    *) die 'the pairing role cannot be determined (see the reason above); refusing --apply.' ;;
  esac
  process_group apply baseline baseline.tsv
  process_group apply baseline agents.tsv
  apply_orca
  for name in $modules; do
    info "MODULE $name"
    process_group apply "$name" "$(group_manifest "$name")"
    if has_function "$(module_function "$name" apply)"; then "$(module_function "$name" apply)"; fi
  done
  info 'BASELINE_DONE'
}

# ---------------------------------------------------------------- check

missing=0
# report <state> <label>: print "label: state"; PENDING, MISSING, UNREACHABLE and CONFLICT states count as missing.
report() {
  printf '%s: %s\n' "$2" "$1"
  case "$1" in PENDING* | MISSING* | CONFLICT* | UNREACHABLE*) missing=$((missing + 1)) ;; esac
}

check_tools() { # check_tools <manifest> <group>
  local name check method
  while IFS=$'\t' read -r name check method; do
    if row_present "$check" "$method"; then printf 'PRESENT %s\n' "$name"; else printf 'MISSING %s\n' "$name"; missing=$((missing + 1)); fi
  done < <(manifest_select "$1" "$PLATFORM" "$2")
}

check_versions() {
  local tool version
  for tool in node pnpm python3.12 uv bun; do
    have "$tool" || continue
    version=$("$tool" --version 2>/dev/null | head -n 1) || version=unknown
    printf 'VERSION %s %s\n' "$tool" "$version"
  done
}

check_orca() {
  local status accounts settings lines targets skills
  if have "$ORCA_CLI"; then printf 'PRESENT orca CLI (%s)\n' "$(basename "$ORCA_CLI")"; else printf 'MISSING orca CLI\n'; missing=$((missing + 1)); return 0; fi
  if status=$("$ORCA_CLI" status --json 2>/dev/null) && printf '%s' "$status" | json has result.runtime.reachable; then
    report reachable 'Orca runtime'
  else
    report UNREACHABLE 'Orca runtime'
    return 0
  fi
  lines=$(missing_skill_lines)
  if [ -z "$lines" ]; then report installed 'Orca skills'; else
    while IFS=$'\t' read -r targets skills; do report "MISSING $skills" 'Orca skills'; done <<<"$lines"
  fi
  if accounts=$(orca_rpc accounts.list); then
    if printf '%s' "$accounts" | json has codex.activeAccountId; then report selected 'Orca Codex'; else report PENDING 'Orca Codex'; fi
    if printf '%s' "$accounts" | json has claude.activeAccountId; then report selected 'Orca Claude'; else report 'not selected' 'Orca Claude'; fi
  else
    report 'PENDING (accounts.list failed)' 'Orca accounts'
  fi
  if settings=$(orca_rpc settings.get); then
    lines=$(printf '%s' "$settings" | json get settings | json diff "$(desired_settings)" | tr '\n' ' ')
    lines=${lines% }
    if [ -z "$lines" ]; then report aligned 'Orca settings'; else report "differs (${lines}); --apply aligns them" 'Orca settings'; fi
  fi
  if [ "$task_source" = linear ] || [ "$(printf '%s' "${settings:-}" | json get settings.defaultTaskSource 2>/dev/null)" = linear ]; then
    if orca_rpc linear.status | json has connected; then report connected 'Linear'
    elif [ "$task_source" = linear ]; then report PENDING 'Linear'
    else report 'not connected (task source is linear; add --task-source linear to require it)' 'Linear'; fi
  fi
}

# The role check reads local pairing stores, so it runs even when the Orca runtime is unreachable.
check_role() {
  local role_output role_status=0
  if [ -n "$role" ]; then role_output=$(bash "$ORCA_SETUP_ROOT/orca/role.sh" --expect "$role") || role_status=$?
  else role_output=$(bash "$ORCA_SETUP_ROOT/orca/role.sh") || role_status=$?; fi
  printf '%s\n' "$role_output" | sed '1s/^ROLE /Pairing role: /'
  case "$role_status" in
    0) ;;
    1) report CONFLICT 'Pairing role check' ;;
    *) report UNREACHABLE 'Pairing role check' ;;
  esac
}

do_check() {
  [ "$SUPPORT" != unsupported ] || die "unsupported device: $(detect_distro) $ARCH"
  info "Device: $(detect_distro) $ARCH, package manager: $(detect_pkg_manager), Orca CLI: $ORCA_CLI"
  if [ -z "$PLATFORM" ] || [ "$SUPPORT" = planned ]; then
    info 'Linux checks are not implemented in P0 (planned for P1/P2).'
    exit 1
  fi
  check_tools baseline.tsv baseline
  check_tools agents.tsv baseline
  check_versions
  if have gh && gh auth status --hostname github.com >/dev/null 2>&1; then report PASS 'GitHub auth'; else report PENDING 'GitHub auth'; fi
  check_orca
  check_role
  if have node; then node "$ORCA_SETUP_ROOT/audit/readiness.cjs" || report 'MISSING (audit failed)' 'Readiness audit'; fi
  info "MISSING_ITEMS $missing"
  [ "$missing" -le 255 ] || missing=255
  exit "$missing"
}

# ---------------------------------------------------------------- auth

do_auth() {
  local name
  [ "$SUPPORT" = supported ] || die "--auth-* is not implemented for this device in P0 ($(detect_distro) $ARCH)."
  for name in $auths; do "auth_${name}"; done
}

case "$action" in
  plan) do_plan ;;
  apply) do_apply ;;
  check) do_check ;;
  auth) do_auth ;;
esac
