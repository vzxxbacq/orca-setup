#!/usr/bin/env bash
# Run orca-rpc.cjs inside the installed Orca's bundled runtime (ELECTRON_RUN_AS_NODE), so it can reuse
# Orca's own paired transport. Usage: orca-rpc.sh local|ENVIRONMENT METHOD [JSON]
# macOS: the app bundle; Linux: the .deb install under /opt (lib/detect.sh). ORCA_APP_PATH overrides both.
set -euo pipefail
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$here/../lib/common.sh"
# shellcheck source=lib/detect.sh
. "$here/../lib/detect.sh"

case "$(detect_os)" in
  macos | linux) ;;
  *) die 'orca-rpc: unsupported operating system.' ;;
esac
executable=$(orca_executable)
resources=$(orca_resources_dir)
[ -x "$executable" ] || die "orca-rpc: Orca executable not found at $executable (set ORCA_APP_PATH)."
export ELECTRON_RUN_AS_NODE=1 ORCA_RESOURCES_PATH="$resources"
exec "$executable" "$here/orca-rpc.cjs" "$@"
