# Fedora CoreOS Template for Proxmox

Scripts and configuration files to create a Fedora CoreOS template in Proxmox with CloudInit support

## Prereqs

- curl
- wget
- jq
- xz-utils
- openssl
- git
- genisoimage

## Quick Start

1. Clone the repository:
```bash
git clone https://github.com/talltechy/fedora-coreos-proxmox.git
cd fedora-coreos-proxmox
```

2. Review and modify the configuration files if needed:
   - `template.conf`: Basic VM template settings
   - `fcos-base-tmplt.yaml`: Ignition configuration

The ignition file provided is only a working basis.
For a more advanced configuration go to <https://docs.fedoraproject.org/en-US/fedora-coreos/>
   
3. Run the setup script:
```bash
chmod +x vmsetup.sh
./vmsetup.sh
```

## Configuration Files

### template.conf

This file contains the basic configuration for your VM template:

```bash
# Template + Storage Config
export TEMPLATE_NAME="coreos"                              # Name of the template
export TEMPLATEIGNITION="fcos-base-tmplt.yaml"             # Ignition config file
export TEMPLATEVMSTORAGE="local"                           # Proxmox storage location
export SNIPPETSTORAGE="local"                              # Storage for hook script and ignition file
export VMDISKOPTIONS=",discard=on"                         # Additional disk options
export STREAMS_V="stable"                                  # FCOS stream (stable/testing/next)
export ARCHITECTURES_V="x86_64"                            # CPU architecture
export PLATFORM_V="qemu"                                   # Platform type
export BASE_URL="https://builds.coreos.fedoraproject.org"  # FCOS build URL
```

### Script Features

The `vmsetup.sh` script provides several features:

```
Usage: vmsetup.sh [OPTIONS]

Options:
  --update-snippets    Update hook script and template snippets
  --help              Display help message
  --update-script     Update script from git repository and reload
```

## VM Template Features

The created template includes:

- QEMU Guest Agent support
- Cloud-init integration
- Automatic disk trimming
- Custom MOTD and system messages
- Network configuration support
- TPM and UEFI support

## First Boot Process

1. The VM will boot using the generated ignition configuration
2. QEMU guest agent will be installed automatically
3. The system will reboot once to complete initialization
4. CloudInit settings will be applied after the reboot

## Important Notes

- Network connectivity is required during first boot for QEMU guest agent installation
- The template automatically enables trimming for SSDs using fstrim.timer
- The template includes a custom MOTD (Message of the Day) configuration
- Console logging level is set to WARNING to reduce noise

## CloudInit Support

The template supports the following CloudInit parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| User | System user account | admin |
| Password | User password | Required |
| DNS Domain | Search domain for DNS | Optional |
| DNS Servers | DNS server addresses | Optional |
| SSH Keys | Public SSH keys | Optional |
| IP Configuration | IPv4 network settings | Optional (DHCP) |

The settings are applied at boot

### CloudInit Parameter Requirements

- Either a password or SSH key must be configured
- For static IP configuration, you need:
  - IP address
  - Netmask
  - Gateway (optional)
  - DNS servers (optional)
  - Search domain (optional)
 
## Troubleshooting

### Updating Components

To update script components:
```bash
# Update hook script and snippets
./vmsetup.sh --update-snippets

# Update entire script from repository
./vmsetup.sh --update-script
```

## Additional Resources

- [Fedora CoreOS Documentation](https://docs.fedoraproject.org/en-US/fedora-coreos/)
- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)
- [CloudInit Documentation](https://cloudinit.readthedocs.io/)
