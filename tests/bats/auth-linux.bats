#!/usr/bin/env bats
# Interactive authentication on Linux (P3), headless and with a desktop, against fake gh, agy, xdg-open and Orca.
# No real login runs. The Linear key is typed into a pseudo-terminal and must reach only the fake Orca runtime.

load helpers

LINEAR_KEY=lin_api_FAKEKEY0123456789abcdefSECRET

setup() {
  make_sandbox
  fake_linux
  unset SSH_CONNECTION SSH_TTY DBUS_SESSION_BUS_ADDRESS
}

no_calls() { [ ! -s "$FAKE_LOG" ] || { cat "$FAKE_LOG"; return 1; }; }

# fake_gh <logged-in yes|no>: gh logs each login with the GH_BROWSER it was given.
fake_gh() {
  # shellcheck disable=SC2016 # the stub body expands when the stub runs
  fake_cmd gh '[ "$1 $2" = "auth status" ] && { [ '"$1"' = yes ]; exit; }
echo "gh $* GH_BROWSER=${GH_BROWSER:-unset}" >>"$FAKE_LOG"'
}

# fake_orca_runtime <connected true|false>: the Orca executable the RPC bridge runs. linear.connect stores what it
# reads on stdin in $SB/received (the only place the key may go); while $SB/runtime-down exists every call fails.
fake_orca_runtime() {
  export ORCA_APP_PATH=$SB/opt/Orca
  mkdir -p "$ORCA_APP_PATH/resources"
  cat >"$ORCA_APP_PATH/orca-ide" <<SH
#!$REAL_BASH
[ ! -e "\$SB/runtime-down" ] || exit 1
case "\$3" in
  linear.status) echo '{"connected":$1}' ;;
  linear.connect) cat >"\$SB/received"; echo '{"connected":true}' ;;
  *) echo "Orca \$*" >>"\$FAKE_LOG"; echo '{}' ;;
esac
SH
  chmod +x "$ORCA_APP_PATH/orca-ide"
  # shellcheck disable=SC2016
  fake_cmd xdg-open 'echo "xdg-open $*" >>"$FAKE_LOG"'
}

# linear_on_tty: run --auth-linear on a pseudo-terminal and type the key at the hidden prompt.
linear_on_tty() {
  [ -n "$REAL_PYTHON" ] || skip 'python3 is needed for the pseudo-terminal'
  PTY_INPUT=$LINEAR_KEY run "$REAL_PYTHON" "$BATS_TEST_DIRNAME/pty.py" 'Paste Linear API key (hidden)' \
    "$REAL_BASH" "$REPO_ROOT/setup.sh" --auth-linear
}

# The key may appear only in what the fake runtime received.
key_nowhere_else() {
  [[ "$output" != *"$LINEAR_KEY"* ]] || { echo 'the key was echoed or printed'; return 1; }
  run grep -rlF -- "$LINEAR_KEY" "$BATS_TEST_TMPDIR"
  [ "$output" = "$SB/received" ] || { echo "the key is in: $output"; return 1; }
}

# ------------------------------------------------------------------ gh

@test "--auth-gh keeps an existing valid login" {
  fake_gh yes
  run_setup --auth-gh
  [ "$status" -eq 0 ]
  [[ "$output" == *'GitHub already authenticated'* ]]
  no_calls
}

@test "--auth-gh without a desktop uses the device-code flow and never tries a browser" {
  fake_gh no
  run_setup --auth-gh
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'No desktop here: open https://github.com/login/device on any device'* ]]
  [ "$(cat "$FAKE_LOG")" = 'gh auth login --hostname github.com --git-protocol https --web GH_BROWSER=true' ]
}

@test "--auth-gh with a desktop opens the browser as on macOS" {
  fake_gh no
  export WAYLAND_DISPLAY=wayland-0
  run_setup --auth-gh
  [ "$status" -eq 0 ]
  [[ "$output" != *'No desktop'* ]]
  [ "$(cat "$FAKE_LOG")" = 'gh auth login --hostname github.com --git-protocol https --web GH_BROWSER=unset' ]
}

@test "headless detection: DISPLAY or WAYLAND_DISPLAY means a desktop" {
  . "$REPO_ROOT/lib/detect.sh"
  [ "$(detect_desktop)" = no ]
  [ "$(DISPLAY=:0 detect_desktop)" = yes ]
  [ "$(WAYLAND_DISPLAY=wayland-0 detect_desktop)" = yes ]
}

# ------------------------------------------------------------------ agy

@test "--auth-agy starts agy; headless without SSH or D-Bus it says why the sign-in may not work" {
  # shellcheck disable=SC2016
  fake_cmd agy 'echo "agy $*" >>"$FAKE_LOG"'
  run_setup --auth-agy
  [ "$status" -eq 0 ]
  [[ "$output" == *'agy prints its sign-in URL only in an SSH session'* ]]
  [[ "$output" == *'no D-Bus session'* ]]
  [[ "$output" == *'+ agy'* ]]
  [ "$(cat "$FAKE_LOG")" = 'agy ' ]
  : >"$FAKE_LOG"
  SSH_CONNECTION='198.51.100.1 50000 198.51.100.2 22' DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus run_setup --auth-agy
  [ "$status" -eq 0 ]
  [[ "$output" != *WARNING* ]]
  [[ "$output" == *'open it on any device, sign in, and paste the code'* ]]
}

@test "--auth-agy needs agy" {
  run_setup --auth-agy
  [ "$status" -eq 1 ]
  [[ "$output" == *'agy is not installed'* ]]
}

# ------------------------------------------------------------------ linear

@test "--auth-linear headless prints the URL, reads the key hidden and hands it only to Orca" {
  fake_orca_runtime false
  linear_on_tty
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'Create a personal API key at https://linear.app/settings/api'* ]]
  [[ "$output" == *'Linear connected.'* ]]
  [ "$(cat "$SB/received")" = "{\"apiKey\":\"$LINEAR_KEY\"}" ]
  key_nowhere_else
  # Headless: nothing tries to open a browser.
  no_calls
}

@test "--auth-linear with a desktop opens the page with xdg-open" {
  fake_orca_runtime false
  export DISPLAY=:0
  linear_on_tty
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$FAKE_LOG")" = 'xdg-open https://linear.app/settings/api' ]
  key_nowhere_else
}

@test "--auth-linear keeps an existing connection and asks for no key" {
  fake_orca_runtime true
  run_setup --auth-linear
  [ "$status" -eq 0 ]
  [[ "$output" == *'Linear already connected'* ]]
  [ ! -e "$SB/received" ]
  no_calls
}

@test "--auth-linear stops before the prompt when this device runs no Orca runtime" {
  fake_orca_runtime false
  touch "$SB/runtime-down"
  run_setup --auth-linear
  [ "$status" -eq 1 ]
  [[ "$output" == *'the Orca runtime on this device does not answer'* ]]
  [[ "$output" != *'Paste Linear API key'* ]]
}

@test "the Linear prompt refuses to read a key that is not typed into a terminal" {
  fake_orca_runtime false
  run bash -c "printf '%s\n' '$LINEAR_KEY' | '$REAL_BASH' '$REPO_ROOT/setup.sh' --auth-linear"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Run in an interactive terminal'* ]]
  [[ "$output" != *"$LINEAR_KEY"* ]]
  [ ! -e "$SB/received" ]
}
