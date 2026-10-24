#!/usr/bin/env bash
# Pairing role check (README section 5.1). Read-only.
#
# A client saves environments (it dials servers); a server accepts runtime pairings (it is dialed).
# Saved environments come from `<orca> environment list --json`; runtime clients come from the device
# registry in Orca's user-data directory, of which only the scope, name and last-seen time are read.
# Tokens and device ids are never read into output. Mobile pairings do not count.
#
# Usage: role.sh [--expect client|server] [--names]
#   Prints "ROLE <none|client|server|dual>" and counts. Pairing names are printed on a conflict, or
#   always with --names. Exit status: 0 consistent, 1 dual role or a conflict with --expect, 2 usage error.
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
have node || { echo 'ROLE unknown (node is not installed yet)'; exit 0; }

user_data=$(orca_user_data_dir)
orca_cli=$(detect_orca_cli)
# Saved environments: the public CLI first, the pairing store file when the CLI cannot answer.
if environments=$("$orca_cli" environment list --json 2>/dev/null); then
  environments_source=cli
else
  environments=''
  environments_source='file'
fi

# shellcheck disable=SC2016 # the single-quoted program is JavaScript, not shell
ROLE_ENVIRONMENTS_JSON=$environments ROLE_ENVIRONMENTS_SOURCE=$environments_source \
  ROLE_USER_DATA_DIR=$user_data ROLE_EXPECT=$expect ROLE_NAMES=$names \
  ROLE_RECENT_DAYS=${ORCA_SETUP_RECENT_DAYS:-30} node -e '
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const env = process.env;
const dir = env.ROLE_USER_DATA_DIR;
const clean = name => String(name || "(unnamed)").replace(/[\u0000-\u001f\u007f]/g, "?");
const readJson = file => { try { return JSON.parse(fs.readFileSync(path.join(dir, file), "utf8")); } catch { return null; } };

let environments = [];
if (env.ROLE_ENVIRONMENTS_SOURCE === "cli") {
  try { environments = JSON.parse(env.ROLE_ENVIRONMENTS_JSON).result.environments || []; } catch { environments = []; }
} else {
  environments = (readJson("orca-environments.json") || {}).environments || [];
}
const environmentNames = environments.map(e => clean(e.name));

const devices = readJson("orca-devices.json");
const cutoff = Date.now() - Number(env.ROLE_RECENT_DAYS) * 24 * 3600 * 1000;
const runtime = (Array.isArray(devices) ? devices : []).filter(d => d && d.scope === "runtime");
const recent = runtime.filter(d => Number(d.lastSeenAt || d.pairedAt || 0) >= cutoff).map(d => clean(d.name));
const mobile = (Array.isArray(devices) ? devices : []).filter(d => d && d.scope === "mobile").length;

const role = environmentNames.length && recent.length ? "dual"
  : environmentNames.length ? "client" : recent.length ? "server" : "none";
const conflict = role === "dual"
  || (env.ROLE_EXPECT === "server" && environmentNames.length > 0)
  || (env.ROLE_EXPECT === "client" && recent.length > 0);
const showNames = conflict || env.ROLE_NAMES === "yes";

console.log(`ROLE ${role}`);
console.log(`saved environments: ${environmentNames.length}`);
console.log(`runtime clients seen in the last ${env.ROLE_RECENT_DAYS} days: ${recent.length} (of ${runtime.length})`);
console.log(`mobile pairings: ${mobile} (not counted)`);
if (showNames) {
  for (const name of environmentNames) console.log(`  saved environment: ${name}`);
  for (const name of recent) console.log(`  runtime client: ${name}`);
}
if (conflict) {
  const wanted = env.ROLE_EXPECT || "one role";
  if (environmentNames.length && wanted !== "client") {
    console.log("CONFLICT this host saves environments; remove them with `environment rm` to keep it a server");
  }
  if (recent.length && wanted !== "server") {
    console.log("CONFLICT this host accepts runtime clients; revoke them in Settings > Remote Orca Servers to keep it a client");
  }
  process.exitCode = 1;
}
'
