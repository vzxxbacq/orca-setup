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

# supported | unsupported: whether setup.sh can provision the device.
detect_support() {
  if [ -z "$(detect_unsupported_reason)" ]; then echo supported; else echo unsupported; fi
}

# Why the device cannot be provisioned; empty when it can. Linux is Ubuntu 24.04 / Debian 12 on x86_64 only.
detect_unsupported_reason() {
  local arch distro
  arch=$(detect_arch)
  case "$(detect_os)" in
    macos)
      case "$arch" in arm64 | x86_64) ;; *) echo "macOS on $arch is not supported (arm64 and x86_64 only)." ;; esac ;;
    linux)
      distro=$(detect_distro)
      if [ "$arch" != x86_64 ]; then
        echo "Linux on $arch is not supported: x86_64 only (no arm64)."
      elif [ "$distro" != 'ubuntu 24.04' ] && [ "$distro" != 'debian 12' ]; then
        echo "$distro is not supported: only Ubuntu 24.04 and Debian 12 (x86_64)."
      fi ;;
    *) echo "$(uname -s) is not supported (macOS, or Ubuntu 24.04 / Debian 12 on x86_64)." ;;
  esac
}

# Orca desktop app bundle (macOS).
orca_app_path() {
  printf '%s\n' "${ORCA_APP_PATH:-${ORCA_SETUP_APPLICATIONS_DIR:-/Applications}/Orca.app}"
}

# The installed Orca: the app bundle on macOS; on Linux the directory that holds the Electron executable and
# resources/ (the .deb uses /opt/Orca; its postinst also knows /opt/orca-ide and /opt/orca). ORCA_APP_PATH wins.
orca_install_dir() {
  local dir
  if [ "$(detect_os)" = macos ] || [ -n "${ORCA_APP_PATH:-}" ]; then
    orca_app_path
    return
  fi
  for dir in /opt/Orca /opt/orca-ide /opt/orca; do
    [ -d "$dir/resources" ] && { printf '%s\n' "$dir"; return; }
  done
  echo /opt/Orca
}

# orca_executable: Orca's Electron executable, which runs scripts as Node.js with ELECTRON_RUN_AS_NODE=1.
# On Linux the name follows the CLI shim's own lookup (orca-ide, orca, Orca).
orca_executable() {
  local dir name
  dir=$(orca_install_dir)
  if [ "$(detect_os)" = macos ]; then
    printf '%s\n' "$dir/Contents/MacOS/Orca"
    return
  fi
  for name in orca-ide orca Orca; do
    [ -f "$dir/$name" ] && [ -x "$dir/$name" ] && { printf '%s\n' "$dir/$name"; return; }
  done
  printf '%s\n' "$dir/orca-ide"
}

# orca_resources_dir: the app's resources (app.asar.unpacked/out/cli/runtime-client.js lives below it).
orca_resources_dir() {
  if [ "$(detect_os)" = macos ]; then printf '%s\n' "$(orca_install_dir)/Contents/Resources"
  else printf '%s\n' "$(orca_install_dir)/resources"; fi
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

# orca_user_data_candidates: possible Orca user-data directories (pairing stores), most likely first.
# Mirrors upstream orcad's resolveUserDataPath: $ORCA_USER_DATA, else $XDG_DATA_HOME/Orca, else ~/.orca on a
# headless Linux runtime; the Electron desktop path follows as a second candidate on Linux.
orca_user_data_candidates() {
  if [ -n "${ORCA_USER_DATA:-}" ]; then
    printf '%s\n' "$ORCA_USER_DATA"
    return
  fi
  case "$(detect_os)" in
    macos) printf '%s\n' "$HOME/Library/Application Support/Orca" ;;
    *)
      if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s\n' "$XDG_DATA_HOME/Orca"; else printf '%s\n' "$HOME/.orca"; fi
      printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/Orca" ;;
  esac
}

# orca_user_data_dir: the first candidate that holds a pairing store, else the first candidate.
orca_user_data_dir() {
  local dir first=''
  while IFS= read -r dir; do
    [ -n "$first" ] || first=$dir
    if [ -e "$dir/orca-devices.json" ] || [ -e "$dir/orca-environments.json" ]; then
      printf '%s\n' "$dir"
      return
    fi
  done < <(orca_user_data_candidates)
  printf '%s\n' "$first"
}
