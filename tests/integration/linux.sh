#!/usr/bin/env bash
# Linux integration test, prepared by .github/workflows/ci.yml; never run it on a real machine.
#
#   linux.sh client   inside a fresh ubuntu:24.04 or debian:12 container (no systemd), as a non-root user with
#                     passwordless sudo: --apply --role client installs the baseline and the Orca .deb;
#   linux.sh server   directly on a GitHub-hosted Ubuntu 24.04 runner VM (systemd), as the runner user:
#                     --apply --role server also enables linger and starts the orca-serve user unit.
#
# Both modes then check that a second --apply changes nothing (no step lines, same packages, apt sources,
# keyrings, dotfiles and unit), that a login shell finds the user-level tools, that orca-ide runs, that no output
# carries a pairing URL, and that --check counts only interactive authentication items.
set -euo pipefail
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d)
mode=${1:-}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail 'run as a non-root user'
case "$mode" in
  client) [ -f /.dockerenv ] || [ -n "${CI:-}" ] || fail 'client mode is only for throwaway CI containers' ;;
  server)
    [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] ||
      fail 'server mode is only for GitHub-hosted runners'
    # The runner has no loopback-free private address to advertise; a test-only override allows 127.0.0.2.
    export ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS=1
    # The runner user has no login session; linger starts its user manager under /run/user/<uid>.
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} ;;
  *) fail 'usage: linux.sh client|server' ;;
esac
args=(--apply --role "$mode")
[ "$mode" = client ] || args+=(--pairing-address 127.0.0.2)
unit=$HOME/.config/systemd/user/orca-serve.service

# Everything --apply may change, in a comparable form.
state() {
  # shellcheck disable=SC2016 # dpkg-query format fields
  dpkg-query -W -f '${Package} ${Version}\n'
  find /etc/apt/keyrings /etc/apt/sources.list.d "$HOME/.local/bin" -maxdepth 1 -print 2>/dev/null | sort
  sha256sum /etc/apt/keyrings/* /etc/apt/sources.list.d/* "$HOME/.profile" "$HOME/.zshrc" "$unit" 2>/dev/null || true
  ls /var/lib/systemd/linger 2>/dev/null || true
}

# Pairing offers look like orca://pair?code=...; fail without printing the match.
no_pairing_secret() {
  if grep -qiE 'orca://pair|[?&#]code=' "$@"; then fail "a pairing URL or code appeared in: $*"; fi
}

echo '::group::first --apply'
"$repo/setup.sh" "${args[@]}" 2>&1 | tee "$work/first.log"
echo '::endgroup::'
grep -qx BASELINE_DONE "$work/first.log" || fail 'first --apply did not finish'
state >"$work/state-1"

echo '::group::second --apply'
"$repo/setup.sh" "${args[@]}" 2>&1 | tee "$work/second.log"
echo '::endgroup::'
state >"$work/state-2"
if grep -n '^+ ' "$work/second.log"; then fail 'the second --apply ran steps'; fi
# Only PRESENT items, skipped items and the pairing role report are allowed.
if grep -vE '^(PRESENT |SKIP |ROLE |saved environments: |runtime clients |mobile pairings: |BASELINE_DONE$)' "$work/second.log"; then
  fail 'the second --apply printed more than PRESENT lines'
fi
diff -u "$work/state-1" "$work/state-2" || fail 'the second --apply changed the system'
[ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.profile")" -eq 1 ] || fail 'the PATH block must appear once in .profile'
[ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.zshrc")" -eq 1 ] || fail 'the PATH block must appear once in .zshrc'

echo '::group::login shell PATH'
# shellcheck disable=SC2016 # expanded by the login shell
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin bash -lc \
  'for tool in node npm pnpm uv python3.12 ruff codex claude dsh dsh-tui pi bun omp grok agy gh orca-ide; do command -v "$tool" || exit 1; done
   for tool in node pnpm uv python3.12 ruff gh bun; do "$tool" --version || exit 1; done' ||
  fail 'a login shell does not find or cannot run the user-level tools'
echo '::endgroup::'

echo '::group::Orca'
dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' orca-ide
[ "$(readlink -f /usr/bin/orca-ide)" = /opt/Orca/resources/bin/orca-ide ] || fail '/usr/bin/orca-ide is not the .deb CLI shim'
orca-ide skills installed --json >"$work/skills.json" || fail 'orca-ide does not run'
for skill in orca-cli orca-linear computer-use; do
  node "$repo/lib/json.cjs" missing "$skill" <"$work/skills.json" | grep -q . && fail "skill $skill is not installed"
done
if [ "$mode" = client ]; then
  [ ! -e "$unit" ] || fail 'a client must not get the serve unit'
  if command -v systemd-analyze >/dev/null; then
    # shellcheck disable=SC2016 # expanded by the inner shell
    ORCA_SETUP_ROOT=$repo bash -c '. "$ORCA_SETUP_ROOT/lib/common.sh"; . "$ORCA_SETUP_ROOT/lib/orca-serve.sh"
      ORCA_CLI=orca-ide; serve_unit_render "$(serve_command)" 203.0.113.10' >"$work/orca-serve.service"
    systemd-analyze verify --man=no "$work/orca-serve.service" || fail 'the rendered unit does not pass systemd-analyze verify'
    echo 'systemd-analyze verify: ok'
  fi
else
  systemctl --user is-active --quiet orca-serve.service || fail 'orca-serve.service is not active'
  systemctl --user is-enabled --quiet orca-serve.service || fail 'orca-serve.service is not enabled'
  [ "$(loginctl show-user "$USER" --property=Linger --value)" = yes ] || fail 'linger is off'
  systemd-analyze --user verify --man=no "$unit" || fail 'the installed unit does not pass systemd-analyze verify'
  orca-ide status --json >"$work/status.json" || fail 'orca-ide status failed'
  node "$repo/lib/json.cjs" has result.runtime.reachable <"$work/status.json" || fail 'the Orca runtime is not reachable'
  journalctl --user -u orca-serve.service --no-pager >"$work/journal.log" 2>&1 || true
  no_pairing_secret "$work/status.json" "$work/journal.log"
  echo "journal: $(wc -l <"$work/journal.log") lines, no pairing URL"
fi
echo '::endgroup::'

echo '::group::--check'
status=0
"$repo/setup.sh" --check --role "$mode" >"$work/check.log" 2>&1 || status=$?
cat "$work/check.log"
echo '::endgroup::'
no_pairing_secret "$work/first.log" "$work/second.log" "$work/check.log"
counted=$(grep -E '^MISSING |: (PENDING|MISSING|CONFLICT|UNREACHABLE|INACTIVE|OFF)' "$work/check.log" || true)
if [ "$mode" = client ]; then expected='GitHub auth: PENDING'
else expected=$'GitHub auth: PENDING\nOrca Codex: PENDING'; fi
[ "$counted" = "$expected" ] || fail "--check counts more than interactive authentication: $counted"
[ "$status" -eq "$(grep -c . <<<"$expected")" ] || fail "--check exit code $status"
echo "PASS ($mode): --apply is idempotent, Orca runs, and --check reports only interactive authentication"
