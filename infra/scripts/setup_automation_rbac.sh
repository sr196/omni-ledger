#!/usr/bin/env bash

# Creates a least-privilege Proxmox role, a service user and API tokens for
# Packer and Terraform automation. Safe to run more than once.

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." >&2
   exit 1
fi

# --- Configuration (override with environment variables) --------------------
ROLE_NAME="${ROLE_NAME:-AutomationRole}"
# @pve is the Proxmox-only realm: the account exists only inside Proxmox, has
# no Linux login, and with no password set it can only be used via its tokens.
AUTOMATION_USER="${AUTOMATION_USER:-automation@pve}"
TOKEN_FILE="${TOKEN_FILE:-/root/automation-tokens.env}"
ROTATE_TOKENS="${ROTATE_TOKENS:-0}"
read -r -a TOKENS <<< "${TOKENS:-packer-token terraform-token}"

# Privileges needed to build templates with Packer and manage VMs with Terraform.
DESIRED_PRIVS=(
    # VM lifecycle and configuration
    "VM.Allocate" "VM.Clone" "VM.Audit" "VM.PowerMgmt" "VM.Console" "VM.Migrate"
    "VM.Config.CDROM" "VM.Config.CPU" "VM.Config.Disk" "VM.Config.HWType"
    "VM.Config.Memory" "VM.Config.Network" "VM.Config.Options" "VM.Config.Cloudinit"
    # Guest agent queries (IP discovery). VM.Monitor covers this up to PVE 8;
    # PVE 9 removed it in favour of VM.GuestAgent.*. Whichever is unknown to
    # this host is filtered out below.
    "VM.Monitor" "VM.GuestAgent.Audit"
    # Storage: disks, and ISO / cloud-init snippet uploads (Packer)
    "Datastore.AllocateSpace" "Datastore.AllocateTemplate" "Datastore.Audit"
    # Read node / pool state, and attach VMs to bridges (required on PVE 8+)
    "Sys.Audit" "Pool.Audit" "SDN.Use"
)

for cmd in pveum pvesh; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: '$cmd' not found. Run this script on a Proxmox VE host." >&2
        exit 1
    fi
done

# --- Filter privileges to those this PVE version knows -----------------------
# The built-in Administrator role holds every privilege the host supports.
echo "Reading the privileges supported by this Proxmox VE version..."
KNOWN_PRIVS=" $(pvesh get /access/roles/Administrator --output-format json \
    | grep -oE '"[A-Za-z]+(\.[A-Za-z]+)+"' | tr -d '"' | tr '\n' ' ') "

PRIVS=()
for priv in "${DESIRED_PRIVS[@]}"; do
    if [[ "$KNOWN_PRIVS" == *" $priv "* ]]; then
        PRIVS+=("$priv")
    else
        echo "Warning: Privilege '$priv' does not exist on this PVE version; skipping it."
    fi
done

if [[ ${#PRIVS[@]} -eq 0 ]]; then
    echo "Error: None of the requested privileges are known to this host." >&2
    exit 1
fi

# --- Role -------------------------------------------------------------------
echo ""
if pveum role list --output-format json | grep -qE "\"roleid\" *: *\"$ROLE_NAME\""; then
    echo "Role '$ROLE_NAME' exists; resetting its privileges..."
    # modify without -append replaces the list, so the role matches exactly
    pveum role modify "$ROLE_NAME" -privs "${PRIVS[*]}"
else
    echo "Creating role '$ROLE_NAME'..."
    pveum role add "$ROLE_NAME" -privs "${PRIVS[*]}"
fi
echo "Privileges: ${PRIVS[*]}"

# --- User -------------------------------------------------------------------
echo ""
if pveum user list --output-format json | grep -qE "\"userid\" *: *\"$AUTOMATION_USER\""; then
    echo "User '$AUTOMATION_USER' already exists."
else
    echo "Creating user '$AUTOMATION_USER'..."
    pveum user add "$AUTOMATION_USER" --comment "Packer/Terraform automation (token-only)"
fi

# --- ACL --------------------------------------------------------------------
echo "Granting '$ROLE_NAME' to '$AUTOMATION_USER' on path '/'..."
pveum acl modify / -user "$AUTOMATION_USER" -role "$ROLE_NAME"

# --- Tokens -----------------------------------------------------------------
# Token secrets are shown by Proxmox only once, at creation. They are collected
# here and written to a root-only file; they are never printed to the terminal.
echo ""
EXISTING_TOKENS=" $(pveum user token list "$AUTOMATION_USER" --output-format json \
    | { grep -oE '"tokenid" *: *"[^"]+"' || true; } | cut -d'"' -f4 | tr '\n' ' ') "

# packer-token -> PACKER, my-ci-token -> MY_CI
env_prefix() {
    local name="${1%-token}"
    printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_'
}

NEW_SECRETS=""
SKIPPED=()
for token in "${TOKENS[@]}"; do
    if [[ "$EXISTING_TOKENS" == *" $token "* ]]; then
        if [[ "$ROTATE_TOKENS" == "1" ]]; then
            echo "Rotating token '$token' (removing the old one)..."
            pveum user token remove "$AUTOMATION_USER" "$token"
        else
            echo "Token '$token' already exists; skipping (its secret cannot be shown again)."
            SKIPPED+=("$token")
            continue
        fi
    fi

    echo "Creating token '$token'..."
    # --privsep 0: the token carries the user's own permissions (AutomationRole)
    output=$(pveum user token add "$AUTOMATION_USER" "$token" --privsep 0 \
        --comment "Created by setup_automation_rbac.sh" --output-format json)
    token_id=$(printf '%s' "$output" | grep -oE '"full-tokenid" *: *"[^"]+"' | cut -d'"' -f4)
    secret=$(printf '%s' "$output" | grep -oE '"value" *: *"[^"]+"' | cut -d'"' -f4)

    if [[ -z "$token_id" || -z "$secret" ]]; then
        echo "Error: Could not read the ID or secret of token '$token' from pveum output." >&2
        exit 1
    fi

    prefix=$(env_prefix "$token")
    NEW_SECRETS+="${prefix}_TOKEN_ID=${token_id}"$'\n'
    NEW_SECRETS+="${prefix}_TOKEN_SECRET=${secret}"$'\n'
done

if [[ -n "$NEW_SECRETS" ]]; then
    # Files created from here on are readable by root only
    umask 077
    if [[ -f "$TOKEN_FILE" ]]; then
        echo "Backing up $TOKEN_FILE..."
        cp -p "$TOKEN_FILE" "${TOKEN_FILE}.bak_$(date +%Y%m%d%H%M%S)"
    fi
    {
        echo "# Proxmox API tokens for $AUTOMATION_USER, created $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Copy these into the team secrets manager, then: shred -u $TOKEN_FILE"
        printf '%s' "$NEW_SECRETS"
    } > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "Token IDs and secrets written to $TOKEN_FILE (mode 600)."
fi

echo ""
echo "=========================================================================="
echo "Proxmox RBAC and automation tokens are configured."
echo ""
if [[ -n "$NEW_SECRETS" ]]; then
    echo "ACTION REQUIRED: store the values in $TOKEN_FILE in the team secrets"
    echo "manager now, then delete the file (and any .bak_* copies of it):"
    echo "   shred -u $TOKEN_FILE ${TOKEN_FILE}.bak_*"
    echo ""
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "Skipped existing tokens: ${SKIPPED[*]}"
    echo "To issue new secrets for them, re-run with ROTATE_TOKENS=1."
    echo ""
fi
echo "Acceptance Criteria:"
echo "1. Verify the role and its privileges:"
echo "   pveum role list | grep $ROLE_NAME"
echo ""
echo "2. Verify the user's effective permissions:"
echo "   pveum user permissions $AUTOMATION_USER --path /"
echo ""
echo "3. Verify the tokens exist (privsep 0):"
echo "   pveum user token list $AUTOMATION_USER"
echo ""
echo "4. Verify a token authenticates against the API (should return version JSON):"
echo "   curl -sk -H \"Authorization: PVEAPIToken=<TOKEN_ID>=<TOKEN_SECRET>\" https://localhost:8006/api2/json/version"
echo "=========================================================================="
