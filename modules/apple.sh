# shellcheck shell=bash
# --apple: Apple build helpers from the manifest, then Xcode's first launch (or the App Store when Xcode is missing).
XCODE_APP=${ORCA_SETUP_APPLICATIONS_DIR:-/Applications}/Xcode.app
XCODE_APP_STORE_URL='macappstore://itunes.apple.com/app/id497799835'
module_apple_describe() {
  if [ "$PLATFORM" = debian ]; then echo 'macOS only: skipped on Linux with a notice.'
  else echo 'Install Apple build helpers; open the App Store if full Xcode is missing.'; fi
}

module_apple_skip() {
  [ "$PLATFORM" = debian ] || return 1
  # shellcheck disable=SC2034 # read by setup.sh
  MODULE_SKIP_REASON='not applicable on Linux (Xcode and the Apple build helpers are macOS-only)'
}

xcode_selected() { [ "$(xcode-select -p 2>/dev/null)" = "$XCODE_APP/Contents/Developer" ]; }
xcode_first_launch_done() { xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; }

module_apple_plan() {
  if [ ! -d "$XCODE_APP" ]; then
    info '    Xcode missing: open the App Store page for Xcode'
    return 0
  fi
  xcode_selected || info "    sudo xcode-select --switch $XCODE_APP/Contents/Developer"
  xcode_first_launch_done || info '    sudo xcodebuild -runFirstLaunch'
  if xcode_selected && xcode_first_launch_done; then info '    Xcode selected and initialized'; fi
}

module_apple_apply() {
  if [ ! -d "$XCODE_APP" ]; then
    open "$XCODE_APP_STORE_URL"
    info 'Finish installing Xcode in the App Store, then rerun with --apple.'
    return 0
  fi
  xcode_selected || step sudo xcode-select --switch "$XCODE_APP/Contents/Developer"
  xcode_first_launch_done || step sudo xcodebuild -runFirstLaunch
}
