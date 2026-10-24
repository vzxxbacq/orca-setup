# shellcheck shell=bash
# --containers. macOS: Docker Desktop from the manifest, then open it once so it can initialize. Linux: Docker
# Engine from Docker's apt repository (the "containers" rows of manifest/baseline.tsv), then the user joins the
# docker group. Docker or Podman installed any other way is left alone (manifest/apt-conflicts.tsv).
module_containers_describe() {
  if [ "$PLATFORM" = debian ]; then echo "Install Docker Engine from Docker's apt repository if missing; add you to the docker group."
  else echo 'Install Docker Desktop if missing, then open it for initialization.'; fi
}

# The docker group grants root-equivalent access to the Docker daemon; membership applies from the next login.
docker_group_member() { id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx docker; }

# An install that orca-setup can continue: nothing Docker- or Podman-like yet, or Docker Engine from the
# repository setup this module writes (same keyring and source list).
module_containers_skip() {
  local conflicts
  [ "$PLATFORM" = debian ] || return 1
  conflicts=$(debian_conflicts docker)
  if [ -n "$conflicts" ]; then
    # shellcheck disable=SC2034 # read by setup.sh
    MODULE_SKIP_REASON="Docker or Podman from another source is installed ($conflicts); it is left alone"
    return 0
  fi
  if { have docker || have podman || debian_installed apt:docker-ce; } && ! apt_repo_configured docker; then
    # shellcheck disable=SC2034 # read by setup.sh
    MODULE_SKIP_REASON="$(if have podman; then echo Podman; else echo Docker; fi) is already installed without orca-setup's Docker repository; it is left alone"
    return 0
  fi
  return 1
}

module_containers_plan() {
  if [ "$PLATFORM" != debian ]; then info '    open -a Docker'; return 0; fi
  if docker_group_member; then info "    present  $(id -un) in the docker group"
  else
    DEBIAN_MODE=plan as_root usermod -aG docker "$(id -un)"
    info '    the docker group applies from your next login; it grants root-equivalent access to Docker'
  fi
}

module_containers_apply() {
  if [ "$PLATFORM" != debian ]; then step open -a Docker; return 0; fi
  if docker_group_member; then
    info "PRESENT $(id -un) in the docker group"
  else
    as_root usermod -aG docker "$(id -un)"
    docker_group_member || die "$(id -un) is still not in the docker group."
  fi
  # The running session keeps its old groups.
  id -nG | tr ' ' '\n' | grep -qx docker ||
    info 'NOTE log out and back in (a new login) before using docker without sudo'
}

module_containers_check() {
  [ "$PLATFORM" = debian ] || return 0
  if docker_group_member; then report member 'docker group'; else report MISSING 'docker group'; fi
}
