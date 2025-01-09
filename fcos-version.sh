#!/bin/bash

source ./colours.sh

# URL to fetch the stable release JSON
RELEASE_JSON="https://builds.coreos.fedoraproject.org/streams/stable.json"
# Fetch the JSON data and extract the stable release number using jq
VERSION=$(curl -s $RELEASE_JSON | jq -r '.architectures.x86_64.artifacts.qemu.release')
if [ $? -ne 0 ]; then
    print_error "Failed to fetch the stable release JSON from $RELEASE_JSON"
    exit 1
fi

# Print the stable release number
print_info "Current stable release number: $VERSION"
