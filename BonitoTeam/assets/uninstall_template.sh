#!/usr/bin/env sh
# BonitoTeam worker uninstaller — reverses install_template.sh.
#
#   curl -fsSL {{SERVER_URL}}/uninstall.sh | sh
#
# OR, if you already have the file locally:
#   sh ~/.local/share/bonitoteam/BonitoWorker/uninstall.sh
#
# Stops + disables the user systemd service, removes the install root
# (~/.local/share/bonitoteam), the wrapper symlinks, and the systemd unit.
# ~/bonitoteam-projects (cloned repos + project files) is PRESERVED by
# default — pass --purge-projects if you really want to wipe it.
set -eu

PURGE_PROJECTS=0
ASSUME_YES=0
INSTALL_ROOT="$HOME/.local/share/bonitoteam"
BIN_DIR="$HOME/.local/bin"
PROJECTS_ROOT="$HOME/bonitoteam-projects"
SVC_FILE="$HOME/.config/systemd/user/bonitoteam-worker.service"
WRAPPER="$BIN_DIR/bonitoteam-worker-start"
WORKER_LINK="$BIN_DIR/bonitoteam-worker"
MCP_LINK="$BIN_DIR/bonitoteam-mcp"

while [ $# -gt 0 ]; do
    case "$1" in
        --purge-projects) PURGE_PROJECTS=1; shift ;;
        --yes|-y)         ASSUME_YES=1;     shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

step() { echo ""; echo "==> $*"; }
ok()   { echo "    ok   : $*"; }
info() { echo "    info : $*"; }

echo "==> BonitoTeam worker uninstaller"
echo "    Install root : $INSTALL_ROOT       (REMOVE)"
echo "    Wrappers     : $BIN_DIR/bonitoteam-{worker,mcp,worker-start}  (REMOVE)"
echo "    systemd unit : $SVC_FILE  (REMOVE)"
if [ "$PURGE_PROJECTS" -eq 1 ]; then
    echo "    Projects     : $PROJECTS_ROOT (PURGE)"
else
    echo "    Projects     : $PROJECTS_ROOT (KEEP — pass --purge-projects to wipe)"
fi

# ── Confirmation ──────────────────────────────────────────────────────────────
# When run as `curl ... | sh` stdin is the pipe, not the terminal — `read`
# would get EOF and silently fall through to "Aborted". Re-open /dev/tty so
# the prompt actually reaches the user.
#
# `[ -r /dev/tty ]` is misleading: the file always exists, but opening it
# fails when the process has no controlling terminal (cron / CI / nested
# Docker exec). Use an actual open-test in a subshell so we can fall back
# cleanly when there's no terminal at all.
if [ "$ASSUME_YES" -ne 1 ]; then
    if (exec < /dev/tty) 2>/dev/null; then
        echo ""
        printf "Proceed? [y/N] " > /dev/tty
        read -r reply < /dev/tty
        case "$reply" in [Yy]*) ;; *) echo "Aborted."; exit 1 ;; esac
    else
        echo "ERROR: no controlling terminal for the confirmation prompt;" >&2
        echo "       re-run with --yes to skip it." >&2
        exit 1
    fi
fi

# ── Stop + disable user service ───────────────────────────────────────────────
step "Stop + disable user service"
if command -v systemctl > /dev/null 2>&1; then
    if systemctl --user is-active --quiet bonitoteam-worker 2>/dev/null; then
        systemctl --user stop bonitoteam-worker
        ok "stopped"
    else
        info "not running"
    fi
    if systemctl --user is-enabled --quiet bonitoteam-worker 2>/dev/null; then
        systemctl --user disable bonitoteam-worker > /dev/null 2>&1 || true
        ok "disabled"
    else
        info "not enabled"
    fi
else
    info "systemctl not available"
fi

# ── Remove unit ───────────────────────────────────────────────────────────────
step "Remove systemd unit"
if [ -f "$SVC_FILE" ]; then
    rm -f "$SVC_FILE"
    if command -v systemctl > /dev/null 2>&1; then
        systemctl --user daemon-reload || true
    fi
    ok "removed $SVC_FILE"
else
    info "no unit at $SVC_FILE"
fi

# ── Remove wrappers ───────────────────────────────────────────────────────────
step "Remove wrapper scripts + symlinks"
for f in "$WRAPPER" "$WORKER_LINK" "$MCP_LINK"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
        rm -f "$f"
        ok "removed $f"
    fi
done

# ── Remove install root ───────────────────────────────────────────────────────
step "Remove install root"
if [ -d "$INSTALL_ROOT" ]; then
    rm -rf "$INSTALL_ROOT"
    ok "removed $INSTALL_ROOT"
else
    info "no install at $INSTALL_ROOT"
fi

# ── Optionally purge projects ─────────────────────────────────────────────────
if [ "$PURGE_PROJECTS" -eq 1 ]; then
    step "Purge projects"
    if [ -d "$PROJECTS_ROOT" ]; then
        rm -rf "$PROJECTS_ROOT"
        ok "removed $PROJECTS_ROOT"
    else
        info "no projects at $PROJECTS_ROOT"
    fi
else
    step "Preserve projects"
    info "$PROJECTS_ROOT retained — remove manually with: rm -rf $PROJECTS_ROOT"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  BonitoTeam worker uninstalled."
echo "============================================================"
echo ""
echo "  Reinstall:    curl -fsSL <server-url>/install.sh | sh"
