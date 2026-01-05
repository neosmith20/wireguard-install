# WireGuard VPN Installer (UFW Edition)

A secure and automated WireGuard VPN server installer that uses UFW (Uncomplicated Firewall) exclusively for firewall management. This script simplifies the process of setting up a WireGuard VPN server on various Linux distributions.

## 🌟 Features

- **UFW-Only Firewall**: Uses UFW exclusively, automatically disabling conflicting firewalls (firewalld)
- **Multi-Distribution Support**: Works on Debian, Ubuntu, Fedora, CentOS, AlmaLinux, Rocky Linux, Oracle Linux, Arch Linux, and Alpine Linux
- **Automated Setup**: Interactive installation with sensible defaults
- **Client Management**: Easy client creation, listing, and revocation
- **IPv4 & IPv6 Support**: Full dual-stack support with automatic forwarding configuration
- **QR Code Generation**: Automatic QR code generation for easy mobile device setup
- **Security First**: Uses pre-shared keys and modern WireGuard best practices

## 📋 Requirements

### Supported Operating Systems

- **Debian**: 10 (Buster) or later
- **Ubuntu**: 18.04 or later
- **Fedora**: 32 or later
- **CentOS**: 8 or later
- **AlmaLinux**: 8 or later
- **Rocky Linux**: 8 or later
- **Oracle Linux**: 8 or later
- **Arch Linux**: Latest
- **Alpine Linux**: Latest

### System Requirements

- Root access or sudo privileges
- A fresh server with a public IP address
- At least 512 MB RAM (1 GB recommended)
- A virtualization environment that supports WireGuard (OpenVZ and standard LXC are not supported)

### Network Requirements

- UDP port for WireGuard (default: random port between 49152-65535)
- SSH access (port 22) should remain open

## 🚀 Installation & Usage

### Quick Start

1. **Download the script:**
   ```bash
   wget https://raw.githubusercontent.com/neosmith20/wireguard-install/main/wireguard-install-ufw.sh
   chmod +x wireguard-install-ufw.sh
   ```

2. **Run the installer as root:**
   ```bash
   sudo ./wireguard-install-ufw.sh
   ```

3. **Follow the interactive prompts:**
   - Confirm your server's public IP address
   - Select your public network interface
   - Choose a WireGuard interface name (default: wg0)
   - Set WireGuard IPv4 and IPv6 addresses
   - Choose a UDP port (or use the randomly generated one)
   - Configure DNS resolvers for clients
   - Set allowed IPs (default routes all traffic through VPN)

4. **Create your first client:**
   - The script will automatically prompt you to create your first client
   - Enter a client name (alphanumeric, dashes, or underscores only)
   - The script will generate a configuration file and QR code

5. **Get your client configuration:**
   - Configuration file location: `/root/wg0-client-CLIENTNAME.conf`
   - Scan the QR code with your mobile device's WireGuard app, or
   - Copy the configuration file to your client device

### Managing Clients

After installation, run the script again to access the management menu:

```bash
sudo ./wireguard-install-ufw.sh
```

**Available Options:**
- **Add a new client**: Create additional VPN client configurations
- **List all clients**: View all configured clients
- **Revoke a client**: Remove a client's access to the VPN
- **Uninstall WireGuard**: Completely remove WireGuard and all configurations
- **Exit**: Close the management menu

## 🔧 Configuration Details

### Firewall Configuration

The script automatically configures UFW with the following rules:

- **Default Policies:**
  - Incoming: DENY
  - Outgoing: ALLOW
  - Routed: ALLOW

- **Allowed Ports:**
  - SSH (22/tcp)
  - WireGuard (your chosen UDP port)

- **NAT & Routing:**
  - MASQUERADE rules for VPN subnet
  - Forwarding between WireGuard and public interfaces
  - IPv4 and IPv6 forwarding enabled

### WireGuard Configuration

- **Server Config Location:** `/etc/wireguard/wg0.conf`
- **Client Configs Location:** `/root/wg0-client-CLIENTNAME.conf`
- **Parameters File:** `/etc/wireguard/params`

### IP Forwarding

The script enables IP forwarding in two locations:
- `/etc/ufw/sysctl.conf`
- `/etc/sysctl.d/wg.conf`

Both IPv4 and IPv6 forwarding are enabled.

## 🛠️ Troubleshooting

### WireGuard Not Starting

If WireGuard doesn't start after installation:

```bash
# Check WireGuard status
sudo systemctl status wg-quick@wg0

# Check for errors
sudo journalctl -u wg-quick@wg0

# Try rebooting the server
sudo reboot
```

### No Internet on Client

1. Verify UFW is active and rules are loaded:
   ```bash
   sudo ufw status verbose
   ```

2. Check IP forwarding is enabled:
   ```bash
   sysctl net.ipv4.ip_forward
   sysctl net.ipv6.conf.all.forwarding
   ```

4. Try rebooting the server
   ```bash
   sudo reboot
   ```

### Firewalld Conflicts

The script automatically detects and disables firewalld. If you experience issues:

```bash
# Manually stop and disable firewalld
sudo systemctl stop firewalld
sudo systemctl disable firewalld
sudo systemctl mask firewalld

# Restart UFW
sudo systemctl restart ufw
```

## 📱 Client Setup

### Mobile Devices (iOS/Android)

1. Install the WireGuard app from your device's app store
2. Tap the "+" button
3. Select "Create from QR code"
4. Scan the QR code displayed after client creation

### Desktop/Laptop

1. Install WireGuard for your operating system from [wireguard.com](https://www.wireguard.com/install/)
2. Copy the client configuration file to your device
3. Import the configuration into WireGuard
4. Activate the tunnel

## 🔒 Security Notes

- All client configurations use pre-shared keys for additional security
- Keep your `/etc/wireguard/` directory secure (permissions are set to 600 by default)
- Regularly update your system and WireGuard packages
- Use strong, unique client names
- Revoke access for unused clients promptly

## 📝 Uninstallation

To completely remove WireGuard:

```bash
sudo ./wireguard-install-ufw.sh
```

Select option **4) Uninstall WireGuard** from the menu.

**Warning:** This will remove all WireGuard configurations and client files. Back up `/etc/wireguard/` before uninstalling if you want to keep your configurations.

## 🙏 Acknowledgments

This project is based on the excellent work by [**angristan**](https://github.com/angristan) and their [wireguard-install](https://github.com/angristan/wireguard-install) script.

**Key differences from the original:**
- UFW-only firewall management (iptables and firewalld removed)
- Automatic firewalld detection and disabling
- Enhanced UFW installation and configuration
- Improved error handling and service enablement
- Streamlined for UFW-based systems

Special thanks to angristan for providing the original idea, code structure, and inspiration for this project!

## 📄 License

This project maintains the same license as the original [wireguard-install](https://github.com/angristan/wireguard-install) project.

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the issues page.

## 📞 Support

If you encounter any problems:

1. Check the [Troubleshooting](#-troubleshooting) section
2. Review the [WireGuard documentation](https://www.wireguard.com/)
3. Check UFW logs: `sudo journalctl -u ufw`
4. Open an issue on GitHub

## ⭐ Show Your Support

If this project helped you, please consider giving it a star on GitHub!

---

**Made with ❤️ for the VPN community**
