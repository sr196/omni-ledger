# Copy to variables.pkrvars.hcl (git-ignored) and adjust for your host.
# Do NOT put the token secret here; export it instead:
#   export PKR_VAR_proxmox_token_secret='<PACKER_TOKEN_SECRET>'

proxmox_url      = "https://pve.lan:8006/api2/json"
proxmox_token_id = "automation@pve!packer-token"
proxmox_node     = "pve"

iso_file          = "local:iso/Rocky-9-latest-x86_64-minimal.iso"
iso_storage_pool  = "local"
disk_storage_pool = "local-lvm"
network_bridge    = "vmbr0"

# vm_id   = 9000
# disk_size = "20G"
# cores   = 2
# memory  = 2048
