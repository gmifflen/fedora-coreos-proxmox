# fedora-coreos-proxmox

Fedora CoreOS template for proxmox with cloudinit support

## Create FCOS VM Template

### Configuration

* **vmsetup.sh**

```bash
# Template + Storage Config
TEMPLATE_NAME="coreos"
TEMPLATEIGNITION="fcos-base-tmplt.yaml"
TEMPLATEVMSTORAGE="local"               # Proxmox storage
SNIPPETSTORAGE="local"                  # Snippets storage for hook and ignition file
VMDISKOPTIONS=",discard=on"             # Add options to vmdisk
STREAMS_V="stable"                      # stable, testing, next
ARCHITECTURES_V="x86_64"                # x86_64, aarch64, ppc64le, etc.
PLATFORM_V="qemu"                       # qemu, aws, azure, gcp, oci, openstack, packet, vmware, etc..
BASE_URL="https://builds.coreos.fedoraproject.org"
```

* **fcos-base-tmplt.yaml**

The ignition file provided is only a working basis.
For a more advanced configuration go to <https://docs.fedoraproject.org/en-US/fedora-coreos/>

it contains :

* Correct fstrim service with no fstab file
* Install qemu-guest-agent on first boot
* Install CloudInit wrapper
* Raise console message logging level from DEBUG (7) to WARNING (4)
* Add motd/issue

### Script output

```bash
root@pve:~# git clone https://github.com/talltechy/fedora-coreos-proxmox.git
Cloning into 'fedora-coreos-proxmox'...
remote: Enumerating objects: 187, done.
remote: Counting objects: 100% (128/128), done.
remote: Compressing objects: 100% (76/76), done.
remote: Total 187 (delta 87), reused 91 (delta 52), pack-reused 59 (from 1)
Receiving objects: 100% (187/187), 103.41 KiB | 912.00 KiB/s, done.
Resolving deltas: 100% (116/116), done.
root@pve:~# cd fedora-coreos-proxmox/
root@pve:~/fedora-coreos-proxmox# ./vmsetup.sh
Check if vm storage local exists... [ok]
Check if snippet storage local exists... [ok]
Copy hook-script and ignition config to snippet storage...
'fcos-base-tmplt.yaml' -> '/var/lib/vz/snippets/fcos-base-tmplt.yaml'
'hook-fcos.sh' -> '/var/lib/vz/snippets/hook-fcos.sh'
Get storage "local" type... [file]
Download fedora coreos...
fedora-coreos-40.20240906.3.0-qemu.x86_64.qcow 100%[==================================================================================================>] 756.21M  10.9MB/s    in 42s
fedora-coreos-40.20240906.3.0-qemu.x86_64.qcow2.xz (1/1)
  100 %      756.2 MiB / 1685.5 MiB = 0.449    72 MiB/s       0:23
Successfully extracted Fedora CoreOS image.
Create fedora coreos vm 900
update VM 900: -agent enabled=1 -autostart 1 -bios ovmf -boot c -bootdisk scsi0 -cores 4 -cpu max -machine q35 -memory 4096 -onboot 1 -ostype l26 -scsihw virtio-scsi-pci -tablet 0
update VM 900: -description Fedora CoreOS - Template
 - Version             : 40.20240906.3.0
 - Cloud-init          : true
 - Creation date       :
update VM 900: -net0 virtio,bridge=vmbr0

Create Cloud-init vmdisk...
update VM 900: -ide2 local:cloudinit
Formatting '/var/lib/vz/images/900/vm-900-cloudinit.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off preallocation=metadata compression_type=zlib size=4194304 lazy_refcounts=off refcount_bits=16
ide2: successfully created disk 'local:900/vm-900-cloudinit.qcow2,media=cdrom'
generating cloud-init ISO
importing disk 'fedora-coreos-40.20240906.3.0-qemu.x86_64.qcow2' to VM 900 ...
Formatting '/var/lib/vz/images/900/vm-900-disk-0.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off preallocation=metadata compression_type=zlib size=10737418240 lazy_refcounts=off refcount_bits=16
transferred 0.0 B of 10.0 GiB (0.00%)
transferred 112.6 MiB of 10.0 GiB (1.10%)
transferred 218.1 MiB of 10.0 GiB (2.13%)
transferred 327.7 MiB of 10.0 GiB (3.20%)
transferred 438.3 MiB of 10.0 GiB (4.28%)
transferred 547.8 MiB of 10.0 GiB (5.35%)
transferred 656.4 MiB of 10.0 GiB (6.41%)
transferred 762.9 MiB of 10.0 GiB (7.45%)
transferred 865.3 MiB of 10.0 GiB (8.45%)
transferred 974.8 MiB of 10.0 GiB (9.52%)
transferred 1.1 GiB of 10.0 GiB (10.59%)
transferred 1.2 GiB of 10.0 GiB (11.66%)
transferred 1.3 GiB of 10.0 GiB (12.73%)
transferred 1.4 GiB of 10.0 GiB (13.80%)
transferred 1.5 GiB of 10.0 GiB (14.86%)
transferred 1.6 GiB of 10.0 GiB (15.93%)
transferred 1.7 GiB of 10.0 GiB (17.00%)
transferred 1.8 GiB of 10.0 GiB (18.07%)
transferred 1.9 GiB of 10.0 GiB (19.14%)
transferred 2.0 GiB of 10.0 GiB (20.21%)
transferred 2.1 GiB of 10.0 GiB (21.27%)
transferred 2.2 GiB of 10.0 GiB (22.34%)
transferred 2.3 GiB of 10.0 GiB (23.38%)
transferred 2.4 GiB of 10.0 GiB (24.45%)
transferred 2.6 GiB of 10.0 GiB (25.52%)
transferred 2.7 GiB of 10.0 GiB (26.59%)
transferred 2.8 GiB of 10.0 GiB (27.66%)
transferred 2.9 GiB of 10.0 GiB (28.73%)
transferred 3.0 GiB of 10.0 GiB (29.79%)
transferred 3.1 GiB of 10.0 GiB (30.89%)
transferred 3.2 GiB of 10.0 GiB (31.95%)
transferred 3.3 GiB of 10.0 GiB (33.02%)
transferred 3.4 GiB of 10.0 GiB (34.09%)
transferred 3.5 GiB of 10.0 GiB (35.16%)
transferred 3.6 GiB of 10.0 GiB (36.23%)
transferred 3.7 GiB of 10.0 GiB (37.30%)
transferred 3.8 GiB of 10.0 GiB (38.36%)
transferred 3.9 GiB of 10.0 GiB (39.43%)
transferred 4.0 GiB of 10.0 GiB (40.50%)
transferred 4.2 GiB of 10.0 GiB (41.57%)
transferred 4.3 GiB of 10.0 GiB (42.64%)
transferred 4.4 GiB of 10.0 GiB (43.71%)
transferred 4.5 GiB of 10.0 GiB (44.77%)
transferred 4.6 GiB of 10.0 GiB (45.84%)
transferred 4.7 GiB of 10.0 GiB (46.91%)
transferred 4.8 GiB of 10.0 GiB (47.98%)
transferred 4.9 GiB of 10.0 GiB (49.05%)
transferred 5.0 GiB of 10.0 GiB (50.11%)
transferred 5.1 GiB of 10.0 GiB (51.22%)
transferred 5.2 GiB of 10.0 GiB (52.25%)
transferred 5.3 GiB of 10.0 GiB (53.32%)
transferred 5.4 GiB of 10.0 GiB (54.38%)
transferred 5.5 GiB of 10.0 GiB (55.45%)
transferred 5.7 GiB of 10.0 GiB (56.52%)
transferred 5.8 GiB of 10.0 GiB (57.59%)
transferred 5.9 GiB of 10.0 GiB (58.66%)
transferred 6.0 GiB of 10.0 GiB (59.73%)
transferred 6.1 GiB of 10.0 GiB (60.79%)
transferred 6.2 GiB of 10.0 GiB (61.86%)
transferred 6.3 GiB of 10.0 GiB (62.93%)
transferred 6.4 GiB of 10.0 GiB (64.00%)
transferred 6.5 GiB of 10.0 GiB (65.07%)
transferred 6.6 GiB of 10.0 GiB (66.14%)
transferred 6.7 GiB of 10.0 GiB (67.20%)
transferred 6.8 GiB of 10.0 GiB (68.27%)
transferred 6.9 GiB of 10.0 GiB (69.34%)
transferred 7.0 GiB of 10.0 GiB (70.44%)
transferred 7.2 GiB of 10.0 GiB (71.51%)
transferred 7.3 GiB of 10.0 GiB (72.58%)
transferred 7.4 GiB of 10.0 GiB (73.65%)
transferred 7.5 GiB of 10.0 GiB (74.72%)
transferred 7.6 GiB of 10.0 GiB (75.78%)
transferred 7.7 GiB of 10.0 GiB (76.87%)
transferred 7.8 GiB of 10.0 GiB (77.94%)
transferred 7.9 GiB of 10.0 GiB (79.00%)
transferred 8.0 GiB of 10.0 GiB (80.07%)
transferred 8.1 GiB of 10.0 GiB (81.14%)
transferred 8.2 GiB of 10.0 GiB (82.21%)
transferred 8.3 GiB of 10.0 GiB (83.28%)
transferred 8.4 GiB of 10.0 GiB (84.35%)
transferred 8.5 GiB of 10.0 GiB (85.41%)
transferred 8.6 GiB of 10.0 GiB (86.48%)
transferred 8.8 GiB of 10.0 GiB (87.55%)
transferred 8.9 GiB of 10.0 GiB (88.62%)
transferred 9.0 GiB of 10.0 GiB (89.69%)
transferred 9.1 GiB of 10.0 GiB (90.76%)
transferred 9.2 GiB of 10.0 GiB (91.82%)
transferred 9.3 GiB of 10.0 GiB (92.89%)
transferred 9.4 GiB of 10.0 GiB (93.96%)
transferred 9.5 GiB of 10.0 GiB (95.08%)
transferred 9.6 GiB of 10.0 GiB (96.15%)
transferred 9.7 GiB of 10.0 GiB (97.21%)
transferred 9.8 GiB of 10.0 GiB (98.33%)
transferred 9.9 GiB of 10.0 GiB (99.40%)
transferred 10.0 GiB of 10.0 GiB (100.00%)
transferred 10.0 GiB of 10.0 GiB (100.00%)
Successfully imported disk as 'unused0:local:900/vm-900-disk-0.qcow2'
update VM 900: -scsi0 local:900/vm-900-disk-0.qcow2,discard=on -scsihw virtio-scsi-pci
update VM 900: -efidisk0 local:1,efitype=4m,pre-enrolled-keys=1
Formatting '/var/lib/vz/images/900/vm-900-disk-1.raw', fmt=raw size=540672 preallocation=off
transferred 0.0 B of 528.0 KiB (0.00%)
transferred 528.0 KiB of 528.0 KiB (100.00%)
transferred 528.0 KiB of 528.0 KiB (100.00%)
efidisk0: successfully created disk 'local:900/vm-900-disk-1.raw,efitype=4m,pre-enrolled-keys=1,size=528K'
update VM 900: -tpmstate0 local:1,version=v2.0
Formatting '/var/lib/vz/images/900/vm-900-disk-2.raw', fmt=raw size=4194304 preallocation=off
tpmstate0: successfully created disk 'local:900/vm-900-disk-2.raw,size=4M,version=v2.0'
update VM 900: -hookscript local:snippets/hook-fcos.sh
Convert VM 900 in proxmox vm template... [done]
```

## Operation

Before starting an FCOS VM, we create an ignition file by merging the data from the cloudinit and the fcos-base-tmplt.yaml file.
Then we modify the configuration of the vm to add the loading of the ignition file and we reset the start of the vm.

  ![fcos_proxmox_first_start](./screenshot/fcos_proxmox_first_start.png)

During the first boot the vm will install qemu-agent and will restart.
Warning, for that the network must be operational

## CloudInit

Only these parameters are supported by our cloudinit wrapper:

* User (only one) default = admin
* Passwd
* DNS domain
* DNS Servers
* SSH public key
* IP Configuration (ipv4 only)

The settings are applied at boot
