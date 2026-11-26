# Rocky Linux 9 golden image -> Proxmox Cloud-Init template (OMNI-8)
#
# Boots the Rocky 9 ISO under UEFI (OVMF) on a Q35 machine, serves
# http/ks.cfg for an unattended install, seals the guest and converts it to
# a Cloud-Init template. See README.md for usage.

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    proxmox = {
      version = "~> 1.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# --- Proxmox connection --------------------------------------------------------

variable "proxmox_url" {
  type        = string
  description = "Proxmox API endpoint, e.g. https://pve.lan:8006/api2/json"
}

variable "proxmox_token_id" {
  type        = string
  description = "Full API token ID, e.g. automation@pve!packer-token (see infra/scripts/setup_automation_rbac.sh)"
}

variable "proxmox_token_secret" {
  type        = string
  sensitive   = true
  description = "API token secret. Pass via PKR_VAR_proxmox_token_secret; never commit it."
}

variable "proxmox_insecure_tls" {
  type        = bool
  default     = true
  description = "Skip TLS verification (Proxmox ships a self-signed certificate)."
}

variable "proxmox_node" {
  type    = string
  default = "pve"
}

# --- Template shape -------------------------------------------------------------

variable "vm_id" {
  type    = number
  default = 9000
}

variable "vm_name" {
  type    = string
  default = "rocky9-cloudinit-template"
}

variable "iso_file" {
  type    = string
  default = "local:iso/Rocky-9-latest-x86_64-minimal.iso"
}

variable "iso_storage_pool" {
  type    = string
  default = "local"
}

variable "disk_storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Storage for the OS disk, EFI vars disk and cloud-init drive."
}

variable "disk_size" {
  type    = string
  default = "20G"
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 2048
}

# --- Build-time access ----------------------------------------------------------

variable "ssh_password" {
  type        = string
  sensitive   = true
  default     = "rockypass"
  description = "Build-only password for 'rocky'; must match http/ks.cfg. Locked before sealing."
}

variable "http_bind_address" {
  type        = string
  default     = "0.0.0.0"
  description = "Address Packer's HTTP server listens on; the Proxmox VM must reach it."
}

# --- Source -------------------------------------------------------------------------

source "proxmox-iso" "rocky9" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_tls
  node                     = var.proxmox_node

  vm_id                = var.vm_id
  vm_name              = var.vm_name
  template_name        = var.vm_name
  template_description = "Rocky Linux 9 Cloud-Init Golden Image, built ${timestamp()} by Packer"

  # UEFI on Q35. Rocky 9 requires x86-64-v2; the plugin default (kvm64) lacks it.
  machine    = "q35"
  bios       = "ovmf"
  os         = "l26"
  cpu_type   = "x86-64-v2-AES"
  cores      = var.cores
  memory     = var.memory
  qemu_agent = true

  efi_config {
    efi_storage_pool  = var.disk_storage_pool
    efi_type          = "4m"
    pre_enrolled_keys = false
  }

  boot_iso {
    type             = "ide"
    iso_file         = var.iso_file
    iso_storage_pool = var.iso_storage_pool
    unmount          = true
  }

  scsi_controller = "virtio-scsi-single"
  disks {
    type         = "scsi"
    disk_size    = var.disk_size
    storage_pool = var.disk_storage_pool
    format       = "raw"
    io_thread    = true
    discard      = true
  }

  network_adapters {
    model  = "virtio"
    bridge = var.network_bridge
  }

  # Attach a cloud-init drive so clones can be configured (user, keys, network).
  cloud_init              = true
  cloud_init_storage_pool = var.disk_storage_pool

  # Under OVMF the ISO shows a GRUB2 menu: select "Install Rocky Linux 9",
  # edit the entry, append the Kickstart args to the linuxefi line, boot (F10).
  http_directory    = "${path.root}/http"
  http_bind_address = var.http_bind_address
  boot_wait         = "10s"
  boot_command = [
    "<up>e<wait><down><down><end>",
    " inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg",
    "<F10>"
  ]

  communicator = "ssh"
  ssh_username = "rocky"
  ssh_password = var.ssh_password
  ssh_timeout  = "30m"
}

# --- Build: patch and seal ---------------------------------------------------------

build {
  sources = ["source.proxmox-iso.rocky9"]

  provisioner "shell" {
    # ks.cfg grants rocky NOPASSWD sudo for the build
    execute_command = "sudo sh -eux '{{ .Path }}'"
    inline = [
      # Patch the image
      "dnf -y update",
      "dnf clean all",
      # Reset cloud-init so clones run it from scratch
      "cloud-init clean --logs --seed",
      # Per-clone identity: sshd-keygen recreates host keys, systemd the machine-id
      "rm -f /etc/ssh/ssh_host_*",
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/systemd/random-seed",
      # Remove build-only access; cloud-init's default_user sets up clones
      "passwd -l rocky",
      "rm -f /etc/sudoers.d/rocky",
      "rm -f /root/ks-post.log",
      "sync"
    ]
  }
}
