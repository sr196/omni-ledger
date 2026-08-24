# Proxmox GPU Passthrough Scripts

This directory contains shell scripts designed to automate the configuration of a Proxmox VE host for GPU passthrough (specifically targeting NVIDIA GPUs for VMs like Ollama).

## Order of Execution

For a complete setup, the scripts should be executed in the following order:

1. `enable_iommu.sh`
2. `blacklist_gpu_drivers.sh`
3. `setup_vfio.sh`

## How to Execute

### Prerequisites
- You must run these scripts with **root privileges** directly on the Proxmox VE host.
- A reboot is required to apply the kernel and initramfs changes. If running them all at once, you can decline the reboot prompt for the first two scripts and only reboot after the final one.

### Steps
1. Transfer the scripts to your Proxmox VE host.
2. Ensure they have executable permissions:
   ```bash
   chmod +x enable_iommu.sh blacklist_gpu_drivers.sh setup_vfio.sh
   ```
3. Run them sequentially as root:
   ```bash
   ./enable_iommu.sh
   # (Answer 'N' to the reboot prompt to continue with the next script)
   
   ./blacklist_gpu_drivers.sh
   # (Answer 'N' to the reboot prompt to continue with the next script)
   
   ./setup_vfio.sh
   # (Answer 'Y' to the reboot prompt to finally reboot the host)
   ```

## Scripts Overview & Purpose

### 1. `enable_iommu.sh`
**Purpose:** Modifies kernel boot flags to instruct the Linux kernel to initialize direct memory access (DMA) remapping subsystems. This maintains clean IOMMU group separation across PCIe buses, which is a strict prerequisite for hardware passthrough.
**What it does:**
- Backs up `/etc/default/grub`.
- Appends `intel_iommu=on iommu=pt` to `GRUB_CMDLINE_LINUX_DEFAULT`.
- Runs `update-grub` to regenerate the bootloader configuration.

### 2. `blacklist_gpu_drivers.sh`
**Purpose:** Prevents the Proxmox host kernel from loading default graphics drivers. If the host kernel loads these drivers, it locks the PCIe video card device resources and VRAM, preventing the VFIO subsystem from passing the card cleanly to a VM.
**What it does:**
- Backs up `/etc/modprobe.d/pve-blacklist.conf`.
- Adds `nouveau`, `nvidia`, `nvidiafb`, `nvidia_drm`, and `radeon` to the blacklist.
- Rebuilds the boot image via `update-initramfs -u -k all`.

### 3. `setup_vfio.sh`
**Purpose:** Configures the Virtual Function I/O (VFIO) framework, which enables direct device access and secure user-space memory management required by QEMU/KVM. It also isolates the NVIDIA GPU by binding it to the `vfio-pci` driver, making it ready for VM assignment.
**What it does:**
- Backs up `/etc/modules` and adds the required VFIO modules (`vfio`, `vfio_iommu_type1`, `vfio_pci`, `vfio_virqfd`).
- Dynamically detects the NVIDIA GPU Vendor:Device IDs (e.g., `10de:XXXX`) using `lspci`.
- Binds these IDs to the VFIO driver by writing to `/etc/modprobe.d/vfio.conf`.
- Rebuilds the boot image via `update-initramfs -u -k all`.

---
*Note: Each script provides specific post-reboot validation commands (Acceptance Criteria) upon completion, allowing you to verify that the configuration was applied successfully.*
