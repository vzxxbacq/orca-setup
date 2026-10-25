#!/usr/bin/env bash
# Installs the tools of the Orca server image; docker/Dockerfile runs it as root. Never run it on a device.
# Everything comes from manifest/ through the same lib/ code setup.sh uses, with the same checks (apt key
# fingerprints, the Orca .deb's digest and control fields, marksman's digest): the baseline tools and agents, the
# media, android and agent-gemini modules, and the "image" rows. User-level tools (npm packages, the official
# installers, uv's Python and ruff, marksman) go under the fixed prefix /opt/orca-agents, which plays the user's home
# while they are installed, so below it they keep the user-level layout (.local/bin, .grok/bin).
set -euo pipefail
[ "${ORCA_SETUP_IMAGE_BUILD:-}" = 1 ] || { echo 'docker/build.sh only runs in the Orca server image build (docker/Dockerfile).' >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo 'docker/build.sh runs as root in the image build.' >&2; exit 1; }

ORCA_SETUP_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=lib/common.sh
. "$ORCA_SETUP_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$ORCA_SETUP_ROOT/lib/detect.sh"
# shellcheck source=lib/manifest.sh
. "$ORCA_SETUP_ROOT/lib/manifest.sh"
# shellcheck source=lib/pkg-macos.sh
. "$ORCA_SETUP_ROOT/lib/pkg-macos.sh"
# shellcheck source=lib/pkg-debian.sh
. "$ORCA_SETUP_ROOT/lib/pkg-debian.sh"
# shellcheck source=lib/npm-tools.sh
. "$ORCA_SETUP_ROOT/lib/npm-tools.sh"
# shellcheck source=lib/rows.sh
. "$ORCA_SETUP_ROOT/lib/rows.sh"

TOOLS_PREFIX=/opt/orca-agents
IMAGE_GROUPS='media android agent-gemini image'

[ "$(detect_support)" = supported ] || die "$(detect_unsupported_reason)"
# shellcheck disable=SC2034 # read by lib/rows.sh
PLATFORM=debian
export HOME=$TOOLS_PREFIX DEBIAN_FRONTEND=noninteractive
mkdir -p "$HOME"
# Unlike setup.sh (umask 077), everything here must stay readable for the host user the container runs as.
umask 022
setup_path

process_group apply baseline baseline.tsv
process_group apply baseline agents.tsv
for group in $IMAGE_GROUPS; do process_group apply "$group" "$(group_manifest "$group")"; done
require_orca_libraries

# Caches and package lists do not belong in the image.
apt-get clean
rm -rf /var/lib/apt/lists/* "$HOME/.npm" "$HOME/.cache"
chmod -R a+rX "$HOME"
# The image's default user would take UID 1000, which most host users have.
if id -u ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi
# The container runs as the host user's UID:GID with a read-only root filesystem: docker/entrypoint.sh writes the
# user's entry next to the image's own ones on /tmp, where these links point.
mv /etc/passwd /etc/passwd.image
mv /etc/group /etc/group.image
ln -s /tmp/passwd /etc/passwd
ln -s /tmp/group /etc/group
# The marker for setup.sh and remote/provision.sh: this is the Orca server image (also ORCA_SETUP_CONTAINER).
printf 'orca-server\n' >/etc/orca-server-image
info 'orca-setup: the Orca server image is ready'
