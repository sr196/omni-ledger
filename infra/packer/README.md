# Packer: Rocky Linux 9 Golden Image

## `http/ks.cfg` — Unattended Kickstart

`http/ks.cfg` installs Rocky Linux 9 with no prompts, so Packer can build a Proxmox VM template.

**What it does:**
- Runs the text installer and accepts the EULA. There is no first-boot wizard.
- Installs from the Rocky BaseOS and AppStream mirrors, so it works from the minimal or boot ISO. The guest needs internet access during the install.
- Sets DHCP networking, `en_US.UTF-8`, a `us` keyboard and UTC time. SELinux is enforcing and the firewall only allows SSH.
- Wipes the disk and creates **plain partitions (no LVM)**, so `cloud-utils-growpart` can grow `/` when a clone's disk is resized.
- Installs `@^minimal-environment`, `qemu-guest-agent`, `cloud-init`, `cloud-utils-growpart`, `curl`, `sudo` and `tar`. A missing package fails the install; it is not skipped.
- `%post` (stops the install on any error; the log is at `/root/ks-post.log`):
  - Gives `rocky` passwordless sudo, and checks the sudoers file with `visudo`.
  - Checks that the required packages are installed.
  - Enables `qemu-guest-agent` and the cloud-init units. Newer cloud-init releases renamed some units, so it enables whichever unit names the installed package has.
  - Empties `/etc/machine-id` and removes the systemd random seed, so every clone gets its own identity.
- Reboots when the install is done.

### Credentials
- **root is locked** (`rootpw --lock`).
- `rocky` / `rockypass` is a **build-only** login for Packer's SSH communicator. The Packer cleanup provisioner must lock it (`sudo passwd -l rocky`) before the template is converted. Clones get real SSH keys from cloud-init.

### Using it from Packer
```hcl
http_directory = "http"
boot_command = [
  "<up><wait><tab>",
  " inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg<enter>"
]
ssh_username = "rocky"
ssh_password = "rockypass"
```

### Validating
```bash
python3 -m venv .venv && .venv/bin/pip install pykickstart
.venv/bin/ksvalidator -v RHEL9 infra/packer/http/ks.cfg
```
