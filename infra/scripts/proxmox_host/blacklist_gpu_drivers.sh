#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." >&2
   exit 1
fi

BLACKLIST_FILE="/etc/modprobe.d/pve-blacklist.conf"
DRIVERS=("nouveau" "nvidia" "nvidiafb" "nvidia_drm" "radeon")

echo "Configuring GPU driver blacklist in $BLACKLIST_FILE..."

# Ensure the modprobe.d directory exists
mkdir -p /etc/modprobe.d/

# Create the file if it does not exist
if [[ ! -f "$BLACKLIST_FILE" ]]; then
    touch "$BLACKLIST_FILE"
fi

# Backup the file
echo "Backing up $BLACKLIST_FILE..."
cp "$BLACKLIST_FILE" "${BLACKLIST_FILE}.bak_$(date +%Y%m%d%H%M%S)"

# Loop through each driver and add it if not already present
for driver in "${DRIVERS[@]}"; do
    if grep -q "^\s*blacklist\s\+${driver}\b" "$BLACKLIST_FILE"; then
        echo "Driver '$driver' is already blacklisted."
    else
        echo "Blacklisting '$driver'..."
        echo "blacklist $driver" >> "$BLACKLIST_FILE"
    fi
done

echo "Successfully updated $BLACKLIST_FILE."

echo "Updating initramfs kernel images (this may take a minute)..."
if update-initramfs -u -k all; then
    echo "update-initramfs completed successfully (exit code 0)."
else
    echo "Error: update-initramfs failed." >&2
    exit 1
fi

echo ""
echo "=========================================================================="
echo "GPU driver blacklist configuration is complete. A reboot is required."
echo ""
echo "After reboot, you can verify the configuration by running:"
echo "  lsmod | grep -E \"nouveau|nvidia|radeon\""
echo ""
echo "Expected output: empty (no host GPU drivers should be active)."
echo "=========================================================================="
echo ""

read -p "Would you like to reboot the host now? [y/N] " -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    reboot
else
    echo "Please remember to reboot the host manually later to apply the changes."
fi
