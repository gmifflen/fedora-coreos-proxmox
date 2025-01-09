#!/bin/bash

source ./colours.sh

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
setup_butane() {
    local ARCH=x86_64
    local OS=unknown-linux-gnu # Linux
    local DOWNLOAD_URL=https://github.com/coreos/butane/releases/download

    # Fetch the latest version from GitHub API with a timeout and error handling
    local BUTANE_VER=$(curl -s --max-time 10 -H "User-Agent: script" https://api.github.com/repos/coreos/butane/releases/latest | jq -r .tag_name | sed 's/^v//')
    if [[ $? -ne 0 || -z "${BUTANE_VER}" ]]; then
        print_error "Error: Failed to fetch the latest version of Butane from GitHub"
        # Check if the binary already exists and matches the latest version
        if [[ -x /usr/local/bin/butane ]]; then
            current_version=$(/usr/local/bin/butane --version | awk '{print $NF}')
            if [[ "x${current_version}" == "x${BUTANE_VER}" ]]; then
                return 0
            fi
        fi
    fi

    # Check if the binary already exists and matches the latest version
    if [[ -x /usr/local/bin/butane ]]; then
        current_version=$(/usr/local/bin/butane --version | awk '{print $NF}')
        if [[ "x${current_version}" == "x${BUTANE_VER}" ]]; then
            return 0
        fi
    fi

    print_info "Setup Butane..."
    rm -f /usr/local/bin/butane
    wget --quiet --show-progress ${DOWNLOAD_URL}/v${BUTANE_VER}/butane-${ARCH}-${OS} -O /usr/local/bin/butane
    chmod 755 /usr/local/bin/butane
}

setup_yq() {
    [[ -x /usr/local/bin/yq ]] && return 0
    # Fetch the latest version of yq from GitHub API
    local VER=$(curl --silent "https://api.github.com/repos/mikefarah/yq/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    download_command=$([[ -x /usr/bin/wget ]] && echo "wget --quiet --show-progress --output-document" || echo "curl --location --output")
    [[ -x /usr/local/bin/yq ]] && [[ "x$(/usr/local/bin/yq --version | awk '{print $NF}')" == "x${VER}" ]] && return 0
    rm -f /usr/local/bin/yq
    ${download_command} /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${VER}/yq_linux_amd64
    chmod 755 /usr/local/bin/yq
}

# Setup yq, a portable command-line YAML processor
setup_yq

# Setup Butane, a tool for generating Fedora CoreOS Ignition configs
setup_butane

if [[ -x /usr/bin/wget ]]; then
    download_command="wget --quiet --show-progress --output-document"
else
    download_command="curl --location --output"
fi

meta_output=$(qm cloudinit dump ${vmid} meta)
if [[ $? -ne 0 ]]; then
    print_error "Error: yq command failed"
    exit 1
fi
print_debug "Running qm cloudinit dump ${vmid} meta"
meta_output=$(qm cloudinit dump ${vmid} meta)
print_debug "Meta output: ${meta_output}"

# Extract instance_id using grep and awk
instance_id=$(echo "${meta_output}" | grep 'instance-id' | awk '{print $2}')
if [[ -z "${instance_id}" ]]; then
    print_error "Error: Failed to retrieve instance-id for VM${vmid}"
    if [[ -e ${COREOS_FILES_PATH}/${vmid}.id ]]; then
        stored_instance_id=$(cat ${COREOS_FILES_PATH}/${vmid}.id)
        if [[ "x${instance_id}" != "x${stored_instance_id}" ]]; then
            rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
        fi
    fi
fi

# same cloudinit config ?
if [[ -e ${COREOS_FILES_PATH}/${vmid}.id ]] && 
   [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id)" ]]; then
    rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
fi

if [[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]]; then
    exit 0 # already done
fi

user_output=$(qm cloudinit dump ${vmid} user)
if [[ $? -ne 0 ]]; then
    print_error "Error: Failed to dump cloudinit user for VM${vmid}"
    exit 1
fi
print_debug "Running qm cloudinit dump ${vmid} user"
user_output=$(qm cloudinit dump ${vmid} user)
if [[ $? -ne 0 ]]; then
    print_error "Error: Failed to dump cloudinit user for VM${vmid}"
    exit 1
fi
print_debug "User output: ${user_output}"
    
cipasswd=$(echo "${user_output}" | "${YQ_PATH}" eval --exit-status -o json -- 'password' 2> /dev/null)
if [[ $? -ne 0 ]]; then
    print_error "Error: Failed to retrieve password for VM${vmid}"
    exit 1
fi
print_debug "yq output for password: ${cipasswd}"
if [[ -z "${cipasswd}" ]]; then
    print_error "Error: Password is empty for VM${vmid}"
    exit 1
fi

# Check if password is set
if [[ "x${cipasswd}" != "x" ]]; then
    VALIDCONFIG=true
fi

# Check if SSH keys are set
if [[ -z "${VALIDCONFIG}" ]]; then
    ssh_keys=$(qm cloudinit dump ${vmid} user | "${YQ_PATH}" eval --exit-status -o json -- 'ssh_authorized_keys[*]' 2> /dev/null)
    if [[ $? -ne 0 ]]; then
        print_error "Error: Failed to retrieve SSH keys for VM${vmid}"
        exit 1
    fi
    if [[ "x${ssh_keys}" != "x" ]]; then
        VALIDCONFIG=true
    fi
fi

# If neither password nor SSH keys are set, exit with error
if [[ -z "${VALIDCONFIG}" ]]; then
    print_failure "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
    exit 1
fi

hostname="$(qm cloudinit dump ${vmid} user | "${YQ_PATH}" eval --exit-status -o json -- 'hostname' 2> /dev/null)"
if [[ $? -ne 0 || -z "${hostname}" ]]; then
    print_error "Error: Failed to retrieve hostname for VM${vmid}"
    exit 1
fi

print_info "variant: fcos\nversion: 1.1.0" >> ${COREOS_FILES_PATH}/${vmid}.yaml
hostname="$(qm cloudinit dump ${vmid} user | "${YQ_PATH}" eval --exit-status -o json -- 'hostname' 2> /dev/null)"
if [[ $? -ne 0 || -z "${hostname}" ]]; then
    print_error "Error: Failed to retrieve hostname for VM${vmid}"
    exit 1
fi

ciuser="$(qm cloudinit dump ${vmid} user 2> /dev/null | grep ^user: | awk '{print $NF}')"
if [[ $? -ne 0 || -z "${ciuser}" ]]; then
    print_error "Error: Failed to retrieve user for VM${vmid}"
    exit 1
fi

print_info "    - name: \"${ciuser:-admin}\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
print_info "      nexts: \"next-iT CoreOS Administrator\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
print_info "      password_hash: '${cipasswd}'" >> ${COREOS_FILES_PATH}/${vmid}.yaml
print_info '      groups: [ "sudo", "docker", "adm", "wheel", "systemd-journal" ]' >> ${COREOS_FILES_PATH}/${vmid}.yaml
print_info '      ssh_authorized_keys:' >> ${COREOS_FILES_PATH}/${vmid}.yaml
qm cloudinit dump ${vmid} user | "${YQ_PATH}" eval --exit-status -o json -- 'ssh_authorized_keys[*]' | sed -e 's/^/        - "/' -e 's/$/"/' >> ${COREOS_FILES_PATH}/${vmid}.yaml
if [[ $? -ne 0 ]]; then
    print_error "Error: Failed to retrieve SSH keys for VM${vmid}"
    exit 1
fi
print_info >> ${COREOS_FILES_PATH}/${vmid}.yaml
print_ok "[done]"

print_status 0 "Fedora CoreOS: Generate yaml hostname block... "
hostname="$(qm cloudinit dump ${vmid} user | "${YQ_PATH}" eval --exit-status -o json -- 'hostname' 2> /dev/null)"
print_info "# network\nstorage:\n  files:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
netcards_output=$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- 'config[*].name' 2> /dev/null)
if [[ $? -ne 0 ]]; then
    print_error "Error: Failed to retrieve network card names for VM${vmid}"
    exit 1
fi

netcards="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- 'config[*].name' 2> /dev/null | wc -l)"
if [[ $? -ne 0 ]]; then
    print_error "Error: Failed to retrieve network configuration for VM${vmid}"
    exit 1
fi

nameservers="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- "config[${netcards}].address[*]" | paste -s -d ";" -)"
if [[ $? -ne 0 || -z "${nameservers}" ]]; then
    print_error "Error: Failed to retrieve nameservers for VM${vmid}"
    exit 1
fi

searchdomain="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- "config[${netcards}].search[*]" | paste -s -d ";" -)"
if [[ $? -ne 0 ]]; then
    print_error "Error: Failed to retrieve search domain for VM${vmid}"
    exit 1
fi

print_status 0 "Fedora CoreOS: Generate yaml network block... "
netcards="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- 'config[*].name' 2> /dev/null | wc -l)"
for ((i=0; i<${netcards}; i++)); do
    ipv4="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].subnets[0].address 2> /dev/null)" || continue # dhcp
    netmask="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].subnets[0].netmask 2> /dev/null)"
    gw="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].subnets[0].gateway 2> /dev/null)" || true # can be empty
    macaddr="$(qm cloudinit dump ${vmid} network | "${YQ_PATH}" eval --exit-status -o json -- config[${i}].mac_address 2> /dev/null)"
    # ipv6: TODO
    if [[ $? -ne 0 || -z "${ipv4}" ]]; then
        print_error "Error: Failed to retrieve IPv4 address for network interface ${i} of VM${vmid}"
        continue
    fi
    if [[ $? -ne 0 || -z "${netmask}" ]]; then
        print_error "Error: Failed to retrieve netmask for VM${vmid}"
        exit 1
    fi
    if [[ $? -ne 0 ]]; then
        print_error "Error: Failed to retrieve gateway for network interface ${i} of VM${vmid}"
        gw="" # Set gw to an empty string if retrieval fails
    fi
    if [[ $? -ne 0 || -z "${macaddr}" ]]; then
        print_error "Error: Failed to retrieve MAC address for network interface ${i} of VM${vmid}"
        continue
    fi

    print_info "    - path: /etc/NetworkManager/system-connections/net${i}.nmconnection" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "      mode: 0600" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "          [connection]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "          type=ethernet" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "          id=net${i}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "          #interface-name=eth${i}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "\n          [ethernet]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "          mac-address=${macaddr}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "\n          [ipv4]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "          method=manual" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "          addresses=${ipv4}/${netmask}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "          gateway=${gw}" >> ${COREOS_FILES_PATH}/${vmid}.yaml 
    print_info "          dns=${nameservers}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_info "          dns-search=${searchdomain}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
done
print_ok "[done]"

[[ -e "${COREOS_TEMPLATE}" ]] && {
    print_status 0 "Fedora CoreOS: Generate other block based on template... "
    cat "${COREOS_TEMPLATE}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_ok "[done]"
}

print_status 0 "Fedora CoreOS: Generate ignition config... "
/usr/local/bin/butane  --pretty --strict \
            --output ${COREOS_FILES_PATH}/${vmid}.ign \
            ${COREOS_FILES_PATH}/${vmid}.yaml 2> /dev/null
[[ $? -eq 0 ]] || {
    print_error "[failed]"
    exit 1
}
print_ok "[done]"

# Save the cloud-init instance ID to a file for future reference.
# This ensures that the instance ID is preserved across reboots and can be used to detect changes.
echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id
if ! pvesh set /nodes/"$(hostname)"/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null; then
    print_error "Error: Failed to set VM configuration using pvesh for VM${vmid}"
    exit 1
fi

touch /var/lock/qemu-server/lock-${vmid}.conf

print_success "\nNOTICE: New Fedora CoreOS ignition settings generated. Restarting VM..."
if ! qm stop ${vmid}; then
    echo "Error: Failed to stop VM${vmid}"
    exit 1
fi
qm start ${vmid}
if [[ $? -ne 0 ]]; then
    print_error "Error: Failed to start VM${vmid}"
    exit 1
fi

exit 0
