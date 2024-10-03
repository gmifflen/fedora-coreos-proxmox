# This script sets up a Fedora CoreOS virtual machine template on Proxmox VE.
# 
# It performs the following steps:
# 
# 1. Sets global variables for VM configuration and Fedora CoreOS version.
# 2. Checks if the specified VM storage and snippet storage exist in Proxmox VE.
# 3. Ensures that the snippet storage has content snippets enabled.
# 4. Copies the hook script and ignition config to the snippet storage.
# 5. Determines the type of storage (file or block) for the VM.
# 6. Downloads the Fedora CoreOS image if it does not already exist.
# 7. Creates a new VM with the specified configuration.
# 8. Sets the VM description with the Fedora CoreOS version and creation date.
# 9. Configures the network interface for the VM.
# 10. Creates a Cloud-init disk for the VM.
# 11. Imports the Fedora CoreOS disk into the VM.
# 12. Sets the hook script for the VM.
# 13. Converts the VM into a Proxmox VE template.
#!/bin/bash

# Uncomment the following line to enable debug mode
# set -x
set -e

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

# template vm vars
TEMPLATE_VMID=${TEMPLATE_VMID}
TEMPLATE_VMSTORAGE=${TEMPLATE_VMSTORAGE}
SNIPPET_STORAGE=${SNIPPET_STORAGE}
VMDISK_OPTIONS=${VMDISK_OPTIONS}

TEMPLATE_IGNITION="fcos-base-tmplt.yaml"

# fcos version
# URL to fetch the stable release JSON
RELEASE_JSON="https://builds.coreos.fedoraproject.org/streams/stable.json"
# Fetch the JSON data and extract the stable release number using jq
VERSION=$(curl -s $RELEASE_JSON | jq -r '.architectures.x86_64.artifacts.qemu.release')
STREAMS=${STREAMS}
PLATFORM=qemu
BASEURL=https://builds.coreos.fedoraproject.org


# =============================================================================================
# main()

# pve storage exist ?
echo -n "Check if vm storage ${TEMPLATE_VMSTORAGE} exist... "
pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet ok ?
echo -n "Check if snippet storage ${SNIPPET_STORAGE} exist... "
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
        dir|nfs|cifs|glusterfs|cephfs) TEMPLATE_VMSTORAGE_type="file"; echo "[file]"; ;
        lvm|lvmthin|iscsi|iscsidirect|rbd|zfs|zfspool) TEMPLATE_VMSTORAGE_type="block"; echo "[block]"; ;
        *)
                echo "[unknown]"
                exit 1
        ;;
esac

[[ ! -e fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ]] && {
    echo "Download fedora coreos..."
    wget -q --show-progress \
        ${BASEURL}/prod/streams/${STREAMS}/builds/${VERSION}/x86_64/fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
    xz -dv fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
}
}

# create a new VM
echo "Create fedora coreos vm ${VMID}"
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

Creation date : ${template_vmcreated}"

qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0

echo -e "\nCreate Cloud-init vmdisk..."
qm set ${TEMPLATE_VMID} --ide2 ${TEMPLATE_VMSTORAGE}:cloudinit

# import fedora disk
if [[ "x${TEMPLATE_VMSTORAGE_type}" = "xfile" ]]
then
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
qm template ${TEMPLATE_VMID} &> /dev/null
echo "[done]"
