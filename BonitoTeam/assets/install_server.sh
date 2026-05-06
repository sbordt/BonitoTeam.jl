#!/usr/bin/env bash
# BonitoTeam server installer — idempotent.
# Run as root on a Linux machine:
#
#   sudo bash install_server.sh [options]
#
# Options:
#   --public-url URL       URL workers use to reach this server
#                          (default: http://<auto-detected-ip>:PORT)
#   --monorepo-dir DIR     path to an already-present monorepo (default: /opt/bonitoteam)
#   --repo-url URL         git URL to clone if monorepo-dir is absent
#   --secret SECRET        worker shared secret (auto-generated if omitted)
#   --port PORT            bind port (default: 8038)
#
# TLS / reverse proxy are intentionally out of scope — use cloudflared,
# nginx, or any other tunnel/proxy in front of this service.
#
# After install, give workers the one-liner printed at the end.
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PUBLIC_URL=""
MONOREPO_DIR="/opt/bonitoteam"
REPO_URL=""
SECRET=""
PORT=8038

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --public-url)   PUBLIC_URL="$2";    shift 2 ;;
        --monorepo-dir) MONOREPO_DIR="$2";  shift 2 ;;
        --repo-url)     REPO_URL="$2";      shift 2 ;;
        --secret)       SECRET="$2";        shift 2 ;;
        --port)         PORT="$2";          shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root (sudo bash $0 ...)"; exit 1; }

step() { echo ""; echo "==> $*"; }
ok()   { echo "    ok   : $*"; }
info() { echo "    info : $*"; }

DATA_DIR="/var/lib/bonitoteam"
CONFIG_DIR="/etc/bonitoteam"
SERVER_BIN="$MONOREPO_DIR/BonitoTeam/bin/bonitoteam-server"

echo "==> BonitoTeam server installer"

# ── System user ───────────────────────────────────────────────────────────────
step "System user: bonitoteam"
if id bonitoteam &>/dev/null; then
    ok "bonitoteam user exists"
else
    useradd --system \
            --home-dir "$DATA_DIR" \
            --create-home \
            --shell /usr/sbin/nologin \
            --comment "BonitoTeam server" \
            bonitoteam
    ok "created"
fi
mkdir -p "$DATA_DIR/state" "$DATA_DIR/projects"
chown -R bonitoteam:bonitoteam "$DATA_DIR"
chmod 750 "$DATA_DIR"

# ── Julia via juliaup ─────────────────────────────────────────────────────────
step "Julia (juliaup)"
JULIA_BIN=""
for candidate in \
        "$DATA_DIR/.juliaup/bin/julia" \
        /home/bonitoteam/.juliaup/bin/julia \
        /opt/juliaup/bin/julia \
        "$(command -v julia 2>/dev/null || true)"; do
    [[ -x "$candidate" ]] && { JULIA_BIN="$candidate"; break; }
done

if [[ -z "$JULIA_BIN" ]]; then
    info "juliaup not found — installing for bonitoteam user"
    sudo -u bonitoteam bash -c 'curl -fsSL https://install.julialang.org | sh -s -- --yes'
    sudo -u bonitoteam bash -c 'source ~/.juliaup/env; juliaup add lts; juliaup default lts'
    JULIA_BIN="$DATA_DIR/.juliaup/bin/julia"
fi
ok "$(sudo -u bonitoteam "$JULIA_BIN" --version)"

# ── Monorepo ──────────────────────────────────────────────────────────────────
step "Monorepo"
if [[ -d "$MONOREPO_DIR/BonitoTeam" ]]; then
    ok "found at $MONOREPO_DIR"
elif [[ -n "$REPO_URL" ]]; then
    info "cloning $REPO_URL -> $MONOREPO_DIR"
    git clone "$REPO_URL" "$MONOREPO_DIR"
    chown -R bonitoteam:bonitoteam "$MONOREPO_DIR"
    ok "cloned"
else
    echo ""
    echo "ERROR: $MONOREPO_DIR/BonitoTeam not found and --repo-url not given."
    echo "       Either copy the monorepo to $MONOREPO_DIR or pass --repo-url."
    exit 1
fi
chmod +x "$MONOREPO_DIR/BonitoTeam/bin/"*

# ── Julia env ─────────────────────────────────────────────────────────────────
step "Julia env (BonitoTeam)"
sudo -u bonitoteam "$JULIA_BIN" \
    "--project=$MONOREPO_DIR/BonitoTeam" \
    --startup-file=no \
    -e 'import Pkg; Pkg.instantiate(); Pkg.precompile()'
ok "instantiated + precompiled"

# ── Worker secret ─────────────────────────────────────────────────────────────
step "Worker secret"
if [[ -z "$SECRET" && -f "$CONFIG_DIR/server.env" ]]; then
    SECRET=$(grep '^BONITOTEAM_WORKER_SECRET=' "$CONFIG_DIR/server.env" 2>/dev/null \
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
    # Try to find the machine's outbound IP without an external call first
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}' || true)
    if [[ -z "$LOCAL_IP" ]]; then
        LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    PUBLIC_URL="http://${LOCAL_IP:-127.0.0.1}:$PORT"
    info "auto-detected: $PUBLIC_URL"
    info "(pass --public-url to override, e.g. for a cloudflare tunnel hostname)"
fi
ok "$PUBLIC_URL"

# ── Config file ───────────────────────────────────────────────────────────────
step "Config: $CONFIG_DIR/server.env"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/server.env" << EOF
BONITOTEAM_WORKER_SECRET=$SECRET
BONITOTEAM_PUBLIC_URL=$PUBLIC_URL
BONITOTEAM_PORT=$PORT
BONITOTEAM_HOST=0.0.0.0
BONITOTEAM_STATE_DIR=$DATA_DIR/state
BONITOTEAM_WORKING_DIR=$DATA_DIR/projects
EOF
chown root:bonitoteam "$CONFIG_DIR/server.env"
chmod 640 "$CONFIG_DIR/server.env"
ok "written (mode 640, group bonitoteam)"

# ── systemd service ───────────────────────────────────────────────────────────
step "systemd service: bonitoteam-server"
cat > /etc/systemd/system/bonitoteam-server.service << EOF
[Unit]
Description=BonitoTeam dashboard server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bonitoteam
Group=bonitoteam
EnvironmentFile=$CONFIG_DIR/server.env
Environment=PATH=$DATA_DIR/.juliaup/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$SERVER_BIN
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictRealtime=true
LockPersonality=true
# Julia JIT requires writable+executable pages — MemoryDenyWriteExecute must stay off
ReadWritePaths=$DATA_DIR $MONOREPO_DIR

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable bonitoteam-server > /dev/null 2>&1 || true
ok "installed + enabled"

# ── Start ─────────────────────────────────────────────────────────────────────
step "Start bonitoteam-server"
systemctl restart bonitoteam-server
sleep 2
if systemctl is-active --quiet bonitoteam-server; then
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
echo "    curl -fsSL $PUBLIC_URL/install.sh | sh"
echo ""
echo "  Logs:    journalctl -u bonitoteam-server -f"
echo "  Config:  $CONFIG_DIR/server.env"
