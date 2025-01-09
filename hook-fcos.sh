#!/bin/bash

# set -e is commented out to allow the script to continue even if some commands fail
#set -e

# output functions
print_ok() {
    echo -e "[OK] $1"
}
print_error() {
    echo -e "[ERROR] $1" >&2
}
print_warn() {
    echo -e "[WARN] $1"
}
print_info() {
    echo -e "[INFO] $1"
}
print_debug() {
    echo -e "[DEBUG] $1"
}
print_success() {
    echo -e "[SUCCESS] $1"
}
 
vmid="$1"
phase="$2"

# global vars
COREOS_TEMPLATE=/opt/fcos-tmplt.yaml
COREOS_FILES_PATH=/etc/pve/next-pve/coreos
YQ_PATH="/usr/local/bin/yq"

mkdir -p "${COREOS_FILES_PATH}"

if ! mkdir -p "${COREOS_FILES_PATH}"; then
    error_exit "Failed to create directory: ${COREOS_FILES_PATH}"
fi

if [[ ! -w "${COREOS_FILES_PATH}" ]]; then
    error_exit "Cannot write to directory: ${COREOS_FILES_PATH}"
fi

# =====================================================================
# functions()
#

error_exit() {
    local message="$1"
    local code="${2:-1}"
    print_error "${message}"
    cleanup
    exit "${code}"
}

cleanup() {
    for file in "${TEMP_FILES[@]}"; do
        rm -f "${file}"
    done
}

version_check() {
    local current="$1"
    local required="$2"
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]} && i<${#ver2[@]}; i++)); do
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        elif ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    return 0
}

setup_butane() {
    local ARCH=x86_64
    local OS=unknown-linux-gnu # Linux
    local DOWNLOAD_URL=https://github.com/coreos/butane/releases/download

    # Fetch the latest version from GitHub API with a timeout and error handling
    local BUTANE_VER=$(curl -s --max-time 10 -H "User-Agent: script" https://api.github.com/repos/coreos/butane/releases/latest | grep '"tag_name":' | sed 's/^v//')
    if [[ $? -ne 0 || -z "${BUTANE_VER}" ]]; then
        print_error "Failed to fetch the latest version of Butane from GitHub"
        # Check if the binary already exists and matches the latest version
        if [[ -x /usr/local/bin/butane ]]; then
            current_version=$(/usr/local/bin/butane --version | awk '{print $NF}')
            if [[ "x${current_version}" == "x${BUTANE_VER}" ]]; then
                return 0
            fi
        fi
    fi

    print_info "Setting up Butane..."
    if [[ -z "${BUTANE_VER}" ]]; then
        BUTANE_VER="0.23.0"  # Fallback version if unable to fetch latest
    fi

    local BUTANE_URL="${DOWNLOAD_URL}/${BUTANE_VER}/butane-${ARCH}-${OS}"
    rm -f /usr/local/bin/butane
    if [[ -x /usr/bin/wget ]]; then
        wget --quiet --show-progress "${BUTANE_URL}" -O /usr/local/bin/butane
    else
        curl --location "${BUTANE_URL}" -o /usr/local/bin/butane
    fi
    chmod 755 /usr/local/bin/butane
}

setup_yq() {
    if [[ -x "${YQ_PATH}" ]]; then
        return 0
    fi

    print_info "Setting up yq..."
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "${YQ_PATH}")"
    
    # Fetch the latest version of yq from GitHub API
    local VER=$(curl -s --max-time 10 "https://api.github.com/repos/mikefarah/yq/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "${VER}" ]]; then
        VER="v4.44.6"  # Fallback version if unable to fetch latest
    fi

    local YQ_URL="https://github.com/mikefarah/yq/releases/download/${VER}/yq_linux_amd64"
    if [[ -x /usr/bin/wget ]]; then
        wget --quiet --show-progress "${YQ_URL}" -O "${YQ_PATH}"
    else
        curl --location "${YQ_URL}" -o "${YQ_PATH}"
    fi

    chmod 755 "${YQ_PATH}"
}

validate_config() {
    local config_file="$1"
    
    if [[ ! -f "${config_file}" ]]; then
        error_exit "Config file ${config_file} not found"
    fi
    
    # Validate YAML syntax
    if ! "${YQ_PATH}" eval '.' "${config_file}" >/dev/null 2>&1; then
        error_exit "Invalid YAML syntax in ${config_file}"
    fi
}

wait_for_pvesh_set() {
    local max_attempts=30
    local attempt=1
    local sleep_time=2
    
    while [[ $attempt -le $max_attempts ]]; do
        print_debug "Attempting pvesh set (attempt $attempt/$max_attempts)"
        if pvesh set /nodes/"$(hostname)"/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /tmp/pvesh.error; then
            rm -f /tmp/pvesh.error
            return 0
        fi
        
        error_output=$(cat /tmp/pvesh.error)
        if [[ "$error_output" == *"trying to acquire lock"* ]] || [[ "$error_output" == *"can't lock file"* ]]; then
            print_info "Waiting for pvesh lock to be released (attempt $attempt/$max_attempts)..."
            sleep $sleep_time
            ((attempt++))
            continue
        fi
        
        # If we get here, it's a different error
        rm -f /tmp/pvesh.error
        return 1
    done
    
    rm -f /tmp/pvesh.error
    return 1
}

# Initialize temp files array
TEMP_FILES=()

# Set up trap for cleanup
trap cleanup EXIT
trap 'print_warn "Script interrupted"; cleanup; exit 1' INT TERM

# Setup yq, a portable command-line YAML processor
# Setup Butane, a tool for generating Fedora CoreOS Ignition configs
setup_yq
setup_butane

if [[ -x /usr/bin/wget ]]; then
    download_command="wget --quiet --show-progress --output-document"
else
    download_command="curl --location --output"
fi

# Get meta information
print_info "Running qm cloudinit dump ${vmid} meta"
meta_output=$(qm cloudinit dump ${vmid} meta)
if [[ $? -ne 0 ]]; then
    error_exit "Failed to dump cloudinit meta"
fi

print_debug "Meta output: ${meta_output}"

# Extract instance_id using grep and awk
instance_id=$(echo "${meta_output}" | grep 'instance-id' | awk '{print $2}')
if [[ -z "${instance_id}" ]]; then
    print_warn "Failed to retrieve instance-id for VM${vmid}"
    if [[ -e ${COREOS_FILES_PATH}/${vmid}.id ]]; then
        stored_instance_id=$(cat ${COREOS_FILES_PATH}/${vmid}.id)
        if [[ "x${instance_id}" != "x${stored_instance_id}" ]]; then
            rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
        fi
    fi
fi

# Check for existing cloudinit config
if [[ -e ${COREOS_FILES_PATH}/${vmid}.id ]] && 
   [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id)" ]]; then
    rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
fi

if [[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]]; then
    print_info "Ignition config already exists"
    exit 0 # already done
fi

# Get user information
print_info "Running qm cloudinit dump ${vmid} user"
user_output=$(qm cloudinit dump ${vmid} user)
if [[ $? -ne 0 ]]; then
    error_exit "Failed to dump cloudinit user for VM${vmid}"
fi

print_debug "User output: ${user_output}"

# Get password
cipasswd=$(echo "${user_output}" | "${YQ_PATH}" eval --exit-status -o json -- '.password // ""' 2> /dev/null)
if [[ $? -ne 0 ]]; then
    error_exit "Failed to retrieve password for VM${vmid}"
fi

print_debug "yq output for password: ${cipasswd}"

if [[ -z "${cipasswd}" ]]; then
    error_exit "Error: Password is empty for VM${vmid}"
fi

# Check if password is set
if [[ "x${cipasswd}" != "x" ]]; then
    VALIDCONFIG=true
fi

# Check if SSH keys are set
if [[ -z "${VALIDCONFIG}" ]]; then
    ssh_keys=$(echo "${user_output}" | "${YQ_PATH}" eval --exit-status -o json -- '.ssh_authorized_keys[]? // []' 2> /dev/null)
    if [[ $? -ne 0 ]]; then
        error_exit "Failed to retrieve SSH keys for VM${vmid}"
    fi
    if [[ "x${ssh_keys}" != "x" ]]; then
        VALIDCONFIG=true
    fi
fi

# If neither password nor SSH keys are set, exit with error
if [[ -z "${VALIDCONFIG}" ]]; then
    error_exit "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
fi

# Begin YAML generation
print_info "Generating YAML configuration"
echo -e "variant: fcos\nversion: 1.1.0" >> ${COREOS_FILES_PATH}/${vmid}.yaml

# Get hostname
hostname="$(echo "${user_output}" | "${YQ_PATH}" eval --exit-status -o json -- '.hostname // "fcos"' 2> /dev/null)"
if [[ $? -ne 0 || -z "${hostname}" ]]; then
    echo "Failed to retrieve hostname for VM${vmid}"
    exit 1
fi

# Get user
ciuser="$(qm cloudinit dump ${vmid} user 2> /dev/null | grep ^user: | awk '{print $NF}')"
if [[ $? -ne 0 || -z "${ciuser}" ]]; then
    error_exit "Failed to retrieve user for VM${vmid}"
fi

# Write user configuration
echo "    - name: \"${ciuser:-admin}\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
echo "      nexts: \"next-iT CoreOS Administrator\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
echo "      password_hash: '${cipasswd}'" >> ${COREOS_FILES_PATH}/${vmid}.yaml
echo '      groups: [ "sudo", "docker", "adm", "wheel", "systemd-journal" ]' >> ${COREOS_FILES_PATH}/${vmid}.yaml
echo '      ssh_authorized_keys:' >> ${COREOS_FILES_PATH}/${vmid}.yaml

echo "${user_output}" | "${YQ_PATH}" eval --exit-status -o json -- '.ssh_authorized_keys[]? // []' | sed -e 's/^/        - "/' -e 's/$/"/' >> ${COREOS_FILES_PATH}/${vmid}.yaml
if [[ $? -ne 0 ]]; then
    error_exit "Failed to retrieve SSH keys for VM${vmid}"
fi

echo >> ${COREOS_FILES_PATH}/${vmid}.yaml
print_success "[done]"

# Network configuration
print_info "Generating network configuration"
echo -e "# network\nstorage:\n  files:" >> ${COREOS_FILES_PATH}/${vmid}.yaml

# Get network configuration
network_output=$(qm cloudinit dump ${vmid} network)
if [[ $? -ne 0 ]]; then
    error_exit "Failed to get network configuration dump"
fi

print_debug "Network output: ${network_output}"

# Get nameservers and search domains from the nameserver config
nameservers=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- '.config[] | select(.type == "nameserver") | .address[]? // []' 2> /dev/null | paste -s -d ";" -)
if [[ $? -ne 0 ]]; then
    print_warn "Failed to retrieve nameservers, using empty value"
    nameservers=""
fi

searchdomain=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- '.config[] | select(.type == "nameserver") | .search[]? // []' 2> /dev/null | paste -s -d ";" -)
if [[ $? -ne 0 ]]; then
    print_warn "Failed to retrieve search domains, using empty value"
    searchdomain=""
fi

# Get network interfaces configuration
# First get count of physical interfaces (excluding nameserver entries)
netcards=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- '.config[] | select(.type != "nameserver") | .[] // []' 2> /dev/null | wc -l)
if [[ $? -ne 0 ]]; then
    print_warn "No network interfaces found"
    netcards=0
fi

# Process each network interface
for ((i=0; i<${netcards}; i++)); do
    ipv4=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- ".config[] | select(.type != \"nameserver\") | .[${i}].subnets[0].address // \"\"" 2> /dev/null) || continue # dhcp
    netmask=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- ".config[] | select(.type != \"nameserver\") | .[${i}].subnets[0].netmask // \"\"" 2> /dev/null)
    gw=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- ".config[] | select(.type != \"nameserver\") | .[${i}].subnets[0].gateway // \"\"" 2> /dev/null) || true # can be empty
    macaddr=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- ".config[] | select(.type != \"nameserver\") | .[${i}].mac_address // \"\"" 2> /dev/null)

   if [[ -z "${ipv4}" || -z "${netmask}" || -z "${macaddr}" ]]; then
        print_warn "Skipping network interface ${i} due to missing configuration"
        continue
    fi
    
    # ipv6: TODO
    
    # Write network interface configuration
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

print_success "[done]"

# Add template if it exists
[[ -e "${COREOS_TEMPLATE}" ]] && {
    print_info -n "Adding template configuration"
    cat "${COREOS_TEMPLATE}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    print_success "[done]"
}

print_info "Generating ignition configuration"
/usr/local/bin/butane  --pretty --strict \
            --output ${COREOS_FILES_PATH}/${vmid}.ign \
            ${COREOS_FILES_PATH}/${vmid}.yaml 2> /dev/null
[[ $? -eq 0 ]] || {
    error_exit "[failed]"
}
print_success "[done]"

if ! mkdir -p "$(dirname /var/lock/qemu-server/lock-${vmid}.conf)"; then
    error_exit "Failed to create lock directory"
fi

touch /var/lock/qemu-server/lock-${vmid}.conf

# Save the cloud-init instance ID to a file for future reference.
# This ensures that the instance ID is preserved across reboots and can be used to detect changes.
print_debug "Setting VM configuration with ignition file: ${COREOS_FILES_PATH}/${vmid}.ign"
echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id

if ! wait_for_pvesh_set; then
    error_output=$(cat /tmp/pvesh.error 2>/dev/null)
    [[ -f /tmp/pvesh.error ]] && rm -f /tmp/pvesh.error
    error_exit "Failed to set VM configuration using pvesh for VM${vmid}. Error: ${error_output}"
fi
rm -f /tmp/pvesh.error

# Restart VM
print_info "\nNOTICE: New Fedora CoreOS ignition settings generated. Restarting VM..."
if ! qm stop ${vmid}; then
    error_exit "Failed to stop VM${vmid}"
fi

if ! qm start ${vmid}; then
    error_exit "Failed to start VM${vmid}"
fi

print_ok "Successfully completed CoreOS configuration for VM${vmid}"
exit 0
