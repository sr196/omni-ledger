#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." >&2
   exit 1
fi

MODULES_FILE="/etc/modules"
VFIO_CONF="/etc/modprobe.d/vfio.conf"

VFIO_MODULES=(
    "vfio"
    "vfio_iommu_type1"
    "vfio_pci"
    "vfio_virqfd"
)

echo "Configuring VFIO modules in $MODULES_FILE..."

# Backup the file if it exists
if [[ -f "$MODULES_FILE" ]]; then
    echo "Backing up $MODULES_FILE..."
    cp "$MODULES_FILE" "${MODULES_FILE}.bak_$(date +%Y%m%d%H%M%S)"
else
    touch "$MODULES_FILE"
fi

# Add each module if it's not already present
for mod in "${VFIO_MODULES[@]}"; do
    if grep -q "^\s*${mod}\b" "$MODULES_FILE"; then
        echo "Module '$mod' is already present."
    else
        echo "Adding '$mod' to $MODULES_FILE..."
        echo "$mod" >> "$MODULES_FILE"
    fi
done

echo ""
echo "Detecting NVIDIA Vendor:Device IDs..."

# Check if lspci is available
if ! command -v lspci &> /dev/null; then
    echo "Error: lspci command not found. Please install pciutils." >&2
    exit 1
fi

# Extract the Vendor:Device IDs for NVIDIA devices
# Expected lspci output format snippet: NVIDIA Corporation Device [10de:2520]
# We grep for NVIDIA, extract the [xxxx:xxxx] pattern, remove brackets, and join with commas
NVIDIA_IDS=$(lspci -nn | grep -i nvidia | grep -Eo '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' | tr -d '[]' | paste -sd ',' - || true)

if [[ -z "$NVIDIA_IDS" ]]; then
    echo "Warning: No NVIDIA devices found on this system using lspci."
    echo "You will need to manually configure the IDs in $VFIO_CONF later."
else
    echo "Found NVIDIA IDs: $NVIDIA_IDS"
    echo "Configuring $VFIO_CONF..."
    
    mkdir -p /etc/modprobe.d/
    
    if [[ -f "$VFIO_CONF" ]]; then
        echo "Backing up $VFIO_CONF..."
        cp "$VFIO_CONF" "${VFIO_CONF}.bak_$(date +%Y%m%d%H%M%S)"
    fi
    
    echo "options vfio-pci ids=$NVIDIA_IDS" > "$VFIO_CONF"
    echo "Successfully updated $VFIO_CONF."
fi

echo ""
echo "Updating initramfs kernel images (this may take a minute)..."
if update-initramfs -u -k all; then
    echo "update-initramfs completed successfully (exit code 0)."
else
    echo "Error: update-initramfs failed." >&2
    exit 1
fi

echo ""
echo "=========================================================================="
echo "VFIO framework configuration is complete. A reboot is required."
echo ""
echo "Acceptance Criteria (Post-reboot):"
echo "1. Verify VFIO modules are loaded:"
echo "   lsmod | grep vfio"
echo ""
echo "2. Validate that the GPU sits in a dedicated IOMMU group:"
echo "   for d in /sys/kernel/iommu_groups/*/devices/*; do n=\${d#*/iommu_groups/*}; n=\${n%%/*}; printf 'IOMMU Group %s ' \"\$n\"; lspci -nns \"\${d##*/}\"; done | grep -i nvidia"
echo ""
echo "3. Verify Kernel driver in use is vfio-pci (for NVIDIA devices):"
echo "   lspci -nnk -d 10de:"
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
