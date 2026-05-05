#!/usr/bin/env sh
# BonitoTeam worker installer — idempotent.
# Usage:    curl -fsSL {{SERVER_URL}}/install.sh | sh
# Re-runs:  same command — every step is "check / update / create".
#
# Layout after install:
#   ~/.local/share/bonitoteam/BonitoMCP/      stdio MCP server (own Julia env)
#   ~/.local/share/bonitoteam/BonitoWorker/   WS relay (own Julia env)
#   ~/.local/bin/{bonitoteam-worker,bonitoteam-mcp,bonitoteam-worker-start}
#   ~/.config/systemd/user/bonitoteam-worker.service
#   ~/bonitoteam-projects/                    rsync target for project sources
set -eu

SERVER="{{SERVER_URL}}"
SECRET="{{WORKER_SECRET}}"
INSTALL_ROOT="$HOME/.local/share/bonitoteam"
MCP_DIR="$INSTALL_ROOT/BonitoMCP"
WORKER_DIR="$INSTALL_ROOT/BonitoWorker"
BIN_DIR="$HOME/.local/bin"
PROJECTS_ROOT="$HOME/bonitoteam-projects"

echo "==> BonitoTeam worker installer"
echo "    Server : $SERVER"

mkdir -p "$INSTALL_ROOT" "$BIN_DIR" "$PROJECTS_ROOT"

# Make user-local bins available for the rest of this script
export PATH="$BIN_DIR:$HOME/.juliaup/bin:$PATH"

step() { echo ""; echo "==> $*"; }

# ── Prerequisites: claude, claude-agent-acp, npm (user-managed) ──────────────
# We assume you've already installed and logged in to Claude Code via your usual
# means (e.g. `npm install -g @anthropic-ai/claude-code` + `claude login`). The
# installer only verifies they're on PATH.
step "Prerequisites in PATH"
missing=""
for bin in npm claude claude-agent-acp; do
    if command -v "$bin" > /dev/null 2>&1; then
        echo "    ok   : $bin -> $(command -v "$bin")"
    else
        echo "    MISS : $bin"
        missing="$missing $bin"
    fi
done
if [ -n "$missing" ]; then
    echo ""
    echo "ERROR: missing required binaries:$missing"
    echo "       Install with:"
    echo "         npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp"
    echo "         claude login"
    exit 1
fi

# ── Julia (via juliaup) ───────────────────────────────────────────────────────
step "Julia"
if ! command -v juliaup > /dev/null 2>&1; then
    echo "    juliaup missing — installing..."
    curl -fsSL https://install.julialang.org | sh -s -- --yes
    export PATH="$HOME/.juliaup/bin:$PATH"
fi
if ! command -v julia > /dev/null 2>&1; then
    juliaup add lts && juliaup default lts
fi
echo "    julia: $(julia --version)"

# ── Worker bundle (BonitoMCP + BonitoWorker source trees) ────────────────────
step "Worker bundle"
TMP_TAR="$(mktemp -t bonitoteam-bundle.XXXXXX.tar.gz)"
trap 'rm -f "$TMP_TAR"' EXIT
echo "    fetching $SERVER/worker/bundle.tar.gz..."
curl -fsSL "$SERVER/worker/bundle.tar.gz" -o "$TMP_TAR"
tar -xzf "$TMP_TAR" -C "$INSTALL_ROOT"
chmod +x "$MCP_DIR/bin/"* "$WORKER_DIR/bin/"*
echo "    extracted to $INSTALL_ROOT"

step "Instantiate Julia envs"
echo "    BonitoMCP..."
julia --project="$MCP_DIR" --startup-file=no \
    -e 'import Pkg; Pkg.instantiate(); Pkg.precompile()'
echo "    BonitoWorker..."
julia --project="$WORKER_DIR" --startup-file=no \
    -e 'import Pkg; Pkg.instantiate(); Pkg.precompile()'

# ── Wrappers + startup shim ──────────────────────────────────────────────────
step "Wrappers + startup shim"
ln -sf "$MCP_DIR/bin/bonitoteam-mcp"       "$BIN_DIR/bonitoteam-mcp"
ln -sf "$WORKER_DIR/bin/bonitoteam-worker" "$BIN_DIR/bonitoteam-worker"

cat > "$BIN_DIR/bonitoteam-worker-start" << 'STARTSCRIPT'
#!/usr/bin/env sh
export BONITOTEAM_WORKER_SECRET="__SECRET__"
export BONITOTEAM_SERVER_URL="${BONITOTEAM_SERVER_URL:-__SERVER__}"
export BONITOTEAM_MCP_BIN="${BONITOTEAM_MCP_BIN:-__BINDIR__/bonitoteam-mcp}"
export BONITOTEAM_PROJECTS_ROOT="${BONITOTEAM_PROJECTS_ROOT:-__PROJROOT__}"
export PATH="$HOME/.juliaup/bin:$PATH"
exec "__BINDIR__/bonitoteam-worker"
STARTSCRIPT
sed -i.bak \
    -e "s@__SECRET__@$SECRET@g" \
    -e "s@__BINDIR__@$BIN_DIR@g" \
    -e "s@__PROJROOT__@$PROJECTS_ROOT@g" \
    -e "s@__SERVER__@$SERVER@g" \
    "$BIN_DIR/bonitoteam-worker-start"
rm -f "$BIN_DIR/bonitoteam-worker-start.bak"
chmod +x "$BIN_DIR/bonitoteam-worker-start"

# ── systemd user service: enable + start ─────────────────────────────────────
step "systemd user service"
if command -v systemctl > /dev/null 2>&1; then
    SVCDIR="$HOME/.config/systemd/user"
    mkdir -p "$SVCDIR"
    cat > "$SVCDIR/bonitoteam-worker.service" << SVCFILE
[Unit]
Description=BonitoTeam agent worker
After=network.target

[Service]
ExecStart=$BIN_DIR/bonitoteam-worker-start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SVCFILE
    systemctl --user daemon-reload
    systemctl --user enable bonitoteam-worker > /dev/null 2>&1 || true
    systemctl --user restart bonitoteam-worker
    sleep 1
    if systemctl --user is-active --quiet bonitoteam-worker; then
        echo "    bonitoteam-worker.service: active"
    else
        echo "    bonitoteam-worker.service failed to start. Check: journalctl --user -u bonitoteam-worker -e"
    fi
else
    echo "    no systemctl — start manually: $BIN_DIR/bonitoteam-worker-start"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Installation complete."
echo "    The worker holds an outbound WebSocket to $SERVER — no inbound port,"
echo "    no firewall rules needed on this machine. It appears in the dashboard"
echo "    as soon as the connection is up."
