#!/bin/bash
#
# pve-nvidia-driver-hook.sh - refresh the locally built NVIDIA driver after a kernel upgrade
#
# The NVIDIA driver is kept on the Proxmox host as a local runfile installer, for example
# NVIDIA-Linux-x86_64-580.178.04.run. A Proxmox kernel upgrade replaces the kernel the driver
# modules were built for, so the driver has to be reinstalled afterwards. This hook finds the
# local runfile and re-runs it:
#
#   host              rebuilds and installs the kernel modules + userspace libraries on the host
#   container <ctid>  installs the userspace libraries only (--no-kernel-modules) inside a
#                     container, because LXC containers share the host kernel
#
# Both modes are idempotent: the driver version in the runfile name is compared with the installed
# driver and nothing is done when they already match (use --force to reinstall in any case).
#
# Usage:
#   pve-nvidia-driver-hook.sh host [--force]
#   pve-nvidia-driver-hook.sh container <ctid> [--force]
#
# pve-update-all.sh runs this hook after the host upgrade and again while container 107 is updated.
#
# Environment overrides:
#   NVIDIA_RUN_FILE=<path>      use this runfile instead of searching the directories
#   NVIDIA_RUN_DIRS="<dirs>"    directories searched for NVIDIA-Linux-x86_64-*.run
#                               (default: /root /opt /usr/local/src /srv /var/lib/vz/dump)
#   NVIDIA_HOST_ARGS="<args>"   installer arguments on the host
#                               (default: --silent --no-x-check --no-nouveau-check)
#   NVIDIA_CT_ARGS="<args>"     installer arguments in a container
#                               (default: --silent --no-kernel-modules --no-x-check --no-nouveau-check)
#   NVIDIA_FORCE_GPU_CHECK=1    ignore the "no NVIDIA hardware detected on this host" check
#   NVIDIA_CT_FORCE=1           install in a container even without an NVIDIA device/library
#   NVIDIA_CT_KEEP_INSTALLER=1  keep the copied runfile inside the container
#   NVIDIA_INSTALL_HEADERS=0    do not install missing kernel headers automatically
#   NVIDIA_UNLOAD_MODULES=0     do not unload the loaded NVIDIA modules before installing
#   NVIDIA_LOAD_MODULE=0        do not load the freshly built module afterwards
#   NVIDIA_UPDATE_INITRAMFS=0   do not run update-initramfs for the target kernel
#
# Overrides used for simulation/testing:
#   PCT=<cmd>                   pct command to use (default: pct)
#   KERNEL_MODULES_DIR=<dir>    kernel modules tree (default: /lib/modules)
#   BOOT_DIR=<dir>              kernel image directory (default: /boot)
#   CT_TMP_DIR=<dir>            directory inside the container used for the copied runfile
#                               (default: /tmp)
#
# Exit status: 0 = installed, already current or not applicable; 1 = failure

set -euo pipefail

PROGNAME="$(basename "$0")"
RUNFILE_PATTERN="NVIDIA-Linux-x86_64-*.run"
PCT="${PCT:-pct}"
KERNEL_MODULES_DIR="${KERNEL_MODULES_DIR:-/lib/modules}"
BOOT_DIR="${BOOT_DIR:-/boot}"
CT_TMP_DIR="${CT_TMP_DIR:-/tmp}"
DEFAULT_RUN_DIRS=(/root /opt /usr/local/src /srv /var/lib/vz/dump)
DEFAULT_HOST_ARGS=(--silent --no-x-check --no-nouveau-check)
DEFAULT_CT_ARGS=(--silent --no-kernel-modules --no-x-check --no-nouveau-check)
STARTED_CT=""

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$PROGNAME" "$*"; }
warn() { printf '%s [%s] WARNING: %s\n' "$(date '+%F %T')" "$PROGNAME" "$*" >&2; }
die() {
  printf '%s [%s] ERROR: %s\n' "$(date '+%F %T')" "$PROGNAME" "$*" >&2
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: pve-nvidia-driver-hook.sh host [--force]
       pve-nvidia-driver-hook.sh container <ctid> [--force]

  host              reinstall the local NVIDIA runfile on the Proxmox host (kernel modules +
                    userspace libraries), building for the newest installed kernel
  container <ctid>  copy the runfile into the container and reinstall the userspace libraries
                    there with --no-kernel-modules
  --force, -f       reinstall even when the installed driver already matches the runfile
EOF
}

# --------------------------------------------------------------- finding the runfile

find_runfile() {
  if [[ -n ${NVIDIA_RUN_FILE:-} ]]; then
    if [[ ! -f $NVIDIA_RUN_FILE ]]; then
      warn "NVIDIA_RUN_FILE=$NVIDIA_RUN_FILE does not exist"
      return 1
    fi
    printf '%s\n' "$NVIDIA_RUN_FILE"
    return 0
  fi

  local -a dirs=()
  if [[ -n ${NVIDIA_RUN_DIRS:-} ]]; then
    # shellcheck disable=SC2206
    dirs=(${NVIDIA_RUN_DIRS})
  else
    dirs=("${DEFAULT_RUN_DIRS[@]}")
  fi

  local -a candidates=()
  local dir file
  for dir in "${dirs[@]}"; do
    if [[ ! -d $dir ]]; then
      continue
    fi
    while IFS= read -r -d '' file; do
      candidates+=("$file")
    done < <(find "$dir" -maxdepth 2 -type f -name "$RUNFILE_PATTERN" -print0 2>/dev/null)
  done

  if (( ${#candidates[@]} == 0 )); then
    warn "no $RUNFILE_PATTERN found in: ${dirs[*]}"
    return 1
  fi

  printf '%s\n' "${candidates[@]}" | sort -V | tail -n 1
}

# 580.178.04 from NVIDIA-Linux-x86_64-580.178.04.run
runfile_version() {
  local base
  base="$(basename "$1")"
  if [[ $base =~ ^NVIDIA-Linux-x86_64-([0-9][0-9.]*)\.run$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  warn "cannot read a driver version from $base"
  return 1
}

# --------------------------------------------------------------- host helpers

# newest installed kernel; after an upgrade this is the kernel that will boot next
newest_installed_kernel() {
  local -a kernels=()
  local file kernel
  for file in "$BOOT_DIR"/vmlinuz-*; do
    if [[ -e $file ]]; then
      kernels+=("${file#"$BOOT_DIR"/vmlinuz-}")
    fi
  done
  if (( ${#kernels[@]} == 0 )); then
    return 1
  fi
  kernel="$(printf '%s\n' "${kernels[@]}" | sort -V | tail -n 1)"
  if [[ ! -d $KERNEL_MODULES_DIR/$kernel ]]; then
    return 1
  fi
  printf '%s\n' "$kernel"
}

# driver version of the installed nvidia module for the given kernel, empty when there is none
kernel_module_version() {
  if ! have modinfo; then
    return 1
  fi
  modinfo -k "$1" -F version "nvidia" 2>/dev/null | head -n 1
}

host_has_nvidia_gpu() {
  if compgen -G '/dev/nvidia*' >/dev/null 2>&1; then
    return 0
  fi
  if have lspci && lspci -nn 2>/dev/null | grep -q '\[10de:'; then
    return 0
  fi
  return 1
}

# the nvidia installer needs $KERNEL_MODULES_DIR/<kernel>/build to build the modules
ensure_kernel_build_dir() {
  local kernel="$1" package
  if [[ -e $KERNEL_MODULES_DIR/$kernel/build ]]; then
    return 0
  fi
  if [[ ${NVIDIA_INSTALL_HEADERS:-1} != 1 ]]; then
    return 1
  fi

  for package in "proxmox-headers-$kernel" "linux-headers-$kernel"; do
    log "kernel build directory for $kernel is missing, trying to install $package"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1 &&
      [[ -e $KERNEL_MODULES_DIR/$kernel/build ]]; then
      log "$package installed"
      return 0
    fi
  done
  return 1
}

# true when the given module is currently loaded
module_is_loaded() {
  lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# driver version of the loaded nvidia module, empty when it is not loaded
loaded_nvidia_version() {
  if ! have modinfo; then
    return 1
  fi
  modinfo -F version "nvidia" 2>/dev/null | head -n 1
}

# the installer replaces the module files, so the loaded modules are detached first (best effort)
unload_nvidia_modules() {
  local module
  for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    if ! module_is_loaded "$module"; then
      continue
    fi
    if modprobe -r "$module" 2>/dev/null; then
      log "unloaded $module"
    else
      warn "$module is still in use, the installer may refuse to replace it (stop GPU workloads first)"
    fi
  done
}

# nvidia-smi needs the modules of the running kernel, so this is only called for live installs
report_loaded_state() {
  if [[ ${NVIDIA_LOAD_MODULE:-1} == 1 ]]; then
    if modprobe nvidia 2>/dev/null; then
      log "nvidia module loaded ($(loaded_nvidia_version || echo 'version unknown'))"
    else
      warn "could not load the nvidia module, a reboot may be required"
    fi
  fi

  if ! have nvidia-smi; then
    return 0
  fi
  local smi_version
  smi_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  if [[ $smi_version == "$1" ]]; then
    log "nvidia-smi reports driver version $1"
  else
    warn "nvidia-smi reports '${smi_version:-nothing}', expected $1"
  fi
}

install_on_host() {
  local force="$1"
  local runfile version running target newest installed_version

  if [[ ${NVIDIA_FORCE_GPU_CHECK:-0} != 1 ]] && ! host_has_nvidia_gpu; then
    log "no NVIDIA hardware detected on this host, nothing to do"
    return 0
  fi

  if ! runfile="$(find_runfile)"; then
    die "NVIDIA runfile not found (set NVIDIA_RUN_FILE or NVIDIA_RUN_DIRS)"
  fi
  if ! version="$(runfile_version "$runfile")"; then
    die "cannot determine the driver version from $(basename "$runfile")"
  fi
  log "using $(basename "$runfile") ($version)"

  running="$(uname -r)"
  target="$running"
  if newest="$(newest_installed_kernel)"; then
    if [[ $newest != "$running" ]]; then
      log "kernel $newest is installed but not running yet, building the driver for it"
      target="$newest"
    fi
  fi

  installed_version="$(kernel_module_version "$target" || true)"
  if [[ $force != true && $installed_version == "$version" ]]; then
    log "NVIDIA $version is already installed for kernel $target, nothing to do"
    return 0
  fi

  if [[ -n $installed_version ]]; then
    log "kernel $target has NVIDIA $installed_version installed, reinstalling $version"
  else
    log "kernel $target has no NVIDIA module installed, installing $version"
  fi

  if ! ensure_kernel_build_dir "$target"; then
    die "kernel headers for $target are missing, install proxmox-headers-$target and re-run"
  fi

  local -a args
  if [[ -n ${NVIDIA_HOST_ARGS:-} ]]; then
    # shellcheck disable=SC2206
    args=(${NVIDIA_HOST_ARGS})
  else
    args=("${DEFAULT_HOST_ARGS[@]}")
  fi
  local live_install=false
  if [[ $target == "$running" ]]; then
    live_install=true
  else
    # the target kernel is not running yet, so install for it explicitly
    args+=("--kernel-name=$target")
  fi

  if [[ $live_install == true && ${NVIDIA_UNLOAD_MODULES:-1} == 1 ]]; then
    unload_nvidia_modules
  fi

  log "running $(basename "$runfile") ${args[*]}"
  if ! ( cd "$(dirname "$runfile")" && sh "$runfile" "${args[@]}" ); then
    die "the NVIDIA installer failed for kernel $target (see /var/log/nvidia-installer.log)"
  fi
  log "NVIDIA $version installed for kernel $target"

  if [[ ${NVIDIA_UPDATE_INITRAMFS:-1} == 1 ]] && have update-initramfs; then
    if update-initramfs -u -k "$target" >/dev/null 2>&1; then
      log "initramfs updated for kernel $target"
    else
      warn "update-initramfs failed for kernel $target"
    fi
  fi

  if [[ $live_install == true ]]; then
    report_loaded_state "$version"
  else
    log "reboot into kernel $target to load the new NVIDIA modules"
  fi
  return 0
}

# --------------------------------------------------------------- container helpers

ct_is_running() {
  $PCT status "$1" 2>/dev/null | grep -qw running
}

# validate the container once so the commands below can assume it exists and is running
ensure_ct_running() {
  local ctid="$1"
  if ! $PCT status "$ctid" >/dev/null 2>&1; then
    die "container $ctid does not exist"
  fi
  if ct_is_running "$ctid"; then
    return 0
  fi

  log "starting container $ctid"
  $PCT start "$ctid"
  STARTED_CT="$ctid"
  for _ in $(seq 1 30); do
    if ct_is_running "$ctid"; then
      return 0
    fi
    sleep 1
  done
  die "container $ctid did not start"
}

# true when the container sees an NVIDIA device or has NVIDIA libraries installed
ct_has_nvidia() {
  $PCT exec "$1" -- bash -c 'compgen -G "/dev/nvidia*" >/dev/null 2>&1 || ldconfig -p 2>/dev/null | grep -q libnvidia' 2>/dev/null
}

# version of the NVIDIA userspace driver inside the container, empty when it is not installed
ct_userspace_version() {
  local version
  version="$($PCT exec "$1" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  if [[ -n $version && $version != *[!0-9.]* ]]; then
    printf '%s\n' "$version"
    return 0
  fi

  # nvidia-smi can be missing, fall back to the version of the installed library; the single quoted
  # container shell is intentional, its variables belong to the container
  # shellcheck disable=SC2016
  version="$($PCT exec "$1" -- bash -c '
    for lib in /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 \
               /usr/lib/aarch64-linux-gnu/libnvidia-ml.so.1 \
               /usr/lib64/libnvidia-ml.so.1 \
               /usr/lib/libnvidia-ml.so.1; do
      if [ -e "$lib" ]; then
        readlink -f "$lib" | sed -n "s/.*\.so\.//p"
        exit 0
      fi
    done
    exit 1
  ' 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n $version ]]; then
    printf '%s\n' "$version"
    return 0
  fi
  return 1
}

# last lines of the installer log inside a container, only when one exists
ct_installer_log() {
  # the single quoted container shell is intentional, its variables belong to the container
  # shellcheck disable=SC2016
  $PCT exec "$1" -- bash -c '
    for log in /var/log/nvidia-installer.log /tmp/nvidia-installer.log; do
      if [ -f "$log" ]; then
        echo "    --- $log (last 20 lines) ---"
        tail -n 20 "$log" | sed "s/^/    /"
      fi
    done
  ' 2>/dev/null || true
}

stop_container() {
  local ctid="$1"
  log "stopping container $ctid"
  if ! $PCT shutdown "$ctid" 2>/dev/null && ! $PCT stop "$ctid" 2>/dev/null; then
    warn "could not stop container $ctid"
  fi
  STARTED_CT=""
}

# make sure a container started by this hook is never left running
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n $STARTED_CT ]]; then
    stop_container "$STARTED_CT"
  fi
  exit "$rc"
}
trap cleanup EXIT

install_in_container() {
  local ctid="$1" force="$2"
  local runfile version target failed=false should_stop=false
  local -a args

  if ! runfile="$(find_runfile)"; then
    die "NVIDIA runfile not found (set NVIDIA_RUN_FILE or NVIDIA_RUN_DIRS)"
  fi
  if ! version="$(runfile_version "$runfile")"; then
    die "cannot determine the driver version from $(basename "$runfile")"
  fi
  log "using $(basename "$runfile") ($version)"

  if ! ct_is_running "$ctid"; then
    should_stop=true
  fi
  ensure_ct_running "$ctid"

  if [[ ${NVIDIA_CT_FORCE:-0} != 1 ]] && ! ct_has_nvidia "$ctid"; then
    log "container $ctid has no NVIDIA device or driver library, skipping (set NVIDIA_CT_FORCE=1 to install anyway)"
    if [[ $should_stop == true ]]; then
      stop_container "$ctid"
    fi
    return 0
  fi

  target="$(ct_userspace_version "$ctid" || true)"
  if [[ $force != true && $target == "$version" ]]; then
    log "container $ctid already has NVIDIA $version installed, nothing to do"
    if [[ $should_stop == true ]]; then
      stop_container "$ctid"
    fi
    return 0
  fi
  log "container $ctid has NVIDIA '${target:-not installed}', expected $version"

  if [[ -n ${NVIDIA_CT_ARGS:-} ]]; then
    # shellcheck disable=SC2206
    args=(${NVIDIA_CT_ARGS})
  else
    args=("${DEFAULT_CT_ARGS[@]}")
  fi

  local remote
  remote="$CT_TMP_DIR/$(basename "$runfile")"
  log "copying $(basename "$runfile") to $remote in container $ctid"
  $PCT push "$ctid" "$runfile" "$remote"

  log "running $(basename "$runfile") ${args[*]} in container $ctid"
  if ! $PCT exec "$ctid" -- bash -c "cd '$CT_TMP_DIR' && rm -f '$CT_TMP_DIR/nvidia-installer.log' && sh '$remote' ${args[*]}"; then
    failed=true
    warn "the NVIDIA installer failed inside container $ctid"
    ct_installer_log "$ctid"
  fi

  if [[ ${NVIDIA_CT_KEEP_INSTALLER:-0} == 1 ]]; then
    log "kept $remote in container $ctid"
  elif ! $PCT exec "$ctid" -- rm -f "$remote"; then
    warn "could not remove $remote from container $ctid"
  fi

  if [[ $failed == false ]]; then
    local new_version
    new_version="$(ct_userspace_version "$ctid" || true)"
    if [[ $new_version == "$version" ]]; then
      log "container $ctid now has NVIDIA $version installed"
    else
      warn "container $ctid reports '${new_version:-not installed}', expected $version"
    fi
  fi

  if [[ $should_stop == true ]]; then
    stop_container "$ctid"
  fi

  if [[ $failed == true ]]; then
    return 1
  fi
  return 0
}

# --------------------------------------------------------------- entry point

main() {
  local force=false mode ctid
  local -a positional=()
  local arg
  for arg in "$@"; do
    case $arg in
      --force | -f) force=true ;;
      -h | --help)
        usage
        return 0
        ;;
      *) positional+=("$arg") ;;
    esac
  done

  mode="${positional[0]:-}"
  case $mode in
    host)
      install_on_host "$force"
      ;;
    container | ct)
      ctid="${positional[1]:-}"
      if [[ ! $ctid =~ ^[0-9]+$ ]]; then
        usage >&2
        die "container mode needs a numeric container id"
      fi
      if ! have "$PCT"; then
        die "$PCT not found, this hook must run on a Proxmox host"
      fi
      install_in_container "$ctid" "$force"
      ;;
    '')
      usage >&2
      return 1
      ;;
    *)
      usage >&2
      die "unknown mode '$mode'"
      ;;
  esac
}

main "$@"