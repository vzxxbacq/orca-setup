#!/usr/bin/env bats
# --gpu (P4): NVIDIA detection on Linux against a fake sysfs tree, lspci, nvidia-smi and nvcc. Detection only:
# no test may reach sudo, apt or any other state-changing command.

load helpers

setup() {
  make_sandbox
  fake_linux
  export ORCA_SETUP_SYSFS_ROOT=$SB/sys ORCA_SETUP_PROC_ROOT=$SB/proc ORCA_SETUP_CUDA_HOME=$SB/cuda
  mkdir -p "$SB/sys/bus/pci/devices" "$SB/sys/module" "$SB/proc"
  pci_device 0000:00:02.0 0x8086 0x030000 # an Intel iGPU is not counted
}

teardown() {
  [ ! -s "$FAKE_LOG" ] || { cat "$FAKE_LOG"; return 1; }
}

pci_device() { # pci_device <slot> <vendor> <class>
  mkdir -p "$SB/sys/bus/pci/devices/$1"
  echo "$2" >"$SB/sys/bus/pci/devices/$1/vendor"
  echo "$3" >"$SB/sys/bus/pci/devices/$1/class"
}

nvidia_gpu() {
  pci_device 0000:01:00.0 0x10de 0x030000
  pci_device 0000:01:00.1 0x10de 0x040300 # its HDMI audio function is not a GPU
  # shellcheck disable=SC2016 # expanded by the stub
  fake_cmd lspci 'case "$*" in "-s 0000:01:00.0") echo "01:00.0 VGA compatible controller: NVIDIA Corporation AD102 [GeForce RTX 4090] (rev a1)" ;; *) exit 1 ;; esac'
}

nvidia_driver() {
  mkdir -p "$SB/sys/module/nvidia"
  echo 550.54.14 >"$SB/sys/module/nvidia/version"
  fake_cmd nvidia-smi 'echo "NVIDIA-SMI 550.54.14"'
}

cuda_toolkit() {
  mkdir -p "$SB/cuda/bin"
  printf '#!%s\necho "Cuda compilation tools, release 12.4, V12.4.131"\n' "$REAL_BASH" >"$SB/cuda/bin/nvcc"
  chmod +x "$SB/cuda/bin/nvcc"
}

missing_items() { sed -n 's/^MISSING_ITEMS //p' <<<"$output"; }

@test "--plan --gpu reports the GPU, driver, nvidia-smi and CUDA, and installs nothing" {
  nvidia_gpu
  nvidia_driver
  cuda_toolkit
  run_setup --plan --gpu
  [ "$status" -eq 0 ]
  [[ "$output" == *'--gpu           Report the NVIDIA GPU, driver, nvidia-smi and CUDA toolkit (detection only; never installs). [selected]'* ]]
  [[ "$output" == *'    NVIDIA GPU 0000:01:00.0: NVIDIA Corporation AD102 [GeForce RTX 4090] (rev a1)'* ]]
  [[ "$output" != *'0000:01:00.1'* ]]
  [[ "$output" != *'0000:00:02.0'* ]]
  [[ "$output" == *'    driver: NVIDIA 550.54.14'* ]]
  [[ "$output" == *'    nvidia-smi: present'* ]]
  [[ "$output" == *"    CUDA toolkit: 12.4 ($SB/cuda/bin/nvcc)"* ]]
  [[ "$output" == *'    detection only: --apply installs nothing for --gpu'* ]]
}

@test "--plan --gpu without an NVIDIA GPU says so" {
  run_setup --plan --gpu
  [ "$status" -eq 0 ]
  [[ "$output" == *'    no NVIDIA GPU found (nothing to check)'* ]]
}

@test "a GPU without the NVIDIA driver: the driver is counted, nvidia-smi and CUDA are not" {
  run_setup --check
  local base
  base=$(missing_items)
  nvidia_gpu
  run_setup --check --gpu
  [[ "$output" == *'NVIDIA GPU: 1 found'* ]]
  [[ "$output" == *'NVIDIA driver: MISSING'* ]]
  [[ "$output" == *'nvidia-smi: missing (not counted)'* ]]
  [[ "$output" == *'CUDA toolkit: not found (not counted)'* ]]
  [ "$(missing_items)" -eq $((base + 1)) ]
  mkdir -p "$SB/sys/module/nouveau"
  run_setup --check --gpu
  [[ "$output" == *'NVIDIA driver: MISSING (nouveau is loaded instead)'* ]]
  [ "$(missing_items)" -eq $((base + 1)) ]
}

@test "a GPU with its driver counts nothing" {
  run_setup --check
  local base
  base=$(missing_items)
  nvidia_gpu
  nvidia_driver
  cuda_toolkit
  run_setup --check --gpu
  [[ "$output" == *'NVIDIA driver: loaded (550.54.14)'* ]]
  [[ "$output" == *'nvidia-smi: present'* ]]
  [[ "$output" == *'CUDA toolkit: present (12.4)'* ]]
  [ "$(missing_items)" -eq "$base" ]
}

@test "no NVIDIA GPU: nothing is counted" {
  run_setup --check
  local base
  base=$(missing_items)
  run_setup --check --gpu
  [[ "$output" == *'NVIDIA GPU: none found (not counted)'* ]]
  [[ "$output" != *'NVIDIA driver'* ]]
  [ "$(missing_items)" -eq "$base" ]
}

@test "without a sysfs tree, lspci finds the GPU; the driver version can come from /proc" {
  rm -rf "$SB/sys/bus"
  # shellcheck disable=SC2016
  fake_cmd lspci 'case "$*" in "-nn -d 10de:") printf "01:00.0 3D controller [0302]: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)\n01:00.1 Audio device [0403]: NVIDIA Corporation Device [10de:1aef]\n" ;; *) exit 1 ;; esac'
  mkdir -p "$SB/proc/driver/nvidia"
  echo 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  535.183.01  Sun May 12 19:39:15 UTC 2024' >"$SB/proc/driver/nvidia/version"
  run_setup --plan --gpu
  [[ "$output" == *'    NVIDIA GPU 01:00.0: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)'* ]]
  [[ "$output" != *'Audio device'* ]]
  [[ "$output" == *'    driver: NVIDIA 535.183.01'* ]]
}

@test "--apply --gpu only prints NOTE lines" {
  nvidia_gpu
  # The module's apply step on its own: --apply would first install the baseline.
  # shellcheck disable=SC2034 # read by modules/gpu.sh
  PLATFORM=debian
  . "$REPO_ROOT/lib/common.sh"
  . "$REPO_ROOT/modules/gpu.sh"
  run module_gpu_apply
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]
  local line
  for line in "${lines[@]}"; do [[ "$line" == 'NOTE gpu: '* ]] || { echo "$line"; return 1; }; done
  [[ "$output" == *'NOTE gpu: driver: missing; install the NVIDIA driver yourself'* ]]
}

@test "macOS skips --gpu with a notice and counts nothing" {
  fake_uname Darwin arm64
  unset ORCA_SETUP_OS_RELEASE
  run_setup --plan --gpu
  [ "$status" -eq 0 ]
  [[ "$output" == *'    skip: not applicable on macOS (NVIDIA GPU detection is Linux-only)'* ]]
  run_setup --check --gpu
  [[ "$output" == *'Module gpu: skipped (not applicable on macOS (NVIDIA GPU detection is Linux-only); not counted)'* ]]
}
