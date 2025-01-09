#!/bin/bash

# set -e is commented out to allow the script to continue even if some commands fail
#set -e

# ANSI color codes
export COLOUR_RED='\033[0;31m'
export COLOUR_GREEN='\033[0;32m'
export COLOUR_YELLOW='\033[1;33m'
export COLOUR_BLUE='\033[0;34m'
export COLOUR_MAGENTA='\033[0;35m'
export COLOUR_CYAN='\033[0;36m'
export COLOUR_WHITE='\033[1;37m'
export COLOUR_RESET='\033[0m'

# status colours
export COLOUR_OK="${COLOUR_GREEN}"
export COLOUR_WARN="${COLOUR_YELLOW}"
export COLOUR_ERROR="${COLOUR_RED}"
export COLOUR_INFO="${COLOUR_CYAN}"
export COLOUR_DEBUG="${COLOUR_MAGENTA}"

# output functions
print_ok() {
    echo -e "${COLOUR_OK}[OK]${COLOUR_RESET} $1"
}
print_error() {
    echo -e "${COLOUR_ERROR}[ERROR]${COLOUR_RESET} $1" >&2
}
print_warn() {
    echo -e "${COLOUR_WARN}[WARN]${COLOUR_RESET} $1"
}
print_info() {
    echo -e "${COLOUR_INFO}[INFO]${COLOUR_RESET} $1"
}
print_debug() {
    echo -e "${COLOUR_DEBUG}[DEBUG]${COLOUR_RESET} $1"
}
 
vmid="$1"
phase="$2"

# global vars
COREOS_TEMPLATE=/opt/fcos-tmplt.yaml
COREOS_FILES_PATH=/etc/pve/next-pve/coreos
YQ_PATH="/usr/local/bin/yq"
LOCK_FILE="/var/lock/coreos-hook-${vmid}.lock"

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
    rm -f "${LOCK_FILE}"
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
    local BUTANE_VER=$(curl -s --max-time 10 -H "User-Agent: script" https://api.github.com/repos/coreos/butane/releases/latest | yq -r .tag_name | sed 's/^v//')
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

    # Check if the binary already exists and matches the latest version
    if [[ -x /usr/local/bin/butane ]]; then
        current_version=$(/usr/local/bin/butane --version | awk '{print $NF}')
        if [[ "x${current_version}" == "x${BUTANE_VER}" ]]; then
            return 0
        fi
    fi

    print_info "Setting up Butane..."
    rm -f /usr/local/bin/butane
    download_command=$([[ -x /usr/bin/wget ]] && echo "wget --quiet --show-progress --output-document" || echo "curl --location --output")
    ${download_command} ${DOWNLOAD_URL}/v${BUTANE_VER}/butane-${ARCH}-${OS} -O /usr/local/bin/butane
    chmod 755 /usr/local/bin/butane
}

setup_yq() {
    [[ -x /usr/local/bin/yq ]] && return 0
    
    # Fetch the latest version of yq from GitHub API
    local VER=$(curl -s --max-time 10 "https://api.github.com/repos/mikefarah/yq/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    download_command=$([[ -x /usr/bin/wget ]] && echo "wget --quiet --show-progress --output-document" || echo "curl --location --output")
    
    [[ -x /usr/local/bin/yq ]] && [[ "x$(/usr/local/bin/yq --version | awk '{print $NF}')" == "x${VER}" ]] && return 0

    print_info "Setting up yq..."
    rm -f /usr/local/bin/yq
    ${download_command} /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${VER}/yq_linux_amd64
    chmod 755 /usr/local/bin/yq
}

validate_config() {
    local config_file="$1"
    
    if [[ ! -f "${config_file}" ]]; then
        error_exit "Config file ${config_file} not found"
    }
    
    # Validate YAML syntax
    if ! "${YQ_PATH}" eval '.' "${config_file}" >/dev/null 2>&1; then
        error_exit "Invalid YAML syntax in ${config_file}"
    }
}

# Initialize temp files array
TEMP_FILES=()

# Check for existing lock
if [ -e "${LOCK_FILE}" ] && kill -0 $(cat "${LOCK_FILE}") 2>/dev/null; then
    print_error "Script is already running"
    exit 1
fi

# Create lock file
echo $$ > "${LOCK_FILE}"

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

network_output=$(qm cloudinit dump ${vmid} network)
netcards=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- '.config[]?.name // []' 2> /dev/null | wc -l)
if [[ $? -ne 0 ]]; then
    error_exit "Failed to retrieve network configuration for VM${vmid}"
fi

nameservers="$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- "config[${netcards}].address[]? // []" | paste -s -d ";" -)"
searchdomain="$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json -- "config[${netcards}].search[]? // []" | paste -s -d ";" -)"

# Process each network interface
for ((i=0; i<${netcards}; i++)); do
    ipv4=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json ".config[${i}].subnets[0].address // \"\"" 2> /dev/null) || continue # dhcp
    netmask=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json ".config[${i}].subnets[0].netmask // \"\"" 2> /dev/null)
    gw=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json ".config[${i}].subnets[0].gateway // \"\"" 2> /dev/null) || true # can be empty
    macaddr=$(echo "${network_output}" | "${YQ_PATH}" eval --exit-status -o json ".config[${i}].mac_address // \"\"" 2> /dev/null)

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

# Save the cloud-init instance ID to a file for future reference.
# This ensures that the instance ID is preserved across reboots and can be used to detect changes.
echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id
if ! pvesh set /nodes/"$(hostname)"/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null; then
    error_exit "Failed to set VM configuration using pvesh for VM${vmid}"
fi

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
