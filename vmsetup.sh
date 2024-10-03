#!/bin/bash

# Uncomment the following line to enable debug mode
# set -x
set -e

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

# Source the template.conf file
if [ -f template.conf ]; then
    source template.conf
else
    echo "Configuration file template.conf not found!"
    exit 1
fi

# Check if running in Proxmox VE environment
if ! command -v pvesh &> /dev/null; then
    echo "This script must be run in a Proxmox VE environment."
    exit 1
fi

# Verify required commands are available
missing_cmds=()
for cmd in curl jq wget xz qm; do
        if ! command -v $cmd &> /dev/null; then
            missing_cmds+=($cmd)
        fi
done

# Check if there are any missing commands and prompt the user to install them
if [ ${#missing_cmds[@]} -ne 0 ]; then

if [ ${#missing_cmds[@]} -ne 0 ]; then
        echo "The following required commands are missing: ${missing_cmds[@]}"
        read -p "Do you want to install them? (y/n) " choice
        if [[ $choice == [Yy]* ]]; then
                if command -v apt-get &> /dev/null; then
                        sudo apt-get update && sudo apt-get install -y ${missing_cmds[@]}
                elif command -v yum &> /dev/null; then
                        sudo yum install -y ${missing_cmds[@]}
                elif command -v dnf &> /dev/null; then
                        sudo dnf install -y ${missing_cmds[@]}
                else
                        echo "Package manager not found. Please install the missing commands manually."
                        exit 1
                fi
        else
                echo "The following commands are required: ${missing_cmds[@]}. Exiting."
                exit 1
        fi
fi

# template vm vars
TEMPLATE_VMID=${TEMPLATE_VMID}
TEMPLATE_VMSTORAGE=${TEMPLATE_VMSTORAGE}
SNIPPET_STORAGE=${SNIPPET_STORAGE}
VMDISK_OPTIONS=${VMDISK_OPTIONS}
TEMPLATE_IGNITION="fcos-base-tmplt.yaml"

# URL to fetch the stable release JSON
RELEASE_JSON="https://builds.coreos.fedoraproject.org/streams/stable.json"
# Fetch the JSON data and extract the stable release number using jq
VERSION=$(curl -s $RELEASE_JSON | jq -r '.architectures.x86_64.artifacts.qemu.release')
if [ $? -ne 0 ]; then
    echo "Failed to fetch the stable release JSON from $RELEASE_JSON"
    exit 1
fi
STREAMS=${STREAMS}
PLATFORM=qemu
BASEURL=https://builds.coreos.fedoraproject.org

# This section checks if all necessary environment variables are set to avoid runtime errors.
required_vars=(TEMPLATE_VMID TEMPLATE_VMSTORAGE SNIPPET_STORAGE STREAMS TEMPLATE_NAME VMDISK_OPTIONS)
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Environment variable $var is required but not set."
        exit 1
    fi
done

# =============================================================================================
# main()

# pve storage exist ?
echo -n "Check if vm storage ${TEMPLATE_VMSTORAGE} exists... "
pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet ok ?
echo -n "Check if snippet storage ${SNIPPET_STORAGE} exists... "
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet enable
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep -q snippets || {
        echo "You must activate content snippet on storage: ${SNIPPET_STORAGE}"
    exit 1
}

# copy files
echo "Copy hook-script and ignition config to snippet storage..."
snippet_storage="$(pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep ^path | awk '{print $NF}')"
cp -av ${TEMPLATE_IGNITION} hook-fcos.sh ${snippet_storage}/snippets
sed -e "/^COREOS_TMPLT/ c\COREOS_TMPLT=${snippet_storage}/snippets/${TEMPLATE_IGNITION}" -i ${snippet_storage}/snippets/hook-fcos.sh
chmod 755 ${snippet_storage}/snippets/hook-fcos.sh

# storage type ? (https://pve.proxmox.com/wiki/Storage)
echo -n "Get storage \"${TEMPLATE_VMSTORAGE}\" type... "
case "$(pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader | grep ^type | awk '{print $2}')" in
        dir|nfs|cifs|glusterfs|cephfs) TEMPLATE_VMSTORAGE_type="file"; echo "[file]";;
        lvm|lvmthin|iscsi|iscsidirect|rbd|zfs|zfspool) TEMPLATE_VMSTORAGE_type="block"; echo "[block]";;
        *)
                echo "[unknown]"
                exit 1
        ;;
esac

[[ ! -e fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ]] && {
    echo "Download fedora coreos..."
    if ! wget -q --show-progress \
        ${BASEURL}/prod/streams/${STREAMS}/builds/${VERSION}/x86_64/fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz; then
        echo "Failed to download Fedora CoreOS image."
        exit 1
    fi

    if ! xz -dv fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz; then
        echo "Failed to extract Fedora CoreOS image."
        exit 1
    fi
}
}
}

# create a new VM
echo "Create fedora coreos vm ${TEMPLATE_VMID}"
qm create ${TEMPLATE_VMID} --name ${TEMPLATE_NAME}
qm set ${TEMPLATE_VMID} --memory 4096 \
			--cpu max \
			--cores 4 \
			--agent enabled=1 \
			--autostart \
			--onboot 1 \
			--ostype l26 \
			--tablet 0 \
			--boot c --bootdisk scsi0

template_vmcreated=$(date +%Y-%m-%d)
qm set ${TEMPLATE_VMID} --description "Fedora CoreOS - Template
 - Version             : ${VERSION}
 - Cloud-init          : true
 - Creation date       : ${template_vmcreated}"

qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0

echo -e "\nCreate Cloud-init vmdisk..."
qm set ${TEMPLATE_VMID} --ide2 ${TEMPLATE_VMSTORAGE}:cloudinit

# Import Fedora CoreOS disk
if [[ "${TEMPLATE_VMSTORAGE_type}" == "file" ]]; then
        vmdisk_name="${TEMPLATE_VMID}/vm-${TEMPLATE_VMID}-disk-0.qcow2"
        vmdisk_format="--format qcow2"
else
        vmdisk_name="vm-${TEMPLATE_VMID}-disk-0"
        vmdisk_format=""
fi
qm importdisk ${TEMPLATE_VMID} fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ${TEMPLATE_VMSTORAGE} ${vmdisk_format}
qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}

# set hook-script
qm set ${TEMPLATE_VMID} --hookscript ${SNIPPET_STORAGE}:snippets/hook-fcos.sh

# convert vm template
echo -n "Convert VM ${TEMPLATE_VMID} in proxmox vm template... "
if ! qm template ${TEMPLATE_VMID} &> /dev/null; then
    echo "[failed]"
    exit 1
fi
echo "[done]"
