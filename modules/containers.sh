# shellcheck shell=bash
# --containers: Docker Desktop from the manifest, then open it once so it can initialize.
module_containers_describe() { echo 'Install Docker Desktop if missing, then open it for initialization.'; }
module_containers_plan() { info '    open -a Docker'; }
module_containers_apply() { step open -a Docker; }
