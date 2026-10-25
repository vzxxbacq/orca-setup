#!/bin/sh
# Entry point of the Orca server image (docker/Dockerfile). The container runs as the host user's UID:GID, which the
# image cannot know, on a read-only root filesystem. So that tools which look the user up (git, ssh, Node.js's
# os.userInfo()) find a name and a home directory, this writes an entry for the current user (its name from $USER, its
# home from $HOME) to /tmp/extrausers, which libnss-extrausers reads next to the image's own /etc/passwd and
# /etc/group (docker/build.sh). `docker exec` sessions share the files the container's first process wrote. Then it
# runs the command.
set -eu
umask 022
uid=$(id -u)
gid=$(id -g)
name=${USER:-orca}
if [ "$uid" -ne 0 ]; then
  mkdir -p /tmp/extrausers
  getent passwd "$uid" >/dev/null 2>&1 ||
    printf '%s:x:%s:%s:orca-setup:%s:/bin/bash\n' "$name" "$uid" "$gid" "${HOME:-/tmp}" >/tmp/extrausers/passwd
  getent group "$gid" >/dev/null 2>&1 || printf '%s:x:%s:\n' "$name" "$gid" >/tmp/extrausers/group
fi
exec "$@"
