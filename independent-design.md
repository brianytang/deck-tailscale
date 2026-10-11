# Independent Steam Frame installer proposal

Prepared 2026-10-11, before inspecting any comparative implementation. Research was confined to Valve documentation, Tailscale documentation/source, the requested upstream repository, and systemd documentation. No device or remote repository was modified.

## Verified facts

Valve identifies Frame as native ARM64 SteamOS, based on Arch Linux. Windows/x86 support is through compatibility layers, so a daemon should use the native Linux ARM64 build. [Valve compatibility documentation](https://partner.steamgames.com/doc/steamhardware/steamframe/compatibility)

Developer Mode enables SSH, ADB, and RDP; Valve documents the default Linux user as `steamos`. The OS filesystem is read-only by default, and Valve cautions that most OS changes are overwritten by updates. [Setup](https://partner.steamgames.com/doc/steamhardware/steamframe/setup), [Debugging](https://partner.steamgames.com/doc/steamhardware/steamframe/debugging?l=english)

Upstream `deck-tailscale` main was `4691bb20d492ae9b2f5121c3eaf6e2dc1950e73f` during research. Its installer selects `.Tarballs.amd64`, puts executables in `/opt/tailscale`, installs a packaged unit plus an executable-path override, creates defaults and profile files, and records those latter files in a SteamOS keep fragment. It resolves `override.conf` from the invoking working directory. It stops/disables an existing daemon before replacing files and treats several service failures as warnings. The uninstaller removes only one binary and leaves its daemon, override directory, and state behind. These are useful adaptation targets, not a reliability contract. [Installer](https://github.com/tailscale-dev/deck-tailscale/blob/4691bb20d492ae9b2f5121c3eaf6e2dc1950e73f/tailscale.sh), [Uninstaller](https://github.com/tailscale-dev/deck-tailscale/blob/4691bb20d492ae9b2f5121c3eaf6e2dc1950e73f/uninstall.sh), [Override](https://github.com/tailscale-dev/deck-tailscale/blob/4691bb20d492ae9b2f5121c3eaf6e2dc1950e73f/override.conf)

Tailscale officially supplies Linux static archives with adjacent `tailscale`, `tailscaled`, defaults, and systemd unit files. ARM64 was available as `tailscale_1.104.1_arm64.tgz`; the package server documents `.sha256` sidecars. [Linux installation](https://tailscale.com/docs/install/linux), [Stable packages](https://pkgs.tailscale.com/stable/)

The packaged unit uses root, `Type=notify`, restart on failure, a runtime socket directory, and state directory mode `0700`. [Tailscale service source](https://github.com/tailscale/tailscale/blob/v1.104.1/cmd/tailscaled/tailscaled.service)

Valve documents additional `/etc` migration whitelist entries through `/etc/atomic-update.conf.d/` and retained updater backups under `/var/lib/steamos-atomupd/`. [Valve SteamOS release notes](https://store.steampowered.com/news/posts/?enddate=1715301479&feed=steam_community_announcements). An upstream maintainer described SteamOS persistence as overlays of `/var` and `/etc`. This is firsthand Deck evidence, not an official Frame guarantee. [Upstream issue 9](https://github.com/tailscale-dev/deck-tailscale/issues/9)

## Locked proposal

Use one root system service named `tailscaled.service` with native kernel networking. Install root-owned executable copies in versioned release directories under `/var/lib/tailscale-bin/` (`0755`), atomically select the complete pair with a root-controlled `current` symlink, keep keys and daemon state separately in `/var/lib/tailscale/` (`0700`), and put the socket under `/run/tailscale/`. This avoids changing the immutable root image and retains normal OS-level networking for Steam applications. Use no container, userspace proxy, system extension, package manager, or broad filesystem unlock.

`/var/lib/tailscale-bin` is the default because it matches the standard persistent system-state hierarchy and avoids a user-controlled executable parent. Its survival across Frame updates remains an inference that must be checked on hardware. An explicitly selected root-owned `/home/.tailscale` can be a fallback if Frame demonstrates that `/home` is persistent and `/var` is unsuitable. Do not silently choose `/home/steamos/...`: even a root-owned child can be replaced by its parent directory's owner. Resolve real paths and validate every ancestor's owner and write permissions, including mount/symlink targets. Never relax ownership of `/home` to accommodate installation.

Copy the official service from the verified release archive, then generate an installer-owned override that resets every executable directive before pointing it at the safe `current` path. Retain `Type=notify`, `Restart=on-failure`, runtime/state/cache directory declarations, and `ExecStopPost=... --cleanup`. Add `RequiresMountsFor=` for executable/state locations. Manage the generated override's filename separately from user overrides. Any bundled source file must be found relative to `${BASH_SOURCE[0]}`, not `$PWD`.

Persist every installer-owned `/etc` file explicitly, using a dedicated fragment: defaults, profile if supplied, service, its installer-owned drop-in if any, its enablement symlink, and the migration fragment itself if the device's documented example permits it. Do not rely on an undocumented default keep list. Do not preserve all of `/etc` or any vendor OS configuration. Read the device's example and updater configuration first; fail with a clear reason if its migration format is unsupported.

Use `TS_DEBUG_FIREWALL_MODE=auto` as an overridable default (the defaults file can override an `Environment=` setting in the service). Preserve any existing explicit user setting. Tailscale's documented auto mode chooses the available backend; it prefers nftables if both are active. Keep netfilter enabled. Do not flush host rules, turn off firewalls, enable routing, advertise routes, enable SSH, or open broad ports during installation. [Firewall mode](https://tailscale.com/docs/features/firewall-mode)

Normally Tailscale needs no manually opened ports. Troubleshoot with `tailscale netcheck`, `tailscale ping`, status, and daemon logs before changing host policy. UDP direct connectivity matters to streaming latency; DERP connectivity alone is not proof of suitable streaming performance. [Firewall ports](https://tailscale.com/docs/reference/faq/firewall-ports)

## Installation/update transaction

1. Validate Linux, native `aarch64`/`arm64`, SteamOS, systemd, required tools, target directories and parents, tun support, and the device's migration mechanism. An unsupported architecture or ambiguous existing install should stop before destructive actions. Inspect `findmnt` for writable/executable target mounts, and ensure storage is not temporary. A writable probe alone does not prove update persistence.
2. Require root explicitly (`sudo bash /absolute/path/tailscale.sh`) or re-execute through ordinary interactive `sudo` while preserving arguments. Never accept, store, pipe, or log a password; do not add sudoers entries or preserve arbitrary caller environment. Derive an optional operator from a validated `SUDO_USER` or explicit argument; do not hardcode `deck`.
3. Download stable metadata with HTTP failure checking. Select exactly `.Tarballs.arm64`; validate the resulting basename against a strict expected archive pattern. Permit an explicit validated version if needed. Use only the fixed Tailscale HTTPS origin.
4. Download and verify the sidecar SHA-256. This catches corruption; a checksum from the same HTTPS origin is not a separate signature trust system. Extract into a private staging directory with an EXIT cleanup trap, validate expected archive paths, reject links/path traversal, and confirm both staged binaries run and report the requested version before touching the running daemon. Avoid root execution of user-modifiable staged paths.
5. Preserve defaults and independent user drop-ins. Refuse to overwrite an unrelated package installation or unit unless a deliberate migration mode was selected. Do not unmerge unrelated system extensions. Maintain an installer ownership marker or manifest, so update/uninstall can distinguish owned files.
6. Stage executable and configuration replacements, back up the previous installer-owned versions, stop the daemon only after all validation succeeds, and atomically rename files within their destination filesystem. Use a versioned directory plus one root-controlled current symlink for installer-controlled updates. On rollback, restore that single selector as well as the prior owned service/config files.
7. Run `systemctl daemon-reload`, enable/start or restart, and check active state and CLI/daemon version consistency. A service failure must return a nonzero result, restore prior installer-owned files, reload, and attempt to restore the previous running state. Do not print installation success after swallowing a restart failure. Authentication is a separate user step after daemon health is established.

The full transaction with rollback avoids upstream's early disable-and-overwrite behavior. A `flock` prevents two copies of the installer from interleaving.

## Update semantics

Recommend rerunning the installer as the primary update path, which refreshes both binaries and installer-managed service/configuration. Retain state and existing user preferences.

Tailscale's manual updater can work as root for a fixed adjacent-binary static install: release source selects tarball updates when `pacman --query tailscale` reports absent, finds adjacent executables, stages `.new` files, and restarts `tailscaled.service`. The proposed versioned-release/current-selector architecture should direct users to the installer instead: the built-in updater would mutate a release directory in place and bypass its manifest, version naming, and rollback transaction. [Release updater source](https://github.com/tailscale/tailscale/blob/v1.104.1/clientupdate/clientupdate.go)

Do **not** promise built-in automatic updates. In release `v1.104.1`, `findCmdTailscale()` only recognizes certain `/usr` and `/usr/local` executable paths on ordinary Linux. It does not recognize `/opt/tailscale`, `/var/lib/tailscale-bin`, or `/home/.tailscale`, and it intentionally ignores PATH. The daemon's auto-update path therefore cannot locate this proposed CLI. [Release daemon updater source](https://github.com/tailscale/tailscale/blob/v1.104.1/feature/clientupdate/clientupdate.go)

Do not enable auto-update or add a timer by default. If a timer is later requested, use a dedicated root-owned updater that shares installation locking and checks ownership; preserve that timer and its enablement in the keep list. Update from a local/LAN SSH or ADB session because restarting tailscaled drops its own transport.

## Uninstallation

Stop and disable the owned service; let its cleanup command remove Tailscale-owned runtime networking. Remove all installer-owned unit/drop-in/profile/default/migration files and both executables, then reload systemd and reset failed state. Never remove unrelated user overrides, packages, or extensions. Preserve `/var/lib/tailscale` by default so reinstallation retains identity. Offer an explicit purge option for keys/preferences/Taildrop state, with concrete scope. Uninstall is not removal from the tailnet admin console; explain the separate device-delete step if complete account removal is desired.

## Required validation and uncertainties

No Steam Frame was available and no device commands were run. Before claiming production compatibility, verify:

- `/var` backing store and mount semantics across reboot and an actual A/B OS update, plus migration of the unit, defaults, fragment, enablement, and state.
- Root ownership and immutability of every executable path ancestor, including the resolved fallback path.
- Required utilities, `/dev/net/tun`, systemd version, service notification support, and the Frame firewall backend/host rules.
- Daemon boot startup in Steam's game session, suspend/resume, network changes, and reconnect behavior.
- QR/browser authentication and operator permissions for `steamos` without enabling SSH automatically.
- Direct connectivity and realistic streaming latency; an authenticated tailnet node alone proves neither Frame remote-play integration nor low-latency VR streaming.
- Failure handling with invalid metadata/archive/checksum, missing dependencies, failed downloads, failed daemon startup, reruns, concurrent runs, update rollback, and state-preserving uninstall/reinstall.

The research supports a native ARM64 installer proposal. It does not establish on-device persistence or Steam Frame streaming integration without the above hardware evidence.
