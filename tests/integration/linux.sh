#!/usr/bin/env bash
# Linux integration test, prepared by .github/workflows/ci.yml; never run it on a real machine.
#
#   linux.sh client   inside a fresh ubuntu:24.04 or debian:12 container (no systemd), as a non-root user with
#                     passwordless sudo: --apply --role client installs the baseline and the Orca .deb, plus every
#                     optional module (Docker Engine on its fresh-install path; --power and --apple are skipped);
#   linux.sh server   directly on a GitHub-hosted Ubuntu 24.04 runner VM (systemd), as the runner user:
#                     --apply --role server also enables linger and starts the orca-serve user unit, masks the sleep
#                     targets (--power), and leaves the runner's preinstalled Docker alone (--containers).
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
if [ "$mode" = client ]; then modules=(--power --containers --apple --android --media --agent-gemini)
else modules=(--power --containers); fi
args=(--apply --role "$mode" "${modules[@]}")
[ "$mode" = client ] || args+=(--pairing-address 127.0.0.2)
unit=$HOME/.config/systemd/user/orca-serve.service

# Everything --apply may change, in a comparable form.
state() {
  # shellcheck disable=SC2016 # dpkg-query format fields
  dpkg-query -W -f '${Package} ${Version}\n'
  # A running orca-ide serve writes its own orca and orca-ide shims into ~/.local/bin (upstream, not setup.sh).
  find /etc/apt/keyrings /etc/apt/sources.list.d "$HOME/.local/bin" -maxdepth 1 -print 2>/dev/null |
    grep -vxF -e "$HOME/.local/bin/orca" -e "$HOME/.local/bin/orca-ide" | sort
  sha256sum /etc/apt/keyrings/* /etc/apt/sources.list.d/* "$HOME/.profile" "$HOME/.zshrc" "$HOME/.bash_profile" "$unit" \
    2>/dev/null || true
  ls /var/lib/systemd/linger 2>/dev/null || true
  id -nG "$USER"
  ls -l /etc/systemd/system/*.target 2>/dev/null || true
}

# Pairing offers look like orca://pair?code=...; fail without printing the match.
no_pairing_secret() {
  if grep -qiE 'orca://pair|[?&#]code=' "$@"; then fail "a pairing URL or code appeared in: $*"; fi
}

# The Docker install the runner image ships (server mode): packages, apt sources and the docker group.
docker_state() {
  # shellcheck disable=SC2016 # dpkg-query format fields
  dpkg-query -W -f '${Package} ${Version}\n' | grep -Ei 'docker|containerd|moby|runc|podman' || true
  ls /etc/apt/sources.list.d /etc/apt/keyrings 2>/dev/null || true
  getent group docker || true
  docker --version 2>/dev/null || true
}
[ "$mode" = client ] || docker_state >"$work/docker-before"

echo '::group::first --apply'
"$repo/setup.sh" "${args[@]}" 2>&1 | tee "$work/first.log"
echo '::endgroup::'
grep -qx BASELINE_DONE "$work/first.log" || fail 'first --apply did not finish'
state >"$work/state-1"
[ ! -e "$unit" ] || cp "$unit" "$work/unit-1"

echo '::group::second --apply'
"$repo/setup.sh" "${args[@]}" 2>&1 | tee "$work/second.log"
echo '::endgroup::'
state >"$work/state-2"
if grep -n '^+ ' "$work/second.log"; then
  [ ! -e "$work/unit-1" ] || diff -u "$work/unit-1" "$unit" || true
  fail 'the second --apply ran steps'
fi
# Only PRESENT items, skipped items, module headers, notes and the pairing role report are allowed.
if grep -vE '^(PRESENT |SKIP |MODULE |NOTE |ROLE |saved environments: |runtime clients |mobile pairings: |BASELINE_DONE$)' "$work/second.log"; then
  fail 'the second --apply printed more than PRESENT lines'
fi
diff -u "$work/state-1" "$work/state-2" || fail 'the second --apply changed the system'
[ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.profile")" -eq 1 ] || fail 'the PATH block must appear once in .profile'
[ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.zshrc")" -eq 1 ] || fail 'the PATH block must appear once in .zshrc'
[ ! -e "$HOME/.bash_profile" ] || [ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.bash_profile")" -eq 1 ] ||
  fail 'the PATH block must appear once in an existing .bash_profile'

echo '::group::login shell PATH'
# The system PATH a login gets from /etc/environment; the runner keeps its preinstalled Node.js in /usr/local/bin.
# shellcheck disable=SC2016 # expanded by the login shell
env -i HOME="$HOME" USER="$USER" PATH=/usr/local/bin:/usr/bin:/bin bash -lc \
  'for tool in node npm pnpm uv python3.12 ruff codex claude dsh dsh-tui pi bun omp grok agy gh orca-ide; do command -v "$tool" || exit 1; done
   for tool in node pnpm uv python3.12 ruff gh bun; do "$tool" --version || exit 1; done' ||
  fail 'a login shell does not find or cannot run the user-level tools'
echo '::endgroup::'

echo '::group::Orca'
dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' orca-ide
[ "$(readlink -f /usr/bin/orca-ide)" = /opt/Orca/resources/bin/orca-ide ] || fail '/usr/bin/orca-ide is not the .deb CLI shim'
orca-ide skills list --json >/dev/null || fail 'orca-ide does not run'
# The local dry-run plan writes nothing once every skill is in place.
orca-ide skills install --skill orca-cli --skill orca-linear --skill computer-use --agent universal,claude-code,codex \
  --dry-run --json >"$work/skills.json" || fail 'orca-ide skills install --dry-run failed'
pending=$(node "$repo/lib/json.cjs" skills-pending orca-cli orca-linear computer-use <"$work/skills.json")
[ -z "$pending" ] || fail "skills not installed: $pending"
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

echo '::group::optional modules'
if [ "$mode" = client ]; then
  grep -qx 'SKIP module power: systemd is not the init system here (a container?), so there are no sleep targets to mask' "$work/first.log" ||
    fail '--power must be skipped in a container'
  grep -q '^SKIP module apple: not applicable on Linux' "$work/first.log" || fail '--apple must be skipped on Linux'
  # Docker Engine, fresh install from Docker's repository (no daemon runs in this container).
  grep -qx 'deb \[arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg\] https://download.docker.com/linux/[a-z]* [a-z]* stable' \
    /etc/apt/sources.list.d/docker.list || fail 'the Docker source list is not the expected one'
  dpkg-query -W -f '${Package} ${Version}\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
    fail 'Docker Engine is not installed'
  docker --version || fail 'docker does not run'
  id -nG "$USER" | tr ' ' '\n' | grep -qx docker || fail "$USER is not in the docker group"
  grep -qx 'NOTE log out and back in (a new login) before using docker without sudo' "$work/first.log" ||
    fail 'no new-login notice for the docker group'
  for tool in pdftotext ffmpeg 7z adb fastboot gemini; do command -v "$tool" || fail "$tool is missing"; done
  [ -x "$HOME/.local/bin/marksman" ] || fail 'marksman is not in ~/.local/bin'
  "$HOME/.local/bin/marksman" --version || fail 'marksman does not run'
  adb version || fail 'adb does not run'
  gemini --version || fail 'gemini does not run'
else
  for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    [ "$(systemctl is-enabled "$target" 2>/dev/null || true)" = masked ] || fail "$target is not masked"
  done
  grep -q '^NOTE restart after power loss is a BIOS/UEFI setting' "$work/second.log" || fail 'no BIOS reminder'
  # The runner image ships Docker: --containers must leave it, its packages and its apt sources alone.
  grep -q "^SKIP module containers: .* it is left alone$" "$work/first.log" || fail '--containers did not leave the existing Docker alone'
  docker_state >"$work/docker-after"
  diff -u "$work/docker-before" "$work/docker-after" || fail '--containers changed the existing Docker install'
fi
echo '::endgroup::'

echo '::group::--check'
status=0
"$repo/setup.sh" --check --role "$mode" "${modules[@]}" >"$work/check.log" 2>&1 || status=$?
cat "$work/check.log"
echo '::endgroup::'
no_pairing_secret "$work/first.log" "$work/second.log" "$work/check.log"
counted=$(grep -E '^MISSING |: (PENDING|MISSING|CONFLICT|UNREACHABLE|INACTIVE|OFF)' "$work/check.log" || true)
if [ "$mode" = client ]; then expected='GitHub auth: PENDING'
else expected=$'GitHub auth: PENDING\nOrca Codex: PENDING'; fi
[ "$counted" = "$expected" ] || fail "--check counts more than interactive authentication: $counted"
[ "$status" -eq "$(grep -c . <<<"$expected")" ] || fail "--check exit code $status"
echo "PASS ($mode): --apply is idempotent, Orca runs, and --check reports only interactive authentication"
