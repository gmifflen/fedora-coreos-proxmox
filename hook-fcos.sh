#!/bin/bash

# set -e is commented out to allow the script to continue even if some commands fail
#set -e
 
vmid="$1"
phase="$2"

# global vars
COREOS_TEMPLATE=/opt/fcos-tmplt.yaml
COREOS_FILES_PATH=/etc/pve/next-pve/coreos
YQ_PATH="/usr/local/bin/yq"

# =====================================================================
# functions()
#
setup_fcoreosct()
{
    local ARCH=x86_64
    local OS=unknown-linux-gnu # Linux
    local DOWNLOAD_URL=https://github.com/coreos/fcct/releases/download

    # Fetch the latest version from GitHub API with a timeout and error handling
    local CT_VER=$(curl -s --max-time 10 https://api.github.com/repos/coreos/fcct/releases/latest | jq -r .tag_name | sed 's/^v//')
    if [[ $? -ne 0 || -z "${CT_VER}" ]]; then
        echo "Error: Failed to fetch the latest version of fcct from GitHub"
        # Check if the binary already exists and matches the latest version
        if [[ -x /usr/local/bin/fcos-ct ]]; then
            current_version=$(/usr/local/bin/fcos-ct --version | awk '{print $NF}')
            if [[ "x${current_version}" == "x${CT_VER}" ]]; then
                return 0
            fi
        fi
    fi

    # Check if the binary already exists and matches the latest version
    [[ -x /usr/local/bin/fcos-ct ]] && [[ "x$(/usr/local/bin/fcos-ct --version | awk '{print $NF}')" == "x${CT_VER}" ]] && return 0

    echo "Setup Fedora CoreOS config transpiler..."
    rm -f /usr/local/bin/fcos-ct
    wget --quiet --show-progress ${DOWNLOAD_URL}/v${CT_VER}/fcct-${ARCH}-${OS} -O /usr/local/bin/fcos-ct
    chmod 755 /usr/local/bin/fcos-ct
}

setup_yq()
{
    # Fetch the latest version of yq from GitHub API
    local VER=$(curl --silent "https://api.github.com/repos/mikefarah/yq/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    download_command=$([[ -x /usr/bin/wget ]] && echo "wget --quiet --show-progress --output-document" || echo "curl --location --output")
    [[ -x /usr/bin/wget ]] && download_command="wget --quiet --show-progress --output-document" || download_command="curl --location --output"
    [[ -x /usr/local/bin/yq ]] && [[ "x$(/usr/local/bin/yq --version | awk '{print $NF}')" == "x${VER}" ]] && return 0
    echo "Setup yaml parser tools yq..."
    rm -f /usr/local/bin/yq
    ${download_command} /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${VER}/yq_linux_amd64
    chmod 755 /usr/local/bin/yq
}

setup_yq
setup_fcoreosct

if [[ -x /usr/bin/wget ]]; then
    download_command="wget --quiet --show-progress --output-document"
else
    download_command="curl --location --output"
fi

# Debugging: Print the output of the qm cloudinit dump command
echo "Running qm cloudinit dump ${vmid} meta"
meta_output=$(qm cloudinit dump ${vmid} meta)
echo "Meta output: ${meta_output}"

# Extract instance_id using grep and awk
instance_id=$(echo "${meta_output}" | grep 'instance-id' | awk '{print $2}')
if [[ -z "${instance_id}" ]]; then
    echo "Error: Failed to retrieve instance-id for VM${vmid}"
    exit 1
fi

if [[ "${phase}" == "pre-start" ]]; then
    if [[ -e ${COREOS_FILES_PATH}/${vmid}.id ]]; then
        stored_instance_id=$(cat ${COREOS_FILES_PATH}/${vmid}.id)
        if [[ "x${instance_id}" != "x${stored_instance_id}" ]]; then
            rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
        fi
    fi
    # same cloudinit config ?
    [[ -e ${COREOS_FILES_PATH}/${vmid}.id ]] && [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id)" ]] && {
        rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
    }
    [[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]] && exit 0 # already done

    echo "Running qm cloudinit dump ${vmid} user"
    user_output=$(qm cloudinit dump ${vmid} user)
    echo "User output: ${user_output}"
    cipasswd=$(echo "${user_output}" | "${YQ_PATH}" eval --exit-status -o json -- 'password' 2> /dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to retrieve password for VM${vmid}"
        exit 1
    fi
    if [[ -z "${cipasswd}" ]]; then
        echo "Error: Password is empty for VM${vmid}"
        exit 1
    fi
    # Check if password is set
    if [[ "x${cipasswd}" != "x" ]]; then
        VALIDCONFIG=true
    fi

    # Check if SSH keys are set
    if [[ -z "${VALIDCONFIG}" ]]; then
        ssh_keys=$(qm cloudinit dump ${vmid} user | "${YQ_PATH}" eval --exit-status -o json -- 'ssh_authorized_keys[*]')
        if [[ "x${ssh_keys}" != "x" ]]; then
            VALIDCONFIG=true
        fi
    fi

    # If neither password nor SSH keys are set, exit with error
    if [[ -z "${VALIDCONFIG}" ]]; then
        echo "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
        exit 1
    fi
    ${VALIDCONFIG:-false} || {
        echo "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
        exit 1
    }

    echo -n "Fedora CoreOS: Generate yaml users block... "
    echo -e "# This file is managed by next-iT hook-script. Do not edit.\n" > ${COREOS_FILES_PATH}/${vmid}.yaml
    echo -e "variant: fcos\nversion: 1.1.0" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    hostname="$(qm cloudinit dump ${vmid} user | "${YQ_PATH}" eval --exit-status -o json -- 'hostname' 2> /dev/null)"
    if [[ $? -ne 0 || -z "${hostname}" ]]; then
        echo "Error: Failed to retrieve hostname for VM${vmid}"
        exit 1
    fi
    ciuser="$(qm cloudinit dump ${vmid} user 2> /dev/null | grep ^user: | awk '{print $NF}')"
    echo "    - name: \"${ciuser:-admin}\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo "      nexts: \"next-iT CoreOS Administrator\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo "      password_hash: '${cipasswd}'" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo '      groups: [ "sudo", "docker", "adm", "wheel", "systemd-journal" ]' >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo '      ssh_authorized_keys:' >> ${COREOS_FILES_PATH}/${vmid}.yaml
    qm cloudinit dump ${vmid} user | "${YQ_PATH}" eval --exit-status -o json -- 'ssh_authorized_keys[*]' | sed -e 's/^/        - "/' -e 's/$/"/' >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo "[done]"

    echo -n "Fedora CoreOS: Generate yaml hostname block... "
    hostname="$(qm cloudinit dump ${vmid} user | "${YQ_PATH}" eval --exit-status -o json -- 'hostname' 2> /dev/null)"
    echo -e "# network\nstorage:\n  files:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo "    - path: /etc/hostname" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo "      mode: 0644" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    # Retrieve network card names
    netcards="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- 'config[*].name' 2> /dev/null | wc -l)"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to retrieve network configuration for VM${vmid}"
        exit 1
    fi
    nameservers="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- "config[${netcards}].address[*]" | paste -s -d ";" -)"
    if [[ $? -ne 0 || -z "${nameservers}" ]]; then
        echo "Error: Failed to retrieve nameservers for VM${vmid}"
        exit 1
    fi
    searchdomain="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- "config[${netcards}].search[*]" | paste -s -d ";" -)"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to retrieve search domain for VM${vmid}"
        exit 1
    fi
    echo -n "Fedora CoreOS: Generate yaml network block... "
    netcards="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- 'config[*].name' 2> /dev/null | wc -l)"
    nameservers="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- "config[${netcards}].address[*]" | paste -s -d ";" -)"
    ipv4="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].subnets[0].address 2> /dev/null)"
    if [[ $? -ne 0 || -z "${ipv4}" ]]; then
        echo "Error: Failed to retrieve IPv4 address for network interface ${i} of VM${vmid}"
        continue
    fi
    netmask="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].subnets[0].netmask 2> /dev/null)"
    if [[ $? -ne 0 || -z "${netmask}" ]]; then
        echo "Error: Failed to retrieve netmask for VM${vmid}"
        exit 1
    fi
    gw="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].subnets[0].gateway 2> /dev/null)"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to retrieve gateway for network interface ${i} of VM${vmid}"
        gw="" # Set gw to an empty string if retrieval fails
    fi
    macaddr="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].mac_address 2> /dev/null)"
    if [[ $? -ne 0 || -z "${macaddr}" ]]; then
        echo "Error: Failed to retrieve MAC address for network interface ${i} of VM${vmid}"
        continue
    fi
    for ((i=0; i<${netcards}; i++)); do
        ipv4="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].subnets[0].address 2> /dev/null)" || continue # dhcp
        netmask="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].subnets[0].netmask 2> /dev/null)"
        gw="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].subnets[0].gateway 2> /dev/null)" || true # can be empty
        macaddr="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].mac_address 2> /dev/null)"
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

    [[ -e "${COREOS_TEMPLATE}" ]] && {
        echo -n "Fedora CoreOS: Generate other block based on template... "
        cat "${COREOS_TEMPLATE}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
        echo "[done]"
    }

    echo -n "Fedora CoreOS: Generate ignition config... "
    /usr/local/bin/fcos-ct  --pretty --strict \
                --output ${COREOS_FILES_PATH}/${vmid}.ign \
                ${COREOS_FILES_PATH}/${vmid}.yaml 2> /dev/null
    [[ $? -eq 0 ]] || {
        echo "[failed]"
        exit 1
    }
    echo "[done]"
    # Save the cloud-init instance ID to a file for future reference.
    # This ensures that the instance ID is preserved across reboots and can be used to detect changes.
    echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id
    if ! pvesh set /nodes/"$(hostname)"/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null; then
        echo "[failed]"
        exit 1
    fi
    pvesh set /nodes/$(hostname)/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null || {
        echo "[failed]"
        exit 1
    }
    touch /var/lock/qemu-server/lock-${vmid}.conf

    echo -e "\nNOTICE: New Fedora CoreOS ignition settings generated. Restarting VM..."
    qm stop ${vmid}
    while qm status ${vmid} | grep -q "running"; do
        sleep 1
    done
    qm start ${vmid}&
    exit 1
fi

exit 0