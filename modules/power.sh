# shellcheck shell=bash
# --power: never sleep and restart after a power loss. macOS: pmset on AC power. Linux: mask systemd's sleep
# targets; restarting after a power loss is a BIOS/UEFI setting the script can only remind you of.
POWER_SLEEP_TARGETS='sleep.target suspend.target hibernate.target hybrid-sleep.target'
POWER_BIOS_NOTE='NOTE restart after power loss is a BIOS/UEFI setting (often "Restore on AC power loss"); set it by hand'

module_power_describe() {
  if [ "$PLATFORM" = debian ]; then echo 'Use sudo to mask the systemd sleep targets; remind you of the BIOS power-loss setting.'
  else echo 'Use sudo to prevent AC sleep and enable restart after power loss.'; fi
}

# Current AC-power value of one pmset setting, empty when unknown.
pmset_ac_value() {
  pmset -g custom 2>/dev/null | awk -v key="$1" '
    /^AC Power/ { ac = 1; next }
    /^[A-Za-z].*:$/ { ac = 0 }
    ac && $1 == key { print $2; exit }
  '
}

power_configured() { [ "$(pmset_ac_value sleep)" = 0 ] && [ "$(pmset_ac_value autorestart)" = 1 ]; }

# systemd runs as the init system (not in a container). ORCA_SETUP_SYSTEMD_RUN_DIR overrides the marker (tests).
systemd_booted() { have systemctl && [ -d "${ORCA_SETUP_SYSTEMD_RUN_DIR:-/run/systemd/system}" ]; }

# The sleep targets that are not masked yet, space-separated.
power_unmasked_targets() {
  local target found=''
  for target in $POWER_SLEEP_TARGETS; do
    [ "$(systemctl is-enabled "$target" 2>/dev/null)" = masked ] || found="$found $target"
  done
  printf '%s\n' "${found# }"
}

module_power_skip() {
  [ "$PLATFORM" = debian ] || return 1
  systemd_booted && return 1
  # shellcheck disable=SC2034 # read by setup.sh
  MODULE_SKIP_REASON='systemd is not the init system here (a container?), so there are no sleep targets to mask'
}

module_power_plan() {
  local targets
  if [ "$PLATFORM" != debian ]; then
    if power_configured; then
      info '    already set: AC sleep 0, autorestart 1'
    else
      info '    sudo pmset -c sleep 0 autorestart 1'
    fi
    return 0
  fi
  targets=$(power_unmasked_targets)
  if [ -z "$targets" ]; then
    info "    already masked: $POWER_SLEEP_TARGETS"
  else
    # shellcheck disable=SC2086 # a space-separated list of unit names
    DEBIAN_MODE=plan as_root systemctl mask $targets
  fi
  info "    ${POWER_BIOS_NOTE#NOTE }"
}

module_power_apply() {
  local targets
  if [ "$PLATFORM" = debian ]; then
    targets=$(power_unmasked_targets)
    if [ -z "$targets" ]; then
      info "PRESENT sleep targets masked ($POWER_SLEEP_TARGETS)"
    else
      # shellcheck disable=SC2086 # a space-separated list of unit names
      as_root systemctl mask $targets
      targets=$(power_unmasked_targets)
      [ -z "$targets" ] || die "still not masked: $targets"
    fi
    info "$POWER_BIOS_NOTE"
    return 0
  fi
  if power_configured; then
    info 'PRESENT power settings (AC sleep 0, autorestart 1)'
    return 0
  fi
  step sudo pmset -c sleep 0 autorestart 1
  pmset -g custom
}

module_power_check() {
  local targets
  if [ "$PLATFORM" = debian ]; then
    targets=$(power_unmasked_targets)
    if [ -z "$targets" ]; then report masked 'Sleep targets'; else report "MISSING (not masked: $targets)" 'Sleep targets'; fi
    return 0
  fi
  if power_configured; then report set 'Power settings (AC sleep 0, autorestart 1)'
  else report MISSING 'Power settings (AC sleep 0, autorestart 1)'; fi
}
