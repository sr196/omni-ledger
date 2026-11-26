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
- `rocky` / `rockypass` is a **build-only** login for Packer's SSH communicator. The build in [`rocky9-template.pkr.hcl`](rocky9-template.pkr.hcl) locks the password and removes the sudoers drop-in before the template is sealed. Clones get real SSH keys from cloud-init.

### Validating
```bash
python3 -m venv .venv && .venv/bin/pip install pykickstart
.venv/bin/ksvalidator -v RHEL9 infra/packer/http/ks.cfg
```

## `rocky9-template.pkr.hcl` — Proxmox Template Build

Builds VM **9000** (`rocky9-cloudinit-template`) on Proxmox: UEFI (OVMF) on a Q35 machine, a VirtIO SCSI disk and NIC, the QEMU guest agent, and a cloud-init drive. It then converts the VM into a template, ready for Terraform to clone.

**How the build works:**
1. Boots the Rocky 9 ISO. In the GRUB2 (UEFI) menu it picks "Install Rocky Linux 9", edits the entry to add `inst.text inst.ks=http://<packer-host>:<port>/ks.cfg`, and boots with F10.
2. Packer serves `http/` from its built-in HTTP server, and the installer runs `ks.cfg` with no prompts.
3. After the reboot Packer logs in over SSH as `rocky`, then patches and seals the guest:
   - `dnf -y update`
   - `cloud-init clean --logs --seed`
   - Removes the SSH host keys and empties `machine-id` and the random seed, so each clone gets its own.
   - Locks `rocky`'s password and removes `/etc/sudoers.d/rocky`.
4. Detaches the ISO, adds the cloud-init drive and converts the VM into a template.

The CPU type is `x86-64-v2-AES`. Rocky 9 needs x86-64-v2, and the plugin's default `kvm64` doesn't provide it, so the installer would fail to boot.

### Prerequisites
- [Packer](https://developer.hashicorp.com/packer/install) 1.10 or newer.
- The `automation@pve!packer-token` API token, created with [`setup_automation_rbac.sh`](../scripts/setup_automation_rbac.sh). Its values are `PACKER_TOKEN_ID` and `PACKER_TOKEN_SECRET`.
- The Rocky 9 ISO uploaded to the ISO storage (default `local:iso/Rocky-9-latest-x86_64-minimal.iso`).
- **The VM must be able to reach the machine running Packer** on the HTTP port Packer picks (8000–9000), and the internet, for the package mirrors. On macOS, allow incoming connections for `packer` in the firewall.
- VM ID 9000 must be free. Packer won't overwrite an existing VM, so to rebuild, run `qm destroy 9000` on the host first.

### Building
```bash
cd infra/packer
cp variables.example.pkrvars.hcl variables.pkrvars.hcl   # git-ignored; edit for your host
export PKR_VAR_proxmox_token_secret='<PACKER_TOKEN_SECRET>' # never commit the secret

packer init .
packer validate -var-file=variables.pkrvars.hcl .
packer build -var-file=variables.pkrvars.hcl .
```

Or use the wrapper, which loads `PROXMOX_API_ENDPOINT`, `PACKER_TOKEN_ID` and `PACKER_TOKEN_SECRET` from the git-ignored repo-root `.env` (and `variables.pkrvars.hcl` if present):
```bash
cd infra/packer
./packer.sh init
./packer.sh validate
./packer.sh build
```

Any variable can be overridden with `-var name=value`, for example `vm_id`, `disk_storage_pool`, `network_bridge`, `disk_size`, `cores` or `memory`. The full list is at the top of the `.pkr.hcl` file.

### Verifying the template
```bash
qm config 9000   # template: 1, bios: ovmf, machine: q35, ide2: ...cloudinit, agent: 1
qm clone 9000 123 --name rocky-test --full
qm set 123 --ciuser rocky --sshkeys ~/.ssh/id_ed25519.pub --ipconfig0 ip=dhcp
qm resize 123 scsi0 +10G && qm start 123
```
Then check the clone:
- You can log in with your SSH key.
- `/` has grown to the new disk size.
- `cat /etc/machine-id` is different from other clones.
- The Proxmox summary shows the guest agent's IP.
- Logging in as `rocky` with the password fails.
