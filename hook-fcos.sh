# This script is a hook for Fedora CoreOS on Proxmox. It performs various setup tasks and generates necessary configuration files for Fedora CoreOS VMs.
# 
# Usage:
#   ./hook-fcos.sh <vmid> <phase>
#
# Parameters:
#   vmid  - The ID of the virtual machine.
#   phase - The phase of the VM lifecycle (e.g., "pre-start").
#
# Global Variables:
#   COREOS_TMPLT       - Path to the Fedora CoreOS template YAML file.
#   COREOS_FILES_PATH  - Path to store generated CoreOS files.
#   YQ                 - Command to read YAML files using yq.
#
# Functions:
#   setup_fcoreosct()  - Sets up the Fedora CoreOS Config Transpiler (fcos-ct).
#   setup_yq()         - Sets up the YAML parser tool yq.
#
# Main Logic:
#   - If the phase is "pre-start", the script performs the following tasks:
#     - Dumps cloud-init metadata and user data for the VM.
#     - Checks if the cloud-init configuration has changed and regenerates necessary files if needed.
#     - Generates YAML blocks for users, hostname, and network configuration.
#     - Generates an Ignition config file using fcos-ct.
#     - Saves the cloud-init instance ID.
#     - Sets VM configuration arguments for Fedora CoreOS.
#     - Restarts the VM if new Ignition settings are generated.
#!/bin/bash

# set -e is commented out to allow the script to continue even if some commands fail
#set -e
 
vmid="$1"
phase="$2"

# global vars
COREOS_TMPLT=/opt/fcos-tmplt.yaml
COREOS_FILES_PATH=/etc/pve/next-pve/coreos
YQ="/usr/local/bin/yq read --exitStatus --printMode v --stripComments --"

# ==================================================================================================================================================================
# functions()
#
setup_fcoreosct()
{
        local ARCH=x86_64
        local OS=unknown-linux-gnu # Linux
        local DOWNLOAD_URL=https://github.com/coreos/fcct/releases/download

        # Fetch the latest version from GitHub API
        local CT_VER=$(curl -s https://api.github.com/repos/coreos/fcct/releases/latest | jq -r .tag_name | sed 's/^v//')

        # Check if the binary already exists and matches the latest version
        [[ -x /usr/local/bin/fcos-ct ]] && [[ "x$(/usr/local/bin/fcos-ct --version | awk '{print $NF}')" == "x${CT_VER}" ]] && return 0

        echo "Setup Fedora CoreOS config transpiler..."
        rm -f /usr/local/bin/fcos-ct
        wget --quiet --show-progress ${DOWNLOAD_URL}/v${CT_VER}/fcct-${ARCH}-${OS} -O /usr/local/bin/fcos-ct
        chmod 755 /usr/local/bin/fcos-ct
}
setup_fcoreosct

setup_yq()
{
    # Fetch the latest version of yq from GitHub API
    local VER=$(curl --silent "https://api.github.com/repos/mikefarah/yq/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    [[ -x /usr/bin/wget ]] && download_command="wget --quiet --show-progress --output-document" || download_command="curl --location --output"
    [[ -x /usr/local/bin/yq ]] && [[ "x$(/usr/local/bin/yq --version | awk '{print $NF}')" == "x${VER}" ]] && return 0
    echo "Setup yaml parser tools yq..."
    rm -f /usr/local/bin/yq
    ${download_command} /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${VER}/yq_linux_amd64
    chmod 755 /usr/local/bin/yq
}
setup_yq

# ==================================================================================================================================================================
# main()
#
if [[ "${phase}" == "pre-start" ]]
then
	instance_id="$(qm cloudinit dump ${vmid} meta | ${YQ} - 'instance-id')"

	# same cloudinit config ?
	[[ -e ${COREOS_FILES_PATH}/${vmid}.id ]] && [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id)" ]] && {
		rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
	}
	[[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]] && exit 0 # already done

	mkdir -p ${COREOS_FILES_PATH} || exit 1
		
	# check config
	cipasswd="$(qm cloudinit dump ${vmid} user | ${YQ} - 'password' 2> /dev/null)" || true # can be empty
	[[ "x${cipasswd}" != "x" ]] && VALIDCONFIG=true
	${VALIDCONFIG:-false} || [[ "x$(qm cloudinit dump ${vmid} user | ${YQ} - 'ssh_authorized_keys[*]')" == "x" ]] || VALIDCONFIG=true
	${VALIDCONFIG:-false} || {
		echo "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
		exit 1
	}

	echo -n "Fedora CoreOS: Generate yaml users block... "
	echo -e "# This file is managed by next-iT hook-script. Do not edit.\n" > ${COREOS_FILES_PATH}/${vmid}.yaml
	echo -e "variant: fcos\nversion: 1.1.0" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo -e "# user\npasswd:\n  users:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	ciuser="$(qm cloudinit dump ${vmid} user 2> /dev/null | grep ^user: | awk '{print $NF}')"
	echo "    - name: \"${ciuser:-admin}\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      nexts: \"next-iT CoreOS Administrator\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      password_hash: '${cipasswd}'" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo '      groups: [ "sudo", "docker", "adm", "wheel", "systemd-journal" ]' >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo '      ssh_authorized_keys:' >> ${COREOS_FILES_PATH}/${vmid}.yaml
	qm cloudinit dump ${vmid} user | ${YQ} - 'ssh_authorized_keys[*]' | sed -e 's/^/        - "/' -e 's/$/"/' >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "[done]"

	echo -n "Fedora CoreOS: Generate yaml hostname block... "
	hostname="$(qm cloudinit dump ${vmid} user | ${YQ} - 'hostname' 2> /dev/null)"
	echo -e "# network\nstorage:\n  files:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "    - path: /etc/hostname" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      mode: 0644" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	# Convert hostname to lowercase using bash-specific feature
	echo -e "          ${hostname,,}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml 
	echo "[done]"
	
	echo -n "Fedora CoreOS: Generate yaml network block... "
	netcards="$(qm cloudinit dump ${vmid} network | ${YQ} - 'config[*].name' 2> /dev/null | wc -l)"
	nameservers="$(qm cloudinit dump ${vmid} network | ${YQ} - "config[${netcards}].address[*]" | paste -s -d ";" -)"
	searchdomain="$(qm cloudinit dump ${vmid} network | ${YQ} - "config[${netcards}].search[*]" | paste -s -d ";" -)"
	for (( i=0; i<${netcards}; i++ ))
	do
		ipv4="" netmask="" gw="" macaddr="" # reset on each run
		ipv4="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].address 2> /dev/null)" || continue # dhcp
		netmask="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].netmask 2> /dev/null)"
		gw="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].gateway 2> /dev/null)" || true # can be empty
		macaddr="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].mac_address 2> /dev/null)"
		# ipv6: TODO

		echo "    - path: /etc/NetworkManager/system-connections/net${i}.nmconnection" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "      mode: 0600" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          [connection]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          type=ethernet" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          id=net${i}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          #interface-name=eth${i}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo -e "\n          [ethernet]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          mac-address=${macaddr}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo -e "\n          [ipv4]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          method=manual" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          addresses=${ipv4}/${netmask}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          gateway=${gw}" >> ${COREOS_FILES_PATH}/${vmid}.yaml 
		echo "          dns=${nameservers}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo -e "          dns-search=${searchdomain}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	done
	echo "[done]"

	[[ -e "${COREOS_TMPLT}" ]]&& {
		echo -n "Fedora CoreOS: Generate other block based on template... "
		cat "${COREOS_TMPLT}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "[done]"
	}

	echo -n "Fedora CoreOS: Generate ignition config... "
	/usr/local/bin/fcos-ct 	--pretty --strict \
				--output ${COREOS_FILES_PATH}/${vmid}.ign \
				${COREOS_FILES_PATH}/${vmid}.yaml 2> /dev/null
	[[ $? -eq 0 ]] || {
		echo "[failed]"
		exit 1
	}
	echo "[done]"

	# save cloudinit instanceid
	echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id

	# check vm config (no args on first boot)
	qm config ${vmid} --current | grep -q ^args || {
		echo -n "Set args com.coreos/config on VM${vmid}... "
		pvesh set /nodes/"$(hostname)"/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null || {
		pvesh set /nodes/$(hostname)/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null || {
			echo "[failed]"
			exit 1
		}
		touch /var/lock/qemu-server/lock-${vmid}.conf

		# hack for reload new ignition file
		echo -e "\nWARNING: New generated Fedora CoreOS ignition settings, we must restart vm..."
		qm stop ${vmid}
		while qm status ${vmid} | grep -q "running"; do
			sleep 1
		done
		qm start ${vmid}&
		exit 1
	}
fi

exit 0
