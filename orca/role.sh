#!/usr/bin/env bash
# Pairing role check (DESIGN.md section 5.1). Read-only.
#
# A client saves environments (it dials servers); a server accepts runtime pairings (it is dialed).
# Saved environments come from `<orca> environment list --json`; runtime clients come from the device
# registry in Orca's user-data directory (see orca/role.cjs). Mobile pairings do not count.
# The check fails closed: when it cannot read the stores it reports "ROLE unknown" with a reason.
#
# Usage: role.sh [--expect client|server] [--names]
#   Prints "ROLE <none|client|server|dual|unknown>" and counts. Pairing names are printed on a conflict, or
#   always with --names. Exit status: 0 consistent, 1 dual role or a conflict with --expect, 2 usage error,
#   3 role unknown.
set -euo pipefail
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$here/../lib/common.sh"
# shellcheck source=lib/detect.sh
. "$here/../lib/detect.sh"

expect=''
names=no
while [ $# -gt 0 ]; do
  case "$1" in
    --expect)
      [ $# -ge 2 ] || { echo 'role.sh: --expect needs client or server' >&2; exit 2; }
      expect=$2
      shift ;;
    --names) names=yes ;;
    *) echo "role.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$expect" in '' | client | server) ;; *) echo 'role.sh: --expect needs client or server' >&2; exit 2 ;; esac

# The logic needs a JavaScript runtime: Node.js, else the one bundled with Orca (a fresh device is often
# paired before the baseline installs Node.js).
runtime=()
if have node; then
  runtime=(node)
elif [ -x "$(orca_executable)" ]; then
  runtime=(env ELECTRON_RUN_AS_NODE=1 "$(orca_executable)")
else
  echo 'ROLE unknown'
  echo "reason: neither node nor Orca's bundled runtime is available"
  exit 3
fi

user_data=$(orca_user_data_dir)
orca_cli=$(detect_orca_cli)
# Saved environments: the public CLI first, the pairing store file when the CLI cannot answer.
if environments=$("$orca_cli" environment list --json 2>/dev/null); then
  environments_source=cli
else
  environments=''
  environments_source='file'
fi

ROLE_ENVIRONMENTS_JSON=$environments ROLE_ENVIRONMENTS_SOURCE=$environments_source \
  ROLE_USER_DATA_DIR=$user_data ROLE_EXPECT=$expect ROLE_NAMES=$names \
  ROLE_RECENT_DAYS=${ORCA_SETUP_RECENT_DAYS:-30} "${runtime[@]}" "$here/role.cjs"
