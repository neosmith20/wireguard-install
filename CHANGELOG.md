# Changelog

Notable changes to the WireGuard + UFW installer. These are **script revision milestones**; they do not imply that corresponding GitHub Releases or tags have been published. The current main-branch script identifies itself as **v8.1**, a multi-distribution review candidate.

## 8.1 — ShellCheck 0.9.0 compatibility

### Fixed
- Rewrote four `A && B || :` lines as `if` statements so ShellCheck 0.9.0 (Ubuntu 24.04, used by the GitHub Actions check) passes. Newer ShellCheck releases no longer flag this pattern.

**No behavior change.**

## Documentation update (after v8.0)

### Changed
- Updated the README for v8: the install command now makes the script executable (`chmod +x`), and the prompts, client file location, per-client LAN access, server access, automatic SSH/firewalld/IPv6 handling, uninstall behavior and testing status match the v8 script.

**Documentation only. No changes to the installer script.**

## 8.0 — Simpler prompts, per-client LAN access, MTU finder

### Changed
- Prompts now work like [angristan/wireguard-install](https://github.com/angristan/wireguard-install): questions come first in the same order and wording, with pre-filled defaults you can accept with Enter or edit, and invalid answers ask again instead of quitting.
- Yes/no questions take `y` or `n`; removed the typed `PACKAGES`, `INSTALL`, `ENABLE`, `CHANGE`, `REPLACE`, `ENABLE-IPV6`, `REVOKE` and `UNINSTALL` confirmations.
- Packages install automatically after "Press any key to continue".
- The SSH port is detected and allowed automatically before UFW is enabled (no SSH question).
- firewalld replacement, an already-active UFW with a permissive routed default, and enabling UFW IPv6 filtering are handled automatically with a printed warning.
- The random VPN subnet is offered as the pre-filled "Server WireGuard IPv4" answer (`10.x.y.1`).
- VPN clients can reach services on the VPN server (no server-access question).
- Client configs are saved next to the script as `<interface>-client-<name>.conf` (falls back to the sudo user's home or `/root` when piped).
- Revoke a client by picking its number; uninstall asks a single `[y/n]`.
- Uninstall restores UFW's original IPv6 setting automatically if the installer changed it.

### Added
- Per-client LAN access: LAN is blocked by default and chosen with a `[y/n]` when each client is added. LAN-allowed clients still can't reach other VPN clients.
- LAN-allowed split-tunnel clients get the server's LAN networks added to their `AllowedIPs` automatically.
- Menu option **4) Find the best MTU (wire-seek)**: runs [yeya/wire-seek](https://github.com/yeya/wire-seek), pinned to v0.4.0 with built-in SHA-256 checksums (amd64 and arm64; installs `gcompat` on Alpine). Applies the result to the server and new clients, and can update existing client files. Uninstall moved to option 5 and Exit to 6.

### Compatibility
- Installer state remains schema `4`, so v8 can manage a v7 installation; v7 client files in `/etc/wireguard/clients` are still cleaned up on revoke/uninstall.

### Validation
- Exercised in a disposable Ubuntu 24.04 environment with userspace WireGuard and a test systemd stand-in: re-asking on invalid answers, install, two real clients (with and without LAN access), server access, client isolation, LAN DNS, metadata blocking, revoke by number, wire-seek download/checksum rejection/MTU discovery/apply, uninstall cleanup, rollback, and an already-active UFW.

## Documentation update (after v7.0)

### Changed
- Rewrote the README to describe the actual v7 prompts, paths, firewall policy, client behavior, supported-platform targets, and uninstall semantics.
- Documented the difference between isolated IPv4 testing and still-unverified native kernel/systemd, IPv6, multi-distribution package, and firewalld integration tests.
- Clarified why earlier installations must be removed with their matching installer version.
- Replaced historical descriptions of default routed-ALLOW policy, files under `/root`, and an obsolete `/etc/wireguard/params` state file.

**Documentation only. No changes to the installer script.**

## 7.0 — Tagged NAT cleanup

### Fixed
- Tagged IPv4 and IPv6 UFW NAT masquerade rules with installer-specific iptables comments.
- Changed live NAT validation and cleanup to match only installer-owned tagged rules, preserving otherwise identical administrator rules.
- Avoided adding an unnecessary blank line before an appended UFW NAT section and restored existing NAT files byte-for-byte in the tested layouts.
- Kept live cleanup compatible with repeated UFW reloads that create duplicate tagged NAT entries.

### Compatibility
- Installer state format remains schema `4`, but v7's cleanup **cannot identify untagged NAT rules** created by v6.1 or older. Use the original installer version when uninstalling an earlier installation.

## 6.1 — IPv4 connectivity and cleanup

### Fixed
- Added DNS resolver `/32` routes to generated split-tunnel clients when resolvers were outside their existing `AllowedIPs`; avoids explicitly routing an endpoint IP into the tunnel.
- Removed remaining live masquerade entries on uninstall and failed-install rollback after UFW reloads.
- Avoided accumulating an extra blank line in common `before.rules` install/uninstall cycles.

### Validation
- Real IPv4 tunnel handshakes, forwarding, DNS behavior, access restrictions, client add/revoke, uninstall, and rollback were exercised in a disposable Ubuntu 24.04 environment using userspace WireGuard and a test systemd stand-in.

## 6.0 — Arch compatibility

### Fixed
- Handled `/etc/os-release` files with no `VERSION_ID` (notably Arch Linux), rather than failing under `set -u`.
- Included Arch's `procps-ng` dependency for `sysctl` on minimal installations.

## 5.0 — Installation robustness

### Fixed
- Checked for matching kernel headers when falling back to legacy WireGuard/DKMS installation on older Debian/Ubuntu kernels.
- Skipped the private-LAN DNS exception prompt for DNS served directly by the WireGuard host.
- Identified outdated installer state before validating keys introduced in later versions.
- Reworked the firewalld-to-UFW handoff to enable UFW first, then stop firewalld, reload UFW, and verify NAT; rollback attempts to restore firewalld first.
- Tightened variable scoping and removed unsupported version-specific comments.

## 4.0 — IPv6 rule ordering and firewall safeguards

### Fixed
- Used UFW `prepend` rather than inserting IPv6 rules at a potentially invalid numbered position.
- Improved saved-state validation, cleanup safeguards, and explicit confirmations when enabling host-wide UFW IPv6 filtering.
- Added more explicit choices for access to host services and restricted private DNS.

## 3.0 — Multi-distribution candidate

### Added
- Package-manager paths for APT, DNF, Pacman, and APK and OpenRC handling for Alpine.
- Distribution-specific preflights and handling for existing firewalld configurations.
- Sequential client host addresses inside the random first-install subnet.
- Scoped private-network/cloud-metadata blocking and improved rollback handling.

## 2.0 — Initial UFW rewrite

### Added
- First-install randomized, collision-checked `10.x.y.0/24` VPN networks.
- More restrictive UFW forwarding rules, IPv4 NAT, client configuration permissions, and installation safety checks.
- Client add/list/revoke management and QR enrollment.

## 1.0.0 — 2025-01-04 (historical)

- Initial UFW-oriented derivative of [angristan/wireguard-install](https://github.com/angristan/wireguard-install).
- The early implementation's configuration paths, firewall defaults, and cleanup behavior have since changed substantially. Refer to the README for current behavior.

## Known validation gaps

Native kernel WireGuard and real service/reboot persistence, full-tunnel IPv6/NAT66 behavior, active firewalld replacement, and package installations on all targeted distributions require further end-to-end tests. Passing Bash syntax, ShellCheck, or shfmt is not evidence that every platform/network scenario works.

## License and attribution

The installer retains MIT licensing and upstream attribution to [angristan/wireguard-install](https://github.com/angristan/wireguard-install). See [LICENSE](LICENSE) and the source-file notices.
