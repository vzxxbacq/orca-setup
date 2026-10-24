# shellcheck shell=bash
# --android: packages come from the "android" group of manifest/baseline.tsv. On Linux the package is
# android-sdk-platform-tools (Debian 12 main, Ubuntu 24.04 universe); a device whose apt sources lack it is skipped.
ANDROID_PLATFORM_TOOLS_URL=https://developer.android.com/tools/releases/platform-tools
module_android_describe() { echo 'Install Android platform tools if missing.'; }

# apt_known <package>: the package lists offer the package.
apt_known() { have apt-cache && apt-cache show --no-all-versions "$1" >/dev/null 2>&1; }

module_android_skip() {
  local check method package
  [ "$PLATFORM" = debian ] || return 1
  while IFS=$'\t' read -r _ check method <&3; do
    row_present "$check" "$method" && continue
    package=$(debian_package "$method") || continue
    apt_known "$package" && continue
    # --apply reads fresh package lists first; --plan and --check use the device's lists.
    if [ "$1" = apply ] && [ "$APT_UPDATED" != yes ]; then apt_update; apt_known "$package" && continue; fi
    [ "$1" != plan ] || return 1
    # shellcheck disable=SC2034 # read by setup.sh
    MODULE_SKIP_REASON="the apt sources of this device do not offer $package (on Ubuntu it is in universe); install Google's platform-tools from $ANDROID_PLATFORM_TOOLS_URL by hand"
    return 0
  done 3< <(platform_rows baseline.tsv android)
  return 1
}

module_android_plan() {
  [ "$PLATFORM" = debian ] || return 0
  info "    when the refreshed package lists do not offer it, --apply skips it with a notice (Google's zip: $ANDROID_PLATFORM_TOOLS_URL)"
}
