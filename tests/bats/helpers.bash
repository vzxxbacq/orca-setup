# shellcheck shell=bash
# Shared fixtures: every test runs in a sandbox whose PATH holds only a few real utilities plus fakes,
# so results never depend on what the machine running the tests has installed.

# `run !` (expect failure) needs bats 1.5; a bare `! cmd` never fails a test.
bats_require_minimum_version 1.5.0

REPO_ROOT=$(CDPATH='' cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
REAL_BASH=$(command -v bash)
# shellcheck disable=SC2034 # used by the test files
REAL_DIFF=$(command -v diff)
REAL_NODE=$(command -v node)

# Real utilities the scripts need; everything else must be faked explicitly.
SANDBOX_UTILS='bash env awk sed grep cat tr sort head cut paste mktemp dirname basename rm mkdir chmod id node ls wc date cp uniq tail sleep touch'

make_sandbox() {
  SB=$BATS_TEST_TMPDIR/sandbox
  mkdir -p "$SB/bin" "$SB/home" "$SB/Applications" "$SB/userdata"
  local util path
  for util in $SANDBOX_UTILS; do
    path=$(command -v "$util") || continue
    ln -sf "$path" "$SB/bin/$util"
  done
  export SB HOME=$SB/home
  export PATH=$SB/bin
  export ORCA_SETUP_BREW_PREFIX=$SB/brew
  export ORCA_SETUP_DEB_CLI=$SB/no-deb-cli
  export ORCA_SETUP_APPLICATIONS_DIR=$SB/Applications
  export ORCA_USER_DATA=$SB/userdata
  export FAKE_LOG=$SB/fake.log
  unset ORCA_CLI_COMMAND ORCA_APP_PATH ORCA_SETUP_OS_RELEASE DISPLAY WAYLAND_DISPLAY XDG_CONFIG_HOME XDG_DATA_HOME
  fake_uname Darwin arm64
  fake_cmd sw_vers 'echo 15.5'
}

# fake_cmd <name> <body>: an executable stub on the sandbox PATH. The old entry may be a symlink to a
# real utility, so it is removed first instead of being written through.
fake_cmd() {
  rm -f "$SB/bin/$1"
  printf '#!%s\n%s\n' "$REAL_BASH" "$2" >"$SB/bin/$1"
  chmod +x "$SB/bin/$1"
}

# Stubs that only need to exist (present tools).
fake_present() {
  local name
  for name in "$@"; do fake_cmd "$name" "echo \"$name 1.0.0\""; done
}

fake_uname() {
  fake_cmd uname "case \"\${1:-}\" in -m) echo $2 ;; *) echo $1 ;; esac"
}

# fake_os_release <ID> <VERSION_ID> [ID_LIKE]
fake_os_release() {
  export ORCA_SETUP_OS_RELEASE=$SB/os-release
  {
    printf 'NAME="Fake %s"\n' "$1"
    printf 'ID=%s\n' "$1"
    printf 'VERSION_ID="%s"\n' "$2"
    [ -z "${3:-}" ] || printf 'ID_LIKE="%s"\n' "$3"
  } >"$ORCA_SETUP_OS_RELEASE"
}

# fake_brew <installed formula or cask...>: `brew list` answers from the list; installs are logged.
fake_brew() {
  fake_cmd brew "
case \"\$1\" in
  list) for name in $*; do [ \"\$name\" = \"\${!#}\" ] && exit 0; done; exit 1 ;;
  *) echo \"brew \$*\" >>\"\$FAKE_LOG\"; exit 0 ;;
esac"
}

# A fake Orca: the app bundle (whose executable answers RPC calls) and the CLI.
fake_orca() {
  local app=$SB/Applications/Orca.app
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
  cat >"$app/Contents/MacOS/Orca" <<SH
#!$REAL_BASH
# As ELECTRON_RUN_AS_NODE, scripts other than the RPC bridge run on Node.js, like Orca's bundled runtime.
case "\$1" in *role.cjs) exec "$REAL_NODE" "\$@" ;; esac
# argv: orca-rpc.cjs local METHOD PARAMS
case "\$3" in
  settings.get) echo '{"settings":{"defaultTuiAgent":"claude","agentStatusHooksEnabled":true}}' ;;
  accounts.list) echo '{"codex":{"activeAccountId":"acct-secret-id"},"claude":{"activeAccountId":null}}' ;;
  linear.status) echo '{"connected":false}' ;;
  *) echo "Orca \$*" >>"\$FAKE_LOG"; echo '{}' ;;
esac
SH
  chmod +x "$app/Contents/MacOS/Orca"
  # shellcheck disable=SC2016 # the stub body expands when the stub runs
  fake_cmd orca '
case "$1 $2" in
  "environment list") cat "$ORCA_USER_DATA/cli-environments.json" 2>/dev/null || echo "{\"ok\":true,\"result\":{\"environments\":[]}}" ;;
  "skills installed") echo "{\"ok\":true,\"result\":{\"skills\":[{\"name\":\"orca-cli\"},{\"name\":\"orca-linear\"}]}}" ;;
  "status --json") echo "{\"ok\":true,\"result\":{\"runtime\":{\"reachable\":true}}}" ;;
  *) echo "orca $*" >>"$FAKE_LOG" ;;
esac'
}

run_setup() { run "$REAL_BASH" "$REPO_ROOT/setup.sh" "$@"; }

# fake_baseline_present: every baseline tool and agent check command exists (real node stays in place).
fake_baseline_present() {
  local check alt
  while IFS= read -r check; do
    alt=${check%%|*}
    case "$alt" in
      - | app:*) continue ;;
      lib:*) fake_library "${alt#lib:}"; continue ;;
    esac
    [ -e "$SB/bin/$alt" ] || fake_present "$alt"
  done < <(awk -F'\t' '!/^[[:space:]]*(#|$)/ && $3 == "baseline" { print $2 }' \
    "$REPO_ROOT/manifest/baseline.tsv" "$REPO_ROOT/manifest/agents.tsv")
}

# fake_linux [ID VERSION_ID ID_LIKE ARCH]: Ubuntu 24.04 x86_64 by default. apt state lives in the sandbox:
# keyrings and source lists under $SB/apt, installed packages in $FAKE_DPKG. The fake sudo logs every call
# and records `apt-get install` packages as installed; it never runs anything.
fake_linux() {
  fake_uname Linux "${4:-x86_64}"
  fake_os_release "${1:-ubuntu}" "${2:-24.04}" "${3-debian}"
  export ORCA_SETUP_APT_KEYRINGS_DIR=$SB/apt/keyrings ORCA_SETUP_APT_SOURCES_DIR=$SB/apt/sources.list.d
  export FAKE_DPKG=$SB/dpkg-installed
  : >"$FAKE_DPKG"
  # shellcheck disable=SC2016 # the stub bodies expand when the stubs run
  fake_cmd dpkg-query 'for p; do :; done; grep -qxF -- "$p" "$FAKE_DPKG" && printf "install ok installed"'
  # shellcheck disable=SC2016
  fake_cmd sudo 'echo "sudo $*" >>"$FAKE_LOG"
case "$*" in
  *"apt-get install"*) for p; do :; done; echo "$p" >>"$FAKE_DPKG" ;;
  *"loginctl enable-linger"*) echo yes >"$SB/linger" ;;
esac'
  # The dynamic linker cache starts empty; fake_library adds to it.
  # shellcheck disable=SC2016
  fake_cmd ldconfig '[ "$1" = -p ] && cat "$SB/ldconfig" 2>/dev/null'
  : >"$SB/ldconfig"
  # A regular user with a fixed name, so snapshots do not depend on who runs the tests.
  # shellcheck disable=SC2016
  fake_cmd id 'case "${1:-}" in -u) echo 1000 ;; -un) echo builder ;; *) echo "uid=1000(builder)" ;; esac'
}

# fake_orca_linux: Orca installed from the .deb, plus systemd. The CLI (orca-ide on PATH) answers status, skills
# and environment list (failing without a cli-environments.json, so role.sh reads the pairing store files); the
# Electron executable under $ORCA_APP_PATH answers orca-rpc calls. The runtime is up while $SB/runtime-up exists,
# which the fake `systemctl --user start` creates. Its status reply carries a fake pairing URL, so any test can
# prove that setup.sh never prints what the CLI reports.
fake_orca_linux() {
  export ORCA_APP_PATH=$SB/opt/Orca
  mkdir -p "$ORCA_APP_PATH/resources"
  echo '{"defaultTuiAgent":"claude","agentStatusHooksEnabled":true}' >"$SB/orca-settings.json"
  echo '{"ok":true,"result":{"skills":[{"name":"orca-cli"},{"name":"orca-linear"},{"name":"computer-use"}]}}' >"$SB/orca-skills.json"
  cat >"$ORCA_APP_PATH/orca-ide" <<SH
#!$REAL_BASH
case "\$1" in *role.cjs) exec "$REAL_NODE" "\$@" ;; esac
[ -e "\$SB/runtime-up" ] || { echo 'runtime unreachable' >&2; exit 1; }
case "\$3" in
  settings.get) printf '{"settings":%s}\n' "\$(cat "\$SB/orca-settings.json")" ;;
  settings.update) cat >"\$SB/orca-settings.json"; echo '{}' ;;
  accounts.list) echo '{"codex":{"activeAccountId":null},"claude":{"activeAccountId":null}}' ;;
  *) echo "Orca \$*" >>"\$FAKE_LOG"; echo '{}' ;;
esac
SH
  chmod +x "$ORCA_APP_PATH/orca-ide"
  # shellcheck disable=SC2016 # the stub bodies expand when the stubs run
  fake_cmd orca-ide '
case "$1 $2" in
  "environment list") cat "$ORCA_USER_DATA/cli-environments.json" 2>/dev/null || exit 1 ;;
  "skills installed") cat "$SB/orca-skills.json" ;;
  "status --json")
    [ -e "$SB/runtime-up" ] || { echo "{\"ok\":false}"; exit 1; }
    echo "{\"ok\":true,\"result\":{\"runtime\":{\"reachable\":true},\"pairing\":{\"url\":\"orca://pair?code=FAKE-PAIRING-SECRET\"}}}" ;;
  *) echo "orca-ide $*" >>"$FAKE_LOG" ;;
esac'
  # shellcheck disable=SC2016
  fake_cmd loginctl 'case "$1" in show-user) cat "$SB/linger" 2>/dev/null || echo no ;; *) echo "loginctl $*" >>"$FAKE_LOG"; exit 1 ;; esac'
  # shellcheck disable=SC2016
  fake_cmd systemctl '
[ "$1" = --user ] || { echo "systemctl $*" >>"$FAKE_LOG"; exit 1; }
shift
quiet=no; [ "${2:-}" = --quiet ] && quiet=yes
case "$1" in
  show-environment) exit 0 ;;
  is-enabled) [ -e "$SB/unit-enabled" ] ;;
  is-active) if [ -e "$SB/runtime-up" ]; then [ $quiet = yes ] || echo active; else [ $quiet = yes ] || echo inactive; exit 3; fi ;;
  enable) echo "systemctl --user $*" >>"$FAKE_LOG"; touch "$SB/unit-enabled" ;;
  start | restart) echo "systemctl --user $*" >>"$FAKE_LOG"; touch "$SB/runtime-up" ;;
  *) echo "systemctl --user $*" >>"$FAKE_LOG" ;;
esac'
}

# fake_library <soname>: the fake `ldconfig -p` (installed by fake_linux) lists the library.
fake_library() {
  printf '\t%s (libc6,x86-64) => /usr/lib/x86_64-linux-gnu/%s\n' "$1" "$1" >>"$SB/ldconfig"
}

# fake_gpg: `gpg --show-keys` lists the fingerprints written in a fake key file ("FAKEKEY <fpr> ..."), and
# fails on anything else; `--dearmor` copies the input.
fake_gpg() {
  # shellcheck disable=SC2016
  fake_cmd gpg '
for file; do :; done
case " $* " in
  *" --dearmor "*) out=""; prev=""; for a; do [ "$prev" = --output ] && out=$a; prev=$a; done; cat "$file" >"$out"; exit 0 ;;
esac
read -r magic fprs <"$file" || true
[ "$magic" = FAKEKEY ] || exit 2
for fpr in $fprs; do printf "pub:-:4096:1:%s:0:::-:::scESC::::::23::0:\nfpr:::::::::%s:\nsub:-:4096:1:0:0:::::e\nfpr:::::::::SUB%s:\n" "${fpr: -16}" "$fpr" "$fpr"; done'
}
