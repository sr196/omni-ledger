#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." >&2
   exit 1
fi

GRUB_FILE="/etc/default/grub"
# Parameters to append
IOMMU_FLAGS="intel_iommu=on iommu=pt"

echo "Checking $GRUB_FILE for IOMMU configuration..."

if [[ ! -f "$GRUB_FILE" ]]; then
    echo "Error: $GRUB_FILE does not exist." >&2
    exit 1
fi

# Check if flags are already present
if grep -q "intel_iommu=on" "$GRUB_FILE" && grep -q "iommu=pt" "$GRUB_FILE"; then
    echo "IOMMU flags are already present in $GRUB_FILE."
else
    echo "Backing up $GRUB_FILE..."
    cp "$GRUB_FILE" "${GRUB_FILE}.bak_$(date +%Y%m%d%H%M%S)"

    echo "Appending IOMMU flags to GRUB_CMDLINE_LINUX_DEFAULT..."
    # Use sed to add the flags inside the quotes of GRUB_CMDLINE_LINUX_DEFAULT
    # This handles cases where there might be existing parameters or it's empty
    sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 $IOMMU_FLAGS\"/" "$GRUB_FILE"
    
    echo "Successfully updated $GRUB_FILE."
fi

echo "Regenerating GRUB bootloader configuration..."
if update-grub; then
    echo "update-grub completed successfully (exit code 0)."
else
    echo "Error: update-grub failed." >&2
    exit 1
fi

echo ""
echo "=========================================================================="
echo "IOMMU configuration is complete. A reboot is required to apply changes."
echo ""
echo "After reboot, you can verify the configuration by running:"
echo "  dmesg | grep -e DMAR -e IOMMU"
echo ""
echo "Expected output should include:"
echo "  - DMAR: IOMMU enabled"
echo "  - DMAR: Intel(R) Virtualization Technology for Directed I/O"
echo "=========================================================================="
echo ""

read -p "Would you like to reboot the host now? [y/N] " -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    reboot
else
    echo "Please remember to reboot the host manually later."
fi
