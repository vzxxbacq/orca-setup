#!/usr/bin/env bats
# lib/detect.sh with a fake uname and fake os-release files.

load helpers

setup() {
  make_sandbox
  # shellcheck source=../../lib/common.sh
  . "$REPO_ROOT/lib/common.sh"
  # shellcheck source=../../lib/detect.sh
  . "$REPO_ROOT/lib/detect.sh"
}

@test "macOS on Apple silicon" {
  fake_uname Darwin arm64
  [ "$(detect_os)" = macos ]
  [ "$(detect_arch)" = arm64 ]
  [ "$(detect_distro)" = 'macos 15.5' ]
  [ "$(detect_desktop)" = yes ]
  [ "$(detect_support)" = supported ]
}

@test "macOS package manager follows brew presence" {
  [ "$(detect_pkg_manager)" = none ]
  fake_brew
  [ "$(detect_pkg_manager)" = brew ]
}

@test "Ubuntu 24.04 x86_64 is supported, headless without a display" {
  fake_uname Linux x86_64
  fake_os_release ubuntu 24.04 debian
  [ "$(detect_os)" = linux ]
  [ "$(detect_distro)" = 'ubuntu 24.04' ]
  [ "$(detect_linux_family)" = debian ]
  [ "$(detect_pkg_manager)" = apt ]
  [ "$(detect_desktop)" = no ]
  [ "$(detect_support)" = supported ]
  DISPLAY=:0 detect_desktop | grep -qx yes
}

@test "Debian 12 x86_64 is supported; amd64 is normalized" {
  fake_uname Linux amd64
  fake_os_release debian 12
  [ "$(detect_arch)" = x86_64 ]
  [ "$(detect_support)" = supported ]
}

@test "Linux arm64 and Fedora are unsupported" {
  fake_uname Linux aarch64
  fake_os_release ubuntu 24.04 debian
  [ "$(detect_arch)" = arm64 ]
  [ "$(detect_support)" = unsupported ]
  [ "$(detect_unsupported_reason)" = 'Linux on arm64 is not supported: x86_64 only (no arm64).' ]
  fake_uname Linux x86_64
  fake_os_release fedora 41
  [ "$(detect_linux_family)" = fedora ]
  [ "$(detect_pkg_manager)" = dnf ]
  [ "$(detect_support)" = unsupported ]
  [ "$(detect_unsupported_reason)" = 'fedora 41 is not supported: only Ubuntu 24.04 and Debian 12 (x86_64).' ]
  fake_os_release ubuntu 22.04 debian
  [ "$(detect_support)" = unsupported ]
}

@test "unknown kernels are unsupported" {
  fake_uname FreeBSD amd64
  [ "$(detect_os)" = unsupported ]
  [ "$(detect_support)" = unsupported ]
}

@test "Orca CLI: ORCA_CLI_COMMAND wins everywhere" {
  fake_uname Linux x86_64
  ORCA_CLI_COMMAND=my-orca detect_orca_cli | grep -qx my-orca
}

@test "Orca CLI: orca-ide on Linux, never the screen reader" {
  fake_uname Linux x86_64
  fake_present orca
  [ "$(detect_orca_cli)" = orca-ide ]
}

@test "Orca CLI on macOS: orca on PATH, else the app bundle shim" {
  [ "$(detect_orca_cli)" = orca ]
  fake_orca
  rm "$SB/bin/orca"
  printf '#!/bin/sh\n' >"$SB/Applications/Orca.app/Contents/Resources/bin/orca"
  chmod +x "$SB/Applications/Orca.app/Contents/Resources/bin/orca"
  [ "$(detect_orca_cli)" = "$SB/Applications/Orca.app/Contents/Resources/bin/orca" ]
  fake_present orca
  [ "$(detect_orca_cli)" = orca ]
}

@test "Orca user-data directory: ORCA_USER_DATA wins" {
  [ "$(orca_user_data_dir)" = "$SB/userdata" ]
  fake_uname Linux x86_64
  [ "$(orca_user_data_dir)" = "$SB/userdata" ]
}

@test "Orca user-data directory on macOS is Application Support/Orca" {
  unset ORCA_USER_DATA
  [ "$(orca_user_data_dir)" = "$HOME/Library/Application Support/Orca" ]
}

@test "Orca user-data directory on headless Linux follows orcad: XDG_DATA_HOME/Orca, else ~/.orca" {
  unset ORCA_USER_DATA
  fake_uname Linux x86_64
  [ "$(orca_user_data_dir)" = "$HOME/.orca" ]
  XDG_DATA_HOME=$SB/data orca_user_data_dir | grep -qx "$SB/data/Orca"
}

@test "Orca user-data directory on Linux falls back to the Electron desktop path when it holds the stores" {
  unset ORCA_USER_DATA
  fake_uname Linux x86_64
  mkdir -p "$HOME/.orca/agent-hooks" "$HOME/.config/Orca"
  echo '[]' >"$HOME/.config/Orca/orca-devices.json"
  [ "$(orca_user_data_dir)" = "$HOME/.config/Orca" ]
  XDG_CONFIG_HOME=$SB/cfg orca_user_data_dir | grep -qx "$HOME/.orca"
  echo '[]' >"$HOME/.orca/orca-devices.json"
  [ "$(orca_user_data_dir)" = "$HOME/.orca" ]
}

@test "is_present handles commands, alternatives and apps" {
  fake_present b
  is_present b
  is_present 'a|b'
  run ! is_present 'a|c'
  is_present -
  run ! is_present app:Thing
  mkdir "$SB/Applications/Thing.app"
  is_present app:Thing
  is_present 'missing|app:Thing'
}
