#!/usr/bin/env bash
# Install the official static client without unlocking SteamOS's root filesystem.
set -Eeuo pipefail
umask 022

die() {
  printf 'ERROR: %s\n' "$*" >&2
  if declare -F on_error >/dev/null; then on_error 1; fi
  exit 1
}
[[ $EUID -eq 0 ]] || die 'Run this installer with sudo bash tailscale.sh.'
[[ $# -eq 0 ]] || die 'This installer takes no arguments.'
for command in curl jq tar sha256sum systemctl install stat mktemp readlink flock; do
  command -v "$command" >/dev/null || die "Missing required command: $command"
done
case "$(uname -m)" in
  aarch64|arm64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) die 'Only ARM64 (Steam Frame) and x86-64 (Steam Deck) are supported.' ;;
esac

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$script_dir/override.conf" ]] || die 'Missing override.conf next to the installer.'
bin_dir=/home/.tailscale-bin
unit_dir=/etc/systemd/system
dropin_dir=$unit_dir/tailscaled.service.d
defaults=/etc/default/tailscaled
profile=/etc/profile.d/tailscale.sh
keep=/etc/atomic-update.conf.d/tailscale.conf
marker=$bin_dir/managed-by-deck-tailscale

# A privileged daemon must never execute files replaceable by the login user.
# Check ancestors before mkdir/install, and refuse symlinked configuration targets.
secure_directory() {
  local path=$1 owner mode
  [[ ! -L "$path" ]] || die "Refusing symlinked directory: $path"
  if [[ -e "$path" ]]; then
    [[ -d "$path" ]] || die "Not a directory: $path"
    owner=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    if [[ $owner != 0 ]] || (( (8#$mode & 0022) != 0 )); then
      die "Directory must be root-owned and not group/other writable: $path"
    fi
  else
    install -d -o root -g root -m 0755 -- "$path"
  fi
}
secure_file() {
  local path=$1 owner mode
  [[ ! -L "$path" ]] || die "Refusing symlinked file: $path"
  if [[ -e "$path" ]]; then
    [[ -f "$path" ]] || die "Not a regular file: $path"
    owner=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    if [[ $owner != 0 ]] || (( (8#$mode & 0022) != 0 )); then die "Unsafe file ownership or mode: $path"; fi
  fi
}
secure_directory /run
secure_file /run/deck-tailscale.lock
exec 9>/run/deck-tailscale.lock
flock -n 9 || die 'Another install or uninstall is running.'
for path in /home /var /var/lib "$bin_dir" "$bin_dir/releases" /var/lib/tailscale /etc /etc/systemd "$unit_dir" "$dropin_dir" "$unit_dir/multi-user.target.wants" /etc/default /etc/profile.d /etc/atomic-update.conf.d; do
  secure_directory "$path"
done
chmod 0700 /var/lib/tailscale
for path in "$defaults" "$profile" "$keep" "$unit_dir/tailscaled.service" "$dropin_dir/10-steamos.conf" "$marker" /var/lib/tailscale/tailscaled.state; do
  secure_file "$path"
done
if [[ -e "$dropin_dir/override.conf" ]]; then
  die 'An older override.conf exists. Back it up outside tailscaled.service.d and remove it before installing; see readme.md.'
fi
[[ ! -e "$bin_dir/current" || -L "$bin_dir/current" ]] || die "$bin_dir/current must be a symlink."
if [[ -L "$bin_dir/current" ]]; then
  previous=$(readlink "$bin_dir/current")
  [[ $previous =~ ^releases/release\.[[:alnum:]]+$ ]] || die 'Unsafe current release target.'
  [[ -d "$bin_dir/$previous" ]] || die 'Current release directory is missing.'
  secure_directory "$bin_dir/$previous"
  for path in "$bin_dir/$previous/tailscale" "$bin_dir/$previous/tailscaled"; do
    secure_file "$path"
    [[ -x $path ]] || die "Missing executable: $path"
  done
fi
if [[ -e $marker ]]; then
  grep -qx 'deck-tailscale-v1' "$marker" || die 'Unknown installation ownership marker.'
else
  [[ $(systemctl show tailscaled --property=LoadState --value) == not-found ]] || die 'An unmanaged system or package unit already exists; see readme.md.'
  for path in "$unit_dir/tailscaled.service" "$profile" "$keep" "$dropin_dir/10-steamos.conf" "$bin_dir/current"; do
    [[ ! -e $path && ! -L $path ]] || die "Existing unmanaged installation at $path; see readme.md."
  done
fi

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
# shellcheck source=lib/transaction.sh
source "$script_dir/lib/transaction.sh"
fetch() { curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 20 --max-time 300 "$@"; }

printf 'Looking up the latest stable %s release...\n' "$arch"
fetch 'https://pkgs.tailscale.com/stable/?mode=json' > "$tmp/metadata.json"
tarball=$(jq -er --arg arch "$arch" '.Tarballs[$arch] | strings' "$tmp/metadata.json")
[[ $tarball =~ ^tailscale_([0-9]+\.[0-9]+\.[0-9]+)_${arch}\.tgz$ ]] || die "Unexpected archive name: $tarball"
version=${BASH_REMATCH[1]}
fetch "https://pkgs.tailscale.com/stable/$tarball" -o "$tmp/tailscale.tgz"
fetch "https://pkgs.tailscale.com/stable/$tarball.sha256" -o "$tmp/checksum"
read -r checksum _ < "$tmp/checksum" || [[ -n $checksum ]]
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
cli_version=$("$release/tailscale" version)
daemon_version=$("$release/tailscaled" --version)
[[ ${cli_version%%$'\n'*} == "$version" && ${daemon_version%%$'\n'*} == "$version" ]] || die 'Staged binaries do not report the expected version.'

begin_transaction
# Stop with the old loaded unit, before replacing its cleanup command or reloading.
if (( was_active )); then systemctl stop tailscaled; fi
# Keep administrator settings, including an existing device's login state.
if [[ ! -e $defaults ]]; then
  install -o root -g root -m 0644 "$tmp/$archive_dir/systemd/tailscaled.defaults" "$defaults"
fi
{ printf '# Managed by deck-tailscale.\n'; cat "$tmp/$archive_dir/systemd/tailscaled.service"; } > "$tmp/unit"
install -o root -g root -m 0644 "$tmp/unit" "$unit_dir/tailscaled.service"
firewall_mode=auto
[[ $arch != arm64 ]] || firewall_mode=nftables
sed "s/TS_DEBUG_FIREWALL_MODE=auto/TS_DEBUG_FIREWALL_MODE=$firewall_mode/" "$script_dir/override.conf" > "$tmp/override"
install -o root -g root -m 0644 "$tmp/override" "$dropin_dir/10-steamos.conf"
cat > "$tmp/profile" <<'EOF'
# Managed by deck-tailscale.
export PATH="$PATH:/home/.tailscale-bin/current"
EOF
install -o root -g root -m 0644 "$tmp/profile" "$profile"
cat > "$tmp/keep" <<'EOF'
# Managed by deck-tailscale.
/etc/default/tailscaled
/etc/profile.d/tailscale.sh
/etc/systemd/system/tailscaled.service
/etc/systemd/system/tailscaled.service.d/10-steamos.conf
/etc/systemd/system/multi-user.target.wants/tailscaled.service
/etc/atomic-update.conf.d/tailscale.conf
EOF
install -o root -g root -m 0644 "$tmp/keep" "$keep"
printf 'deck-tailscale-v1\n' > "$tmp/marker"
if [[ ${existed[0]} == 0 ]] || { [[ -e $marker ]] && grep -qx 'owns-defaults' "$marker"; }; then
  printf 'owns-defaults\n' >> "$tmp/marker"
fi
install -o root -g root -m 0644 "$tmp/marker" "$marker"

# Download and stage first. Switch the entire binary pair atomically while stopped.
# Run this over local SSH: stopping Tailscale disconnects sessions using it.
ln -s "releases/${release##*/}" "$bin_dir/.current.$$"
mv -Tf -- "$bin_dir/.current.$$" "$bin_dir/current"
systemctl daemon-reload
systemctl enable tailscaled
systemctl restart tailscaled
systemctl is-active --quiet tailscaled || die 'tailscaled did not become active; inspect journalctl -u tailscaled.'
transaction=0

printf 'Installed Tailscale %s (%s).\n' "$version" "$arch"
printf 'Load the CLI with: source /etc/profile.d/tailscale.sh\n'
printf 'Then connect with: sudo /home/.tailscale-bin/current/tailscale up --operator=<your-login-user>\n'
printf 'Installation does not authenticate the device. Check tailscale status after browser login.\n'
