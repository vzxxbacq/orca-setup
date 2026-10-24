# shellcheck shell=bash
# Device detection: OS, distribution, architecture, package manager, desktop presence and the Orca CLI name.
# Every function prints a single word (or line) and has no side effects.
# Tests point ORCA_SETUP_OS_RELEASE at a fake os-release file and put a fake `uname` on PATH.

# macos | linux | unsupported
detect_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux) echo linux ;;
    *) echo unsupported ;;
  esac
}

# arm64 | x86_64 | the raw machine name
detect_arch() {
  local machine
  machine=$(uname -m)
  case "$machine" in
    arm64 | aarch64) echo arm64 ;;
    x86_64 | amd64) echo x86_64 ;;
    *) echo "$machine" ;;
  esac
}

# os_release_field <KEY>: value from os-release, unquoted, without sourcing the file.
os_release_field() {
  local file=${ORCA_SETUP_OS_RELEASE:-/etc/os-release} line value=''
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$1="*) value=${line#*=} ;;
    esac
  done <"$file"
  value=${value#\"}
  value=${value%\"}
  value=${value#\'}
  value=${value%\'}
  printf '%s\n' "$value"
}

# "<id> <version>", e.g. "macos 15.5" or "ubuntu 24.04"
detect_distro() {
  case "$(detect_os)" in
    macos) printf 'macos %s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)" ;;
    linux) printf '%s %s\n' "$(os_release_field ID)" "$(os_release_field VERSION_ID)" ;;
    *) echo 'unknown unknown' ;;
  esac
}

# Distribution family: debian | fedora | other (Linux only)
detect_linux_family() {
  local ids
  ids=" $(os_release_field ID) $(os_release_field ID_LIKE) "
  case "$ids" in
    *" debian "* | *" ubuntu "*) echo debian ;;
    *" fedora "* | *" rhel "* | *" centos "*) echo fedora ;;
    *) echo other ;;
  esac
}

# brew | apt | dnf | none
detect_pkg_manager() {
  case "$(detect_os)" in
    macos)
      if command -v brew >/dev/null 2>&1; then echo brew; else echo none; fi ;;
    linux)
      case "$(detect_linux_family)" in
        debian) echo apt ;;
        fedora) echo dnf ;;
        *) echo none ;;
      esac ;;
    *) echo none ;;
  esac
}

# yes | no: whether a graphical session is available to open a browser or an app.
detect_desktop() {
  case "$(detect_os)" in
    macos) echo yes ;;
    linux)
      if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then echo yes; else echo no; fi ;;
    *) echo no ;;
  esac
}

# supported | planned | unsupported: whether this phase can --apply on the device.
detect_support() {
  local os arch distro
  os=$(detect_os)
  arch=$(detect_arch)
  case "$os" in
    macos)
      case "$arch" in arm64 | x86_64) echo supported ;; *) echo unsupported ;; esac ;;
    linux)
      distro=$(detect_distro)
      if [ "$arch" = x86_64 ] && { [ "$distro" = 'ubuntu 24.04' ] || [ "$distro" = 'debian 12' ]; }; then
        echo planned
      else
        echo unsupported
      fi ;;
    *) echo unsupported ;;
  esac
}

# Orca desktop app bundle (macOS).
orca_app_path() {
  printf '%s\n' "${ORCA_APP_PATH:-${ORCA_SETUP_APPLICATIONS_DIR:-/Applications}/Orca.app}"
}

# The Orca CLI to call. ORCA_CLI_COMMAND wins; on Linux bare `orca` is the GNOME screen reader, so use
# `orca-ide`; on macOS fall back to the shim inside the app bundle when `orca` is not on PATH yet.
detect_orca_cli() {
  local shim
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    printf '%s\n' "$ORCA_CLI_COMMAND"
    return
  fi
  case "$(detect_os)" in
    linux) echo orca-ide ;;
    macos)
      shim="$(orca_app_path)/Contents/Resources/bin/orca"
      if ! command -v orca >/dev/null 2>&1 && [ -x "$shim" ]; then
        printf '%s\n' "$shim"
      else
        echo orca
      fi ;;
    *) echo orca ;;
  esac
}

# Orca's user-data directory, which holds the pairing stores read by orca/role.sh.
orca_user_data_dir() {
  if [ -n "${ORCA_USER_DATA_DIR:-}" ]; then
    printf '%s\n' "$ORCA_USER_DATA_DIR"
    return
  fi
  case "$(detect_os)" in
    macos) printf '%s\n' "$HOME/Library/Application Support/orca" ;;
    *) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/orca" ;;
  esac
}
