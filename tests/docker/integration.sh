#!/usr/bin/env bash
# Linux integration test. Runs inside a fresh ubuntu:24.04 or debian:12 container as a non-root user with
# passwordless sudo (prepared by .github/workflows/ci.yml); never run it on a real machine.
#   1. --apply --role server installs the baseline;
#   2. a second --apply changes nothing: no step lines, same packages, apt sources, keyrings and dotfiles;
#   3. a login shell finds the user-level tools through the PATH block, and the baseline tools run;
#   4. --check reports only interactive authentication items as missing.
set -euo pipefail
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail 'run as a non-root user'
[ -f /.dockerenv ] || [ -n "${CI:-}" ] || fail 'only for throwaway CI containers'

# Everything --apply may change, in a comparable form.
state() {
  # shellcheck disable=SC2016 # dpkg-query format fields
  dpkg-query -W -f '${Package} ${Version}\n'
  find /etc/apt/keyrings /etc/apt/sources.list.d "$HOME/.local/bin" -maxdepth 1 -print 2>/dev/null | sort
  sha256sum /etc/apt/keyrings/* /etc/apt/sources.list.d/* "$HOME/.profile" "$HOME/.zshrc" 2>/dev/null || true
}

echo '::group::first --apply'
"$repo/setup.sh" --apply --role server 2>&1 | tee "$work/first.log"
echo '::endgroup::'
grep -qx BASELINE_DONE "$work/first.log" || fail 'first --apply did not finish'
state >"$work/state-1"

echo '::group::second --apply'
"$repo/setup.sh" --apply --role server 2>&1 | tee "$work/second.log"
echo '::endgroup::'
state >"$work/state-2"
if grep -n '^+ ' "$work/second.log"; then fail 'the second --apply ran steps'; fi
# Only PRESENT items, deferred items (Orca: P2) and the pairing role report are allowed.
if grep -vE '^(PRESENT |SKIP |ROLE |saved environments: |runtime clients |mobile pairings: |BASELINE_DONE$)' "$work/second.log"; then
  fail 'the second --apply printed more than PRESENT lines'
fi
diff -u "$work/state-1" "$work/state-2" || fail 'the second --apply changed the system'
[ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.profile")" -eq 1 ] || fail 'the PATH block must appear once in .profile'
[ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.zshrc")" -eq 1 ] || fail 'the PATH block must appear once in .zshrc'

echo '::group::login shell PATH'
# shellcheck disable=SC2016 # expanded by the login shell
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin bash -lc \
  'for tool in node npm pnpm uv python3.12 ruff codex claude dsh dsh-tui pi bun omp grok agy gh; do command -v "$tool" || exit 1; done
   for tool in node pnpm uv python3.12 ruff gh bun; do "$tool" --version || exit 1; done' ||
  fail 'a login shell does not find or cannot run the user-level tools'
echo '::endgroup::'

echo '::group::--check'
status=0
"$repo/setup.sh" --check --role server >"$work/check.log" 2>&1 || status=$?
cat "$work/check.log"
echo '::endgroup::'
counted=$(grep -E '^MISSING |: (PENDING|MISSING|CONFLICT|UNREACHABLE)' "$work/check.log" || true)
[ "$counted" = 'GitHub auth: PENDING' ] || fail "--check counts more than interactive authentication: $counted"
[ "$status" -eq 1 ] || fail "--check exit code $status, expected 1"
echo 'PASS: --apply is idempotent and --check reports only interactive authentication'
