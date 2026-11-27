    # Both packages install the same "onnxruntime" module, so remove whichever
    # are present (make install may have put the CPU build back on a rerun)
    # and then install the GPU build cleanly.
    installed=()
    for pkg in onnxruntime onnxruntime-gpu; do
        if uv pip show --quiet "$pkg" &> /dev/null; then
            installed+=("$pkg")
        fi
    done
    if (( ${#installed[@]} )); then
        uv pip uninstall "${installed[@]}"
    fi
#!/usr/bin/env bash
#
# Install the open-source Unstructured API (github.com/Unstructured-IO/unstructured-api)
# with NVIDIA GPU acceleration on a Rocky Linux 9/10 VM, and run it as a
# systemd service.
#
# Prerequisite: the NVIDIA driver must already be installed and loaded
# (run ./install_nvidia_driver.sh, reboot, and check that nvidia-smi works).
# CUDA and cuDNN user-space libraries come from Python wheels, so the CUDA
# toolkit does not need to be installed system-wide.
#
# Usage:
#   sudo ./install_unstructured_api.sh
#
# Environment overrides:
#   APP_USER=kiosk                  service account (created if missing)
#   INSTALL_ROOT=/opt/unstructured  where the app and its Python live
#   UNSTRUCTURED_API_REF=<ref>      git branch/tag/commit to check out (default: repo default branch)
#   PORT=8000                       listen port
#   WORKERS=1                       uvicorn workers (each loads models into GPU memory)
#   UNSTRUCTURED_API_KEY=<key>      require this key in the unstructured-api-key header
#   PANDOC_VERSION=3.6.4            pandoc release used if dnf has no pandoc package
#   REQUIRE_GPU=1                   set to 0 to finish even if CUDA is not usable
#
# After it finishes, check with:
#   systemctl status unstructured-api
#   curl -s http://localhost:8000/healthcheck

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,27p' "$0"; exit 0
fi

# --- Configuration -----------------------------------------------------------

APP_USER="${APP_USER:-kiosk}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/unstructured}"
APP_DIR="${INSTALL_ROOT}/unstructured-api"
PYTHON_DIR="${INSTALL_ROOT}/python"
UNSTRUCTURED_API_REF="${UNSTRUCTURED_API_REF:-}"
PORT="${PORT:-8000}"
WORKERS="${WORKERS:-1}"
UNSTRUCTURED_API_KEY="${UNSTRUCTURED_API_KEY:-}"
PANDOC_VERSION="${PANDOC_VERSION:-3.6.4}"
REQUIRE_GPU="${REQUIRE_GPU:-1}"
ENV_FILE="/etc/unstructured-api/unstructured-api.env"
UNIT_FILE="/etc/systemd/system/unstructured-api.service"

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

if ! command -v nvidia-smi &> /dev/null || ! nvidia-smi &> /dev/null; then
    if [[ "$REQUIRE_GPU" == "1" ]]; then
        echo "Error: nvidia-smi is missing or cannot talk to the GPU." >&2
        echo "Run ./install_nvidia_driver.sh and reboot first (or set REQUIRE_GPU=0)." >&2
        exit 1
    fi
    echo "Warning: no working NVIDIA driver; continuing because REQUIRE_GPU=0."
else
    echo "Found GPU:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | sed 's/^/  /'
fi

# --- [1/6] System packages ---------------------------------------------------

echo ">>> [1/6] Installing system dependencies..."

# CRB + EPEL carry several of the document tools on EL9/EL10.
dnf -y install dnf-plugins-core
dnf config-manager --set-enabled crb
dnf -y install epel-release

# Debian -> Rocky package mapping:
#   libmagic-dev   -> file-devel (libmagic for python-magic)
#   tesseract-ocr  -> tesseract (+ English language data)
#   (implicit)     -> mesa-libGL, glib2: needed by opencv, absent on minimal images
dnf -y install --setopt=install_weak_deps=False \
    ca-certificates \
    curl \
    git \
    make \
    gcc \
    gcc-c++ \
    tar \
    gzip \
    file-devel \
    poppler-utils \
    tesseract \
    mesa-libGL \
    glib2

# English traineddata is a separate package on some releases.
dnf -y install --setopt=install_weak_deps=False tesseract-langpack-eng &> /dev/null || true
if ! tesseract --list-langs 2>/dev/null | grep -qx 'eng'; then
    echo "Error: tesseract has no English language data installed." >&2
    exit 1
fi

# LibreOffice converts legacy .doc/.ppt/.xls. Rocky 9 ships it in AppStream;
# Rocky 10 dropped it, so treat it as optional there.
if ! dnf -y install --setopt=install_weak_deps=False \
        libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress; then
    echo "Warning: LibreOffice is not available from the enabled repos."
    echo "         .doc/.ppt/.xls files will fail to parse until 'soffice' is installed."
fi

# pandoc handles .epub/.odt/.rtf/.org/.rst. Use the distro package if there is
# one, otherwise pull the official static build.
if ! command -v pandoc &> /dev/null; then
    if ! dnf -y install --setopt=install_weak_deps=False pandoc &> /dev/null; then
        case "$(uname -m)" in
            x86_64)  PANDOC_ARCH="amd64" ;;
            aarch64) PANDOC_ARCH="arm64" ;;
            *) echo "Error: no pandoc build for $(uname -m)." >&2; exit 1 ;;
        esac
        echo "Installing pandoc ${PANDOC_VERSION} from GitHub releases..."
        tmp="$(mktemp -d)"
        curl -fsSL -o "${tmp}/pandoc.tar.gz" \
            "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-${PANDOC_ARCH}.tar.gz"
        tar -xzf "${tmp}/pandoc.tar.gz" -C "$tmp"
        install -m 0755 "${tmp}/pandoc-${PANDOC_VERSION}/bin/pandoc" /usr/local/bin/pandoc
        rm -rf "$tmp"
    fi
fi
echo "pandoc: $(pandoc --version | head -n1)"

# --- [2/6] Service account ---------------------------------------------------

echo ">>> [2/6] Ensuring user ${APP_USER} exists..."
if ! id -u "${APP_USER}" &> /dev/null; then
    useradd -m -s /bin/bash "${APP_USER}"
fi
APP_HOME="$(getent passwd "${APP_USER}" | cut -d: -f6)"

# The app lives under /opt rather than the home directory: with SELinux
# enforcing, systemd may not execute binaries labelled user_home_t.
install -d -o "${APP_USER}" -g "${APP_USER}" -m 0755 "${INSTALL_ROOT}"

# --- [3/6] + [4/6] App install (as the service user) -------------------------

echo ">>> [3/6] Installing uv and unstructured-api as ${APP_USER}..."
runuser -u "${APP_USER}" -- env \
    HOME="${APP_HOME}" \
    APP_DIR="${APP_DIR}" \
    UNSTRUCTURED_API_REF="${UNSTRUCTURED_API_REF}" \
    REQUIRE_GPU="${REQUIRE_GPU}" \
    UV_PYTHON_INSTALL_DIR="${PYTHON_DIR}" \
    UV_PYTHON_PREFERENCE="only-managed" \
    bash -euo pipefail -c '
    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    if [[ ! -d "$APP_DIR/.git" ]]; then
        git clone https://github.com/Unstructured-IO/unstructured-api.git "$APP_DIR"
    fi
    cd "$APP_DIR"
    if [[ -n "$UNSTRUCTURED_API_REF" ]]; then
        git fetch --tags origin
        git checkout "$UNSTRUCTURED_API_REF"
    fi

    make install

    echo ">>> [4/6] Swapping CPU onnxruntime for onnxruntime-gpu..."
    # Both packages provide the same "onnxruntime" module, so remove whichever
    # are present (make install can put the CPU build back on a rerun), then
    # install the GPU build cleanly. Checking first avoids uv warnings about
    # packages that are not installed.
    installed=()
    for pkg in onnxruntime onnxruntime-gpu; do
        if uv pip show "$pkg" &> /dev/null; then
            installed+=("$pkg")
        fi
    done
    if (( ${#installed[@]} )); then
        uv pip uninstall "${installed[@]}"
    fi
    # The cuda/cudnn extras pull the CUDA 12 runtime and cuDNN 9 as wheels, so
    # no system CUDA toolkit is needed.
    uv pip install "onnxruntime-gpu[cuda,cudnn]"

    echo ">>> Verifying GPU runtimes..."
    .venv/bin/python - <<PY
import sys
import torch
import onnxruntime as ort

if hasattr(ort, "preload_dlls"):
    ort.preload_dlls()

torch_ok = torch.cuda.is_available()
print("PyTorch", torch.__version__, "CUDA:", torch_ok,
      "(" + torch.cuda.get_device_name(0) + ")" if torch_ok else "")
providers = ort.get_available_providers()
print("ONNX Runtime", ort.__version__, "providers:", providers)

if "$REQUIRE_GPU" == "1" and (not torch_ok or "CUDAExecutionProvider" not in providers):
    sys.exit("Error: CUDA is not usable from PyTorch and/or ONNX Runtime.")
PY
'

# Make sure the tree carries the default /opt labels (usr_t, executable by systemd).
if command -v selinuxenabled &> /dev/null && selinuxenabled; then
    restorecon -R "${INSTALL_ROOT}"
fi

# --- [5/6] systemd service ---------------------------------------------------

echo ">>> [5/6] Creating and enabling systemd service..."

# Secrets go in a restricted env file (root + service group), not the world-readable unit file.
install -d -m 0750 -o root -g "${APP_USER}" "$(dirname "${ENV_FILE}")"
install -m 0640 -o root -g "${APP_USER}" /dev/null "${ENV_FILE}"
cat > "${ENV_FILE}" <<EOF
# Managed by install_unstructured_api.sh
${UNSTRUCTURED_API_KEY:+UNSTRUCTURED_API_KEY=${UNSTRUCTURED_API_KEY}}
EOF

cat > "${UNIT_FILE}" <<EOF
# Managed by install_unstructured_api.sh
[Unit]
Description=Unstructured Open Source API
After=network-online.target nvidia-persistenced.service
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment="HOME=${APP_HOME}"
Environment="PATH=${APP_DIR}/.venv/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=-${ENV_FILE}
ExecStart=${APP_DIR}/.venv/bin/uvicorn prepline_general.api.app:app --host 0.0.0.0 --port ${PORT} --workers ${WORKERS}
Restart=on-failure
RestartSec=5
# First start downloads layout models; give it time.
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable unstructured-api.service
systemctl restart unstructured-api.service

# --- [6/6] Firewall ----------------------------------------------------------

echo ">>> [6/6] Opening port ${PORT}/tcp if firewalld is running..."
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PORT}/tcp"
    firewall-cmd --reload
else
    echo "firewalld is not running; skipping."
fi

# --- Done --------------------------------------------------------------------

echo
echo ">>> Setup complete. Service status:"
systemctl is-active unstructured-api.service
echo "Health check: curl -s http://localhost:${PORT}/healthcheck"
