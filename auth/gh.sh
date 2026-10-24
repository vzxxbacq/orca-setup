# shellcheck shell=bash
# --auth-gh: GitHub browser authentication; an existing valid login is kept. `gh auth login --web` is GitHub's
# device-code flow: gh shows a one-time code and the device page. Without a desktop (Linux) nothing can open a
# browser here, so the user opens the page on any other device; GH_BROWSER=true keeps gh from trying.
GITHUB_DEVICE_URL=https://github.com/login/device
auth_gh_describe() {
  if [ "$(detect_desktop)" = no ]; then echo "GitHub device-code login: open $GITHUB_DEVICE_URL on any device and enter the code gh shows; an existing valid login is kept."
  else echo 'GitHub browser authentication, retaining an existing valid login.'; fi
}
auth_gh() {
  have gh || die 'gh is not installed; run --apply first.'
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    info 'GitHub already authenticated'
  elif [ "$(detect_desktop)" = no ]; then
    info "No desktop here: open $GITHUB_DEVICE_URL on any device and enter the one-time code gh shows (pressing Enter opens nothing)."
    step env GH_BROWSER=true gh auth login --hostname github.com --git-protocol https --web
  else
    step gh auth login --hostname github.com --git-protocol https --web
  fi
}
