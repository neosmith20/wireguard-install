# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-01-04

### Added
- **New `disableFirewalld()` function**: Automatically detects and disables firewalld to prevent conflicts with UFW
  - Stops firewalld service
  - Disables firewalld from starting on boot
  - Masks firewalld service to prevent accidental re-enabling
  
- **New `installUfw()` function**: Robust UFW installation with comprehensive error handling
  - Checks if UFW is already installed
  - Installs UFW based on detected Linux distribution
  - Includes EPEL repository setup for RHEL-based systems (CentOS, AlmaLinux, Rocky Linux)
  - Verifies successful installation before proceeding
  - Exits with clear error messages if installation fails

- **Enhanced `applyUfw()` function**: Complete rewrite of firewall configuration
  - Sets proper default policies (deny incoming, allow outgoing, allow routed)
  - Explicitly allows SSH (port 22/tcp) to prevent lockouts
  - Configures UFW forwarding policies in `/etc/default/ufw`
  - Enables IP forwarding for both IPv4 and IPv6 in `/etc/ufw/sysctl.conf`
  - Creates backup of `/etc/ufw/before.rules` before modifications
  - Intelligently adds NAT MASQUERADE rules to `before.rules`
  - Adds routing rules between WireGuard and public interfaces
  - Enables UFW service via systemd (or rc-service for Alpine)
  - Displays UFW status after configuration

- **Better status messages**: Color-coded output for installation steps and warnings

- **Service enablement**: Ensures UFW service starts on boot across all supported distributions

### Changed
- **Removed all iptables commands**: Script now uses UFW exclusively for all firewall operations
- **Removed firewalld branch**: Eliminated the conditional firewalld configuration path entirely
- **Updated installation flow**: 
  1. Checks for and disables firewalld first
  2. Installs UFW if not present
  3. Configures UFW before WireGuard setup
  4. No PostUp/PostDown commands in WireGuard config (UFW handles everything)

- **Improved error handling**: Script now exits gracefully with clear messages if:
  - UFW installation fails
  - Required packages cannot be installed
  - System is unsupported

- **Simplified WireGuard configuration**: Removed PostUp/PostDown iptables commands from `/etc/wireguard/wg0.conf` since UFW manages all firewall rules persistently

- **Enhanced uninstall process**: Restores UFW `before.rules` backup if it exists during uninstallation

### Removed
- **All iptables direct manipulation**: No more raw iptables commands in PostUp/PostDown
- **Firewalld detection and configuration**: Complete removal of firewalld-specific code paths
- **Conditional firewall logic**: Script no longer checks `pgrep firewalld` to decide which firewall to use

### Fixed
- **Firewall conflicts**: Prevents UFW and firewalld from running simultaneously
- **UFW not starting on boot**: Explicitly enables UFW service via systemd
- **Missing UFW on non-Ubuntu systems**: Installs UFW automatically on Debian, Fedora, CentOS, etc.
- **Incomplete NAT configuration**: Ensures MASQUERADE rules are properly added to UFW's before.rules
- **IP forwarding not persisting**: Configures forwarding in both UFW and system sysctl files

### Security
- **SSH protection**: Explicitly allows SSH before enabling UFW to prevent accidental lockouts
- **Maintains pre-shared keys**: Continues using pre-shared keys for all client connections
- **Proper file permissions**: Keeps strict 600 permissions on `/etc/wireguard/` directory

## Differences from Original (angristan/wireguard-install)

This fork is specifically designed for users who prefer or require UFW as their firewall solution. Key philosophical differences:

| Feature | Original (angristan) | This Fork (UFW Edition) |
|---------|---------------------|------------------------|
| **Firewall Support** | iptables, firewalld, or UFW | UFW only |
| **Firewall Selection** | Detects and uses available firewall | Always uses UFW, disables others |
| **Installation** | Assumes firewall is present | Installs UFW if missing |
| **Configuration Method** | PostUp/PostDown in WireGuard config | Persistent UFW rules |
| **Conflict Handling** | May have conflicts if multiple firewalls exist | Automatically resolves conflicts |

## Version History

### [1.0.0] - 2025-01-04
- Initial release of UFW-only edition
- Fork from angristan/wireguard-install
- Complete firewall management overhaul

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for ways to get started.

## Acknowledgments

Original script and concept by [angristan](https://github.com/angristan/wireguard-install)

[1.0.0]: https://github.com/neosmith20/wireguard-install/releases/tag/v1.0.0
