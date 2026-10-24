# shellcheck shell=bash
# --auth-gh: GitHub browser authentication; an existing valid login is kept.
auth_gh_describe() { echo 'GitHub browser authentication, retaining an existing valid login.'; }
auth_gh() {
  have gh || die 'gh is not installed; run --apply first.'
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    info 'GitHub already authenticated'
  else
    step gh auth login --hostname github.com --git-protocol https --web
  fi
}
