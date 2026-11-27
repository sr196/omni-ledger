#!/usr/bin/env bash
#
# Install LM Studio's headless daemon (llmster) and the lms CLI on a Rocky
# Linux 9/10 VM, download a model, and run the LM Studio server as a systemd
# service that loads the model on boot.
#
# Follows https://lmstudio.ai/docs (llmster: "Run on startup with systemd").
# For GPU offload, install the NVIDIA driver first (./0_install_nvidia_driver.sh
# and reboot); without a GPU the model runs on CPU.
#
# Usage:
#   sudo ./2_install_lms.sh
#
# Environment overrides:
#   APP_USER=kiosk                  service account (created if missing)
#   LMS_MODEL=qwen/qwen3-4b-2507    model to download and load on startup
#   CONTEXT_LENGTH=32768            context length the model is loaded with
#   GPU_OFFLOAD=max                 lms load --gpu value: max, off, or 0.0-1.0
#   PORT=1234                       server listen port
#   BIND_ADDRESS=0.0.0.0            listen address (127.0.0.1 = this VM only)
#   COMPAT_DIR=/opt/lmstudio-runtime  newer libstdc++ used on Rocky 9 (GCC 11)
#
# After it finishes, check with:
#   systemctl status lmstudio
#   curl -s http://localhost:1234/v1/models

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,26p' "$0"; exit 0
fi

# --- Configuration -----------------------------------------------------------

APP_USER="${APP_USER:-kiosk}"
LMS_MODEL="${LMS_MODEL:-qwen/qwen3-4b-2507}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-32768}"
GPU_OFFLOAD="${GPU_OFFLOAD:-max}"
PORT="${PORT:-1234}"
BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
COMPAT_DIR="${COMPAT_DIR:-/opt/lmstudio-runtime}"
SERVICE_NAME="lmstudio"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

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

# llmster and its llama.cpp engines are built for AVX2 (x86-64-v3); without it
# lms dies with "Illegal instruction". Proxmox CPU models such as kvm64 or
# x86-64-v2-AES hide AVX/AVX2, so the VM needs CPU type "host" (or x86-64-v3).
for flag in avx avx2 fma; do
    if ! grep -qw "$flag" /proc/cpuinfo; then
        echo "Error: this CPU does not expose '${flag}', which LM Studio requires." >&2
        echo "On the Proxmox host, set the VM's CPU type to host and restart the VM:" >&2
        echo "  qm set <vmid> --cpu host && qm shutdown <vmid> && qm start <vmid>" >&2
        exit 1
    fi
done

if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    echo "Found GPU:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | sed 's/^/  /'
else
    echo "Warning: no working NVIDIA driver found; the model will run on CPU."
fi

# --- [1/5] System packages ---------------------------------------------------

echo ">>> [1/5] Installing system dependencies..."
# policycoreutils-python-utils provides semanage (SELinux labelling below).
dnf -y install --setopt=install_weak_deps=False \
    ca-certificates \
    curl \
    tar \
    gzip \
    bzip2 \
    policycoreutils-python-utils

# llmster's native modules need GLIBCXX_3.4.30 (GCC 12+). Rocky 9 ships GCC 11's
# libstdc++ (up to 3.4.29), and gcc-toolset does not replace the runtime
# library. In that case, install a newer libstdc++/libgcc from conda-forge into
# COMPAT_DIR and point llmster at it with LD_LIBRARY_PATH (system libs untouched).
LMS_LD_LIBRARY_PATH=""
if ! grep -qa 'GLIBCXX_3\.4\.30' /lib64/libstdc++.so.6; then
    echo "System libstdc++ lacks GLIBCXX_3.4.30; installing a newer runtime in ${COMPAT_DIR}..."
    if ! grep -qa 'GLIBCXX_3\.4\.30' "${COMPAT_DIR}/lib/libstdc++.so.6" 2>/dev/null; then
        tmp="$(mktemp -d)"
        curl -fsSL "https://micro.mamba.pm/api/micromamba/linux-64/latest" \
            | tar -xj -C "$tmp" bin/micromamba
        rm -rf "${COMPAT_DIR}"
        MAMBA_ROOT_PREFIX="${tmp}/root" "${tmp}/bin/micromamba" create -y \
            -p "${COMPAT_DIR}" -c conda-forge --override-channels \
            libstdcxx-ng libgcc-ng
        rm -rf "$tmp"
    fi
    if ! grep -qa 'GLIBCXX_3\.4\.30' "${COMPAT_DIR}/lib/libstdc++.so.6"; then
        echo "Error: ${COMPAT_DIR}/lib/libstdc++.so.6 still lacks GLIBCXX_3.4.30." >&2
        exit 1
    fi
    if command -v selinuxenabled &> /dev/null && selinuxenabled; then
        restorecon -R "${COMPAT_DIR}"
    fi
    LMS_LD_LIBRARY_PATH="${COMPAT_DIR}/lib"
fi

# --- [2/5] Service account ---------------------------------------------------

echo ">>> [2/5] Ensuring user ${APP_USER} exists..."
if ! id -u "${APP_USER}" &> /dev/null; then
    useradd -m -s /bin/bash "${APP_USER}"
fi
APP_HOME="$(getent passwd "${APP_USER}" | cut -d: -f6)"
LMS_BIN="${APP_HOME}/.lmstudio/bin/lms"

# If this is a rerun, stop the service so the install steps own the daemon.
if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    echo "Stopping running ${SERVICE_NAME} service..."
    systemctl stop "${SERVICE_NAME}.service"
fi

# --- [3/5] llmster + lms, model download (as the service user) ---------------

echo ">>> [3/5] Installing llmster and downloading ${LMS_MODEL} as ${APP_USER}..."
runuser -u "${APP_USER}" -- env \
    HOME="${APP_HOME}" \
    ${LMS_LD_LIBRARY_PATH:+LD_LIBRARY_PATH="${LMS_LD_LIBRARY_PATH}"} \
    LMS_BIN="${LMS_BIN}" \
    LMS_MODEL="${LMS_MODEL}" \
    CONTEXT_LENGTH="${CONTEXT_LENGTH}" \
    GPU_OFFLOAD="${GPU_OFFLOAD}" \
    PORT="${PORT}" \
    bash -euo pipefail -c '
    # runuser keeps the caller'"'"'s working directory (often /root), which this
    # user cannot enter; lms then fails to spawn anything with EACCES.
    cd "$HOME"

    install_llmster() { curl -fsSL https://lmstudio.ai/install.sh | bash; }

    if [[ ! -x "$LMS_BIN" ]]; then
        install_llmster
    else
        # The installer ends with "lms bootstrap -y". If an earlier run died
        # there (e.g. "Illegal instruction" on a CPU without AVX2), lms exists
        # but cannot find llmster. Bootstrap is idempotent, so always rerun it.
        "$LMS_BIN" bootstrap -y || true
    fi
    "$LMS_BIN" --help > /dev/null

    # If the daemon still cannot find a valid installation, reinstall once.
    if ! "$LMS_BIN" daemon up; then
        echo "lms daemon up failed; reinstalling llmster and retrying..."
        install_llmster
        "$LMS_BIN" daemon up
    fi
    trap "\"$LMS_BIN\" daemon down || true" EXIT

    "$LMS_BIN" get "$LMS_MODEL" --yes

    echo ">>> Manual test: load model and start server..."
    "$LMS_BIN" load "$LMS_MODEL" --context-length "$CONTEXT_LENGTH" --gpu "$GPU_OFFLOAD" --yes
    "$LMS_BIN" server start --port "$PORT"
    for _ in $(seq 1 30); do
        if curl -fsS "http://localhost:${PORT}/v1/models" > /dev/null; then break; fi
        sleep 1
    done
    curl -fsS "http://localhost:${PORT}/v1/models"; echo
    "$LMS_BIN" ps
    "$LMS_BIN" server stop
    "$LMS_BIN" unload --all
'

# With SELinux enforcing, systemd (init_t) may not execute files labelled
# user_home_t. Label the lms CLI as bin_t; the processes it starts then run
# unconfined and can use the rest of ~/.lmstudio as usual.
if command -v selinuxenabled &> /dev/null && selinuxenabled; then
    echo "Labelling ${APP_HOME}/.lmstudio/bin for SELinux..."
    semanage fcontext -a -t bin_t "${APP_HOME}/.lmstudio/bin(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t bin_t "${APP_HOME}/.lmstudio/bin(/.*)?"
    restorecon -R "${APP_HOME}/.lmstudio/bin"
fi

# --- [4/5] systemd service ---------------------------------------------------

echo ">>> [4/5] Creating and enabling systemd service..."
LMS_ENV_LINE=""
if [[ -n "${LMS_LD_LIBRARY_PATH}" ]]; then
    LMS_ENV_LINE="Environment=\"LD_LIBRARY_PATH=${LMS_LD_LIBRARY_PATH}\""
fi
cat > "${UNIT_FILE}" <<EOF
# Managed by 2_install_lms.sh
[Unit]
Description=LM Studio Server (${LMS_MODEL})
After=network-online.target nvidia-persistenced.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_HOME}
Environment="HOME=${APP_HOME}"
${LMS_ENV_LINE}
ExecStartPre=${LMS_BIN} daemon up
ExecStartPre=${LMS_BIN} load ${LMS_MODEL} --context-length ${CONTEXT_LENGTH} --gpu ${GPU_OFFLOAD} --yes
ExecStart=${LMS_BIN} server start --bind ${BIND_ADDRESS} --port ${PORT}
ExecStop=${LMS_BIN} daemon down
# Loading the model can take a while on first boot.
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl start "${SERVICE_NAME}.service"

# Open the port for other machines when listening beyond localhost.
if [[ "${BIND_ADDRESS}" != "127.0.0.1" ]] && systemctl is-active --quiet firewalld; then
    echo "Opening port ${PORT}/tcp in firewalld..."
    firewall-cmd --permanent --add-port="${PORT}/tcp"
    firewall-cmd --reload
fi

# --- [5/5] Verify ------------------------------------------------------------

echo ">>> [5/5] Waiting for the API on port ${PORT}..."
for _ in $(seq 1 60); do
    if curl -fsS "http://localhost:${PORT}/v1/models" > /dev/null 2>&1; then break; fi
    sleep 2
done
if ! curl -fsS "http://localhost:${PORT}/v1/models"; then
    echo "Error: the API did not respond. Check: journalctl -u ${SERVICE_NAME}" >&2
    exit 1
fi
echo

# --- Done --------------------------------------------------------------------

echo
echo ">>> Setup complete. Service status:"
systemctl is-active "${SERVICE_NAME}.service"
echo "Loaded model: ${LMS_MODEL} (context length ${CONTEXT_LENGTH})"
echo "API:          curl -s http://localhost:${PORT}/v1/models"
if [[ "${BIND_ADDRESS}" != "127.0.0.1" ]]; then
    echo "Remote:       curl -s http://$(hostname -I | awk '{print $1}'):${PORT}/v1/models"
    echo "Note: the API has no authentication; keep this port on a trusted network."
fi
