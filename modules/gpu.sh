# shellcheck shell=bash
# --gpu (Linux only): report the NVIDIA GPU, its kernel driver, nvidia-smi and the CUDA toolkit. Detection only:
# nothing is ever installed, and neither --plan nor --apply changes anything. --check --gpu counts a missing driver
# when an NVIDIA GPU is present. Tests point ORCA_SETUP_SYSFS_ROOT, ORCA_SETUP_PROC_ROOT and ORCA_SETUP_CUDA_HOME
# at fake trees.
GPU_SYSFS=${ORCA_SETUP_SYSFS_ROOT:-/sys}
GPU_PROC=${ORCA_SETUP_PROC_ROOT:-/proc}
GPU_CUDA_HOME=${ORCA_SETUP_CUDA_HOME:-/usr/local/cuda}
GPU_DRIVER_HINT='install the NVIDIA driver yourself (Ubuntu: ubuntu-drivers; Debian: nvidia-driver from non-free), then reboot'

module_gpu_describe() {
  if [ "$PLATFORM" = debian ]; then echo 'Report the NVIDIA GPU, driver, nvidia-smi and CUDA toolkit (detection only; never installs).'
  else echo 'Linux only: NVIDIA GPU detection; skipped on macOS with a notice.'; fi
}

module_gpu_skip() {
  [ "$PLATFORM" != debian ] || return 1
  # shellcheck disable=SC2034 # read by setup.sh
  MODULE_SKIP_REASON='not applicable on macOS (NVIDIA GPU detection is Linux-only)'
}

# gpu_devices: one line per NVIDIA display controller (PCI vendor 0x10de, class 0x03xxxx): "<slot><TAB><name>".
# sysfs answers without extra tools; lspci, when present, only adds the model name.
gpu_devices() {
  local dir slot name found=no
  for dir in "$GPU_SYSFS"/bus/pci/devices/*; do
    [ -r "$dir/vendor" ] && [ -r "$dir/class" ] || continue
    [ "$(cat "$dir/vendor")" = 0x10de ] || continue
    case "$(cat "$dir/class")" in 0x03*) ;; *) continue ;; esac
    slot=${dir##*/}
    name=''
    if have lspci; then name=$(lspci -s "$slot" 2>/dev/null | head -n 1 | sed 's/^[^ ]* [^:]*: //'); fi
    printf '%s\t%s\n' "$slot" "${name:-NVIDIA device}"
    found=yes
  done
  [ "$found" = no ] || return 0
  # No readable sysfs tree (unusual): fall back to lspci's VGA / 3D / display classes.
  have lspci || return 0
  lspci -nn -d 10de: 2>/dev/null | awk '/\[03[0-9a-f][0-9a-f]\]/ { slot = $1; $1 = ""; sub(/^ [^:]*: /, ""); print slot "\t" $0 }'
}

# gpu_driver_version: the loaded NVIDIA kernel module's version, empty when it is not loaded.
gpu_driver_version() {
  local version=''
  if [ -r "$GPU_SYSFS/module/nvidia/version" ]; then version=$(head -n 1 "$GPU_SYSFS/module/nvidia/version")
  elif [ -r "$GPU_PROC/driver/nvidia/version" ]; then
    version=$(sed -n 's/.*Kernel Module[^0-9]*\([0-9][0-9.]*\).*/\1/p' "$GPU_PROC/driver/nvidia/version" | head -n 1)
  fi
  printf '%s\n' "$version"
}

gpu_nouveau_loaded() { [ -d "$GPU_SYSFS/module/nouveau" ]; }

# gpu_cuda_version: "<version> (<nvcc path>)" for the CUDA toolkit's nvcc, empty when there is none.
gpu_cuda_version() {
  local nvcc version
  nvcc=$(command -v nvcc 2>/dev/null) || nvcc=''
  [ -n "$nvcc" ] || [ ! -x "$GPU_CUDA_HOME/bin/nvcc" ] || nvcc=$GPU_CUDA_HOME/bin/nvcc
  [ -n "$nvcc" ] || return 0
  version=$("$nvcc" --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9.]*\).*/\1/p' | head -n 1)
  printf '%s (%s)\n' "${version:-unknown}" "$nvcc"
}

# gpu_report <prefix>: print the findings, one line each, with <prefix> in front.
gpu_report() {
  local prefix=$1 devices driver cuda slot name
  devices=$(gpu_devices)
  if [ -z "$devices" ]; then
    info "${prefix}no NVIDIA GPU found (nothing to check)"
    return 0
  fi
  while IFS=$'\t' read -r slot name; do info "${prefix}NVIDIA GPU $slot: $name"; done <<<"$devices"
  driver=$(gpu_driver_version)
  if [ -n "$driver" ]; then info "${prefix}driver: NVIDIA $driver"
  elif gpu_nouveau_loaded; then info "${prefix}driver: missing (nouveau is loaded instead); $GPU_DRIVER_HINT"
  else info "${prefix}driver: missing; $GPU_DRIVER_HINT"; fi
  if have nvidia-smi; then info "${prefix}nvidia-smi: present"; else info "${prefix}nvidia-smi: missing (ships with the driver)"; fi
  cuda=$(gpu_cuda_version)
  if [ -n "$cuda" ]; then info "${prefix}CUDA toolkit: $cuda"; else info "${prefix}CUDA toolkit: not found (optional; never installed here)"; fi
}

module_gpu_plan() {
  gpu_report '    '
  info '    detection only: --apply installs nothing for --gpu'
}

module_gpu_apply() { gpu_report 'NOTE gpu: '; }

module_gpu_check() {
  local devices driver cuda
  devices=$(gpu_devices)
  if [ -z "$devices" ]; then
    report 'none found (not counted)' 'NVIDIA GPU'
    return 0
  fi
  report "$(wc -l <<<"$devices" | tr -d ' ') found" 'NVIDIA GPU'
  driver=$(gpu_driver_version)
  if [ -n "$driver" ]; then report "loaded ($driver)" 'NVIDIA driver'
  elif gpu_nouveau_loaded; then report 'MISSING (nouveau is loaded instead)' 'NVIDIA driver'
  else report MISSING 'NVIDIA driver'; fi
  if have nvidia-smi; then report present 'nvidia-smi'; else report 'missing (not counted)' 'nvidia-smi'; fi
  cuda=$(gpu_cuda_version)
  if [ -n "$cuda" ]; then report "present (${cuda%% *})" 'CUDA toolkit'; else report 'not found (not counted)' 'CUDA toolkit'; fi
}
