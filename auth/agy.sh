# shellcheck shell=bash
# --auth-agy: start agy so the user can sign in to a Google account interactively.
auth_agy_describe() { echo 'Start agy for interactive Google account sign-in.'; }
auth_agy() {
  have agy || die 'agy is not installed; run --apply first.'
  step agy
}
