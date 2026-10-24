# shellcheck shell=bash
# Shared helpers: logging, non-root check, umask, PATH and idempotency checks.
# Sourced by setup.sh and the scripts under orca/; never executed directly.

ORCA_SETUP_ROOT=${ORCA_SETUP_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
ORCA_SETUP_MANIFEST_DIR=${ORCA_SETUP_MANIFEST_DIR:-$ORCA_SETUP_ROOT/manifest}

info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Print a command, then run it. Used for every state-changing step of --apply.
step() {
  printf '+ %s\n' "$*"
  "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

require_non_root() {
  [ "$(id -u)" -ne 0 ] || die 'Run as your regular user, without sudo.'
}

# Homebrew prefix on macOS; ORCA_SETUP_BREW_PREFIX overrides detection (tests use it).
brew_prefix() {
  if [ -n "${ORCA_SETUP_BREW_PREFIX:-}" ]; then
    printf '%s\n' "$ORCA_SETUP_BREW_PREFIX"
  elif [ -x /opt/homebrew/bin/brew ]; then
    printf '%s\n' /opt/homebrew
  else
    printf '%s\n' /usr/local
  fi
}

# User-level tool directories always come first; on macOS the Homebrew paths follow.
setup_path() {
  local prefix
  if [ "$(uname -s)" = Darwin ]; then
    prefix=$(brew_prefix)
    PATH="$prefix/opt/node@24/bin:$prefix/bin:$prefix/sbin:$PATH"
  fi
  PATH="$HOME/.local/bin:$HOME/.grok/bin:$PATH"
  export PATH
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_ANALYTICS=1
}

setup_environment() {
  umask 077
  setup_path
}

# is_present <check>: a manifest check spec is satisfied.
#   cmd        a command on PATH
#   a|b        any of several commands
#   app:Name   /Applications/Name.app exists (ORCA_SETUP_APPLICATIONS_DIR overrides the folder)
#   -          nothing to check
is_present() {
  local rest=$1 alt
  [ "$rest" = - ] && return 0
  while [ -n "$rest" ]; do
    alt=${rest%%|*}
    case "$alt" in
      app:*) [ -d "${ORCA_SETUP_APPLICATIONS_DIR:-/Applications}/${alt#app:}.app" ] && return 0 ;;
      *) have "$alt" && return 0 ;;
    esac
    [ "$alt" = "$rest" ] && break
    rest=${rest#*|}
  done
  return 1
}

# Download an official installer script, syntax-check it, then run it. Nothing is piped into a shell.
run_installer() {
  local url=$1 stage status
  stage=$(mktemp -d "${TMPDIR:-/tmp}/orca-setup.XXXXXX")
  status=0
  {
    step curl -q -fLsS --connect-timeout 10 --max-time 120 "$url" -o "$stage/install.sh" &&
      bash -n "$stage/install.sh" &&
      step bash "$stage/install.sh"
  } || status=$?
  rm -rf -- "$stage"
  return "$status"
}
