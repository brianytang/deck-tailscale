# Steam Frame implementation decision

2026-10-11. Upstream: `tailscale-dev/deck-tailscale` at
`4691bb20d492ae9b2f5121c3eaf6e2dc1950e73f`. Comparison:
`sherbondy/frame-tailscale` at `f44997ee3120edd1035a47dde870aeaf927292be`.
Our independent prototype was committed as `7971f2a` before the comparison.
[The independent proposal](../independent-design.md) records that original design;
[the comparison memo](comparison-review.md) records the reviewers' initial debate.

## Debate and result

| Question | Independent proposal | Comparison evidence | Agreed result |
| --- | --- | --- | --- |
| Native build | Detect ARM64 / amd64 | Frame fork detects ARM64 | Official native stable archive |
| Binary location | Root-owned `/var/lib/tailscale-bin` | `/home/steamos/tailscale` tested writable, but its user-owned parent permits replacing root-executed code | Root-owned `/home/.tailscale-bin`, after inspecting actual storage |
| Firewall | Overridable `auto` | Reported Frame iptables failure fixed by explicit nftables | Frame `nftables`; Deck `auto`; defaults override |
| Update | Stage, verify, switch binary pair | Comparison stops before extraction and replaces binaries individually | Verified staging and atomic selector, plus configuration/service rollback |
| Settings and identity | Preserve defaults/state | Same useful behavior in comparison | Preserve both, including on failure |
| SteamOS retention | Explicit owned files | Comparison lists defaults/profile only; neither tested OS upgrades | Explicit unit/override/wants/defaults/profile/fragment entries |
| Uninstall | Preserve identity | Comparison preserves identity, removes fixed paths | Require ownership marker; preserve identity, custom drop-ins, preexisting defaults |
| Automatic updates | No promise at custom path | Upstream suggested auto-update | Installer-driven updates; no automatic updater claim |

The reviewers initially favored `/var` to protect the privileged executable
directory. Actual headset inspection then showed that this would waste a small
system partition. The final location combines the comparison fork's practical
home-partition choice with a root-controlled ancestor. It does not change the
ownership of `/home/steamos`.

Review also rejected the independent prototype's initial incomplete transaction:
an atomic binary selector alone did not restore overwritten configuration or a
previously running service. The final transaction snapshots those files and the
old selector/service state, stops through the old loaded unit, then publishes.
Failure restores the previous installation and explicitly reports incomplete
recovery. Staged executable probes happen before service downtime.

## Observed headset facts

Read-only SSH inspection through the existing paired SteamOS Devkit key:

- SteamOS `0.4.5`, build `20261007.6125817`, variant `vr`, kernel architecture
  `aarch64`, normal account `steamos`.
- `/var`: ext4 `/dev/sda7`, writable, 224 MiB total, 197 MiB available.
- `/home`: ext4 `/dev/sda8`, writable, 929 GiB total, 822 GiB available;
  root-owned mode `0755`.
- `/etc`: writable overlay, upper/work directories on `/var/lib/overlays/etc`.
- TUN character device, running systemd, `jq`, and `flock` present.
- `tailscaled` unit absent. Interactive sudo authentication required.
- Installed `/usr/lib/rauc/atomic-update-keep.conf` explicitly preserves
  additional keep fragments, systemd units, drop-ins, and enablement directories.

Official Tailscale stable metadata identified `1.104.1`. Both downloaded ARM64
and amd64 archives matched their published SHA-256 sidecars. The ARM64 client
pair is 72,434,436 bytes before filesystem overhead; several retained releases
would exhaust `/var`. This is the reason for revising the independent location.

## Validation boundaries

Offline tests exercise native archive selection, checksum/download/extraction
failures, wrong executable versions, state/config preservation, ownership and
symlink guards, update rollback across active/enabled states, service failures,
and repeated uninstall. Network, systemd, and root ownership are modeled;
filesystem operations and hashing run for real in a confined temporary tree.

All 11 groups covering 35 fixture scenarios passed on the final implementation.
Bash syntax checks and ShellCheck 0.11 passed without diagnostics. The official
systemd unit plus our executable override passed `systemd-analyze verify` in a
native temporary directory with the verified executable paths substituted.

Hardware preflight confirms prerequisites. Both official `1.104.1` ARM64
executables ran successfully on this headset and reported the expected version;
the amd64 pair also passed version probes in Ubuntu. Root installation, tailnet
authentication/connectivity, reboot, and
actual SteamOS A/B update survival must be recorded separately as they occur.
The comparison fork's reported `1.102.4` connectivity is useful evidence, not a
test of this fork or this headset.

## Sources

- [Valve Frame setup](https://partner.steamgames.com/doc/steamhardware/steamframe/setup)
- [Valve Frame debugging](https://partner.steamgames.com/doc/steamhardware/steamframe/debugging)
- [Official static clients](https://tailscale.com/docs/install/static)
- [Official stable packages](https://pkgs.tailscale.com/stable/)
- [Firewall mode](https://tailscale.com/docs/features/firewall-mode)
- [Comparison README at reviewed revision](https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/readme.md)
