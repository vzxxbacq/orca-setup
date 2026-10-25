# shellcheck shell=bash
# Manifest rows: how one row is labelled, detected and installed, and how a whole group is planned or applied.
# Shared by setup.sh and the Orca server image build (docker/build.sh). Needs PLATFORM (macos | debian) and
# lib/common.sh, lib/manifest.sh, lib/pkg-macos.sh, lib/pkg-debian.sh and lib/npm-tools.sh.

# Which manifest a group lives in.
group_manifest() {
  case "$1" in agent-*) echo agents.tsv ;; *) echo baseline.tsv ;; esac
}

method_label() {
  case "$1" in
    brew:*) printf 'brew formula %s' "${1#brew:}" ;;
    cask:*) printf 'brew cask %s' "${1#cask:}" ;;
    npm:*) printf 'npm %s -> ~/.local' "${1#npm:}" ;;
    installer:*) printf 'official installer %s' "${1#installer:}" ;;
    github-release:*) printf '%s from the latest stable %s release -> ~/.local/bin' "$(printf '%s' "${1#github-release:}" | cut -d: -f2)" "$(printf '%s' "${1#github-release:}" | cut -d: -f1)" ;;
    os) printf 'shipped with macOS (Command Line Tools)' ;;
    apt:*) printf 'apt %s' "${1#apt:}" ;;
    apt-repo:*) printf 'apt %s from %s' "${1##*:}" "$(apt_repo_uri "$(printf '%s' "${1#apt-repo:}" | cut -d: -f1)")" ;;
    uv-python:*) printf 'uv python install %s' "${1#uv-python:}" ;;
    uv-tool:*) printf 'uv tool install %s' "${1#uv-tool:}" ;;
    orca-deb:*) printf '.deb from the latest stable %s release' "$(printf '%s' "${1#orca-deb:}" | cut -d: -f1)" ;;
    *) printf '%s' "$1" ;;
  esac
}

# row_present <check> <method>: detected through the check command, or through the package manager.
# A "-" check on an apt row means only dpkg can tell.
row_present() {
  case "$2" in
    apt:* | apt-repo:* | orca-deb:*) { [ "$1" != - ] && is_present "$1"; } || debian_installed "$2" ;;
    brew:* | cask:*) is_present "$1" || macos_installed "$2" ;;
    *) is_present "$1" ;;
  esac
}

# platform_rows <file.tsv> <group>: the group's rows for this platform, in install order.
platform_rows() {
  if [ "$PLATFORM" = debian ]; then manifest_select "$1" debian "$2" | debian_order; else manifest_select "$1" "$PLATFORM" "$2"; fi
}

# install_row <method>: install one missing row with its method.
install_row() {
  case "$1" in
    npm:*) npm_install "${1#npm:}" ;;
    installer:*) run_installer "${1#installer:}" ;;
    uv-python:*) have uv || die 'uv is required to install Python.'; step uv python install "${1#uv-python:}" ;;
    uv-tool:*) have uv || die "uv is required to install ${1#uv-tool:}."; step uv tool install "${1#uv-tool:}" ;;
    apt:* | apt-repo:* | orca-deb:* | github-release:*) debian_install "$1" ;;
    *) macos_install "$1" ;;
  esac
}

# process_rows <plan|apply>: plan or apply the "name<TAB>check<TAB>method" rows read from fd 3 (the loop keeps the
# caller's stdin for installers and sudo).
process_rows() {
  local mode=$1 name check method
  while IFS=$'\t' read -r name check method <&3; do
    if row_present "$check" "$method"; then
      if [ "$mode" = plan ]; then printf '  present  %s\n' "$name"; else printf 'PRESENT %s\n' "$name"; fi
      continue
    fi
    if [ "$mode" = plan ]; then
      if [ "$method" = os ]; then printf '  missing  %-22s %s\n' "$name" "$(method_label "$method")"
      else printf '  install  %-22s %s\n' "$name" "$(method_label "$method")"; fi
      debian_plan "$method"
      continue
    fi
    install_row "$method"
    row_present "$check" "$method" || die "$name is still missing after installation"
  done
}

# Print or apply one manifest group; $1 = plan|apply, $2 = group, $3 = manifest file.
process_group() {
  process_rows "$1" 3< <(platform_rows "$3" "$2")
}
