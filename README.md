# Omni Ledger

## Infrastructure Scripts

The `infra/scripts` directory contains automation scripts for configuring a Proxmox VE host: GPU passthrough (VFIO), and RBAC and API tokens for Packer and Terraform.

- [**enable_iommu.sh**](infra/scripts/enable_iommu.sh)
  Enables IOMMU by modifying GRUB boot flags to maintain clean separation across PCIe buses.
- [**blacklist_gpu_drivers.sh**](infra/scripts/blacklist_gpu_drivers.sh)
  Prevents the Proxmox kernel from loading default graphics drivers, freeing the GPU for VM passthrough.
- [**setup_vfio.sh**](infra/scripts/setup_vfio.sh)
  Isolates the NVIDIA GPU and binds it to the Virtual Function I/O (VFIO) framework for direct device access in QEMU/KVM.
- [**setup_automation_rbac.sh**](infra/scripts/setup_automation_rbac.sh)
  Creates a least-privilege `AutomationRole`, the `automation@pve` service user and the `packer-token` / `terraform-token` API tokens.

For detailed execution order and usage instructions, see the [Scripts README](infra/scripts/README.md).