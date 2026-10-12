# WireGuard VPN Installer — UFW Edition

A Bash installer for a WireGuard VPN server using **UFW (Uncomplicated Firewall)** to manage firewall policy and persistent NAT configuration. It supports interactive setup, client management, a randomized private VPN subnet, and safety checks for existing host firewalls.

> **Project status: v7.0 review candidate.** IPv4 connectivity, client management, firewall isolation, uninstall, and rollback have been exercised in an isolated Ubuntu 24.04 userspace-WireGuard test network. Native kernel WireGuard, real systemd/OpenRC boot persistence, full-tunnel IPv6, firewalld replacement, and package installation across every targeted distribution have **not** all been verified. Test on a disposable VM with console access before using a remote production server.

## Features

- **Random subnet on first install:** chooses a collision-checked `10.x.y.0/24` network, records it, and assigns client IPs sequentially (starting at `.2`).
- **UFW-managed firewall:** default-deny incoming/routed policies on new UFW setups, with explicit WireGuard transit rules.
- **Protected destinations:** blocks VPN forwarding to `169.254.0.0/16` (including common cloud metadata addresses); private LAN and host-service access are denied by default, with explicit options.
- **DNS handling:** accepts two IPv4 resolvers, can allow narrow TCP/UDP 53 exceptions for private resolvers, and adds required DNS host routes to split-tunnel client configs (without routing a matching endpoint IP into itself).
- **IPv6 choices:** optional IPv6 egress using NAT66 on suitable hosts; for IPv4 full tunnels without IPv6 egress, attempts to route client IPv6 into the tunnel and block it. IPv6 behavior still needs native end-to-end testing.
- **Client lifecycle:** add, list, and revoke peers; generate QR codes when `qrencode` is installed; synchronize peers without intentionally disrupting other clients.
- **Safer changes:** SSH-port protection before activating previously inactive UFW, explicit confirmations, firewall snapshots and attempted rollback on installation failure.
- **Tagged NAT:** installer-owned masquerade rules are identified by comments, so cleanup can preserve an otherwise identical administrator-created rule.

UFW owns the firewall configuration, but the script **does use `iptables`/`ip6tables`** to check and remove its *tagged live NAT entries*. It does not add WireGuard `PostUp`/`PostDown` firewall commands.

## Targeted Linux distributions

| Distribution | Targeted versions | Notes |
| --- | --- | --- |
| Ubuntu | 18.04 or newer | Older kernels may need matching headers/DKMS support; retired releases need maintained or archived repos |
| Debian | 10 or newer | Debian 10 requires administrator-configured archived Buster backports and compatible kernel support |
| Fedora | 32 or newer | Uses DNF |
| AlmaLinux | 8 or newer | UFW may require EPEL; kernel module availability varies |
| Rocky Linux | 8 or newer | UFW may require EPEL; kernel module availability varies |
| CentOS Stream | 8 or newer | Retired versions require working repos; UFW may require EPEL |
| Oracle Linux | 8 or newer | EPEL availability and kernel module depend on the host |
| Arch Linux | Rolling release | Requires a supported kernel; uses Pacman and systemd |
| Alpine Linux | Supported releases with required packages | Install Bash first; requires `wireguard-tools-openrc`/`ufw-openrc` and OpenRC |

**Targeted does not mean tested on every version.** The script checks for a usable WireGuard kernel driver and permission to create an interface before editing firewall configuration. Containers without the necessary kernel support or privileges will fail that preflight. It does not automatically repair end-of-life package repositories or install third-party kernel module repositories.

## Before you install

- Use a **disposable VM or host with out-of-band/console access** for the first live test. Back up existing UFW and network settings.
- You need root privileges, suitable package repositories, a working WireGuard kernel driver, and a network interface with IPv4 connectivity.
- Ensure the selected UDP listening port is reachable externally, including router port forwarding or cloud-provider firewall rules as applicable.
- Review SSH ports carefully. The installer detects an existing SSH connection or `sshd` configuration where possible and asks which TCP port(s) to protect.
- If **firewalld** is active, the installer displays existing zones/services/ports, requires an explicit replacement confirmation, enables UFW first, and then disables firewalld. **It does not automatically migrate other allowed services.** Prepare equivalent UFW allowances before switching.
- The installer refuses to proceed while a separately managed `nftables` service is active.
- Activating UFW or enabling IPv6 filtering can affect unrelated host services. The installer asks for confirmation but cannot guarantee against remote lockout.

## Install

Download and **review** the script before running it:

```bash
wget https://raw.githubusercontent.com/neosmith20/wireguard-install/main/wireguard-install-ufw.sh
less wireguard-install-ufw.sh
sudo bash wireguard-install-ufw.sh
```

The installer prompts for the outgoing interface, public endpoint address/hostname, WireGuard interface (default `wg0`), UDP port, first-run `10.x.y.0/24` subnet, two IPv4 DNS resolvers, client `AllowedIPs`, LAN and server-service access, IPv6 mode, and SSH protection.

Default client IPv4 `AllowedIPs` is `0.0.0.0/0` (full tunnel). For a split tunnel, enter the intended IPv4 CIDRs instead. Private-LAN forwarding is blocked unless explicitly enabled; permitting LAN access also requires valid routes and a return path outside the installer.

### IPv6 behavior

- **IPv6 egress available and enabled:** configures ULA client addresses and IPv6 NAT66.
- **Full-tunnel IPv4 without enabled IPv6 egress:** configures an IPv6 tunnel route and UFW block mode to avoid intentionally leaving IPv6 outside the VPN. The host must have IPv6 kernel support even if it has no public IPv6 route.
- **Split-tunnel IPv4 without enabled IPv6 egress:** leaves client IPv6 to the client's normal network.

The IPv6 paths have not received the same live end-to-end coverage as the IPv4 split-tunnel path. Do not assume IPv6 leak protection is verified on every client OS.

## Client configuration and management

After installation, the script offers to create the first client. Run the same script again for the management menu:

```bash
sudo bash wireguard-install-ufw.sh
```

| Option | Action |
| --- | --- |
| 1 | Add client |
| 2 | List clients |
| 3 | Revoke client (requires typing `REVOKE`) |
| 4 | Uninstall this managed WireGuard server (requires typing `UNINSTALL`) |
| 5 | Exit |

- **Server config:** `/etc/wireguard/<interface>.conf` (e.g. `/etc/wireguard/wg0.conf`)
- **Client configs:** `/etc/wireguard/clients/<name>.conf`
- **Installer state:** `/etc/wireguard/ufw-installer.state`
- **Managed forwarding config:** `/etc/sysctl.d/99-z-wg-ufw-installer.conf`
- **UFW NAT files:** `/etc/ufw/before.rules` and, if IPv6 NAT66 is enabled, `/etc/ufw/before6.rules`

Installer-created client files contain **private keys and preshared keys** and are kept root-readable only. Treat QR codes as sensitive secrets as well. Securely transfer the config to the device; import it using a WireGuard-compatible client.

## Firewall behavior

On a newly enabled UFW installation, the installer sets **deny incoming**, **allow outgoing**, and **deny routed**, then applies scoped exceptions. On an already-active UFW installation, it preserves the existing incoming/outgoing defaults but may change an overly permissive routed default **after confirmation**.

Typical installer-managed policy:

- Allow the chosen WireGuard UDP listening port on the selected public interface.
- Allow WireGuard-client forwarding through the specified outbound interface.
- Deny routed traffic toward the cloud metadata/link-local IPv4 range.
- Deny private IPv4 ranges (RFC1918 and CGNAT) unless LAN access is enabled; optionally permit selected private DNS resolvers on TCP/UDP 53 only.
- Deny access from VPN clients to server-hosted services by default; optionally allow all host services or only configured host DNS (TCP/UDP 53).
- Apply IPv6 forwarding, NAT66, or block rules according to the selected IPv6 mode.

IPv4 NAT is stored in UFW's `before.rules`, tagged with an installer-specific comment. Because UFW reloads can duplicate live NAT entries, v7 removes **only its own tagged entries** on uninstall/rollback.

## Uninstall and existing installations

Use menu option **4** to stop the managed WireGuard service and remove its tracked peers, UFW rules, tagged NAT entries, configuration, and persistent forwarding file.

Uninstall **does not** automatically uninstall shared OS packages, disable UFW, remove SSH safety rules, restore firewalld, or reset all global firewall/forwarding policies; these may be used by other services. Review them yourself afterward. If the installer changed UFW's global IPv6 setting, restoring the earlier setting is offered separately with a warning.

**Version compatibility:** v7 still uses installer state schema `4`, but v7's tagged NAT cleanup does **not** recognize the untagged NAT entries written by v6.1 and earlier. If you installed with v6.1 or an earlier revision, **uninstall with that same version first**, rather than assuming v7 will fully clean it up. v3 state is not automatically migrated.

## Troubleshooting

Inspect the service, WireGuard handshake, firewall, and selected route:

```bash
sudo wg show
sudo ufw status verbose
ip -4 route
sysctl net.ipv4.ip_forward
sudo systemctl status wg-quick@wg0   # systemd distributions; replace wg0 if needed
sudo journalctl -u wg-quick@wg0 -b --no-pager
```

On Alpine/OpenRC, inspect `rc-service wg-quick.wg0 status` instead of `systemctl`.

For clients with a handshake but no internet, check UDP reachability, configured `AllowedIPs`, DNS resolution, UFW forwarding rules, tagged NAT entries, and external provider/router firewall rules. When private LAN access is enabled, confirm a working route and return path. For full-tunnel IPv6, check the selected IPv6 mode and test traffic rather than assuming support.

If an installation fails, inspect the rollback output before disconnecting. The installer may retain recovery snapshots under `/root/.wgufw-install-backup.*` if rollback is incomplete.

## Testing status

| Area | Status |
| --- | --- |
| ShellCheck, shfmt, Bash syntax | Reported clean for v7 during independent review |
| IPv4 test tunnel, client handshake and NAT | Tested in disposable Ubuntu 24.04 environment with **userspace WireGuard** |
| Private-LAN, cloud-metadata, host access and DNS exceptions | Tested in isolated network |
| Client creation, revocation, uninstall and rollback | Tested in isolated network |
| Native WireGuard kernel + real systemd services/reboot | **Not yet verified end to end** |
| IPv6 full tunnel / NAT66 / leak-blocking | **Not yet verified end to end** |
| Active firewalld replacement and package installs on other distros | **Not yet verified end to end** |

The isolated test environment used test-only substitutions for the missing kernel WireGuard driver and systemd service. **Those substitutions are not part of the published installer.**

## License and acknowledgments

MIT licensed; see [LICENSE](LICENSE) and the copyright notices retained in the installer. This project is derived from and inspired by [angristan/wireguard-install](https://github.com/angristan/wireguard-install).

Issues and proposed improvements are welcome through this repository's [Issues](https://github.com/neosmith20/wireguard-install/issues) page. Please include the distribution/version, WireGuard mode, UFW status, a redacted log, and exact steps to reproduce. **Never post private keys, preshared keys, or complete client configs.**
