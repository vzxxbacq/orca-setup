#!/usr/bin/env bash
# Run orca-rpc.cjs inside the installed Orca's bundled runtime (ELECTRON_RUN_AS_NODE), so it can reuse
# Orca's own paired transport. Usage: orca-rpc.sh local|ENVIRONMENT METHOD [JSON]
set -euo pipefail
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$here/../lib/common.sh"
# shellcheck source=lib/detect.sh
. "$here/../lib/detect.sh"

case "$(detect_os)" in
  macos)
    app=$(orca_app_path)
    executable="$app/Contents/MacOS/Orca"
    resources="$app/Contents/Resources" ;;
  linux) die 'orca-rpc: Orca on Linux is not implemented yet (P2).' ;;
  *) die 'orca-rpc: unsupported operating system.' ;;
esac
[ -x "$executable" ] || die "orca-rpc: Orca executable not found at $executable (set ORCA_APP_PATH)."
export ELECTRON_RUN_AS_NODE=1 ORCA_RESOURCES_PATH="$resources"
exec "$executable" "$here/orca-rpc.cjs" "$@"
