# shellcheck shell=bash
# apt packages, third-party apt repositories and the Orca .deb on Ubuntu 24.04 / Debian 12 (x86_64). Existing installs are
# detected and never upgraded. as_root is the only place that calls sudo; in plan mode it prints each command
# instead of running it, so --plan lists exactly the root commands --apply would run. The Orca server image build
# (docker/build.sh) uses the same code as root.

APT_KEYRINGS_DIR=${ORCA_SETUP_APT_KEYRINGS_DIR:-/etc/apt/keyrings}
APT_SOURCES_DIR=${ORCA_SETUP_APT_SOURCES_DIR:-/etc/apt/sources.list.d}
DEBIAN_MODE=apply # plan: print root commands instead of running them
GITHUB_API=${ORCA_SETUP_GITHUB_API:-https://api.github.com}
APT_UPDATED=no
PLANNED_REPOS='' # repositories whose setup --plan already printed

as_root() {
  if [ "$DEBIAN_MODE" = plan ]; then
    printf '           sudo %s\n' "$*"
    return 0
  fi
  # Only the Orca server image build (docker/build.sh) runs as root; setup.sh refuses to.
  if [ "$(id -u)" -eq 0 ]; then
    printf '+ %s\n' "$*"
    (umask 022 && "$@")
    return
  fi
  have sudo || die 'sudo is required for the apt steps; install it and add your user to the sudo group.'
  printf '+ sudo %s\n' "$*"
  # setup.sh runs with umask 077; files written as root must stay readable for everyone.
  (umask 022 && sudo "$@")
}

apt_get() { as_root env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

apt_update() {
  apt_get update
  APT_UPDATED=yes
}

apt_install() {
  [ "$APT_UPDATED" = yes ] || apt_update
  apt_get install -y --no-install-recommends "$@"
}

# apt_pick <a|b|...>: the first alternative apt can install (a package name differs between Ubuntu 24.04 and
# Debian 12, e.g. libasound2t64 and libasound2), else the first one. Reads the package lists only; --apply refreshes
# them first (debian_install), --plan uses whatever lists the device has.
apt_pick() {
  local alt rest=$1
  while [ -n "$rest" ]; do
    alt=${rest%%|*}
    if have apt-cache && apt-cache show --no-all-versions "$alt" >/dev/null 2>&1; then printf '%s\n' "$alt"; return; fi
    [ "$alt" = "$rest" ] && break
    rest=${rest#*|}
  done
  printf '%s\n' "${1%%|*}"
}

# debian_package <method>: the apt package an apt method installs (alternatives "a|b" stay as they are).
debian_package() {
  case "$1" in
    apt:*) printf '%s\n' "${1#apt:}" ;;
    apt-repo:* | orca-deb:*) printf '%s\n' "${1##*:}" ;;
    *) return 1 ;;
  esac
}

# debian_installed <method>: dpkg already holds the package, or one of its alternatives (the check command may be
# missing, or "-").
debian_installed() {
  local packages package
  packages=$(debian_package "$1") || return 1
  have dpkg-query || return 1
  for package in ${packages//|/ }; do
    # shellcheck disable=SC2016 # ${Status} is a dpkg-query format field
    [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" != 'install ok installed' ] || return 0
  done
  return 1
}

# debian_order: manifest rows (name<TAB>check<TAB>method) in install order. Distribution packages come first
# because curl, gnupg and the certificates are needed to add repositories; npm needs Node.js from a repository;
# uv-managed tools need uv from its installer. The order within each class is kept.
debian_order() {
  awk -F'\t' '
    { if ($3 ~ /^apt:/) r = 1; else if ($3 ~ /^apt-repo:/) r = 2; else if ($3 ~ /^installer:/) r = 3
      else if ($3 ~ /^npm:/) r = 4; else r = 5
      rows[r] = rows[r] $0 "\n" }
    END { for (r = 1; r <= 5; r++) printf "%s", rows[r] }
  '
}

# key_fingerprints <file>: primary-key fingerprints of an OpenPGP key file, one per line. Read-only: a throwaway
# GNUPGHOME keeps the user's keyring untouched.
key_fingerprints() {
  local home status=0
  have gpg || return 1
  home=$(mktemp -d "${TMPDIR:-/tmp}/orca-setup-gpg.XXXXXX")
  GNUPGHOME=$home gpg --batch --quiet --show-keys --with-colons --with-fingerprint "$1" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10 } { want = 0 }' || status=$?
  rm -rf -- "$home"
  return "$status"
}

# key_matches <file> <fingerprint,...>: the key holds at least one primary key and only expected ones.
key_matches() {
  local fingerprints fingerprint
  fingerprints=$(key_fingerprints "$1") || return 1
  [ -n "$fingerprints" ] || return 1
  while IFS= read -r fingerprint; do
    case ",$2," in
      *",$fingerprint,"*) ;;
      *) warn "unexpected signing key $fingerprint in $1"; return 1 ;;
    esac
  done <<<"$fingerprints"
}

# apt_repo_row <repo>: the apt-repos.tsv row for one repository, with {distro} and {codename} replaced by this
# device's os-release ID and release code name (Docker publishes one repository per distribution and release).
apt_repo_row() {
  local row codename
  row=$(manifest_rows apt-repos.tsv | awk -F'\t' -v repo="$1" '$1 == repo')
  [ -n "$row" ] || die "no apt repository named $1 in manifest/apt-repos.tsv"
  case "$row" in
    *'{codename}'*)
      codename=$(os_release_field UBUNTU_CODENAME)
      [ -n "$codename" ] || codename=$(os_release_field VERSION_CODENAME)
      [ -n "$codename" ] || die "the $1 repository needs the release code name, which /etc/os-release does not name."
      row=${row//\{codename\}/$codename} ;;
  esac
  row=${row//\{distro\}/$(os_release_field ID)}
  printf '%s\n' "$row"
}

apt_repo_uri() { apt_repo_row "$1" | cut -f6; }

# apt_repo_configured <repo>: the repository's keyring verifies against the manifest and its source list is the
# one debian_add_repo writes.
apt_repo_configured() {
  local repo key_url fingerprints keyring list uri suite components keyring_path
  IFS=$'\t' read -r repo key_url fingerprints keyring list uri suite components <<<"$(apt_repo_row "$1")"
  keyring_path=$APT_KEYRINGS_DIR/$keyring
  [ -r "$keyring_path" ] &&
    [ "$(cat "$APT_SOURCES_DIR/$list" 2>/dev/null)" = "deb [arch=amd64 signed-by=$keyring_path] $uri $suite $components" ] &&
    key_matches "$keyring_path" "$fingerprints"
}

# debian_add_repo <repo>: trust the repository's signing key (only after its fingerprints match the manifest)
# and add its source list. Nothing happens when the keyring verifies and the source list is already in place.
debian_add_repo() {
  local repo key_url fingerprints keyring list uri suite components keyring_path list_path line stage key source
  apt_repo_configured "$1" && return 0
  IFS=$'\t' read -r repo key_url fingerprints keyring list uri suite components <<<"$(apt_repo_row "$1")"
  keyring_path=$APT_KEYRINGS_DIR/$keyring
  list_path=$APT_SOURCES_DIR/$list
  line="deb [arch=amd64 signed-by=$keyring_path] $uri $suite $components"
  if [ "$DEBIAN_MODE" = plan ]; then
    # Several packages may share one repository; its setup is printed once.
    case " $PLANNED_REPOS " in *" $repo "*) return 0 ;; esac
    PLANNED_REPOS="$PLANNED_REPOS $repo"
    info "           download $key_url, require fingerprint(s) $fingerprints"
    key='<verified key>'
    source='<source list>'
  else
    have gpg || die "gpg is required to verify the $repo signing key."
    stage=$(mktemp -d "${TMPDIR:-/tmp}/orca-setup.XXXXXX")
    step curl -q -fLsS --connect-timeout 10 --max-time 120 "$key_url" -o "$stage/key" || { rm -rf -- "$stage"; die "could not download the $repo signing key."; }
    if ! key_matches "$stage/key" "$fingerprints"; then
      rm -rf -- "$stage"
      die "the $repo signing key does not match manifest/apt-repos.tsv ($fingerprints); refusing to trust it."
    fi
    key=$stage/key
    if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$stage/key"; then
      mkdir -m 700 "$stage/gnupg"
      GNUPGHOME=$stage/gnupg gpg --batch --quiet --dearmor --output "$stage/key.gpg" "$stage/key"
      key=$stage/key.gpg
    fi
    source=$stage/source.list
    printf '%s\n' "$line" >"$source"
  fi
  as_root install -d -m 0755 "$APT_KEYRINGS_DIR"
  as_root install -m 0644 "$key" "$keyring_path"
  as_root install -m 0644 "$source" "$list_path"
  [ "$DEBIAN_MODE" != plan ] || info "             $line"
  apt_update
  [ -z "${stage:-}" ] || rm -rf -- "$stage"
}

# github_release_fetch <owner/repo> <asset regex> <asset label> <stage>: download the one asset matching the regex
# from the latest stable GitHub release of <owner/repo> (never a draft or prerelease) into <stage>, and verify it
# against the sha256 digest GitHub records for that asset. Sets RELEASE_TAG and RELEASE_NAME; dies on any mismatch.
github_release_fetch() {
  local repo=$1 pattern=$2 label=$3 stage=$4 asset url digest
  have node || die "node is required to read the $repo release."
  have sha256sum || die "sha256sum is required to verify $label."
  step curl -q -fLsS --connect-timeout 10 --max-time 60 -H 'Accept: application/vnd.github+json' \
    "$GITHUB_API/repos/$repo/releases/latest" -o "$stage/release.json" || die "could not read the latest $repo release."
  asset=$(node "$ORCA_SETUP_ROOT/lib/json.cjs" release-asset "$pattern" <"$stage/release.json") ||
    die "the latest $repo release has no single $label."
  IFS=$'\t' read -r RELEASE_TAG RELEASE_NAME url digest <<<"$asset"
  case "$url" in "https://github.com/$repo/releases/download/$RELEASE_TAG/$RELEASE_NAME") ;; *) die "unexpected download URL for $RELEASE_NAME: $url" ;; esac
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "GitHub records no sha256 digest for $RELEASE_NAME; refusing to install an unverified package (install it by hand from https://github.com/$repo/releases)."
  info "$repo $RELEASE_TAG: $RELEASE_NAME"
  step curl -q -fLsS --connect-timeout 10 --max-time 900 "$url" -o "$stage/$RELEASE_NAME" || die "could not download $RELEASE_NAME."
  printf '%s  %s\n' "${digest#sha256:}" "$stage/$RELEASE_NAME" | sha256sum -c --status ||
    die "$RELEASE_NAME does not match the sha256 digest GitHub records for it; refusing to install it."
  info "verified $RELEASE_NAME (sha256 ${digest#sha256:})"
}

# github_deb_install <owner/repo> <package>: install <package>_<version>_amd64.deb from the latest stable GitHub
# release of <owner/repo>. The download must match the sha256 digest GitHub records for the release asset, and its
# control fields must name <package> for amd64; then apt installs it from the local file and resolves its
# dependencies. Nothing is installed when any check fails.
github_deb_install() {
  local repo=$1 package=$2 stage name
  if [ "$DEBIAN_MODE" = plan ]; then
    info "           resolve the latest stable release of $repo with the GitHub API; download ${package}_<version>_amd64.deb"
    info "           require the sha256 digest GitHub records for that asset, and Package: $package, Architecture: amd64"
    apt_install "<verified ${package}_<version>_amd64.deb>"
    return 0
  fi
  have node || die "node is required to read the $repo release."
  { have sha256sum && have dpkg-deb; } || die "sha256sum and dpkg-deb are required to verify the $package package."
  stage=$(mktemp -d "${TMPDIR:-/tmp}/orca-setup.XXXXXX")
  # shellcheck disable=SC2064 # expand $stage now; the trap only cleans up after a failure below
  trap "rm -rf -- '$stage'" EXIT
  github_release_fetch "$repo" "^${package}_[0-9][^_/]*_amd64[.]deb\$" "${package}_<version>_amd64.deb" "$stage"
  name=$RELEASE_NAME
  { [ "$(dpkg-deb -f "$stage/$name" Package)" = "$package" ] && [ "$(dpkg-deb -f "$stage/$name" Architecture)" = amd64 ]; } ||
    die "$name is not the $package package for amd64; refusing to install it."
  # apt reads local packages as its unprivileged _apt user; setup.sh's umask 077 would hide the file from it.
  chmod 0755 "$stage"
  chmod 0644 "$stage/$name"
  apt_install "$stage/$name"
  rm -rf -- "$stage"
  trap - EXIT
}

# github_binary_install <owner/repo> <asset> <command>: install the single-file binary <asset> from the latest
# stable GitHub release of <owner/repo> as ~/.local/bin/<command>, after it matches the sha256 digest GitHub records
# for it. User-level: no sudo. Nothing is written to ~/.local/bin when a check fails.
github_binary_install() {
  local repo=$1 asset=$2 command=$3 stage bin_dir=$HOME/.local/bin
  if [ "$DEBIAN_MODE" = plan ]; then
    info "           resolve the latest stable release of $repo with the GitHub API; download $asset"
    info "           require the sha256 digest GitHub records for that asset, then install it as ~/.local/bin/$command"
    return 0
  fi
  stage=$(mktemp -d "${TMPDIR:-/tmp}/orca-setup.XXXXXX")
  # shellcheck disable=SC2064 # expand $stage now; the trap only cleans up after a failure below
  trap "rm -rf -- '$stage'" EXIT
  github_release_fetch "$repo" "^${asset//./[.]}\$" "$asset" "$stage"
  mkdir -p "$bin_dir"
  chmod 0755 "$stage/$asset"
  step cp "$stage/$asset" "$bin_dir/$command"
  rm -rf -- "$stage"
  trap - EXIT
}

# debian_conflicts <repo>: the installed packages that apt-conflicts.tsv lists for a repository (another source's
# install of the same software, which --apply never replaces), space-separated; empty when there are none.
debian_conflicts() {
  local packages package found=''
  packages=$(manifest_rows apt-conflicts.tsv | awk -F'\t' -v repo="$1" '$1 == repo { print $2 }')
  for package in $packages; do
    ! debian_installed "apt:$package" || found="$found $package"
  done
  printf '%s\n' "${found# }"
}

# debian_install <method>: install one missing apt package (with its repository first, when it needs one).
debian_install() {
  local spec
  case "$1" in
    apt:*)
      spec=${1#apt:}
      # Alternatives are resolved against fresh package lists.
      if [ "$spec" != "${spec%%|*}" ] && [ "$DEBIAN_MODE" != plan ] && [ "$APT_UPDATED" != yes ]; then apt_update; fi
      apt_install "$(apt_pick "$spec")" ;;
    apt-repo:*)
      spec=${1#apt-repo:}
      debian_add_repo "${spec%%:*}"
      apt_install "${spec#*:}" ;;
    orca-deb:*)
      spec=${1#orca-deb:}
      github_deb_install "${spec%:*}" "${spec##*:}" ;;
    github-release:*)
      # <owner/repo>:<asset>:<command>
      spec=${1#github-release:}
      github_binary_install "${spec%%:*}" "$(printf '%s' "$spec" | cut -d: -f2)" "${spec##*:}" ;;
    *) die "unknown Debian install method: $1" ;;
  esac
}

# debian_plan <method>: print the root commands debian_install would run.
debian_plan() {
  case "$1" in apt:* | apt-repo:* | orca-deb:* | github-release:*) DEBIAN_MODE=plan debian_install "$1" ;; esac
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
