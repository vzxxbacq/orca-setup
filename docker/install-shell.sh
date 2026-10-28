#!/usr/bin/env bash
# Image-build helper. Never download shell plugins during container startup.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=manifest/shell.env
. "$root/manifest/shell.env"
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
curl -q -fsSL --retry 3 "https://codeload.github.com/ohmyzsh/ohmyzsh/tar.gz/$OMZ_REVISION" -o "$archive"
printf '%s  %s\n' "$OMZ_SHA256" "$archive" | sha256sum --check --status
mkdir -p /opt/oh-my-zsh /etc/ssh/ssh_config.d /run/sshd
tar -xzf "$archive" --strip-components=1 -C /opt/oh-my-zsh
chmod -R a+rX /opt/oh-my-zsh
# Do not bake package-generated host identities into an image.
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
printf 'Include /run/orca-ssh/client.conf\n' > /etc/ssh/ssh_config.d/00-orca-internal.conf
