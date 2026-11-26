#!/usr/bin/env bash

# Runs Packer with the Proxmox credentials from the repo-root .env file.
#
#   ./packer.sh init
#   ./packer.sh validate
#   ./packer.sh build
#   ./packer.sh build -var vm_id=9001     # extra args are passed through
#
# .env (git-ignored) must define:
#   PROXMOX_API_ENDPOINT   e.g. https://pve.example.com  (/api2/json is added if missing)
#   PACKER_TOKEN_ID        e.g. automation@pve!packer-token
#   PACKER_TOKEN_SECRET
# and may define:
#   PROXMOX_NODE           cluster node to build the VM on, e.g. pve2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../../.env}"
VAR_FILE="$SCRIPT_DIR/variables.pkrvars.hcl"

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <init|validate|build|...> [packer args]" >&2
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: $ENV_FILE not found." >&2
    exit 1
fi

# Export every variable defined in .env
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for var in PROXMOX_API_ENDPOINT PACKER_TOKEN_ID PACKER_TOKEN_SECRET; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: $var is not set in $ENV_FILE." >&2
        exit 1
    fi
done

# Packer's Proxmox plugin needs exactly <scheme>://<host>[:port]/api2/json.
# Drop any path given in .env (e.g. a pasted .../api2/json/version) first.
if [[ ! "$PROXMOX_API_ENDPOINT" =~ ^(https?://[^/]+) ]]; then
    echo "Error: PROXMOX_API_ENDPOINT must look like https://host[:port]." >&2
    exit 1
fi
endpoint="${BASH_REMATCH[1]}/api2/json"

# Packer reads input variables from PKR_VAR_<name>; these override the var file
export PKR_VAR_proxmox_url="$endpoint"
export PKR_VAR_proxmox_token_id="$PACKER_TOKEN_ID"
export PKR_VAR_proxmox_token_secret="$PACKER_TOKEN_SECRET"
# Optional: cluster node to build on (otherwise variables.pkrvars.hcl / default "pve")
if [[ -n "${PROXMOX_NODE:-}" ]]; then
    export PKR_VAR_proxmox_node="$PROXMOX_NODE"
fi

cd "$SCRIPT_DIR"

cmd="$1"
shift
case "$cmd" in
    validate|build|console|inspect)
        # Node, storage, bridge, etc. come from the git-ignored var file if present
        if [[ -f "$VAR_FILE" ]]; then
            exec packer "$cmd" -var-file="$VAR_FILE" "$@" .
        fi
        exec packer "$cmd" "$@" .
        ;;
    *)
        exec packer "$cmd" "$@" .
        ;;
esac
