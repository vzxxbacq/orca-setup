# shellcheck shell=bash
# Docker on a Linux server host (--role server, README section 6.7). The host gets Docker Engine from Docker's apt
# repository (the "containers" rows of manifest/baseline.tsv, after the rows manifest/server-host.tsv names), or keeps
# a working Docker installed any other way as it is. Podman, and a Docker that does not work, are refused.
# The docker group grants root-equivalent access to the daemon. A group joined during this run is not active in the
# running session until the next login, so docker then runs through "sg docker", which asks for nothing because the
# group database already lists the user. Needs lib/common.sh, lib/manifest.sh, lib/pkg-debian.sh, lib/rows.sh and
# docker_group_member from modules/containers.sh.

DOCKER_VIA='' # direct | sg: how this session reaches the Docker daemon (docker_connect)

# docker_is_podman: the docker command is Podman's (podman-docker), or Podman is installed without a docker command.
docker_is_podman() {
  if have docker; then docker --version 2>/dev/null | grep -qi podman || debian_installed apt:podman-docker
  else have podman; fi
}

# docker_engine_state: what --apply does about Docker Engine:
#   install   nothing Docker-like is installed: Docker Engine from Docker's repository (the containers rows)
#   repo      Docker Engine from orca-setup's own repository setup: complete it (missing rows only)
#   existing  Docker from another source (Docker's convenience script, distribution packages, a hand-made
#             repository, a CI runner): used as it is, never changed, once it works
#   podman    Podman: refused
docker_engine_state() {
  if docker_is_podman; then echo podman
  elif apt_repo_configured docker; then echo repo
  elif have docker || debian_installed apt:docker-ce || [ -n "$(debian_conflicts docker)" ]; then echo existing
  else echo install; fi
}

# docker_host_rows: the rows --apply installs for Docker Engine, in install order: what Docker's repository needs
# first (manifest/server-host.tsv names baseline.tsv rows), then the containers rows.
docker_host_rows() {
  local names
  names=" $(manifest_rows server-host.tsv | cut -f1 | paste -sd ' ' -) "
  manifest_select baseline.tsv debian baseline | awk -F'\t' -v names="$names" 'index(names, " " $1 " ")' | debian_order
  manifest_select baseline.tsv debian containers | debian_order
}

docker_compose_version() { docker compose version --short 2>/dev/null | head -n 1; }

# docker_connect: how this session reaches the daemon: directly (the session has the docker group, or the socket
# is open to it some other way), else through "sg docker" (the user joined the group after this session started).
# Returns 1 when neither reaches a daemon.
docker_connect() {
  DOCKER_VIA=''
  have docker || return 1
  if docker version >/dev/null 2>&1; then DOCKER_VIA=direct; return 0; fi
  if docker_group_member && have sg && sg docker -c 'docker version' >/dev/null 2>&1; then DOCKER_VIA=sg; return 0; fi
  return 1
}

# dk <docker args...>: run docker the way docker_connect found. Through sg, the arguments are quoted into the one
# command line sg accepts.
dk() {
  local words='' arg
  if [ "$DOCKER_VIA" != sg ]; then docker "$@"; return; fi
  for arg in docker "$@"; do words="$words $(shq "$arg")"; done
  sg docker -c "${words# }"
}

# dk_step <docker args...>: print, then run a state-changing docker command.
dk_step() {
  printf '+ docker %s\n' "$*"
  dk "$@"
}

# docker_problem: why the installed Docker cannot run the Orca server; empty when it can (needs docker_connect).
docker_problem() {
  if docker_is_podman; then echo "Podman is installed$(have docker && printf ' as the docker command'); the Orca server needs Docker Engine"
  elif ! have docker; then echo "Docker packages from another source are installed ($(debian_conflicts docker | tr -s ' ' ',')), but there is no docker command"
  elif [ -z "$(docker_compose_version)" ]; then echo 'the Docker Compose plugin (docker compose) is missing'
  elif [ -z "$DOCKER_VIA" ] && ! docker_connect; then
    if docker_group_member; then echo "Docker's daemon does not answer (is the docker service running?)"
    else echo "Docker's daemon does not answer this user (not in the docker group)"; fi
  fi
}

docker_plan() {
  local state user version
  user=$(id -un)
  state=$(docker_engine_state)
  info 'Docker Engine (--apply):'
  case "$state" in
    podman)
      info "  refuse   $(docker_problem); --apply stops here (remove Podman, or install Docker yourself, then rerun)"
      return 0 ;;
    install | repo) process_rows plan 3< <(docker_host_rows) ;;
    existing)
      version=$(docker --version 2>/dev/null | head -n 1)
      if have docker && [ -n "$(docker_compose_version)" ]; then
        info "  present  ${version:-docker} from another source, with Compose $(docker_compose_version); used as it is"
      else
        info "  refuse   $(docker_problem); --apply stops here"
      fi ;;
  esac
  if docker_group_member; then info "  present  $user in the docker group"
  else
    info '  join     the docker group (root-equivalent: its members control the Docker daemon)'
    DEBIAN_MODE=plan as_root usermod -aG docker "$user"
    info '           until your next login, setup.sh reaches Docker through "sg docker" (no password, no sudo)'
  fi
}

# docker_apply: Docker Engine and the docker group, then a working connection (DOCKER_VIA) or a stop with the reason.
docker_apply() {
  local state problem user
  user=$(id -un)
  state=$(docker_engine_state)
  case "$state" in
    podman) die "$(docker_problem). Remove Podman, or install Docker Engine yourself, then rerun." ;;
    install | repo) process_rows apply 3< <(docker_host_rows) ;;
    existing) have docker && info "PRESENT docker ($(docker --version 2>/dev/null | head -n 1); from another source, used as it is)" ;;
  esac
  if docker_group_member; then info "PRESENT $user in the docker group"
  else
    as_root usermod -aG docker "$user"
    docker_group_member || die "$user is still not in the docker group."
  fi
  docker_connect || true
  problem=$(docker_problem)
  [ -z "$problem" ] || die "Docker cannot run the Orca server: $problem."
  [ "$DOCKER_VIA" != sg ] ||
    info 'NOTE docker runs through "sg docker" in this session; the docker group applies to new logins'
}

# docker_check: the Docker items of --check (report from setup.sh).
docker_check() {
  local problem version
  if ! have docker && [ "$(docker_engine_state)" = install ]; then
    report 'MISSING (run --apply --role server)' 'Docker'
  else
    docker_connect || true
    problem=$(docker_problem)
    if [ -z "$problem" ]; then
      version=$(dk version --format '{{.Server.Version}}' 2>/dev/null) || version=''
      report "working (Engine ${version:-unknown}, Compose $(docker_compose_version))" 'Docker'
    elif docker_is_podman; then report "CONFLICT ($problem)" 'Docker'
    elif have docker && [ -n "$(docker_compose_version)" ]; then report "UNREACHABLE ($problem)" 'Docker'
    else report "MISSING ($problem)" 'Docker'; fi
  fi
  if docker_group_member; then report member 'docker group'
  elif [ "$DOCKER_VIA" = direct ]; then report 'not a member (Docker answers without it; not counted)' 'docker group'
  else report MISSING 'docker group'; fi
}
