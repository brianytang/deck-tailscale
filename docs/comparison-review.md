# Comparison review, 2026-10-11

Independent prototype: `7971f2a`, reviewed before any post-comparison fixes. Competitor: `sherbondy/frame-tailscale` at `f44997ee3120edd1035a47dde870aeaf927292be`. No Steam Frame was available to this reviewer.

## Strongest argument for frame-tailscale

It has the only device evidence in this comparison: its README reports Steam Frame installation, uninstallation, reinstallation, systemd enablement, browser authentication, tailnet connectivity and macOS visibility with Tailscale 1.102.4. It also records a concrete post-login legacy iptables/filter-table failure and a working nftables selection. Its small adaptation preserves the familiar official daemon/service setup, chooses ARM64 at runtime, locates the override relative to the script, requires the home mount, keeps the existing defaults, checks active state after startup, and preserves identity on uninstall. These are useful, substantive improvements over deck-tailscale.

This is stronger evidence of immediate Frame operation than a paper design or mocked installer tests. The fixed `/home/steamos/tailscale` path is demonstrably writable on that test device. However, its README explicitly says reboot and OS-upgrade behavior were not tested; `/home` persistence through a Frame A/B update is therefore not established by those tests.

Source: https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/readme.md

## Where the competitor is weaker

1. **Privileged executable location (high priority).** The service invokes `/home/steamos/tailscale/tailscaled` as root. Even if `install` creates root-owned files and `mkdir` creates a root-owned child, the normal account owns `/home/steamos`. That account can rename the `tailscale` entry and replace it with its own directory/binary. A subsequent start, restart, or cleanup runs its replacement as root. Root ownership of the child does not secure a user-owned parent. Existing directories/symlinks are also accepted without checks. Use a root-controlled ancestor chain, such as verified `/var/lib/tailscale-bin` or root-owned `/home/.tailscale`, without changing ownership of the user's home.
   - Installer: https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/tailscale.sh#L67-L72
   - Override: https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/override.conf#L7-L12
2. **A failed update can destroy a working installation.** It stops/disables the daemon before extraction and file validation, replaces the two binaries separately in place, overwrites configuration, then restarts. It has no rollback. A bad archive, storage failure or startup failure leaves the old service stopped or a partly replaced installation. Download finishes before stopping, which is better than stopping before any network request, but archive validation still comes too late.
   - https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/tailscale.sh#L41-L79
3. **Incomplete update migration.** The keep fragment names only defaults and profile. It does not explicitly name the service, its drop-in, enablement link or the fragment itself. They might survive by an OS default whitelist; the script neither proves nor checks that. No actual reboot or OS update test exists.
   - https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/tailscale.sh#L86-L91
4. **Downloads lack strict integrity/input validation.** Metadata is read with `jq -er`, but the selected basename is not restricted to the expected archive pattern. There is no SHA-256 sidecar verification, no binary version/architecture execution check, and all archive entries are unpacked. The fixed HTTPS origin is a reasonable trust source, but verified expected members and a checksum provide useful failure detection.
   - https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/tailscale.sh#L31-L39
   - https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/tailscale.sh#L62-L65
5. **Ownership/migration semantics are implicit.** Any matching daemon is stopped/disabled, its unit is overwritten, and matching sysext installation triggers unmerge/merge of all extensions. Uninstall removes fixed paths and the override backup regardless of provenance. Both should have an ownership marker and an explicit migration path for earlier installation types.
   - https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/tailscale.sh#L43-L55
   - https://github.com/sherbondy/frame-tailscale/blob/f44997ee3120edd1035a47dde870aeaf927292be/uninstall.sh#L16-L25

## Where the independent prototype is stronger

The prototype chooses native ARM64 (with Deck amd64 support), uses a root-owned `/var/lib/tailscale-bin` hierarchy, rejects symlinked/unprivileged/writable executable ancestors, verifies a strict archive basename and SHA-256, downloads before service interruption, and extracts only the four expected members. Both binaries are staged into one release directory and switched together with an atomic `current` symlink. It separates binaries from `/var/lib/tailscale` state and retains the official service's notification/runtime/state handling. Installer and user drop-ins have different names, and a larger explicit keep list includes the unit, drop-in and enablement. Those are sounder foundations for maintaining the installation.

The SHA-256 is fetched from the same HTTPS origin, so it checks corruption and mismatches rather than adding independent publisher-signature trust. The root-owned path is safer but its Frame update persistence is still an inference. Adding more keep entries does not itself prove the Frame updater accepts/preserves them.

## Must-fix prototype gaps

The design document promises more than commit `7971f2a` implements:

- `tailscale.sh:89-116` publishes unit/drop-in/profile/keep changes before the transaction succeeds. It does not back them up or restore them, nor restore `current`, enablement or prior running state after a restart failure. The old release may remain on disk but that alone is not rollback. Implement one complete transaction and meaningful failed-restart recovery tests.
- No `flock` prevents interleaved updates/uninstall. Add one shared lock.
- No marker/manifest or foreign-unit/package detection protects an existing installation. The installer overwrites a unit at its usual name; the uninstaller deletes it, defaults and binary root by name. Refuse unowned installations unless explicit migration was selected. Remove only owned files.
- The script does not validate `/var/lib/tailscale` and its resolved existing state-file path before starting root code. The official service does declare `StateDirectoryMode=0700`; explicit fail-fast symlink/ownership/mode handling is still needed to match the locked design and avoid surprising adoption of preexisting paths. Add state-path fixtures.
- Platform/systemd/TUN/mount and SteamOS migration-format preflight promised in the design is absent. Validate before any published mutation, and report persistence as unverified until an actual device reboot/update test.
- Staged binaries are not run to verify architecture and version. Add both version probes before service interruption.
- Current selected symlink's target is not validated on reruns, only its type. Resolve it and confirm it stays within a secure owned release directory before cleanup/restart.
- The keep fragment does not name itself and the script does not inspect the device updater's format/example. Preserve the fragment if supported and do not claim upgrade survival before hardware verification.
- The README still contains upstream Deck-only paths, operator `deck`, automatic Tailscale SSH enablement and built-in automatic update instructions, contradicting the proposal. Rewrite around Frame `steamos`, the installed path, installer-driven update and actual test limits.

## Firewall debate and recommendation

For a Frame-focused installer, the competitor's explicit `nftables` default is better grounded than an untested `auto` heuristic because it addresses an observed device failure. It keeps firewall integration enabled and does not require the `nft` executable (Tailscale uses Netlink). Preserve explicit user settings in `/etc/default/tailscaled` and document that this environment knob is temporary. A Deck/generic mode can keep `auto`; alternatively retain auto for Frame but make it a hardware validation item and document targeted `nftables` fallback. Do not say auto has been shown to fix the reported Frame failure.

Tailscale documentation: https://tailscale.com/docs/features/firewall-mode

The preferred maintainable implementation is a small native-systemd adaptation with the competitor's hardware-informed firewall choice and clear user instructions, plus the independent root-controlled binary hierarchy, verified staged pair, explicit persistence files, ownership-aware install/uninstall and full rollback. Neither reviewed commit establishes reboot/OS-upgrade survival. `/var` versus root-owned `/home` should be settled by `findmnt` and actual reboot/A/B update tests on a Frame. The root-executed `/home/steamos` path should not ship simply because it is writable.

Official service source: https://github.com/tailscale/tailscale/blob/v1.104.1/cmd/tailscaled/tailscaled.service
