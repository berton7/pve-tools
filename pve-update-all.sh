#!/bin/bash
# update all containers - supports both Debian and Arch based systems
#
# After the host upgrade the local NVIDIA driver runfile is reinstalled, because a Proxmox kernel
# upgrade replaces the kernel the driver modules were built for. Container 107 gets the userspace
# part of the same driver reinstalled (--no-kernel-modules), containers share the host kernel.

set -euo pipefail

# defined containers that need the NVIDIA userspace driver reinstalled after an update
nvidia_containers="107"

# handle the NVIDIA driver refresh (see pve-nvidia-driver-hook.sh)
nvidia_hook="$(dirname "$(readlink -f "$0")")/pve-nvidia-driver-hook.sh"
nvidia_hook_timeout=900

# set DRY_RUN=1 to only show what would be done
dry_run=false
if [[ ${DRY_RUN:-0} != 0 ]]; then
  dry_run=true
fi

# list of container ids we need to iterate through 
# exclude nixos container and templates
containers=$(pct list | tail -n +2 | grep -v "110" | grep -v "template" | cut -f1 -d' ')

function nvidia_container_wanted() {
  [[ ";$nvidia_containers;" == *";$1;"* ]]
}

# reinstall the NVIDIA driver: kernel modules on the host, userspace only in containers
function refresh_nvidia_driver() {
  local mode=$1
  local container=${2:-}
  local -a hook_env=()

  # These calls are specifically for a configured NVIDIA host/container. Don't gate them on
  # /dev/nvidia* or container library visibility: those can be absent precisely because the
  # kernel modules have just been replaced.
  case $mode in
    host) hook_env+=(NVIDIA_FORCE_GPU_CHECK=1) ;;
    container) hook_env+=(NVIDIA_CT_FORCE=1) ;;
  esac

  if [ ! -f "$nvidia_hook" ]; then
    echo "  Warning: $nvidia_hook not found, skipping the NVIDIA driver refresh"
    return 0
  fi

  if [ $dry_run = true ]; then
    echo "  Would run: $nvidia_hook $mode${container:+ $container}"
    return 0
  fi

  echo "  Refreshing the NVIDIA driver ($mode${container:+ for container $container})..."
  # the driver refresh must never abort the remaining updates
  if timeout "$nvidia_hook_timeout" env "${hook_env[@]}" bash "$nvidia_hook" "$mode" $container; then
    echo "  NVIDIA driver refreshed"
  else
    local rc=$?
    if [ $rc -eq 124 ]; then
      echo "  Warning: the NVIDIA driver refresh timed out after ${nvidia_hook_timeout}s"
    else
      echo "  Warning: the NVIDIA driver refresh failed with exit code $rc"
    fi
  fi
  return 0
}

function update_container() {
  container=$1
  stopped=false
  
  # check if container is stopped; if so, start it, update it, then shut it down
  if [[ -n $(pct status $container | grep "stopped") ]]; then
    echo "starting $container..."
    stopped=true
    pct start $container
    # give container time to fully start
    sleep 5
  fi

  echo "Updating $container..."

  # community-script containers ship their own update helper; use it instead of apt directly
  tags=$(pct config $container | sed -n 's/^tags: *//p')
  if [[ ";$tags;" == *";community-script;"* ]]; then
    echo "  Detected community-script tag, running update command"
    pct exec $container -- bash -c "update"
  # detect package manager
  elif pct exec $container -- bash -c "command -v apt-get" &>/dev/null; then
    echo "  Detected Debian-based system (apt)"
    pct exec $container -- bash -c "sudo apt-get update && sudo apt-get -y full-upgrade && sudo apt-get -y autoremove"
  elif pct exec $container -- bash -c "command -v pacman" &>/dev/null; then
    echo "  Detected Arch-based system (pacman)"
    # update keyring first to avoid signature verification failures during full upgrade
    pct exec $container -- bash -c "sudo pacman -Sy --noconfirm archlinux-keyring && sudo pacman -Su --noconfirm && sudo pacman -Rns \$(pacman -Qdtq) --noconfirm 2>/dev/null || true"
  else
    echo "  Warning: No supported package manager found in container $container"
  fi

  # containers share the host kernel, so only the userspace driver is reinstalled here
  if nvidia_container_wanted "$container"; then
    refresh_nvidia_driver container "$container"
  fi

  if [ $stopped = true ]; then
    echo "stopping $container..."
    pct shutdown $container
  fi
}

# Update the host system (Proxmox)
echo "Updating host system..."
apt-get update 
apt-get -y full-upgrade 
apt-get -y autoremove

# the upgrade may have installed a new kernel, so the locally built NVIDIA driver needs rebuilding
refresh_nvidia_driver host

# Update all containers
for container in $containers
do
  update_container $container
done

echo "All updates completed!"
