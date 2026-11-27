#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." >&2
   exit 1
fi

GRUB_FILE="/etc/default/grub"
KERNEL_CMDLINE_FILE="/etc/kernel/cmdline"

# --- Pick the IOMMU flags for this CPU vendor --------------------------------
# Intel needs intel_iommu=on explicitly; on AMD the IOMMU is enabled by default
# (there is no valid amd_iommu=on value), so only passthrough mode is set.
CPU_VENDOR=$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)
case "$CPU_VENDOR" in
    GenuineIntel) IOMMU_FLAGS=("intel_iommu=on" "iommu=pt") ;;
    AuthenticAMD) IOMMU_FLAGS=("iommu=pt") ;;
    *)
        echo "Error: Unsupported CPU vendor '$CPU_VENDOR' (expected GenuineIntel or AuthenticAMD)." >&2
        exit 1
        ;;
esac
echo "Detected CPU vendor: $CPU_VENDOR (flags: ${IOMMU_FLAGS[*]})"

# --- Detect the bootloader ---------------------------------------------------
# Proxmox installs on ZFS with UEFI boot through systemd-boot, which reads the
# kernel command line from /etc/kernel/cmdline instead of /etc/default/grub.
BOOTLOADER="grub"
if [[ -d /sys/firmware/efi ]] && command -v proxmox-boot-tool &> /dev/null \
    && proxmox-boot-tool status 2> /dev/null | grep -q "systemd-boot"; then
    BOOTLOADER="systemd-boot"
fi
echo "Detected bootloader: $BOOTLOADER"

# Prints the flags from IOMMU_FLAGS that are not already words of "$1"
missing_flags() {
    local cmdline=" $1 " flag
    for flag in "${IOMMU_FLAGS[@]}"; do
        [[ "$cmdline" == *" $flag "* ]] || printf '%s\n' "$flag"
    done
}

backup() {
    cp "$1" "${1}.bak_$(date +%Y%m%d%H%M%S)"
}

if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
    if [[ ! -f "$KERNEL_CMDLINE_FILE" ]]; then
        echo "Error: $KERNEL_CMDLINE_FILE does not exist." >&2
        exit 1
    fi

    current=$(head -n 1 "$KERNEL_CMDLINE_FILE")
    mapfile -t to_add < <(missing_flags "$current")

    if [[ ${#to_add[@]} -eq 0 ]]; then
        echo "IOMMU flags are already present in $KERNEL_CMDLINE_FILE."
    else
        echo "Backing up $KERNEL_CMDLINE_FILE..."
        backup "$KERNEL_CMDLINE_FILE"
        echo "Adding ${to_add[*]} to $KERNEL_CMDLINE_FILE..."
        # /etc/kernel/cmdline must be a single line
        printf '%s\n' "${current:+$current }${to_add[*]}" > "$KERNEL_CMDLINE_FILE"
    fi

    echo "Refreshing boot entries..."
    if proxmox-boot-tool refresh; then
        echo "proxmox-boot-tool refresh completed successfully (exit code 0)."
    else
        echo "Error: proxmox-boot-tool refresh failed." >&2
        exit 1
    fi
else
    if [[ ! -f "$GRUB_FILE" ]]; then
        echo "Error: $GRUB_FILE does not exist." >&2
        exit 1
    fi

    # Read the effective value the same way grub-mkconfig does: by sourcing the
    # file. This handles either quote style and ignores commented-out lines.
    read_grub_cmdline() {
        (set +u; . "$GRUB_FILE"; printf '%s' "${GRUB_CMDLINE_LINUX_DEFAULT:-}")
    }

    current=$(read_grub_cmdline)
    mapfile -t to_add < <(missing_flags "$current")

    if [[ ${#to_add[@]} -eq 0 ]]; then
        echo "IOMMU flags are already present in $GRUB_FILE."
    else
        echo "Backing up $GRUB_FILE..."
        backup "$GRUB_FILE"

        echo "Adding ${to_add[*]} to GRUB_CMDLINE_LINUX_DEFAULT..."
        new_line="GRUB_CMDLINE_LINUX_DEFAULT=\"${current:+$current }${to_add[*]}\""
        tmp=$(mktemp)
        # Replace every active definition (the last one is the effective one,
        # and its value is what we built on); append one if none exists.
        awk -v new="$new_line" '
            /^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=/ { if (!done) print new; done = 1; next }
            { print }
            END { if (!done) print new }
        ' "$GRUB_FILE" > "$tmp"
        cat "$tmp" > "$GRUB_FILE"
        rm -f "$tmp"

        # Verify the change actually took effect
        if [[ -n "$(missing_flags "$(read_grub_cmdline)")" ]]; then
            echo "Error: Failed to apply IOMMU flags to $GRUB_FILE; restore it from the backup." >&2
            exit 1
        fi
        echo "Successfully updated $GRUB_FILE."
    fi

    echo "Regenerating GRUB bootloader configuration..."
    if update-grub; then
        echo "update-grub completed successfully (exit code 0)."
    else
        echo "Error: update-grub failed." >&2
        exit 1
    fi
fi

echo ""
echo "=========================================================================="
echo "IOMMU configuration is complete. A reboot is required to apply changes."
echo ""
echo "After reboot, you can verify the configuration by running:"
echo "  cat /proc/cmdline"
echo "  dmesg | grep -e DMAR -e IOMMU -e AMD-Vi"
echo ""
echo "Expected output should include:"
echo "  - The flags ${IOMMU_FLAGS[*]} in /proc/cmdline"
if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
    echo "  - DMAR: IOMMU enabled"
    echo "  - DMAR: Intel(R) Virtualization Technology for Directed I/O"
else
    echo "  - AMD-Vi: Interrupt remapping enabled"
fi
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
