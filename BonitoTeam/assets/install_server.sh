#!/usr/bin/env bash
# BonitoTeam server installer — idempotent.
# Run as a regular user (sudo is invoked internally for privileged steps):
#
#   bash BonitoTeam/assets/install_server.sh [options]
#
# The systemd service runs as the user invoking sudo (so it can access
# their juliaup install + the monorepo without permission gymnastics).
# Re-run the script to update — service is stopped first, so we never
# leave half-applied state behind.
#
# Options:
#   --public-url URL   URL workers use to reach this server
#                      (default: http://<auto-detected-ip>:PORT)
#   --secret SECRET    worker shared secret (auto-generated if omitted)
#   --port PORT        bind port (default: 8038)
#
# TLS / reverse proxy are out of scope — put cloudflared or similar in front.
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PUBLIC_URL=""
SECRET=""
PORT=8038

# Script lives at BonitoTeam/assets/install_server.sh → monorepo is two levels up
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONOREPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --public-url) PUBLIC_URL="$2"; shift 2 ;;
        --secret)     SECRET="$2";     shift 2 ;;
        --port)       PORT="$2";       shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

step() { echo ""; echo "==> $*"; }
ok()   { echo "    ok   : $*"; }
info() { echo "    info : $*"; }

# ── Service user ──────────────────────────────────────────────────────────────
# Service runs as the human who invoked the installer — they own the monorepo
# and the juliaup install, so no /home traversal permission issues.
SERVICE_USER="${SUDO_USER:-$USER}"
if [[ -z "$SERVICE_USER" || "$SERVICE_USER" == "root" ]]; then
    echo "ERROR: cannot determine non-root user for the service." >&2
    echo "       Run as a regular user; the script will sudo when needed:" >&2
    echo "         bash $0 ..." >&2
    exit 1
fi
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
[[ -d "$SERVICE_HOME" ]] || { echo "ERROR: $SERVICE_USER's home not found"; exit 1; }

DATA_DIR="/var/lib/bonitoteam"
CONFIG_DIR="/etc/bonitoteam"
SERVER_BIN="$MONOREPO_DIR/BonitoTeam/bin/bonitoteam-server"
JULIA_BIN="$(command -v julia || true)"

echo "==> BonitoTeam server installer"
echo "    Monorepo     : $MONOREPO_DIR"
echo "    Service user : $SERVICE_USER"

# ── Sanity checks ─────────────────────────────────────────────────────────────
step "Sanity checks"
[[ -f "$SERVER_BIN" ]] || { echo "ERROR: $SERVER_BIN not found — run from the cloned repo"; exit 1; }
[[ -n "$JULIA_BIN" ]]  || { echo "ERROR: julia not found in PATH — install Julia first"; exit 1; }
command -v sudo > /dev/null || { echo "ERROR: sudo not found"; exit 1; }
chmod +x "$MONOREPO_DIR/BonitoTeam/bin/"*
ok "julia: $(julia --version)"

# ── Stop service before any changes ───────────────────────────────────────────
# Either the old service is running (if we abort before this point) or it's
# stopped and we own the update fully — never half-and-half.
step "Stop existing service (if running)"
if sudo systemctl is-active --quiet bonitoteam-server 2>/dev/null; then
    sudo systemctl stop bonitoteam-server
    ok "stopped"
else
    ok "not running"
fi

# ── Data dir ──────────────────────────────────────────────────────────────────
step "Data dir: $DATA_DIR"
sudo mkdir -p "$DATA_DIR/state" "$DATA_DIR/projects"
sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
sudo chmod 750 "$DATA_DIR"
ok "owned by $SERVICE_USER"

# ── Julia env ─────────────────────────────────────────────────────────────────
# Always operate against the MONOREPO ROOT's Project.toml + Manifest.toml.
# The per-package Project.toml files (BonitoTeam/Project.toml etc.) are
# metadata for declaring deps and must NEVER be used as a runtime env.
step "Julia env (monorepo root)"
julia "--project=$MONOREPO_DIR" --startup-file=no \
    -e 'import Pkg; Pkg.instantiate()'
ok "instantiated"

# ── Worker secret ─────────────────────────────────────────────────────────────
step "Worker secret"
if [[ -z "$SECRET" ]] && sudo test -f "$CONFIG_DIR/server.env" 2>/dev/null; then
    SECRET=$(sudo grep '^BONITOTEAM_WORKER_SECRET=' "$CONFIG_DIR/server.env" \
             | cut -d= -f2- || true)
    [[ -n "$SECRET" ]] && info "reusing existing secret from $CONFIG_DIR/server.env"
fi
if [[ -z "$SECRET" ]]; then
    SECRET=$(openssl rand -hex 32)
    ok "generated new 256-bit secret"
fi

# ── Public URL ────────────────────────────────────────────────────────────────
step "Public URL"
if [[ -z "$PUBLIC_URL" ]]; then
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}' || true)
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    PUBLIC_URL="http://${LOCAL_IP:-127.0.0.1}:$PORT"
    info "auto-detected — pass --public-url to override (e.g. cloudflare tunnel hostname)"
fi
ok "$PUBLIC_URL"

# ── Config file ───────────────────────────────────────────────────────────────
step "Config: $CONFIG_DIR/server.env"
sudo mkdir -p "$CONFIG_DIR"
sudo tee "$CONFIG_DIR/server.env" > /dev/null << EOF
BONITOTEAM_WORKER_SECRET=$SECRET
BONITOTEAM_PUBLIC_URL=$PUBLIC_URL
BONITOTEAM_PORT=$PORT
BONITOTEAM_HOST=0.0.0.0
BONITOTEAM_STATE_DIR=$DATA_DIR/state
BONITOTEAM_WORKING_DIR=$DATA_DIR/projects
EOF
sudo chown "root:$SERVICE_USER" "$CONFIG_DIR/server.env"
sudo chmod 640 "$CONFIG_DIR/server.env"
ok "written (mode 640, group $SERVICE_USER)"

# ── systemd service ───────────────────────────────────────────────────────────
step "systemd service: bonitoteam-server"
sudo tee /etc/systemd/system/bonitoteam-server.service > /dev/null << EOF
[Unit]
Description=BonitoTeam dashboard server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
EnvironmentFile=$CONFIG_DIR/server.env
Environment=PATH=$(dirname "$JULIA_BIN"):/usr/local/bin:/usr/bin:/bin
ExecStart=$SERVER_BIN
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

# Hardening — see systemd.exec(5).
# ProtectHome is intentionally NOT set: the service runs as the install user
# and needs to read/write its own juliaup lockfile (~/.julia/juliaup/) and
# the Julia depot (~/.julia/). Since we run as that user anyway, blocking
# /home would only stop access to *other* users' homes — irrelevant here.
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictRealtime=true
LockPersonality=true
# Julia JIT requires writable+executable pages — MemoryDenyWriteExecute stays off
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable bonitoteam-server > /dev/null 2>&1 || true
ok "installed + enabled"

# ── Start ─────────────────────────────────────────────────────────────────────
step "Start bonitoteam-server"
sudo systemctl start bonitoteam-server
sleep 2
if sudo systemctl is-active --quiet bonitoteam-server; then
    ok "active"
else
    echo "ERROR: service failed to start." >&2
    echo "  journalctl -u bonitoteam-server -e" >&2
    exit 1
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  BonitoTeam server running at $PUBLIC_URL"
echo "============================================================"
echo ""
echo "  Worker install (run on each agent machine):"
echo "    Linux / macOS:  curl -fsSL $PUBLIC_URL/install.jl | julia -"
echo "    Windows:        curl.exe -fsSL $PUBLIC_URL/install.jl -o install.jl"
echo "                    julia install.jl"
echo ""
echo "  Logs:    journalctl -u bonitoteam-server -f"
echo "  Config:  $CONFIG_DIR/server.env"
echo "  State:   $DATA_DIR"
