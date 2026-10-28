# shellcheck shell=bash
# --auth-agy: start agy so the user can sign in to a Google account interactively.
# There is no login subcommand: agy signs in on its first interactive start. Over SSH it does not open a browser;
# it prints an authorization URL to open on any other device and asks for the code that page shows (upstream docs:
# antigravity.google/docs). It keeps the session in the OS keyring, which on Linux is the Secret Service over D-Bus;
# a headless server usually has no unlocked keyring, and then the sign-in does not persist (upstream
# google-antigravity/antigravity-cli issues #53 and #950). setup.sh never sets up a keyring or handles a password.
auth_agy_describe() {
  if [ "$PLATFORM" = debian ] && [ "$(detect_desktop)" = no ]; then
    echo 'Start agy to sign in to Google; over SSH it prints a URL to open elsewhere and asks for the code. Needs an unlocked Secret Service keyring to keep the session.'
  else echo 'Start agy for interactive Google account sign-in.'; fi
}
auth_agy() {
  have agy || die 'agy is not installed; run --apply first.'
  if [ "$PLATFORM" = debian ] && [ "$(detect_desktop)" = no ]; then
    if [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; then
      warn 'agy prints its sign-in URL only in an SSH session; without a desktop or SSH it tries to open a browser here. Run --auth-agy from an SSH login.'
    fi
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      warn 'no D-Bus session: agy keeps its sign-in in the Secret Service keyring, so it may ask again next time (DESIGN.md section 3.4).'
    fi
    info 'agy prints a sign-in URL: open it on any device, sign in, and paste the code it shows back here.'
  fi
  step agy
}
