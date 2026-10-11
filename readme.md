# Tailscale on Steam Frame and Steam Deck

A community installer for the official native Linux Tailscale client on immutable
SteamOS. Steam Frame uses ARM64; Steam Deck uses x86-64. The installer keeps the
root filesystem locked and runs the normal system-wide Tailscale service.

## Install on Steam Frame

Enable Developer Mode and set a user password in the headset settings. Connect
from a PC using your paired Devkit SSH key, or open a terminal on the headset.
Run these commands **on the Frame**, as `steamos`:

```bash
git clone https://github.com/brianytang/deck-tailscale.git ~/deck-tailscale
sudo bash ~/deck-tailscale/tailscale.sh
source /etc/profile.d/tailscale.sh
sudo /home/.tailscale-bin/current/tailscale up --operator=steamos
```

Open the printed login URL on any device and sign in to your Tailscale account.
Installing the service does not authenticate the headset. Install Tailscale on
any PC/server you want to reach and join the same tailnet.

On Steam Deck, use the same installation commands and `--operator=deck` for login.
Tailscale SSH is optional: the existing OpenSSH server works over the Tailscale IP.
The installer does not enable SSH, routing, exit nodes, or automatic client updates.

Requirements: internet, sudo, Bash, systemd, kernel TUN support, `curl`, `jq`,
`tar`, `sha256sum`, `flock`, and standard coreutils. The expected `/home`, `/var`,
and `/etc` directories must be writable where files are installed, root-owned,
and not writable by other users. Symlinked ancestors/configuration are refused.

## Verify

```bash
systemctl is-active tailscaled
systemctl is-enabled tailscaled
tailscale status
tailscale ip -4
tailscale status --json | jq '{BackendState, Health}'
tailscale ping YOUR_OTHER_DEVICE
journalctl -u tailscaled -n 60 --no-pager
```

After browser login, expect `active`, `enabled`, `BackendState: Running`, and no
health warnings. Check that a Tailscale peer can reach the Frame and that the
Frame can reach the intended service. `tailscale ping` shows whether the link is
direct or relayed. Installation alone does not establish app compatibility or
acceptable VR streaming latency.

## Update

Use a local terminal or local-network SSH; restarting the daemon disconnects
sessions carried by Tailscale.

```bash
cd ~/deck-tailscale
git pull --ff-only
sudo bash tailscale.sh
```

The installer downloads the latest stable native archive, verifies its SHA-256
sidecar, extracts only the expected files, and checks both executable versions
before stopping the old service. It then publishes the binary pair together. If
configuration, enablement, or startup fails, it restores the prior selector,
managed configuration, and previous active/enabled service state. Rollback
failures are reported. A lock prevents concurrent install/uninstall operations.
Older successful releases remain available under `/home/.tailscale-bin/releases`.
Existing defaults, login identity, and other systemd drop-ins are preserved.

Use this installer for updates. Built-in `tailscale update` would modify a selected
release in place, bypassing this transaction, and Tailscale's automatic updater
cannot discover the CLI at our custom location. Do not enable automatic updates
for this installation.

## Uninstall

```bash
sudo bash ~/deck-tailscale/uninstall.sh
```

This removes only an installation bearing this fork's ownership marker. It stops
and disables the service, removes our binaries and generated files, and keeps
`/var/lib/tailscale` and custom systemd drop-ins. A defaults file that predated our
installation is retained. Reinstalling can reuse the device identity. The device
entry in the Tailscale admin console is not deleted. Repeated uninstall is safe.

## Existing installations

An unmanaged unit (including a package/vendor unit), a legacy `override.conf`, or
unmanaged profile/keep fragment causes installation to stop with an explanation.
The installer does not remove another installation or unmerge system extensions.
Before migrating, inspect and back up its configuration, stop it through its own
installer, and remove the conflicting managed configuration. Preserve the device
state in `/var/lib/tailscale` if you want to keep the same identity. Never run an
uninstaller blindly against a different installation.

## Layout and firewall

| Component | Location |
| --- | --- |
| Root-controlled binaries and release selector | `/home/.tailscale-bin` |
| Private daemon state | `/var/lib/tailscale` (0700) |
| Runtime socket | `/run/tailscale/tailscaled.sock` |
| Official unit plus our executable override | `/etc/systemd/system/tailscaled.service`, `tailscaled.service.d/10-steamos.conf` |
| Preserved daemon settings | `/etc/default/tailscaled` |
| CLI PATH | `/etc/profile.d/tailscale.sh` |
| SteamOS retention fragment | `/etc/atomic-update.conf.d/tailscale.conf` |

Frame defaults to `TS_DEBUG_FIREWALL_MODE=nftables`, informed by the comparison
fork's observed legacy iptables failure and working nftables fix. Deck defaults
to `auto`. An explicit value in `/etc/default/tailscaled` overrides the fallback.
Look for `router: ... using nftables` in the journal after login. This Tailscale
knob is documented as temporary; revisit it when upgrading the client. It keeps
Tailscale firewall management enabled and does not flush existing rules.

The retention fragment names our unit, override, enablement, defaults, profile,
and itself. Hardware inspection confirms that the current Frame's SteamOS keep
list supports these entries. Actual reboot and OS-update survival are separate
validation steps; an update may still require rerunning the installer.

## Validation and design decision

See [the decision record](docs/steam-frame-decision.md) for the independent
proposal, comparison/debate, hardware findings, exact revisions, and validation
limits. Offline tests run scripts as an ordinary user against confined temporary
filesystem copies with mocked network/systemd/ownership and real archives,
checksums, and file operations:

```bash
bash tests/test-install.sh
```

These tests do not prove real hardware connectivity, reboot behavior, or SteamOS
upgrade survival. The original upstream is
[tailscale-dev/deck-tailscale](https://github.com/tailscale-dev/deck-tailscale).
