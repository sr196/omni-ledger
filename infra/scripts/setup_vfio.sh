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
)

# vfio_virqfd was merged into the vfio module in kernel 6.2 (Proxmox VE 8+).
# Only list it when it still exists as a separate module; otherwise listing it
# makes systemd-modules-load report an error on every boot.
if modinfo vfio_virqfd &> /dev/null; then
    VFIO_MODULES+=("vfio_virqfd")
    HAS_VIRQFD=1
else
    HAS_VIRQFD=0
fi

# Drivers that could claim the GPU's functions before vfio-pci does.
# snd_hda_intel matters most: it grabs the GPU's HDMI audio function and is not
# blacklisted, because the host may need it for its own audio.
SOFTDEP_DRIVERS=("nouveau" "nvidia" "nvidiafb" "nvidia_drm" "snd_hda_intel")

echo "Configuring VFIO modules in $MODULES_FILE..."

# Backup the file if it exists
if [[ -f "$MODULES_FILE" ]]; then
    echo "Backing up $MODULES_FILE..."
    cp "$MODULES_FILE" "${MODULES_FILE}.bak_$(date +%Y%m%d%H%M%S)"
else
    touch "$MODULES_FILE"
fi

# Matches a whole line naming the module. Module names treat '-' and '_' as
# the same, so vfio-pci counts as vfio_pci (and does not count as vfio).
module_line_regex() {
    printf '^[[:space:]]*%s[[:space:]]*$' "${1//_/[-_]}"
}

# Add each module if it's not already present
for mod in "${VFIO_MODULES[@]}"; do
    if grep -qE "$(module_line_regex "$mod")" "$MODULES_FILE"; then
        echo "Module '$mod' is already present."
    else
        echo "Adding '$mod' to $MODULES_FILE..."
        echo "$mod" >> "$MODULES_FILE"
    fi
done

# Remove a stale vfio_virqfd entry left by an earlier run on a newer kernel
if [[ $HAS_VIRQFD -eq 0 ]] && grep -qE "$(module_line_regex vfio_virqfd)" "$MODULES_FILE"; then
    echo "Removing 'vfio_virqfd' from $MODULES_FILE (built into vfio on this kernel)..."
    sed -i -E "/$(module_line_regex vfio_virqfd)/d" "$MODULES_FILE"
fi

echo ""
echo "Detecting NVIDIA Vendor:Device IDs..."

# Check if lspci is available
if ! command -v lspci &> /dev/null; then
    echo "Error: lspci command not found. Please install pciutils." >&2
    exit 1
fi

if [[ -n "${VFIO_PCI_IDS:-}" ]]; then
    # Manual override, e.g. VFIO_PCI_IDS=10de:2204,10de:1aef ./setup_vfio.sh
    NVIDIA_IDS="$VFIO_PCI_IDS"
    echo "Using IDs from VFIO_PCI_IDS: $NVIDIA_IDS"
else
    # Find NVIDIA (vendor 10de) display controllers: VGA (0300) or 3D (0302).
    # Example `lspci -Dn` line: 0000:01:00.0 0300: 10de:2204 (rev a1)
    mapfile -t GPU_ADDRS < <(lspci -Dn -d 10de: | awk '$2 ~ /^030[02]:$/ {print $1}')

    if [[ ${#GPU_ADDRS[@]} -gt 1 ]]; then
        echo "Warning: Found ${#GPU_ADDRS[@]} NVIDIA GPUs: ${GPU_ADDRS[*]}"
        echo "All of them will be bound to vfio-pci. To keep one for the host, re-run with"
        echo "VFIO_PCI_IDS set to only the IDs you want to pass through."
    fi

    # Take every function in each GPU's slot (HDMI audio, and on some cards USB
    # and USB-C controllers), since they share an IOMMU group with the GPU and
    # must all be passed through together.
    NVIDIA_IDS=$(
        for addr in "${GPU_ADDRS[@]}"; do
            lspci -n -s "${addr%.*}" | awk '{print $3}'
        done | sort -u | paste -sd ',' -
    )
fi

if [[ -z "$NVIDIA_IDS" ]]; then
    echo "Warning: No NVIDIA GPUs found on this system using lspci."
    echo "You will need to manually configure the IDs in $VFIO_CONF later,"
    echo "or re-run with VFIO_PCI_IDS set."
else
    echo "Found NVIDIA IDs: $NVIDIA_IDS"
    echo "Configuring $VFIO_CONF..."

    mkdir -p /etc/modprobe.d/

    if [[ -f "$VFIO_CONF" ]]; then
        echo "Backing up $VFIO_CONF..."
        cp "$VFIO_CONF" "${VFIO_CONF}.bak_$(date +%Y%m%d%H%M%S)"
    fi

    {
        echo "options vfio-pci ids=$NVIDIA_IDS"
        # Make sure vfio-pci loads, and claims the devices, before these drivers
        for driver in "${SOFTDEP_DRIVERS[@]}"; do
            echo "softdep $driver pre: vfio-pci"
        done
    } > "$VFIO_CONF"
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
echo "3. Verify Kernel driver in use is vfio-pci for every NVIDIA function (GPU and audio):"
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
