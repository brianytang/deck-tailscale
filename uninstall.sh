#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
[[ $EUID -eq 0 ]] || { echo 'Run with sudo bash uninstall.sh.' >&2; exit 1; }
[[ $# -eq 0 ]] || { echo 'This uninstaller takes no arguments.' >&2; exit 1; }

bin_dir=/home/.tailscale-bin
for path in /run /home /var /var/lib "$bin_dir" /etc /etc/systemd /etc/systemd/system /etc/systemd/system/tailscaled.service.d /etc/systemd/system/multi-user.target.wants /etc/default /etc/profile.d /etc/atomic-update.conf.d; do
  [[ ! -L "$path" ]] || { echo "Refusing symlinked directory: $path" >&2; exit 1; }
  if [[ -e "$path" ]]; then
    owner=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    if [[ $owner != 0 ]] || (( (8#$mode & 0022) != 0 )); then echo "Unsafe directory: $path" >&2; exit 1; fi
  fi
done
[[ ! -L /run/deck-tailscale.lock ]] || { echo 'Unsafe installer lock.' >&2; exit 1; }
exec 9>/run/deck-tailscale.lock
flock -n 9 || { echo 'Another install or uninstall is running.' >&2; exit 1; }
marker=$bin_dir/managed-by-deck-tailscale
if [[ ! -e "$bin_dir" && ! -e /etc/systemd/system/tailscaled.service ]]; then
  echo 'Already uninstalled.'
  exit 0
fi
if [[ ! -f $marker || -L $marker ]] || ! grep -qx 'deck-tailscale-v1' "$marker"; then
  echo 'Refusing to uninstall an unmanaged installation.' >&2
  exit 1
fi
for path in "$marker" /etc/systemd/system/tailscaled.service \
  /etc/systemd/system/tailscaled.service.d/10-steamos.conf \
  /etc/default/tailscaled /etc/profile.d/tailscale.sh /etc/atomic-update.conf.d/tailscale.conf; do
  [[ ! -L $path ]] || { echo "Unsafe symlink: $path" >&2; exit 1; }
  if [[ -e $path ]]; then
    owner=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    if [[ $owner != 0 ]] || (( (8#$mode & 0022) != 0 )); then echo "Unsafe file: $path" >&2; exit 1; fi
    if [[ $path != "$marker" && $path != /etc/default/tailscaled ]]; then
      grep -q '^# Managed by deck-tailscale\.' "$path" || { echo "File was replaced by another installation: $path" >&2; exit 1; }
    fi
  fi
done
if [[ -e /etc/systemd/system/tailscaled.service ]]; then
  systemctl stop tailscaled
  systemctl disable tailscaled
fi
if grep -qx 'owns-defaults' "$marker"; then rm -f -- /etc/default/tailscaled; fi
rm -f -- /etc/systemd/system/tailscaled.service \
  /etc/systemd/system/tailscaled.service.d/10-steamos.conf \
  /etc/profile.d/tailscale.sh \
  /etc/atomic-update.conf.d/tailscale.conf
rm -rf -- "$bin_dir"
systemctl daemon-reload
echo 'Uninstalled. Login state in /var/lib/tailscale and custom systemd drop-ins were preserved.'
