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
# shellcheck disable=SC2034 # used by the test files
REAL_PYTHON=$(command -v python3 || true)

# Real utilities the scripts need; everything else must be faked explicitly.
SANDBOX_UTILS='bash env awk sed grep cat tr sort head cut paste mktemp dirname basename rm mkdir chmod id node ls wc date cp uniq tail sleep touch cksum sha256sum shasum ln readlink rmdir'

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
  export ORCA_SETUP_APPLICATIONS_DIR=$SB/Applications
  export ORCA_USER_DATA=$SB/userdata
  export FAKE_LOG=$SB/fake.log
  unset ORCA_CLI_COMMAND ORCA_APP_PATH ORCA_SETUP_OS_RELEASE DISPLAY WAYLAND_DISPLAY XDG_CONFIG_HOME XDG_DATA_HOME \
    ORCA_SETUP_IMAGE ORCA_SETUP_CONTAINER ORCA_SETUP_HOST_ITEMS ORCA_SETUP_HOST_DEVICE ORCA_SETUP_HOST_SERVER \
    ORCA_SETUP_ROLE_CHECKED ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS
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

# fake_uname <kernel> <machine>: `uname -n` (the host name) answers fakehost.
fake_uname() {
  fake_cmd uname "case \"\${1:-}\" in -m) echo $2 ;; -n) echo fakehost ;; *) echo $1 ;; esac"
}

# fake_ip <address...>: `ip -4 -o addr show` lists lo (127.0.0.1/8) and each address (also any line added to
# $SB/ip-addresses later) on an interface of its own; any other ip command fails.
fake_ip() {
  printf '%s\n' "$@" >"$SB/ip-addresses"
  # shellcheck disable=SC2016 # the stub body expands when the stub runs
  fake_cmd ip '[ "$*" = "-4 -o addr show" ] || { echo "ip $*" >>"$FAKE_LOG"; exit 1; }
echo "1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever"
n=0
while read -r address; do
  [ -n "$address" ] || continue
  echo "$((n + 2)): eth$n    inet $address/24 brd ${address%.*}.255 scope global eth$n\       valid_lft forever preferred_lft forever"
  n=$((n + 1))
done <"$SB/ip-addresses"'
}

# fake_os_release <ID> <VERSION_ID> [ID_LIKE]: with the release code name of Ubuntu 24.04 and Debian 12.
fake_os_release() {
  export ORCA_SETUP_OS_RELEASE=$SB/os-release
  {
    printf 'NAME="Fake %s"\n' "$1"
    printf 'ID=%s\n' "$1"
    printf 'VERSION_ID="%s"\n' "$2"
    case "$1 $2" in
      'ubuntu 24.04') printf 'VERSION_CODENAME=noble\nUBUNTU_CODENAME=noble\n' ;;
      'debian 12') printf 'VERSION_CODENAME=bookworm\n' ;;
    esac
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

# fake_skills_plan <installed-file> <args of skills install...>: the JSON of `skills install --dry-run --json`, with
# "keep" for skills listed in the file and "write" for the others.
# shellcheck disable=SC2016 # expanded by the stubs that source it
FAKE_SKILLS_PLAN='plan=""; prev=""
for a; do
  if [ "$prev" = --skill ]; then
    if grep -qx -- "$a" "$installed" 2>/dev/null; then kind=keep; else kind=write; fi
    plan="$plan${plan:+,}{\"name\":\"$a\",\"ops\":[{\"kind\":\"$kind\"}]}"
  fi
  prev=$a
done
echo "{\"executed\":false,\"plan\":{\"skills\":[$plan]}}"'

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
  "skills install") case " $* " in *" --dry-run "*) installed=$SB/mac-skills; printf "orca-cli\norca-linear\n" >"$installed"; '"$FAKE_SKILLS_PLAN"' ;; *) echo "orca $*" >>"$FAKE_LOG" ;; esac ;;
  "status --json") echo "{\"ok\":true,\"result\":{\"runtime\":{\"reachable\":true}}}" ;;
  "--version "*) echo 1.2.3 ;;
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
# keyrings and source lists under $SB/apt, installed packages in $FAKE_DPKG, the user's groups in $SB/groups.
# The fake sudo logs every call, records `apt-get install` packages as installed, `usermod -aG` groups as joined
# and `systemctl mask` units in $SB/masked, and copies `install` files into the sandbox; it runs nothing else.
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
  *"apt-get install"*) for p; do :; done; echo "$p" >>"$FAKE_DPKG"
    # Docker Engine brings the docker command (see fake_docker).
    if [ "$p" = docker-ce ] && [ -e "$SB/docker-stub" ]; then cp "$SB/docker-stub" "$SB/bin/docker"; fi ;;
  *"loginctl enable-linger"*) echo yes >"$SB/linger" ;;
  *"usermod -aG "*) printf " %s" "$3" >>"$SB/groups" ;;
  "systemctl mask "*) shift 2; printf "%s\n" "$@" >>"$SB/masked" ;;
  "install -d "*) for d; do :; done; mkdir -p "$d" ;;
  "install -m 0644 "*) mkdir -p "$(dirname "$5")"; cp "$4" "$5" ;;
esac'
  # The dynamic linker cache starts empty; fake_library adds to it.
  # shellcheck disable=SC2016
  fake_cmd ldconfig '[ "$1" = -p ] && cat "$SB/ldconfig" 2>/dev/null'
  : >"$SB/ldconfig"
  # A regular user with a fixed name, so snapshots do not depend on who runs the tests.
  # shellcheck disable=SC2016
  # `id -nG builder` reads the group database ($SB/groups); bare `id -nG` is this session, which never changes.
  fake_cmd id 'case "${1:-}" in -u) echo 1000 ;; -g) echo 1000 ;; -un) echo builder ;; -nG) if [ -n "${2:-}" ]; then echo "builder$(cat "$SB/groups" 2>/dev/null)"; else echo builder; fi ;; *) echo "uid=1000(builder)" ;; esac'
}

# fake_orca_linux: Orca installed from the .deb, plus systemd. The CLI (orca-ide on PATH) answers status, skills
# install (with --dry-run from $SB/orca-skills; `skills installed` needs a runtime and fails) and environment list (failing without a cli-environments.json, so role.sh reads the pairing store files); the
# Electron executable under $ORCA_APP_PATH answers orca-rpc calls. The runtime is up while $SB/runtime-up exists,
# which the fake `systemctl --user start` creates. Its status reply carries a fake pairing URL, so any test can
# prove that setup.sh never prints what the CLI reports.
fake_orca_linux() {
  export ORCA_APP_PATH=$SB/opt/Orca
  mkdir -p "$ORCA_APP_PATH/resources"
  echo '{"defaultTuiAgent":"claude","agentStatusHooksEnabled":true}' >"$SB/orca-settings.json"
  printf 'orca-cli\norca-linear\ncomputer-use\n' >"$SB/orca-skills"
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
  "skills installed") exit 1 ;;
  "skills install")
    installed=$SB/orca-skills
    case " $* " in *" --dry-run "*) '"$FAKE_SKILLS_PLAN"' ;; *) echo "orca-ide $*" >>"$FAKE_LOG"; prev=""; for a; do [ "$prev" = --skill ] && echo "$a" >>"$installed"; prev=$a; done ;; esac ;;
  "--version "*) echo 1.2.3 ;;
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

# fake_docker [installed]: a Docker CLI and daemon in $SB/docker. With "installed" the docker command exists now,
# otherwise it appears when the fake sudo installs docker-ce. The daemon answers while $SB/docker/daemon exists, to
# this session when $SB/docker/session-group exists (the session has the docker group) or through the fake sg once
# the group database lists the user. Pulls resolve tags through fake_registry; `compose up` records the container
# from the compose file and starts the runtime ($SB/runtime-up), and its network mode and published ports (in
# $SB/docker/ports, which `container inspect` answers for a format naming NetworkMode); `run` and `exec` run their
# command here, with the image's /opt/orca-setup mapped to this repository and ORCA_SETUP_CONTAINER set for exec, like
# inside the container. Every call that talks to the daemon is logged without its --env values.
fake_docker() {
  mkdir -p "$SB/docker/images" "$SB/registry"
  touch "$SB/docker/daemon" "$SB/docker/compose"
  cat >"$SB/docker-stub" <<SH
#!$REAL_BASH
repo_root='$REPO_ROOT'
real_bash='$REAL_BASH'
SH
  # shellcheck disable=SC2016 # the stub body expands when the stub runs
  cat >>"$SB/docker-stub" <<'SH'
key() { printf '%s' "$1" | tr '/:@' '___'; }
if [ "${1:-}" = --version ]; then
  if [ -e "$SB/docker/podman" ]; then echo 'podman version 5.0.3'; else echo 'Docker version 27.3.1, build fake'; fi
  exit 0
fi
if [ "${1:-} ${2:-}" = 'compose version' ]; then [ -e "$SB/docker/compose" ] && echo 2.29.7; exit; fi
log=$(printf '%s ' docker "$@" | sed -E 's/(--env [A-Z_]+=)[^ ]*/\1.../g')
access=no
[ ! -e "$SB/docker/session-group" ] || access=yes
if [ "${FAKE_SG:-}" = 1 ] && id -nG builder | tr ' ' '\n' | grep -qx docker; then access=yes; fi
if [ ! -e "$SB/docker/daemon" ] || [ "$access" = no ]; then
  echo 'permission denied while trying to connect to the Docker daemon socket' >&2
  exit 1
fi
map() { mapped=(); for a; do mapped+=("${a//\/opt\/orca-setup/$repo_root}"); done; [ "${mapped[0]}" != sh ] || mapped[0]=$real_bash; }
case "$1" in
  version) echo 27.3.1 ;;
  pull)
    echo "${log% }" >>"$FAKE_LOG"
    case "$2" in
      *@sha256:*) ref=$2 ;;
      *) [ -r "$SB/registry/$(key "$2")" ] || { echo "pull: $2 not found" >&2; exit 1; }
         ref="${2%:*}@sha256:$(cat "$SB/registry/$(key "$2")")"
         echo "$ref" >"$SB/docker/images/$(key "$2")" ;;
    esac
    echo "$ref" >"$SB/docker/images/$(key "$ref")" ;;
  image)
    ref=${!#}
    [ -r "$SB/docker/images/$(key "$ref")" ] || exit 1
    case " $* " in
      *org.orca-setup.internal-ssh*) echo "${FAKE_SSH_VERSION:-0}" ;;
      *org.orca-setup.executor-network*) echo "${FAKE_EXEC_NETWORK_VERSION:-1}" ;;
      *Config.Labels*) echo '<no value>' ;;
      *RepoDigests* | *'.Id'*) cat "$SB/docker/images/$(key "$ref")" ;;
    esac ;;
  volume)
    case "$2" in
      inspect) [ -d "$SB/docker/volumes/${!#}" ] ;;
      create) echo "${log% }" >>"$FAKE_LOG"; mkdir -p "$SB/docker/volumes/${!#}" ;;
    esac ;;
  container)
    [ "$2" = inspect ] && [ -r "$SB/docker/container" ] || exit 1
    name=${!#}
    case "$name" in orca-[0-9]*-????????????-*) suffix=${name#orca-}; suffix=${suffix#*-}; suffix=${suffix#*-}; case "$suffix" in executor-gateway) name=$suffix ;; *) name=orca-$suffix ;; esac ;; esac
    case " $* " in
      *State.Health.Status*) [ ! -e "$SB/docker/unhealthy-$name" ] && echo healthy ;;
      *NetworkMode*NetworkSettings.Ports*) cat "$SB/docker/ports" 2>/dev/null ;;
      *NetworkMode*) case "$name" in orca-server) echo container:orca-gateway-id ;; orca-executor) echo container:executor-gateway-id ;; esac ;;
      *'.Id'*) echo "$name-id" ;;
      *)
        if [ "$name" != orca-server ]; then [ -e "$SB/docker/isolated" ] && [ ! -e "$SB/docker/missing-$name" ] || exit 1; fi
        cat "$SB/docker/container" ;;
    esac ;;
  compose)
    echo "${log% }" >>"$FAKE_LOG"
    rm -f "$SB/docker/secret-changed"
    file=$3
    if [[ " $* " == *" down "* ]] || [ "${!#}" = down ]; then
      rm -f "$SB/docker/container" "$SB/docker/ports" "$SB/docker/isolated"
      exit 0
    fi
    label=$(sed -n 's/^      org.orca-setup.config: "\(.*\)"$/\1/p' "$file" | head -n 1)
    if grep -qF '    network_mode: "service:orca-gateway"' "$file"; then touch "$SB/docker/isolated"
    else rm -f "$SB/docker/isolated"; fi
    echo "running $label" >"$SB/docker/container"
    # The network mode, then "<host ip>|<host port>|<port>/tcp" for each published port.
    if grep -qx '    network_mode: host' "$file"; then echo host
    else echo orca-server_default; sed -n 's/^      - "\(.*\):\([0-9]*\):\([0-9]*\)\/tcp"$/\1|\2|\3\/tcp/p' "$file"; fi >"$SB/docker/ports"
    cp "$file" "$SB/docker/compose-used.yaml"
    touch "$SB/runtime-up" ;;
  build)
    echo "${log% }" >>"$FAKE_LOG"
    prev=''; for a; do [ "$prev" != --tag ] || echo "$a" >"$SB/docker/images/$(key "$a")"; prev=$a; done ;;
  run)
    shift
    envs=(); secret_volume=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --rm | --read-only | --interactive) shift ;;
        --env) envs+=("$2"); shift 2 ;;
        --volume) case "$2" in *:/run/secrets) secret_volume=${2%:/run/secrets} ;; esac; shift 2 ;;
        --network | --tmpfs | --user | --cap-drop | --entrypoint) shift 2 ;;
        *) break ;;
      esac
    done
    echo "docker run $1 ${*:2}" >>"$FAKE_LOG"
    [ -r "$SB/docker/images/$(key "$1")" ] || { echo "run: no image $1" >&2; exit 125; }
    shift
    if [ -n "$secret_volume" ] && [ "${1:-}" = /opt/orca-setup/docker/proxy-secret.py ]; then
      cat >"$SB/docker/volumes/$secret_volume/auth"
      chmod 600 "$SB/docker/volumes/$secret_volume/auth"
      case "$secret_volume" in *-executor) current=secret-current-executor ;; *) current=secret-current ;; esac
      cp "$SB/docker/volumes/$secret_volume/auth" "$SB/docker/$current"
      touch "$SB/docker/secret-changed"
      exit 0
    fi
    map "$@"
    env ${envs[@]+"${envs[@]}"} "${mapped[@]}" ;;
  exec)
    shift
    envs=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --interactive | --tty | -i | -t | -it) shift ;;
        --env) case "$2" in *=*) envs+=("$2") ;; *) envs+=("$2=${!2:-}") ;; esac; shift 2 ;;
        *) break ;;
      esac
    done
    target=$1
    case "$target" in orca-[0-9]*-????????????-*) suffix=${target#orca-}; suffix=${suffix#*-}; suffix=${suffix#*-}; case "$suffix" in executor-gateway) target=$suffix ;; *) target=orca-$suffix ;; esac ;; esac
    set -- "$target" "${@:2}"
    if [ "$1" = orca-gateway ] || [ "$1" = executor-gateway ]; then
      if [ "${3:-}" = /opt/orca-setup/docker/proxy-secret.py ]; then
        desired=$(cat)
        current=secret-current; [ "$1" != executor-gateway ] || current=secret-current-executor
        [ -f "$SB/docker/$current" ] && [ "$(cat "$SB/docker/$current")" = "$desired" ]
        exit
      fi
      if [ "${3:-}" = check ] && [ -e "$SB/docker/secret-changed" ]; then exit 1; fi
      [ ! -e "$SB/docker/unhealthy-$1" ]
      exit
    fi
    [ "$(cut -d' ' -f1 "$SB/docker/container" 2>/dev/null)" = running ] || { echo "Error: container $1 is not running" >&2; exit 1; }
    shift
    echo "docker exec $*" >>"$FAKE_LOG"
    map "$@"
    env ORCA_SETUP_CONTAINER=orca-server ${envs[@]+"${envs[@]}"} "${mapped[@]}" ;;
  buildx)
    ref=${!#}
    [ -r "$SB/registry/$(key "$ref")" ] || exit 1
    # Indented, as buildx's json template function prints it.
    printf '{\n  "schemaVersion": 2,\n  "mediaType": "application/vnd.oci.image.index.v1+json",\n  "digest": "sha256:%s",\n  "size": 855,\n  "manifests": [\n    {\n      "digest": "sha256:%s"\n    }\n  ]\n}\n' \
      "$(cat "$SB/registry/$(key "$ref")")" 1111111111111111111111111111111111111111111111111111111111111111 ;;
  *) echo "${log% }" >>"$FAKE_LOG" ;;
esac
SH
  chmod +x "$SB/docker-stub"
  [ "${1:-}" != installed ] || cp "$SB/docker-stub" "$SB/bin/docker"
  # shellcheck disable=SC2016
  fake_cmd sg 'echo "sg $*" >>"$SB/sg.log"
[ "$1" = docker ] && [ "$2" = -c ] || exit 2
id -nG builder | tr " " "\n" | grep -qx docker || { echo "sg: failed" >&2; exit 1; }
FAKE_SG=1 exec "'"$REAL_BASH"'" -c "$3"'
}

# fake_registry <reference> <64 hex>: the digest the registry holds for a tag.
fake_registry() {
  mkdir -p "$SB/registry"
  printf '%s\n' "$2" >"$SB/registry/$(printf '%s' "$1" | tr '/:@' '___')"
}
