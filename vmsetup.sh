#!/bin/bash

# Uncomment the following line to enable debug mode
# set -x
set -e

source ./colours.sh

# =============================================================================================
# global vars

# Force English messages
export LANG=C
export LC_ALL=C

# Function to display help information
show_help() {
    print_header "Usage: vmsetup.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo -e "${COLOR_CYAN}  --update-snippets${COLOR_RESET}          Update the hook script and template snippets and exit."
    echo -e "${COLOR_CYAN}  --help${COLOR_RESET}                     Display this help message and exit."
    echo -e "${COLOR_CYAN}  --update-script${COLOR_RESET}            Update the script from the git repository and reload."
    echo ""
    echo "This script sets up a Fedora CoreOS VM template in a Proxmox VE environment."
    echo "It checks for required commands, downloads the CoreOS image, and configures the VM."
    exec "$0" "$@"
}

# Function to display the main menu
main_menu() {
    print_header "Select an option:"
    echo -e "${COLOR_CYAN}1.${COLOR_RESET} Run the script"
    echo -e "${COLOR_CYAN}2.${COLOR_RESET} Update the hook script and template snippets"
    echo -e "${COLOR_CYAN}3.${COLOR_RESET} Display help information"
    echo -e "${COLOR_CYAN}4.${COLOR_RESET} Update the script from the git repository and reload"
    echo -e "${COLOR_CYAN}5.${COLOR_RESET} Exit"
    read -p "Enter your choice [1-5]: " choice

    case $choice in
        1)
            print_info "Running the script..."
            ;;
        2)
            UPDATE_SNIPPETS_ONLY=true
            ;;
        3)
            show_help
            exit 0
            ;;
        4)
            print_info "Updating the script from the git repository..."
            git pull
            print_info "Reloading the script..."
            exec "$0" "$@"
            ;;
        5)
            print_info "Exiting."
            exit 0
            ;;
        *)
            print_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}

# Function to check for script updates
check_for_updates() {
    local current_version latest_version
    current_version=$(git rev-parse HEAD)
    for branch in "main", "master"; do
      latest_version=$(git ls-remote origin -h "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')
      if [ -n "$latest_version" ]; then
        break
      fi
    done

    if [ -z "$latest_version" ]; then
        print_warn "Unable to determine latest version from remote"
    fi
    

    if [ "$current_version" != "$latest_version" ]; then
        print_header "UPDATE AVAILABLE"
        print_warn "A new version of this script is available."
        echo -e "${COLOR_CYAN}Current version:${COLOR_RESET} $current_version"
        echo -e "${COLOR_CYAN}Latest version:${COLOR_RESET}  $latest_version"
        print_info "Please update the script by selecting the update option or manually by running: git pull"
    fi
}

# Call the update check function
check_for_updates

# Call the main menu function
main_menu

# Check for the --update-snippets or --update-script flag
for arg in "$@"; do
    case $arg in
        --update-snippets)
        UPDATE_SNIPPETS_ONLY=true
        shift
        ;;
        --help)
        show_help
        exit 0
        ;;
        --update-script)
        print_info "Updating the script from the git repository..."
        git pull
        print_info "Reloading the script..."
        exec "$0" "$@"
        ;;
    esac
done

# Source the template.conf file
if [ -f template.conf ]; then
    source template.conf
else
    print_error "Configuration file template.conf not found!"
    exit 1
fi

# Check if running in Proxmox VE environment
if ! command -v pvesh &> /dev/null; then
    print_error "This script must be run in a Proxmox VE environment."
    exit 1
fi

# Verify required commands are available
missing_cmds=()
for cmd in \
    curl \
    jq \
    wget \
    xz \
    qm \
    sha256sum; do
        if ! command -v $cmd &> /dev/null; then
            missing_cmds+=($cmd)
        fi
done

# Check if there are any missing commands and prompt the user to install them
if [ ${#missing_cmds[@]} -ne 0 ]; then
        print_warn "The following required commands are missing: ${missing_cmds[@]}"
        read -p "Do you want to install them? (y/n) " choice
        if [[ $choice == [Yy]* ]]; then
                if command -v apt-get &> /dev/null; then
                        sudo apt-get update && sudo apt-get install -y ${missing_cmds[@]}
                elif command -v yum &> /dev/null; then
                        sudo yum install -y ${missing_cmds[@]}
                elif command -v dnf &> /dev/null; then
                        sudo dnf install -y ${missing_cmds[@]}
                else
                        print_warn "Package manager not found. Please install the missing commands manually."
                        exit 1
                fi
        else
                print_warn "The following commands are required: ${missing_cmds[@]}. Exiting."
                exit 1
        fi
fi

# Function to find the next available VMID starting from 900
find_next_available_vmid() {
    local vmid=900
    local vmids=$(pvesh get /cluster/resources --type vm --output-format json | jq -r '.[].vmid')
    while echo "$vmids" | grep -q "^$vmid$"; do
        vmid=$((vmid + 1))
    done
    echo $vmid
}

# Set TEMPLATE_VMID to the next available VMID
TEMPLATE_VMID=$(find_next_available_vmid)

# template vm vars
TEMPLATE_VMSTORAGE=${TEMPLATEVMSTORAGE}
SNIPPET_STORAGE=${SNIPPETSTORAGE}
VMDISK_OPTIONS=${VMDISKOPTIONS}
TEMPLATE_IGNITION=${TEMPLATEIGNITION:-fcos-base-tmplt.yaml}
# Default to stable, alternatively override with environment variable with either stable, testing, or next
STREAMS=${STREAMS_V:-stable}
ARCHITECTURES=${ARCHITECTURES_V:-x86_64}
PLATFORM=${PLATFORM_V:-qemu}
BASEURL=${BASE_URL:-https://builds.coreos.fedoraproject.org}
# URL to fetch the stable release JSON
RELEASE_JSON=${BASEURL}/streams/${STREAMS}.json
# Fetch the JSON data and extract the stable release number using jq
VERSION=$(curl -s $RELEASE_JSON | jq -r ".architectures.${ARCHITECTURES}.artifacts.${PLATFORM}.release")
if [ $? -ne 0 ]; then
    print_error "Failed to fetch the stable release JSON from $RELEASE_JSON"
    exit 1
fi
# This section checks if all necessary environment variables are set to avoid runtime errors.
required_vars=(TEMPLATE_VMID TEMPLATE_VMSTORAGE SNIPPET_STORAGE STREAMS TEMPLATE_NAME VMDISK_OPTIONS)
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Environment variable $var is required but not set."
        exit 1
    fi
done

# =============================================================================================
# main()

# pve storage exist ?
print_info "Check if vm storage ${TEMPLATE_VMSTORAGE} exists... "
pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader &> /dev/null || {
        print_error -e "[failed]"
        exit 1
}
print_ok "[ok]"

# pve storage snippet ok ?
print_info -n "Check if snippet storage ${SNIPPET_STORAGE} exists... "
if ! snippet_storage_info=$(pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader 2>/dev/null); then
    echo -e "[failed]"
    exit 1
fi
print_ok "[ok]"

pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep -q snippets || {
        print_error "You must activate content snippet on storage: ${SNIPPET_STORAGE}"
    exit 1
}

# copy files
print_info "Copy hook-script and ignition config to snippet storage..."
snippet_storage="$(pvesh get /storage/${SNIPPET_STORAGE} --output-format json | jq -r '.path')"
cp -av ${TEMPLATE_IGNITION} hook-fcos.sh ${snippet_storage}/snippets
sed -e "/^COREOS_TMPLT/ c\COREOS_TMPLT=${snippet_storage}/snippets/${TEMPLATE_IGNITION}" -i ${snippet_storage}/snippets/hook-fcos.sh
chmod 755 ${snippet_storage}/snippets/hook-fcos.sh

# Reload script after updating snippets
if [ "$UPDATE_SNIPPETS_ONLY" = true ]; then
    print_success "Hook script and Template snippets updated. Reloading Script."
    exec "$0" "$@"
fi

# storage type ? (https://pve.proxmox.com/wiki/Storage)
print_info -n "Get storage \"${TEMPLATE_VMSTORAGE}\" type... "
case "$(pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader | grep ^type | awk '{print $2}')" in
    dir|nfs|cifs|glusterfs|cephfs)
        TEMPLATE_VMSTORAGE_type="file"
        print_ok "[file]"
        ;;
    lvm|lvmthin|iscsi|iscsidirect|rbd|zfs|zfspool)
        TEMPLATE_VMSTORAGE_type="block"
        print_ok "[block]"
        ;;
    *)
        print_error "[unknown]"
        exit 1
        ;;
esac

# Function to check if CoreOS image already exists
coreos_image_exists() {
    [[ -e fedora-coreos-${VERSION}-${PLATFORM}.${ARCHITECTURES}.qcow2 ]]
}

if ! coreos_image_exists; then
    print_info "Download fedora coreos..."
    wget -q --show-progress \
        ${BASEURL}/prod/streams/${STREAMS}/builds/${VERSION}/${ARCHITECTURES}/fedora-coreos-${VERSION}-${PLATFORM}.${ARCHITECTURES}.qcow2.xz
    if [ $? -ne 0 ]; then
        print_error "Failed to download Fedora CoreOS image."
        exit 1
    fi
    if ! xz -dv fedora-coreos-${VERSION}-${PLATFORM}.${ARCHITECTURES}.qcow2.xz; then
        print_error "Failed to extract Fedora CoreOS image."
        exit 1
    else
        print_success "Successfully extracted Fedora CoreOS image."
    fi
else
    print_info "CoreOS image already exists. Skipping download."
fi

# create a new VM
print_header "Create fedora coreos vm ${TEMPLATE_VMID}"
if ! qm create ${TEMPLATE_VMID} --name ${TEMPLATE_NAME}; then
    print_error "Failed to create VM ${TEMPLATE_VMID}"
    exit 1
fi
qm set ${TEMPLATE_VMID} --memory 4096 \
            --cpu max \
            --cores 4 \
            --agent enabled=1 \
            --autostart \
            --onboot 1 \
            --ostype l26 \
            --tablet 0 \
            --boot c --bootdisk scsi0 \
            --machine q35 \
            --bios ovmf \
            --scsihw virtio-scsi-pci \

qm set ${TEMPLATE_VMID} --description "Fedora CoreOS - Template
 - Version             : ${VERSION}
 - Cloud-init          : true
 - Creation date       : ${template_vmcreated}"

if ! qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0; then
    print_error "Failed to add network interface to VM ${TEMPLATE_VMID}."
    exit 1
fi

echo -e "\nCreate Cloud-init vmdisk..."
if ! qm set ${TEMPLATE_VMID} --ide2 ${TEMPLATE_VMSTORAGE}:cloudinit; then
    print_error "Failed to add Cloud-init disk to VM ${TEMPLATE_VMID}"
    exit 1
fi

# Import Fedora CoreOS disk
if [[ "${TEMPLATE_VMSTORAGE_type}" == "file" ]]; then
        vmdisk_name="${TEMPLATE_VMID}/vm-${TEMPLATE_VMID}-disk-0.qcow2"
        vmdisk_format="--format qcow2"
else
        vmdisk_name="vm-${TEMPLATE_VMID}-disk-0"
        vmdisk_format=""
fi

if ! qm importdisk ${TEMPLATE_VMID} fedora-coreos-${VERSION}-${PLATFORM}.${ARCHITECTURES}.qcow2 ${TEMPLATE_VMSTORAGE} ${vmdisk_format}; then
    print_error "Failed to import Fedora CoreOS disk."
    exit 1
fi
if ! qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}; then
    print_error "Failed to configure disk for VM ${TEMPLATE_VMID}"
    exit 1
fi

# Add EFI disk for UEFI
if ! qm set ${TEMPLATE_VMID} -efidisk0 ${TEMPLATE_VMSTORAGE}:1,efitype=4m,pre-enrolled-keys=1; then
    print_error "Failed to add EFI disk for UEFI."
    exit 1
fi

# Add TPM state
if ! qm set ${TEMPLATE_VMID} -tpmstate0 ${TEMPLATE_VMSTORAGE}:1,version=v2.0; then
    print_error "Failed to add TPM state to VM ${TEMPLATE_VMID}"
    exit 1
fi

# set hook-script
if ! qm set ${TEMPLATE_VMID} --hookscript ${SNIPPET_STORAGE}:snippets/hook-fcos.sh; then
    print_error "Failed to set hook script for VM ${TEMPLATE_VMID}."
    exit 1
fi

# convert vm template
echo -n "Convert VM ${TEMPLATE_VMID} in proxmox vm template... "
if ! qm template ${TEMPLATE_VMID}; then
    print_error "[failed]"
    exit 1
else
    print_success "[done]"
fi

print_header "Template Creation Complete"
print_info "Template ID: ${TEMPLATE_VMID}"
print_info "Template Name: ${TEMPLATE_NAME}"
print_info "CoreOS Version: ${VERSION}"
print_info "Storage Location: ${TEMPLATE_VMSTORAGE}"
print_success "You can now create VMs from this template using the Proxmox web interface or CLI."
