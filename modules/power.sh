# shellcheck shell=bash
# --power: never sleep on AC power and restart after a power loss (macOS: pmset).
module_power_describe() { echo 'Use sudo to prevent AC sleep and enable restart after power loss.'; }

# Current AC-power value of one pmset setting, empty when unknown.
pmset_ac_value() {
  pmset -g custom 2>/dev/null | awk -v key="$1" '
    /^AC Power/ { ac = 1; next }
    /^[A-Za-z].*:$/ { ac = 0 }
    ac && $1 == key { print $2; exit }
  '
}

power_configured() { [ "$(pmset_ac_value sleep)" = 0 ] && [ "$(pmset_ac_value autorestart)" = 1 ]; }

module_power_plan() {
  if power_configured; then
    info '    already set: AC sleep 0, autorestart 1'
  else
    info '    sudo pmset -c sleep 0 autorestart 1'
  fi
}

module_power_apply() {
  if power_configured; then
    info 'PRESENT power settings (AC sleep 0, autorestart 1)'
    return 0
  fi
  step sudo pmset -c sleep 0 autorestart 1
  pmset -g custom
}
