#!/bin/bash
# update all containers - supports both Debian and Arch based systems

set -euo pipefail

# list of container ids we need to iterate through 
# exclude nixos container and templates
containers=$(pct list | tail -n +2 | grep -v "110" | grep -v "template" | cut -f1 -d' ')

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

# Update all containers
for container in $containers
do
  update_container $container
done

echo "All updates completed!"
