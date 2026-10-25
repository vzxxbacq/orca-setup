#!/bin/sh
# Entry point of the Orca server image (docker/Dockerfile). The container runs as the host user's UID:GID, which the
# image cannot know, and its root filesystem is read-only, so /etc/passwd and /etc/group are links to files on the
# container's /tmp. This writes them, the image's own entries plus one for the current user (its name from $USER and
# its home from $HOME), so tools that look the user up find a name and a home directory. Then it runs the command.
# `docker exec` sessions share the files the container's first process wrote.
set -eu
umask 022
uid=$(id -u)
gid=$(id -g)
name=${USER:-orca}
if [ "$uid" -eq 0 ]; then
  cp /etc/passwd.image /tmp/passwd
  cp /etc/group.image /tmp/group
else
  awk -F: -v uid="$uid" -v name="$name" '$3 != uid && $1 != name' /etc/passwd.image >/tmp/passwd
  printf '%s:x:%s:%s:orca-setup:%s:/bin/bash\n' "$name" "$uid" "$gid" "${HOME:-/tmp}" >>/tmp/passwd
  awk -F: -v gid="$gid" -v name="$name" '$3 != gid && $1 != name' /etc/group.image >/tmp/group
  printf '%s:x:%s:\n' "$name" "$gid" >>/tmp/group
fi
exec "$@"
