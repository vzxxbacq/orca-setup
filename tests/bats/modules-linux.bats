#!/usr/bin/env bats
# Optional modules on Linux (P3): --plan, --apply and --check of --power, --containers, --media, --android,
# --agent-gemini and --apple against fake apt, sudo, gpg, curl, systemctl and Orca. Nothing here runs apt, sudo
# or systemd for real.

load helpers

DOCKER_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

setup() {
  make_sandbox
  fake_linux
  ready
}

no_calls() { [ ! -s "$FAKE_LOG" ] || { cat "$FAKE_LOG"; return 1; }; }

# Every baseline tool, agent and Orca is in place, so --apply --role client only reaches the modules. systemd is
# the init system; the fake systemctl reports units listed in $SB/masked as masked. Keys from the fake curl hold
# $FAKE_KEY_FPRS; marksman's release comes from $SB/release.json and $SB/marksman.
ready() {
  fake_baseline_present
  fake_orca_linux
  echo ca-certificates >>"$FAKE_DPKG"
  printf '# >>> orca-setup PATH >>>\n' >"$HOME/.profile"
  printf '# >>> orca-setup PATH >>>\n' >"$HOME/.zshrc"
  fake_gpg
  mkdir -p "$SB/run-systemd"
  export ORCA_SETUP_SYSTEMD_RUN_DIR=$SB/run-systemd FAKE_KEY_FPRS=$DOCKER_FPR
  # shellcheck disable=SC2016 # the stub bodies expand when the stubs run
  fake_cmd systemctl '
case "$1" in
  is-enabled) grep -qxF -- "$2" "$SB/masked" 2>/dev/null && { echo masked; exit 1; }; echo static ;;
  --user) case "$2" in show-environment) exit 0 ;; is-enabled | is-active) exit 3 ;; esac; echo "systemctl $*" >>"$FAKE_LOG" ;;
  *) echo "systemctl $*" >>"$FAKE_LOG"; exit 1 ;;
esac'
  # shellcheck disable=SC2016
  fake_cmd curl 'out=""; prev=""; for a; do [ "$prev" = -o ] && out=$a; prev=$a; done
case "$*" in
  *api.github.com/repos/artempyanykh/marksman/releases/latest*) cp "$SB/release.json" "$out" ;;
  *releases/download/*) cp "$SB/marksman" "$out" ;;
  *) echo "FAKEKEY ${FAKE_KEY_FPRS//,/ }" >"$out" ;;
esac'
  # shellcheck disable=SC2016
  fake_cmd sha256sum 'read -r want file; have=$("'"$REAL_NODE"'" -e "process.stdout.write(require(\"crypto\").createHash(\"sha256\").update(require(\"fs\").readFileSync(process.argv[1])).digest(\"hex\"))" "$file"); [ "$have" = "$want" ]'
  # The distribution offers every package (apt-cache), and npm records what it installs.
  fake_cmd apt-cache 'exit 0'
  # shellcheck disable=SC2016
  fake_cmd npm 'echo "npm $*" >>"$FAKE_LOG"; for a; do :; done; case "$a" in @google/gemini-cli@latest) fake=gemini ;; *) exit 0 ;; esac
printf "#!/bin/sh\n" >"$SB/bin/$fake"; chmod +x "$SB/bin/$fake"'
}

# fake_marksman <digest|auto> [url]: the latest marksman release and its binary.
fake_marksman() {
  local url=${2:-https://github.com/artempyanykh/marksman/releases/download/2026-02-08/marksman-linux-x64} digest=$1
  printf '#!/bin/sh\necho marksman fake\n' >"$SB/marksman"
  [ "$digest" != auto ] || digest="\"sha256:$("$REAL_NODE" -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$SB/marksman")\""
  printf '{"tag_name":"2026-02-08","draft":false,"prerelease":false,"assets":[{"name":"marksman-linux-x64","digest":%s,"browser_download_url":"%s"},{"name":"marksman-linux-musl-x64","digest":null,"browser_download_url":"x"}]}\n' \
    "$digest" "$url" >"$SB/release.json"
}

apply_modules() { run_setup --apply --role client "$@"; }

# The second run may print only PRESENT, SKIP and NOTE items and the role report.
only_present() {
  [ -z "$(grep -v -e '^PRESENT ' -e '^SKIP ' -e '^NOTE ' -e '^MODULE ' -e '^ROLE ' -e '^saved environments: ' \
    -e '^runtime clients ' -e '^mobile pairings: ' -e '^BASELINE_DONE$' <<<"$output")" ] || { echo "$output"; return 1; }
}

# ------------------------------------------------------------------ plan

@test "--plan shows every Linux module in detail and lists each sudo command" {
  run_setup --plan --role client --power --containers --apple --android --media --agent-gemini
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'--power         Use sudo to mask the systemd sleep targets'*'[selected]'* ]]
  [[ "$output" == *'sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target'* ]]
  [[ "$output" == *'restart after power loss is a BIOS/UEFI setting'* ]]
  [[ "$output" == *'install  docker                 apt docker-ce from https://download.docker.com/linux/ubuntu'* ]]
  [[ "$output" == *"download https://download.docker.com/linux/ubuntu/gpg, require fingerprint(s) $DOCKER_FPR"* ]]
  [[ "$output" == *"deb [arch=amd64 signed-by=$SB/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable"* ]]
  # The repository is set up once for all its packages.
  [ "$(grep -c 'download https://download.docker.com' <<<"$output")" -eq 1 ]
  [[ "$output" == *'apt-get install -y --no-install-recommends docker-compose-plugin'* ]]
  [[ "$output" == *'sudo usermod -aG docker builder'* ]]
  [[ "$output" == *'--apple         macOS only: skipped on Linux with a notice. [selected]'*'skip: not applicable on Linux'* ]]
  [[ "$output" == *'install  android-platform-tools apt android-sdk-platform-tools'* ]]
  [[ "$output" == *'install  poppler                apt poppler-utils'* ]]
  [[ "$output" == *'install  sevenzip               apt p7zip-full'* ]]
  [[ "$output" == *'install  marksman               marksman-linux-x64 from the latest stable artempyanykh/marksman release -> ~/.local/bin'* ]]
  [[ "$output" == *'require the sha256 digest GitHub records for that asset, then install it as ~/.local/bin/marksman'* ]]
  [[ "$output" == *'install  gemini                 npm @google/gemini-cli -> ~/.local'* ]]
  # Every root command is printed as an indented "sudo ..." line.
  [ -z "$(grep 'sudo' <<<"$output" | grep -v -e '^ \{11,\}sudo ' -e '^sudo: present')" ]
  no_calls
}

@test "--plan on Debian 12 uses Docker's Debian repository for bookworm" {
  fake_os_release debian 12
  run_setup --plan --containers
  [ "$status" -eq 0 ]
  [[ "$output" == *'https://download.docker.com/linux/debian bookworm stable'* ]]
  [[ "$output" == *'download https://download.docker.com/linux/debian/gpg'* ]]
  no_calls
}

@test "--plan for modules that are already in place lists no sudo command" {
  printf '%s\n' sleep.target suspend.target hibernate.target hybrid-sleep.target >"$SB/masked"
  printf ' docker' >"$SB/groups"
  local name
  for name in pdftotext ffmpeg 7z marksman adb gemini; do fake_present "$name"; done
  run_setup --plan --power --media --android --agent-gemini
  [ "$status" -eq 0 ]
  [[ "$output" == *'already masked: sleep.target'* ]]
  [ -z "$(grep -e '^ *sudo ' -e '^    install  ' <<<"$output")" ] || { echo "$output"; return 1; }
  no_calls
}

# ------------------------------------------------------------------ power

@test "--power masks the sleep targets once and reminds of the BIOS setting" {
  apply_modules --power
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'+ sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target'* ]]
  [[ "$output" == *'NOTE restart after power loss is a BIOS/UEFI setting'* ]]
  : >"$FAKE_LOG"
  apply_modules --power
  [ "$status" -eq 0 ]
  [[ "$output" == *'PRESENT sleep targets masked'* ]]
  only_present
  no_calls
}

@test "--power masks only the targets that are not masked yet" {
  printf '%s\n' sleep.target hibernate.target >"$SB/masked"
  apply_modules --power
  [ "$status" -eq 0 ]
  [[ "$output" == *'+ sudo systemctl mask suspend.target hybrid-sleep.target'* ]]
}

@test "--power is skipped without systemd (a container)" {
  rm -rf "$SB/run-systemd"
  apply_modules --power
  [ "$status" -eq 0 ]
  [[ "$output" == *'SKIP module power: systemd is not the init system here'* ]]
  no_calls
}

# ------------------------------------------------------------------ containers

@test "--containers verifies Docker's key, installs Docker Engine, joins the docker group; a second run changes nothing" {
  apply_modules --containers
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$SB/apt/sources.list.d/docker.list")" = "deb [arch=amd64 signed-by=$SB/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" ]
  [ "$(cat "$SB/apt/keyrings/docker.gpg")" = "FAKEKEY $DOCKER_FPR" ]
  local package
  for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    grep -qxF "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $package" "$FAKE_LOG"
  done
  [[ "$output" == *'+ sudo usermod -aG docker builder'* ]]
  [[ "$output" == *'NOTE log out and back in (a new login) before using docker without sudo'* ]]
  : >"$FAKE_LOG"
  apply_modules --containers
  [ "$status" -eq 0 ]
  [[ "$output" == *'PRESENT docker-compose-plugin'* ]]
  [[ "$output" == *'PRESENT builder in the docker group'* ]]
  only_present
  no_calls
}

@test "--containers refuses a Docker key whose fingerprint is not in the manifest" {
  export FAKE_KEY_FPRS=0000000000000000000000000000000000000000
  apply_modules --containers
  [ "$status" -eq 1 ]
  [[ "$output" == *'the docker signing key does not match manifest/apt-repos.tsv'* ]]
  [ ! -e "$SB/apt/keyrings/docker.gpg" ]
  no_calls
}

@test "--containers leaves Docker or Podman from another source alone" {
  echo docker.io >>"$FAKE_DPKG"
  apply_modules --containers
  [ "$status" -eq 0 ]
  [[ "$output" == *'SKIP module containers: Docker or Podman from another source is installed (docker.io); it is left alone'* ]]
  no_calls
  run_setup --plan --containers
  [[ "$output" == *'skip: Docker or Podman from another source is installed (docker.io)'* ]]
  [[ "$output" != *usermod* ]]
  sed -i.bak '/^docker.io$/d' "$FAKE_DPKG"
  fake_present podman
  apply_modules --containers
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP module containers: Podman is already installed without orca-setup's Docker repository"* ]]
  rm "$SB/bin/podman"
  fake_present docker # e.g. Docker's convenience script, or a hand-made repository setup
  apply_modules --containers
  [[ "$output" == *"SKIP module containers: Docker is already installed without orca-setup's Docker repository"* ]]
  run_setup --check --containers
  [[ "$output" == *'Module containers: skipped (Docker is already installed'*'; not counted)'* ]]
  no_calls
}

# ------------------------------------------------------------------ media

@test "--media installs the apt packages and marksman after its digest checks out; a second run changes nothing" {
  fake_marksman auto
  apply_modules --media
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local package
  for package in poppler-utils ffmpeg p7zip-full; do
    grep -qxF "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $package" "$FAKE_LOG"
  done
  [[ "$output" == *'artempyanykh/marksman 2026-02-08: marksman-linux-x64'* ]]
  [[ "$output" == *'verified marksman-linux-x64 (sha256 '* ]]
  [ -x "$HOME/.local/bin/marksman" ]
  [ "$("$HOME/.local/bin/marksman")" = 'marksman fake' ]
  # marksman is user-level: no sudo for it.
  [ -z "$(grep -i marksman "$FAKE_LOG")" ]
  : >"$FAKE_LOG"
  local name
  for name in pdftotext ffmpeg 7z; do fake_present "$name"; done
  apply_modules --media
  [ "$status" -eq 0 ]
  [[ "$output" == *'PRESENT marksman'* ]]
  only_present
  no_calls
}

@test "marksman with a wrong digest, no digest or a foreign URL is never installed" {
  local name
  for name in pdftotext ffmpeg 7z; do fake_present "$name"; done
  fake_marksman '"sha256:0000000000000000000000000000000000000000000000000000000000000000"'
  apply_modules --media
  [ "$status" -eq 1 ]
  [[ "$output" == *'marksman-linux-x64 does not match the sha256 digest GitHub records'* ]]
  fake_marksman null
  apply_modules --media
  [ "$status" -eq 1 ]
  [[ "$output" == *'GitHub records no sha256 digest for marksman-linux-x64'* ]]
  fake_marksman auto https://example.com/marksman-linux-x64
  apply_modules --media
  [ "$status" -eq 1 ]
  [[ "$output" == *'unexpected download URL'* ]]
  [ ! -e "$HOME/.local/bin/marksman" ]
  no_calls
}

# ------------------------------------------------------------------ android, gemini, apple

@test "--android installs android-sdk-platform-tools when the distribution offers it" {
  apply_modules --android
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF 'sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends android-sdk-platform-tools' "$FAKE_LOG"
}

@test "--android is skipped with a notice when the apt sources do not offer it" {
  fake_cmd apt-cache 'exit 100'
  apply_modules --android
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'SKIP module android: the apt sources of this device do not offer android-sdk-platform-tools'* ]]
  [[ "$output" == *'https://developer.android.com/tools/releases/platform-tools'* ]]
  # Fresh package lists were read first; nothing was installed.
  run cat "$FAKE_LOG"
  [ "$output" = 'sudo env DEBIAN_FRONTEND=noninteractive apt-get update' ]
}

@test "--agent-gemini installs the Gemini CLI from npm into ~/.local" {
  apply_modules --agent-gemini
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF "npm install --global --prefix $HOME/.local --include=optional @google/gemini-cli@latest" "$FAKE_LOG"
  : >"$FAKE_LOG"
  apply_modules --agent-gemini
  [[ "$output" == *'PRESENT gemini'* ]]
  only_present
  no_calls
}

@test "--apple is skipped on Linux with a notice, not an error" {
  apply_modules --apple
  [ "$status" -eq 0 ]
  [[ "$output" == *'SKIP module apple: not applicable on Linux (Xcode and the Apple build helpers are macOS-only)'* ]]
  [ "${lines[${#lines[@]} - 1]}" = BASELINE_DONE ]
  no_calls
}

# ------------------------------------------------------------------ check

@test "--check counts module items only for the modules given" {
  fake_cmd gh 'exit 0' # logged in
  run_setup --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *marksman* ]]
  [[ "$output" != *'Sleep targets'* ]]
  run_setup --check --media --power --containers --apple
  [[ "$output" == *'MISSING poppler'* ]]
  [[ "$output" == *'MISSING marksman'* ]]
  [[ "$output" == *'Sleep targets: MISSING (not masked: sleep.target suspend.target hibernate.target hybrid-sleep.target)'* ]]
  [[ "$output" == *'MISSING docker-ce-cli'* ]]
  [[ "$output" == *'docker group: MISSING'* ]]
  [[ "$output" == *'Module apple: skipped (not applicable on Linux'*'; not counted)'* ]]
  # 4 media rows, the sleep targets, 5 Docker rows and the docker group.
  [ "$status" -eq 11 ] || { echo "$output"; return 1; }
  no_calls
}
