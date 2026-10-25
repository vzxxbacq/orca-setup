#!/usr/bin/env bash
# Linux integration test, prepared by .github/workflows/ci.yml; never run it on a real machine.
#
#   linux.sh client   inside a fresh ubuntu:24.04 or debian:12 container (no systemd), as a non-root user with
#                     passwordless sudo: --apply --role client installs the baseline and the Orca .deb, plus every
#                     optional module (Docker Engine on its fresh-install path; --power and --apple are skipped);
#   linux.sh server   directly on a GitHub-hosted Ubuntu 24.04 runner VM (systemd), as the runner user, with the
#                     Orca server image built from this checkout and served by a local registry (ORCA_SETUP_IMAGE):
#                     --apply --role server uses the runner's preinstalled Docker as it is, starts the orca-server
#                     container, and masks the sleep targets (--power).
# Both also pass --gpu (detection only; the runners have no NVIDIA GPU).
#
# Both modes then check that a second --apply changes nothing, that no output carries a pairing URL, and that
# --check counts only interactive authentication items. The server also checks the container: the runtime answers,
# mounted data survives a re-create owned by the runner user, writes outside the mounts fail, and --upgrade-image
# moves to a newer image.
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
    [ -n "${ORCA_SETUP_IMAGE:-}" ] || fail 'server mode needs ORCA_SETUP_IMAGE (the image built from this checkout)'
    # The runner has no loopback-free private address to advertise; a test-only override allows 127.0.0.2.
    export ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS=1 ;;
  *) fail 'usage: linux.sh client|server' ;;
esac
if [ "$mode" = client ]; then modules=(--power --containers --apple --android --media --agent-gemini --gpu)
else modules=(--power --containers --gpu); fi
args=(--apply --role "$mode" "${modules[@]}")
[ "$mode" = client ] || args+=(--pairing-address 127.0.0.2)
compose=$HOME/.config/orca-setup/docker/compose.yaml
lock=$HOME/.config/orca-setup/docker/image.lock

# Everything --apply may change, in a comparable form.
state() {
  # shellcheck disable=SC2016 # dpkg-query format fields
  dpkg-query -W -f '${Package} ${Version}\n'
  # A running orca-ide serve writes its own orca and orca-ide shims into ~/.local/bin (upstream, not setup.sh).
  find /etc/apt/keyrings /etc/apt/sources.list.d "$HOME/.local/bin" -maxdepth 1 -print 2>/dev/null |
    grep -vxF -e "$HOME/.local/bin/orca" -e "$HOME/.local/bin/orca-ide" | sort
  sha256sum /etc/apt/keyrings/* /etc/apt/sources.list.d/* "$HOME/.profile" "$HOME/.zshrc" "$HOME/.bash_profile" \
    "$compose" "$lock" 2>/dev/null || true
  id -nG "$USER"
  ls -l /etc/systemd/system/*.target 2>/dev/null || true
  [ "$mode" = client ] || docker inspect --format '{{.Id}} {{.Image}} {{.State.Status}}' orca-server
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

# wait_runtime: until the Orca runtime in the container answers (after a re-create).
wait_runtime() {
  local waited=0
  until docker exec orca-server sh -c 'orca-ide status --json 2>/dev/null' >"$work/status.json" &&
    node "$repo/lib/json.cjs" has result.runtime.reachable <"$work/status.json"; do
    [ "$waited" -lt 120 ] || fail 'the Orca runtime in the container is not reachable'
    sleep 2
    waited=$((waited + 2))
  done
}

[ "$mode" = client ] || docker_state >"$work/docker-before"

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
# Only PRESENT items, skipped items, module headers, notes and the pairing role report are allowed.
if grep -vE '^(PRESENT |SKIP |MODULE |NOTE |ROLE |saved environments: |runtime clients |mobile pairings: |BASELINE_DONE$)' "$work/second.log"; then
  fail 'the second --apply printed more than PRESENT lines'
fi
diff -u "$work/state-1" "$work/state-2" || fail 'the second --apply changed the system'

if [ "$mode" = client ]; then
  [ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.profile")" -eq 1 ] || fail 'the PATH block must appear once in .profile'
  [ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.zshrc")" -eq 1 ] || fail 'the PATH block must appear once in .zshrc'
  [ ! -e "$HOME/.bash_profile" ] || [ "$(grep -c '^# >>> orca-setup PATH >>>$' "$HOME/.bash_profile")" -eq 1 ] ||
    fail 'the PATH block must appear once in an existing .bash_profile'

  echo '::group::login shell PATH'
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
  [ ! -e "$compose" ] || fail 'a client must not get the Orca server container'
  echo '::endgroup::'

  echo '::group::optional modules'
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
  for tool in pdftotext ffmpeg 7z adb fastboot; do command -v "$tool" || fail "$tool is missing"; done
  # User-level tools: ~/.local/bin, which the PATH block puts on a login shell's PATH.
  [ -x "$HOME/.local/bin/marksman" ] || fail 'marksman is not in ~/.local/bin'
  "$HOME/.local/bin/marksman" --version || fail 'marksman does not run'
  "$HOME/.local/bin/gemini" --version || fail 'gemini does not run'
  adb version || fail 'adb does not run'
  echo '::endgroup::'
else
  echo '::group::the Orca server container'
  [ "$(head -n 1 "$compose")" = '# orca-setup: Orca server container for this user' ] || fail 'compose.yaml is not the rendered one'
  grep -qxE "image=${ORCA_SETUP_IMAGE%:*}@sha256:[0-9a-f]{64}" "$lock" || fail 'image.lock does not hold the pulled digest'
  [ "$(docker inspect --format '{{.State.Status}} {{.HostConfig.NetworkMode}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.RestartPolicy.Name}} {{.HostConfig.Init}}' orca-server)" = \
    'running host true unless-stopped true' ] || fail 'the container does not run as rendered'
  [ "$(docker exec orca-server id -u):$(docker exec orca-server id -g)" = "$(id -u):$(id -g)" ] || fail 'the container does not run as the runner user'
  # shellcheck disable=SC2016 # expanded in the container
  [ "$(docker exec orca-server sh -c 'printf %s "$HOME"')" = "$HOME" ] || fail 'the container HOME is not the host home path'
  docker exec orca-server sh -c '! command -v sudo && ! command -v docker' || fail 'sudo or docker exists in the container'
  # shellcheck disable=SC2016 # expanded in the container
  docker exec orca-server sh -c 'for tool in node pnpm uv python3.12 ruff codex claude dsh dsh-tui pi bun omp grok agy gh orca-ide gemini Xvfb pdftotext ffmpeg 7z adb fastboot marksman; do command -v "$tool" >/dev/null || { echo "missing in the image: $tool"; exit 1; }; done' ||
    fail 'the image lacks a tool'
  wait_runtime
  docker logs orca-server >"$work/container.log" 2>&1
  no_pairing_secret "$work/status.json" "$work/container.log"
  echo "status reply reachable; container log: $(wc -l <"$work/container.log") lines, no pairing URL"
  echo '::endgroup::'

  echo '::group::mounts survive a re-create'
  # shellcheck disable=SC2016 # expanded in the container
  docker exec orca-server sh -c 'echo persisted >"$HOME/orca/projects/ci-persist" && echo home >"$HOME/ci-home-file"' ||
    fail 'cannot write into the mounted directories'
  docker compose --file "$compose" down
  docker compose --file "$compose" up --detach
  wait_runtime
  [ "$(cat "$HOME/orca/projects/ci-persist")" = persisted ] || fail 'the mounted file did not survive the re-create'
  [ "$(stat -c %u:%g "$HOME/orca/projects/ci-persist")" = "$(id -u):$(id -g)" ] || fail 'the mounted file is not owned by the runner user'
  [ "$(cat "$HOME/.local/share/orca-setup/home/ci-home-file")" = home ] || fail "a file in the container's home did not persist"
  # shellcheck disable=SC2016 # expanded in the container
  [ "$(docker exec orca-server sh -c 'cat "$HOME/orca/projects/ci-persist"')" = persisted ] || fail 'the container does not see the file'
  for path in /opt/ci-outside /etc/ci-outside /usr/local/ci-outside /ci-outside; do
    if docker exec orca-server sh -c "touch $path" 2>/dev/null; then fail "a write outside the mounts succeeded: $path"; fi
  done
  echo 'writes outside the mounts fail (read-only root filesystem)'
  echo '::endgroup::'

  echo '::group::modules and the preinstalled Docker'
  for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    [ "$(systemctl is-enabled "$target" 2>/dev/null || true)" = masked ] || fail "$target is not masked"
  done
  grep -q '^NOTE restart after power loss is a BIOS/UEFI setting' "$work/second.log" || fail 'no BIOS reminder'
  grep -q '^PRESENT docker (.*from another source, used as it is)$' "$work/first.log" || fail 'the runner Docker was not used as it is'
  docker_state >"$work/docker-after"
  diff -u "$work/docker-before" "$work/docker-after" || fail '--apply changed the existing Docker install'
  echo '::endgroup::'
fi

echo '::group::--check'
status=0
"$repo/setup.sh" --check --role "$mode" "${modules[@]}" >"$work/check.log" 2>&1 || status=$?
cat "$work/check.log"
echo '::endgroup::'
no_pairing_secret "$work/first.log" "$work/second.log" "$work/check.log"
counted=$(grep -E '^MISSING |: (PENDING|MISSING|CONFLICT|UNREACHABLE|INACTIVE|OFF|STALE|WRONG)' "$work/check.log" || true)
if [ "$mode" = client ]; then expected='GitHub auth: PENDING'
else expected=$'GitHub auth: PENDING\nOrca Codex: PENDING'; fi
[ "$counted" = "$expected" ] || fail "--check counts more than interactive authentication: $counted"
[ "$status" -eq "$(grep -c . <<<"$expected")" ] || fail "--check exit code $status"
grep -qx 'NVIDIA GPU: none found (not counted)' "$work/check.log" || fail '--check --gpu did not report the (absent) GPU'

echo '::group::--check --json'
json_status=0
"$repo/setup.sh" --check --json --role "$mode" "${modules[@]}" >"$work/check.json" || json_status=$?
node "$repo/lib/json.cjs" check-summary <"$work/check.json" | tee "$work/check-summary.txt" || fail '--check --json is not a check report'
echo '::endgroup::'
no_pairing_secret "$work/check.json"
[ "$json_status" -eq "$status" ] || fail "--check --json exit code $json_status differs from --check ($status)"
grep -qx "missing $status" "$work/check-summary.txt" || fail '--check --json does not report the same missing count'

if [ "$mode" = server ]; then
  echo '::group::--upgrade-image'
  locked=$(sed -n 's/^image=//p' "$lock")
  before=$(docker inspect --format '{{.Image}}' orca-server)
  printf 'FROM %s\nLABEL org.orca-setup.ci=upgrade\n' "$locked" | docker build --tag "$ORCA_SETUP_IMAGE" -
  docker push "$ORCA_SETUP_IMAGE"
  "$repo/setup.sh" "${args[@]}" 2>&1 | tee "$work/third.log"
  grep -qx "image=$locked" "$lock" || fail 'a re-run without --upgrade-image moved the locked image'
  "$repo/setup.sh" "${args[@]}" --upgrade-image 2>&1 | tee "$work/upgrade.log"
  grep -qx BASELINE_DONE "$work/upgrade.log" || fail '--upgrade-image did not finish'
  ! grep -qx "image=$locked" "$lock" || fail '--upgrade-image kept the old digest'
  [ "$(docker inspect --format '{{.Image}}' orca-server)" != "$before" ] || fail '--upgrade-image did not re-create the container'
  wait_runtime
  [ "$(cat "$HOME/orca/projects/ci-persist")" = persisted ] || fail 'the mounted file did not survive the upgrade'
  no_pairing_secret "$work/third.log" "$work/upgrade.log"
  echo '::endgroup::'
fi
echo "PASS ($mode): --apply is idempotent, Orca runs, and --check reports only interactive authentication"
