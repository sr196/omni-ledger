#!/usr/bin/env bash
#
# Install the NVIDIA driver (and nvidia-smi) on a Rocky Linux 9/10 VM that has
# an NVIDIA GPU passed through from Proxmox (tested target: RTX 3060 12 GB).
#
# Uses NVIDIA's official CUDA repository for RHEL and the open kernel modules,
# which NVIDIA recommends for Turing and newer GPUs (the RTX 3060 is Ampere).
# The kernel module is built with DKMS, so it is rebuilt on kernel updates.
#
# Usage:
#   sudo ./install_nvidia_driver.sh            # install, then reboot yourself
#   sudo ./install_nvidia_driver.sh --reboot   # install and reboot automatically
#
# Environment overrides:
#   NVIDIA_KMOD=open|proprietary   kernel module flavour (default: open)
#
# After the reboot, verify with:  nvidia-smi

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

REBOOT=0
for arg in "$@"; do
    case "$arg" in
        --reboot) REBOOT=1 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "Error: unknown argument '$arg'" >&2; exit 1 ;;
    esac
done

NVIDIA_KMOD="${NVIDIA_KMOD:-open}"
if [[ "$NVIDIA_KMOD" != "open" && "$NVIDIA_KMOD" != "proprietary" ]]; then
    echo "Error: NVIDIA_KMOD must be 'open' or 'proprietary'." >&2
    exit 1
fi

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." >&2
   exit 1
fi

# --- Pre-flight checks -------------------------------------------------------

# shellcheck source=/dev/null
. /etc/os-release
OS_MAJOR="${VERSION_ID%%.*}"
if [[ "${ID:-}" != "rocky" && "${ID_LIKE:-}" != *rhel* ]]; then
    echo "Error: This script targets Rocky Linux / RHEL. Detected: ${PRETTY_NAME:-unknown}" >&2
    exit 1
fi
if [[ "$OS_MAJOR" != "9" && "$OS_MAJOR" != "10" ]]; then
    echo "Error: Unsupported major version '$OS_MAJOR' (expected 9 or 10)." >&2
    exit 1
fi
ARCH="$(uname -m)"
NVIDIA_REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/rhel${OS_MAJOR}/${ARCH}/cuda-rhel${OS_MAJOR}.repo"

echo "Installing pciutils to inspect PCI devices..."
dnf -y install pciutils

# The GPU must be visible inside the VM, or passthrough is not working.
if ! lspci -nn | grep -qi 'vga.*nvidia\|3d.*nvidia'; then
    echo "Error: No NVIDIA GPU found on the PCI bus." >&2
    echo "Check the Proxmox hostpci entry for this VM (q35, pcie=1, All Functions)." >&2
    exit 1
fi
echo "Found GPU:"
lspci -nn | grep -i nvidia | sed 's/^/  /'

# DKMS-built modules are unsigned; with Secure Boot on, the kernel refuses them.
if command -v mokutil &> /dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    echo "Error: Secure Boot is enabled. Disable it in the VM's OVMF settings," >&2
    echo "or enroll a MOK key and sign the NVIDIA modules, then rerun." >&2
    exit 1
fi

# --- Repositories ------------------------------------------------------------

echo "Enabling CRB and EPEL (EPEL provides dkms)..."
dnf -y install dnf-plugins-core
dnf config-manager --set-enabled crb
dnf -y install epel-release

echo "Adding the NVIDIA CUDA repository for RHEL ${OS_MAJOR}..."
dnf config-manager --add-repo "$NVIDIA_REPO_URL"
dnf clean expire-cache

# --- Kernel headers ----------------------------------------------------------

# DKMS needs kernel-devel that matches each kernel it builds for. Bring the
# kernel up to date first, so the driver is built for the kernel we boot next.
echo "Updating the kernel and installing build dependencies..."
dnf -y update kernel kernel-core kernel-modules
dnf -y install kernel-devel kernel-headers gcc make dkms elfutils-libelf-devel

# Also install headers for the running kernel if the repos still have them,
# so the module can be loaded without waiting for a reboot.
RUNNING_KERNEL="$(uname -r)"
if ! dnf -y install "kernel-devel-${RUNNING_KERNEL}" &> /dev/null; then
    echo "Note: kernel-devel for running kernel ${RUNNING_KERNEL} is not available;"
    echo "      the driver will be built for the updated kernel only (reboot required)."
fi

# --- Driver ------------------------------------------------------------------

# Older NVIDIA repos ship the driver as DNF module streams; newer ones ship
# plain packages. Support both.
if dnf -q module list nvidia-driver &> /dev/null; then
    if [[ "$NVIDIA_KMOD" == "open" ]]; then
        STREAM="open-dkms"
    else
        STREAM="latest-dkms"
    fi
    echo "Installing NVIDIA driver from module stream nvidia-driver:${STREAM}..."
    dnf -y module reset nvidia-driver
    dnf -y module install "nvidia-driver:${STREAM}"
else
    if [[ "$NVIDIA_KMOD" == "open" ]]; then
        DRIVER_PKG="nvidia-open"
    else
        DRIVER_PKG="cuda-drivers"
    fi
    echo "Installing NVIDIA driver package ${DRIVER_PKG}..."
    dnf -y install "$DRIVER_PKG"
fi

# nvidia-smi ships in nvidia-driver-cuda; install it explicitly in case the
# metapackage above did not pull it in. nvidia-persistenced keeps the GPU
# initialised on a headless server, which avoids slow first CUDA calls.
echo "Installing nvidia-smi and nvidia-persistenced..."
dnf -y install nvidia-driver-cuda nvidia-persistenced

# Build the module for every installed kernel that has headers, so the next
# boot works whichever kernel it picks.
echo "Building NVIDIA kernel modules with DKMS..."
for kdir in /lib/modules/*; do
    kver="$(basename "$kdir")"
    if [[ -d "${kdir}/build" ]]; then
        echo "  - ${kver}"
        dkms autoinstall -k "$kver"
    fi
done

# --- Disable nouveau ---------------------------------------------------------

echo "Blacklisting nouveau..."
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
# Managed by install_nvidia_driver.sh
blacklist nouveau
options nouveau modeset=0
EOF
grubby --update-kernel=ALL --args="rd.driver.blacklist=nouveau modprobe.blacklist=nouveau"

echo "Regenerating initramfs for all kernels..."
dracut --force --regenerate-all

# --- Services ----------------------------------------------------------------

if systemctl list-unit-files nvidia-persistenced.service &> /dev/null; then
    systemctl enable nvidia-persistenced.service
fi

# --- Done --------------------------------------------------------------------

echo
echo "NVIDIA driver installed:"
rpm -qa | grep -E '^(nvidia-driver|kmod-nvidia|nvidia-open|cuda-drivers)' | sort | sed 's/^/  /'
echo
echo "A reboot is required to unload nouveau and load the NVIDIA driver."
echo "After the reboot, verify with: nvidia-smi"

if [[ $REBOOT -eq 1 ]]; then
    echo "Rebooting in 5 seconds..."
    sleep 5
    systemctl reboot
fi
