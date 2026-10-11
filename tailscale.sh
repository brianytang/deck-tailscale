#!/usr/bin/env bash
# Install the official static client without unlocking SteamOS's root filesystem.
set -Eeuo pipefail
umask 022

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run this installer with sudo bash tailscale.sh.'
[[ $# -eq 0 ]] || die 'This installer takes no arguments.'
for command in curl jq tar sha256sum systemctl install stat mktemp readlink; do
  command -v "$command" >/dev/null || die "Missing required command: $command"
done
case "$(uname -m)" in
  aarch64|arm64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) die 'Only ARM64 (Steam Frame) and x86-64 (Steam Deck) are supported.' ;;
esac

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$script_dir/override.conf" ]] || die 'Missing override.conf next to the installer.'
bin_dir=/var/lib/tailscale-bin
unit_dir=/etc/systemd/system
dropin_dir=$unit_dir/tailscaled.service.d
defaults=/etc/default/tailscaled
profile=/etc/profile.d/tailscale.sh
keep=/etc/atomic-update.conf.d/tailscale.conf

# A privileged daemon must never execute files replaceable by the login user.
# Check ancestors before mkdir/install, and refuse symlinked configuration targets.
secure_directory() {
  local path=$1 owner mode
  [[ ! -L "$path" ]] || die "Refusing symlinked directory: $path"
  if [[ -e "$path" ]]; then
    [[ -d "$path" ]] || die "Not a directory: $path"
    owner=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    [[ $owner == 0 ]] && (( (8#$mode & 0022) == 0 )) || die "Directory must be root-owned and not group/other writable: $path"
  else
    install -d -o root -g root -m 0755 -- "$path"
  fi
}
for path in /var /var/lib "$bin_dir" "$bin_dir/releases" /etc /etc/systemd "$unit_dir" "$dropin_dir" /etc/default /etc/profile.d /etc/atomic-update.conf.d; do
  secure_directory "$path"
done
for path in "$defaults" "$profile" "$keep" "$unit_dir/tailscaled.service" "$dropin_dir/10-steamos.conf"; do
  [[ ! -L "$path" ]] || die "Refusing symlinked file: $path"
done
if [[ -e "$dropin_dir/override.conf" ]]; then
  die 'An older override.conf exists. Back it up outside tailscaled.service.d and remove it before installing; see readme.md.'
fi
[[ ! -e "$bin_dir/current" || -L "$bin_dir/current" ]] || die "$bin_dir/current must be a symlink."

tmp=$(mktemp -d)
release=
cleanup() {
  rm -rf -- "$tmp"
  # A failed download/validation must not leave a half-installed release.
  if [[ -n $release && -d $release ]] && [[ $(readlink "$bin_dir/current" 2>/dev/null || true) != "releases/${release##*/}" ]]; then
    rm -rf -- "$release"
  fi
}
trap cleanup EXIT
trap 'printf "Installation failed (line %s). Existing login state is preserved.\n" "$LINENO" >&2' ERR
fetch() { curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 20 --max-time 300 "$@"; }

printf 'Looking up the latest stable %s release...\n' "$arch"
fetch 'https://pkgs.tailscale.com/stable/?mode=json' > "$tmp/metadata.json"
tarball=$(jq -er --arg arch "$arch" '.Tarballs[$arch] | strings' "$tmp/metadata.json")
[[ $tarball =~ ^tailscale_([0-9]+\.[0-9]+\.[0-9]+)_${arch}\.tgz$ ]] || die "Unexpected archive name: $tarball"
version=${BASH_REMATCH[1]}
fetch "https://pkgs.tailscale.com/stable/$tarball" -o "$tmp/tailscale.tgz"
fetch "https://pkgs.tailscale.com/stable/$tarball.sha256" -o "$tmp/checksum"
read -r checksum _ < "$tmp/checksum"
[[ $checksum =~ ^[a-fA-F0-9]{64}$ ]] || die 'Invalid SHA-256 response.'
printf '%s  %s\n' "$checksum" "$tmp/tailscale.tgz" | sha256sum --check --status || die 'Archive checksum mismatch; existing service was not stopped.'

archive_dir=${tarball%.tgz}
# Extract only expected members; do not unpack arbitrary paths from an archive.
tar -xzf "$tmp/tailscale.tgz" -C "$tmp" --no-same-owner --no-same-permissions -- \
  "$archive_dir/tailscale" "$archive_dir/tailscaled" \
  "$archive_dir/systemd/tailscaled.service" "$archive_dir/systemd/tailscaled.defaults"
for member in tailscale tailscaled systemd/tailscaled.service systemd/tailscaled.defaults; do
  [[ -f "$tmp/$archive_dir/$member" && ! -L "$tmp/$archive_dir/$member" ]] || die "Missing or symlinked archive member: $member"
done
release=$(mktemp -d "$bin_dir/releases/release.XXXXXX")
chmod 0755 "$release"
install -o root -g root -m 0755 "$tmp/$archive_dir/tailscale" "$tmp/$archive_dir/tailscaled" "$release/"
printf '%s\n' "$version" > "$release/VERSION"

# Keep administrator settings, including an existing device's login state.
if [[ ! -e $defaults ]]; then
  install -o root -g root -m 0644 "$tmp/$archive_dir/systemd/tailscaled.defaults" "$defaults"
fi
install -o root -g root -m 0644 "$tmp/$archive_dir/systemd/tailscaled.service" "$unit_dir/tailscaled.service"
install -o root -g root -m 0644 "$script_dir/override.conf" "$dropin_dir/10-steamos.conf"
printf 'export PATH="$PATH:/var/lib/tailscale-bin/current"\n' > "$profile"
chmod 0644 "$profile"
cat > "$keep" <<'EOF'
/etc/default/tailscaled
/etc/profile.d/tailscale.sh
/etc/systemd/system/tailscaled.service
/etc/systemd/system/tailscaled.service.d/10-steamos.conf
/etc/systemd/system/multi-user.target.wants/tailscaled.service
EOF
chmod 0644 "$keep"

# Download and stage first. Switch the entire binary pair atomically while stopped.
# Run this over local SSH: stopping Tailscale disconnects sessions using it.
systemctl daemon-reload
if systemctl is-active --quiet tailscaled; then
  systemctl stop tailscaled
fi
ln -s "releases/${release##*/}" "$bin_dir/.current.$$"
mv -Tf -- "$bin_dir/.current.$$" "$bin_dir/current"
systemctl enable tailscaled
systemctl restart tailscaled
systemctl is-active --quiet tailscaled || die 'tailscaled did not become active; inspect journalctl -u tailscaled.'

printf 'Installed Tailscale %s (%s).\n' "$version" "$arch"
printf 'Load the CLI with: source /etc/profile.d/tailscale.sh\n'
printf 'Then connect with: sudo /var/lib/tailscale-bin/current/tailscale up --operator=<your-login-user>\n'
printf 'Installation does not authenticate the device. Check tailscale status after browser login.\n'
