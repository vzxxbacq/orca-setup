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
# shellcheck source=lib/orca-serve.sh
. "$ORCA_SETUP_ROOT/lib/orca-serve.sh"
for file in "$ORCA_SETUP_ROOT"/modules/*.sh "$ORCA_SETUP_ROOT"/auth/*.sh; do
  # shellcheck source=/dev/null
  . "$file"
done

MODULES='power containers apple android media agent-gemini'
AUTHS='gh codex claude agy linear'
TASK_SOURCES='linear'

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--plan | --apply | --check] [--role client|server] [--pairing-address ADDRESS] [modules]
                  [--task-source linear]
       ./setup.sh --auth-gh | --auth-codex | --auth-claude | --auth-agy | --auth-linear

  --plan         Print what --apply would do on this device (default; read-only).
  --apply        Install missing baseline tools and agents, install Orca skills, align Orca defaults,
                 then run the selected modules. Requires --role.
  --check        Read-only readiness report; the exit code is the number of missing items.
  --role R       Pairing role of this device: client (dials servers) or server (is dialed).
  --pairing-address ADDRESS
                 Linux servers: the private IPv4 address or host name clients dial (Tailscale, LAN,
                 WireGuard). Required for --apply --role server on Linux; never 127.0.0.1 or a wildcard.
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
pairing_address=''
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
    --pairing-address | --pairing-address=*)
      if [ "$1" = --pairing-address ]; then [ $# -ge 2 ] || die '--pairing-address needs an address'; pairing_address=$2; shift
      else pairing_address=${1#--pairing-address=}; fi ;;
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

if [ -n "$pairing_address" ]; then
  [ "$PLATFORM" = debian ] || die '--pairing-address is for Linux servers; on macOS choose the address in Orca: Settings > Remote Orca Servers.'
  [ "$role" != client ] || die '--pairing-address is for --role server; a client never serves or advertises an address.'
  problem=$(pairing_address_problem "$pairing_address")
  [ -z "$problem" ] || die "--pairing-address $pairing_address is refused: $problem. Use the private address clients dial (README section 1)."
fi

# ---------------------------------------------------------------- helpers

orca_rpc() {
  local params=${2:-}
  [ -n "$params" ] || params='{}'
  bash "$ORCA_SETUP_ROOT/orca/orca-rpc.sh" local "$1" "$params" 2>/dev/null
}

json() { node "$ORCA_SETUP_ROOT/lib/json.cjs" "$@"; }

# Auth modes that work on Linux: gh, and the Orca accounts (`orca-ide account add` on this device).
linux_auth() { case "$1" in gh | codex | claude) return 0 ;; *) return 1 ;; esac; }

# linux_role: the role the Linux Orca checks assume: --role, else server when the serve unit exists, else client.
linux_role() {
  if [ -n "$role" ]; then echo "$role"
  elif [ -e "$(serve_unit_path)" ]; then echo server
  else echo client; fi
}

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
    apt:*) printf 'apt %s' "${1#apt:}" ;;
    apt-repo:*) printf 'apt %s from %s' "${1##*:}" "$(apt_repo_uri "$(printf '%s' "${1#apt-repo:}" | cut -d: -f1)")" ;;
    uv-python:*) printf 'uv python install %s' "${1#uv-python:}" ;;
    uv-tool:*) printf 'uv tool install %s' "${1#uv-tool:}" ;;
    orca-deb:*) printf '.deb from the latest stable %s release' "$(printf '%s' "${1#orca-deb:}" | cut -d: -f1)" ;;
    *) printf '%s' "$1" ;;
  esac
}

# row_present <check> <method>: detected through the check command, or through the package manager.
# A "-" check on an apt row means only dpkg can tell.
row_present() {
  case "$2" in
    apt:* | apt-repo:* | orca-deb:*) { [ "$1" != - ] && is_present "$1"; } || debian_installed "$2" ;;
    brew:* | cask:*) is_present "$1" || macos_installed "$2" ;;
    *) is_present "$1" ;;
  esac
}

# platform_rows <file.tsv> <group>: the group's rows for this platform, in install order.
platform_rows() {
  if [ "$PLATFORM" = debian ]; then manifest_select "$1" debian "$2" | debian_order; else manifest_select "$1" "$PLATFORM" "$2"; fi
}

# install_row <method>: install one missing row with its method.
install_row() {
  case "$1" in
    npm:*) npm_install "${1#npm:}" ;;
    installer:*) run_installer "${1#installer:}" ;;
    uv-python:*) have uv || die 'uv is required to install Python.'; step uv python install "${1#uv-python:}" ;;
    uv-tool:*) have uv || die "uv is required to install ${1#uv-tool:}."; step uv tool install "${1#uv-tool:}" ;;
    apt:* | apt-repo:* | orca-deb:*) debian_install "$1" ;;
    *) macos_install "$1" ;;
  esac
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
      debian_plan "$method"
      continue
    fi
    install_row "$method"
    row_present "$check" "$method" || die "$name is still missing after installation"
  done 3< <(platform_rows "$file" "$group")
}

# The PATH block in ~/.profile and ~/.zshrc (Linux): $1 = plan|apply|check.
process_path_block() {
  local file
  for file in $(path_block_files); do
    if path_block_present "$HOME/$file"; then
      case "$1" in plan) printf '  present  PATH block in ~/%s\n' "$file" ;; *) printf 'PRESENT PATH block in ~/%s\n' "$file" ;; esac
      continue
    fi
    case "$1" in
      plan) printf '  add      PATH block in ~/%-11s puts ~/.local/bin and ~/.grok/bin on PATH (marked block)\n' "$file" ;;
      apply) path_block_add "$HOME/$file" ;;
      check) printf 'MISSING PATH block in ~/%s\n' "$file"; missing=$((missing + 1)) ;;
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
  # On a fresh Linux device the check needs the Node.js that the baseline installs.
  [ "$detected" != unknown ] || [ "$PLATFORM" != debian ] || have node || detected='unknown until Node.js is installed'
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
  local name selected
  if [ "$PLATFORM" = debian ]; then
    info 'Optional modules: Linux versions arrive in P3; --apply skips them on Linux.'
    for name in $MODULES; do printf '  --%s\n' "$name"; done
    return 0
  fi
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
  [ "$SUPPORT" = supported ] || die "$(detect_unsupported_reason) --apply refuses this device."
  print_role_plan
  if [ "$PLATFORM" = debian ]; then
    if have sudo; then info 'sudo: present; --apply runs only the sudo commands listed below as root'
    else info 'sudo: missing; --apply needs it for the sudo commands listed below'; fi
  elif have brew; then
    info 'Homebrew: present'
  else
    info 'Homebrew: missing; install it from https://brew.sh first (--apply stops without it)'
  fi
  info 'Baseline tools (--apply):'
  process_group plan baseline baseline.tsv
  info 'Agent CLIs (--apply):'
  process_group plan baseline agents.tsv
  if [ "$PLATFORM" = debian ]; then
    info 'PATH (--apply):'
    process_path_block plan
    info 'Pairing role check (--apply): after the baseline install, before any Orca step'
    case "$role" in
      server) serve_plan "$pairing_address" ;;
      client) info 'Orca client: Orca and its CLI only; no server unit and no pairing offer on this device' ;;
      *) info 'Orca server unit: only with --role server --pairing-address <ip-or-host> (README section 3.3.2)' ;;
    esac
  fi
  print_orca_plan
  print_module_plan
  info 'Authentication (interactive, run on their own):'
  for name in $AUTHS; do
    if [ "$PLATFORM" = debian ] && ! linux_auth "$name"; then printf '  --auth-%-8s %s\n' "$name" 'Linux: arrives in P3.'
    else printf '  --auth-%-8s %s\n' "$name" "$("auth_${name}_describe")"; fi
  done
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
    [ "$PLATFORM" != debian ] || die "the Orca server does not answer settings.get; see: systemctl --user status $ORCA_SERVE_UNIT"
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

# The Orca .deb may not declare every library its Electron runtime loads (README section 3.3.1): name the missing
# ones before any Orca step instead of failing later inside orca-ide.
require_orca_libraries() {
  local libs
  have ldd || return 0
  libs=$(ldd "$(orca_executable)" 2>/dev/null | awk '/not found/ { print $1 }' | paste -sd ' ' -)
  [ -z "$libs" ] ||
    die "orca-ide cannot start: its runtime needs $libs, which the Orca .deb does not install; add their packages to manifest/local/baseline.tsv and rerun --apply."
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

do_apply() {
  local name
  [ "$SUPPORT" = supported ] || die "unsupported device: $(detect_unsupported_reason)"
  if [ "$PLATFORM" = debian ]; then
    have sudo || die 'sudo is required for the apt steps; install it and add your user to the sudo group.'
    [ "$role" != server ] || [ -n "$pairing_address" ] ||
      die '--apply --role server on Linux requires --pairing-address <ip-or-host>, the private address clients dial (README section 3.3.2).'
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
  if [ "$PLATFORM" = debian ] && [ "$role" = server ]; then serve_apply "$pairing_address"; fi
  apply_orca
  if [ "$PLATFORM" = debian ]; then
    for name in $modules; do info "SKIP module $name: Linux support arrives in P3"; done
    info 'BASELINE_DONE'
    return 0
  fi
  for name in $modules; do
    info "MODULE $name"
    process_group apply "$name" "$(group_manifest "$name")"
    if has_function "$(module_function "$name" apply)"; then "$(module_function "$name" apply)"; fi
  done
  info 'BASELINE_DONE'
}

# ---------------------------------------------------------------- check

missing=0
# report <state> <label>: print "label: state"; PENDING, MISSING, UNREACHABLE, CONFLICT, INACTIVE and OFF states
# count as missing.
report() {
  printf '%s: %s\n' "$2" "$1"
  case "$1" in PENDING* | MISSING* | CONFLICT* | UNREACHABLE* | INACTIVE* | OFF*) missing=$((missing + 1)) ;; esac
}

check_tools() { # check_tools <manifest> <group>
  local name check method
  while IFS=$'\t' read -r name check method; do
    if row_present "$check" "$method"; then printf 'PRESENT %s\n' "$name"; else printf 'MISSING %s\n' "$name"; missing=$((missing + 1)); fi
  done < <(platform_rows "$1" "$2")
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
  local status accounts settings lines targets skills reachable=yes
  if have "$ORCA_CLI"; then printf 'PRESENT orca CLI (%s)\n' "$(basename "$ORCA_CLI")"; else printf 'MISSING orca CLI\n'; missing=$((missing + 1)); return 0; fi
  if [ "$PLATFORM" = debian ] && [ "$(linux_role)" = server ]; then serve_check; fi
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
  [ "$SUPPORT" = supported ] || die "unsupported device: $(detect_unsupported_reason)"
  info "Device: $(detect_distro) $ARCH, package manager: $(detect_pkg_manager), Orca CLI: $ORCA_CLI"
  check_tools baseline.tsv baseline
  check_tools agents.tsv baseline
  if [ "$PLATFORM" = debian ]; then process_path_block check; fi
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
  [ "$SUPPORT" = supported ] || die "unsupported device: $(detect_unsupported_reason)"
  if [ "$PLATFORM" = debian ]; then
    for name in $auths; do linux_auth "$name" || die "--auth-$name on Linux arrives in P3; --auth-gh, --auth-codex and --auth-claude work now."; done
  fi
  for name in $auths; do "auth_${name}"; done
}

case "$action" in
  plan) do_plan ;;
  apply) do_apply ;;
  check) do_check ;;
  auth) do_auth ;;
esac
