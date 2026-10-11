#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo bash uninstall.sh.' >&2; exit 1; }
[[ $# -eq 0 ]] || { echo 'This uninstaller takes no arguments.' >&2; exit 1; }

bin_dir=/var/lib/tailscale-bin
for path in /var /var/lib "$bin_dir" /etc /etc/systemd /etc/systemd/system /etc/systemd/system/tailscaled.service.d /etc/default /etc/profile.d /etc/atomic-update.conf.d; do
  [[ ! -L "$path" ]] || { echo "Refusing symlinked directory: $path" >&2; exit 1; }
  if [[ -e "$path" ]]; then
    owner=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    [[ $owner == 0 ]] && (( (8#$mode & 0022) == 0 )) || { echo "Unsafe directory: $path" >&2; exit 1; }
  fi
done
if [[ -e /etc/systemd/system/tailscaled.service ]]; then
  systemctl stop tailscaled
  systemctl disable tailscaled
fi
rm -f -- /etc/systemd/system/tailscaled.service \
  /etc/systemd/system/tailscaled.service.d/10-steamos.conf \
  /etc/default/tailscaled /etc/profile.d/tailscale.sh \
  /etc/atomic-update.conf.d/tailscale.conf
rm -rf -- "$bin_dir"
systemctl daemon-reload
echo 'Uninstalled. Login state in /var/lib/tailscale and custom systemd drop-ins were preserved.'
