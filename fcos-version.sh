#!/bin/bash

# URL to fetch the stable release JSON
URL="https://builds.coreos.fedoraproject.org/streams/stable.json"

# Fetch the JSON data and extract the stable release number using jq
STABLE_RELEASE=$(curl -s $URL | jq -r '.architectures.x86_64.artifacts.qemu.release')

# Print the stable release number
echo "Current stable release number: $STABLE_RELEASE"
