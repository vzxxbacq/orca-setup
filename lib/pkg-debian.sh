# shellcheck shell=bash
# apt packages, third-party apt repositories and the Orca .deb on Ubuntu 24.04 / Debian 12 (x86_64). Existing installs are
# detected and never upgraded. as_root is the only place that calls sudo; in plan mode it prints each command
# instead of running it, so --plan lists exactly the root commands --apply would run.

APT_KEYRINGS_DIR=${ORCA_SETUP_APT_KEYRINGS_DIR:-/etc/apt/keyrings}
APT_SOURCES_DIR=${ORCA_SETUP_APT_SOURCES_DIR:-/etc/apt/sources.list.d}
DEBIAN_MODE=apply # plan: print root commands instead of running them
GITHUB_API=${ORCA_SETUP_GITHUB_API:-https://api.github.com}
APT_UPDATED=no

as_root() {
  if [ "$DEBIAN_MODE" = plan ]; then
    printf '           sudo %s\n' "$*"
    return 0
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

# debian_package <method>: the apt package an apt method installs.
debian_package() {
  case "$1" in
    apt:*) printf '%s\n' "${1#apt:}" ;;
    apt-repo:* | orca-deb:*) printf '%s\n' "${1##*:}" ;;
    *) return 1 ;;
  esac
}

# debian_installed <method>: dpkg already holds the package (the check command may be missing, or "-").
debian_installed() {
  local package
  package=$(debian_package "$1") || return 1
  have dpkg-query || return 1
  # shellcheck disable=SC2016 # ${Status} is a dpkg-query format field
  [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" = 'install ok installed' ]
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

# apt_repo_row <repo>: the apt-repos.tsv row for one repository.
apt_repo_row() {
  local row
  row=$(manifest_rows apt-repos.tsv | awk -F'\t' -v repo="$1" '$1 == repo')
  [ -n "$row" ] || die "no apt repository named $1 in manifest/apt-repos.tsv"
  printf '%s\n' "$row"
}

apt_repo_uri() { apt_repo_row "$1" | cut -f6; }

# debian_add_repo <repo>: trust the repository's signing key (only after its fingerprints match the manifest)
# and add its source list. Nothing happens when the keyring verifies and the source list is already in place.
debian_add_repo() {
  local repo key_url fingerprints keyring list uri suite components keyring_path list_path line stage key source
  IFS=$'\t' read -r repo key_url fingerprints keyring list uri suite components <<<"$(apt_repo_row "$1")"
  keyring_path=$APT_KEYRINGS_DIR/$keyring
  list_path=$APT_SOURCES_DIR/$list
  line="deb [arch=amd64 signed-by=$keyring_path] $uri $suite $components"
  if [ -r "$keyring_path" ] && [ "$(cat "$list_path" 2>/dev/null)" = "$line" ] && key_matches "$keyring_path" "$fingerprints"; then
    return 0
  fi
  if [ "$DEBIAN_MODE" = plan ]; then
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

# github_deb_install <owner/repo> <package>: install <package>_<version>_amd64.deb from the latest stable GitHub
# release of <owner/repo> (never a draft or prerelease). The download must match the sha256 digest GitHub
# records for the release asset, and its control fields must name <package> for amd64; then apt installs it
# from the local file and resolves its dependencies. Nothing is installed when any check fails.
github_deb_install() {
  local repo=$1 package=$2 stage asset tag name url digest
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
  step curl -q -fLsS --connect-timeout 10 --max-time 60 -H 'Accept: application/vnd.github+json' \
    "$GITHUB_API/repos/$repo/releases/latest" -o "$stage/release.json" || die "could not read the latest $repo release."
  asset=$(node "$ORCA_SETUP_ROOT/lib/json.cjs" release-asset "^${package}_[0-9][^_/]*_amd64[.]deb\$" <"$stage/release.json") ||
    die "the latest $repo release has no single ${package}_<version>_amd64.deb."
  IFS=$'\t' read -r tag name url digest <<<"$asset"
  case "$url" in "https://github.com/$repo/releases/download/$tag/$name") ;; *) die "unexpected download URL for $name: $url" ;; esac
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "GitHub records no sha256 digest for $name; refusing to install an unverified package (install it by hand from https://github.com/$repo/releases)."
  info "$repo $tag: $name"
  step curl -q -fLsS --connect-timeout 10 --max-time 900 "$url" -o "$stage/$name" || die "could not download $name."
  printf '%s  %s\n' "${digest#sha256:}" "$stage/$name" | sha256sum -c --status ||
    die "$name does not match the sha256 digest GitHub records for it; refusing to install it."
  { [ "$(dpkg-deb -f "$stage/$name" Package)" = "$package" ] && [ "$(dpkg-deb -f "$stage/$name" Architecture)" = amd64 ]; } ||
    die "$name is not the $package package for amd64; refusing to install it."
  info "verified $name (sha256 ${digest#sha256:})"
  # apt reads local packages as its unprivileged _apt user; setup.sh's umask 077 would hide the file from it.
  chmod 0755 "$stage"
  chmod 0644 "$stage/$name"
  apt_install "$stage/$name"
  rm -rf -- "$stage"
  trap - EXIT
}

# debian_install <method>: install one missing apt package (with its repository first, when it needs one).
debian_install() {
  local spec
  case "$1" in
    apt:*) apt_install "${1#apt:}" ;;
    apt-repo:*)
      spec=${1#apt-repo:}
      debian_add_repo "${spec%%:*}"
      apt_install "${spec#*:}" ;;
    orca-deb:*)
      spec=${1#orca-deb:}
      github_deb_install "${spec%:*}" "${spec##*:}" ;;
    *) die "unknown Debian install method: $1" ;;
  esac
}

# debian_plan <method>: print the root commands debian_install would run.
debian_plan() {
  case "$1" in apt:* | apt-repo:* | orca-deb:*) DEBIAN_MODE=plan debian_install "$1" ;; esac
}
