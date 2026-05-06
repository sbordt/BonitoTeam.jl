#!/usr/bin/env bash
# BonitoTeam server installer — idempotent.
# Run as root on a Linux VPS or server:
#
#   sudo bash install_server.sh --domain your.domain.com [options]
#
# Options:
#   --domain DOMAIN        public hostname, e.g. team.example.com  (required)
#   --monorepo-dir DIR     path to an already-present monorepo      (default: /opt/bonitoteam)
#   --repo-url URL         git URL to clone if monorepo-dir is absent
#   --secret SECRET        worker shared secret (auto-generated if omitted)
#   --port PORT            internal Julia bind port                  (default: 8038)
#   --no-nginx             skip nginx setup (handle TLS yourself)
#   --no-certbot           skip Let's Encrypt cert acquisition
#
# What it does:
#   1.  Creates the system user 'bonitoteam'
#   2.  Installs Julia via juliaup for that user (if not already present)
#   3.  Clones or verifies the monorepo
#   4.  Instantiates + precompiles the BonitoTeam Julia env
#   5.  Generates a worker secret (or reuses an existing one)
#   6.  Writes /etc/bonitoteam/server.env   (mode 640, group bonitoteam)
#   7.  Installs /etc/systemd/system/bonitoteam-server.service with hardening
#   8.  Configures nginx as TLS-terminating reverse proxy with WebSocket support
#   9.  Obtains a Let's Encrypt certificate via certbot
#  10.  Enables + starts the service and prints the worker install command
#
# After install, hand workers the one-liner:
#   curl -fsSL https://DOMAIN/install.sh | sh
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DOMAIN=""
MONOREPO_DIR="/opt/bonitoteam"
REPO_URL=""
SECRET=""
PORT=8038
SETUP_NGINX=true
SETUP_CERTBOT=true

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)       DOMAIN="$2";       shift 2 ;;
        --monorepo-dir) MONOREPO_DIR="$2"; shift 2 ;;
        --repo-url)     REPO_URL="$2";     shift 2 ;;
        --secret)       SECRET="$2";       shift 2 ;;
        --port)         PORT="$2";         shift 2 ;;
        --no-nginx)     SETUP_NGINX=false; SETUP_CERTBOT=false; shift ;;
        --no-certbot)   SETUP_CERTBOT=false; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$DOMAIN" ]] && { echo "ERROR: --domain is required"; exit 1; }
[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root (sudo bash $0 ...)"; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
step() { echo ""; echo "==> $*"; }
ok()   { echo "    ok   : $*"; }
info() { echo "    info : $*"; }

DATA_DIR="/var/lib/bonitoteam"
CONFIG_DIR="/etc/bonitoteam"
SERVER_BIN="$MONOREPO_DIR/BonitoTeam/bin/bonitoteam-server"

echo "==> BonitoTeam server installer"
echo "    Domain  : https://$DOMAIN"
echo "    Monorepo: $MONOREPO_DIR"
echo "    Port    : $PORT (internal; proxied by nginx on 443)"

# ── OS check ──────────────────────────────────────────────────────────────────
step "OS"
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ok "${NAME:-Linux} ${VERSION_ID:-}"
else
    info "unknown Linux distribution — proceeding"
fi

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
    ok "bonitoteam user created"
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
    echo "       Either:"
    echo "         rsync -a /local/monorepo/ root@server:$MONOREPO_DIR/"
    echo "       or pass:  --repo-url https://github.com/you/BonitoTeam"
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

# ── Config file ───────────────────────────────────────────────────────────────
step "Config: $CONFIG_DIR/server.env"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/server.env" << EOF
BONITOTEAM_WORKER_SECRET=$SECRET
BONITOTEAM_PUBLIC_URL=https://$DOMAIN
BONITOTEAM_PORT=$PORT
BONITOTEAM_HOST=127.0.0.1
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

# Hardening — see systemd.exec(5)
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
# Julia's JIT requires writable+executable pages — MemoryDenyWriteExecute must stay off
ReadWritePaths=$DATA_DIR $MONOREPO_DIR

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable bonitoteam-server > /dev/null 2>&1 || true
ok "service installed + enabled"

# ── nginx ─────────────────────────────────────────────────────────────────────
if "$SETUP_NGINX"; then
    step "nginx"
    if ! command -v nginx > /dev/null 2>&1; then
        if command -v apt-get > /dev/null 2>&1; then
            apt-get install -y nginx
        elif command -v dnf > /dev/null 2>&1; then
            dnf install -y nginx
        else
            echo "WARNING: nginx not found; install it manually then re-run." >&2
            SETUP_NGINX=false
            SETUP_CERTBOT=false
        fi
    fi
fi

if "$SETUP_NGINX"; then
    # The WebSocket upgrade map must live inside http {}. /etc/nginx/conf.d/ is
    # included from http {} in every standard distribution package.
    for MAP_DIR in /etc/nginx/conf.d /etc/nginx/http.d; do
        if [[ -d "$MAP_DIR" ]]; then
            cat > "$MAP_DIR/bonitoteam-ws-map.conf" << 'MAPEOF'
# Passed through for WebSocket connections; ignored for plain HTTP.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
MAPEOF
            ok "nginx WS map: $MAP_DIR/bonitoteam-ws-map.conf"
            break
        fi
    done

    NGINX_SITES_A="/etc/nginx/sites-available"
    NGINX_SITES_E="/etc/nginx/sites-enabled"
    mkdir -p "$NGINX_SITES_A" "$NGINX_SITES_E"

    cat > "$NGINX_SITES_A/bonitoteam" << NGINXEOF
# BonitoTeam — auto-generated by install_server.sh

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Let certbot serve ACME challenges; redirect everything else to HTTPS.
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # Modern TLS — https://ssl-config.mozilla.org/ (intermediate profile)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=63072000" always;

    # Proxy all traffic to Julia. The \$connection_upgrade map ensures
    # Connection: upgrade only for WebSocket handshakes (safe for plain HTTP too).
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Persistent WebSocket connections (workers + Bonito frontend) can be idle
        # for long periods between messages — raise the read/send timeouts.
        proxy_read_timeout  86400;
        proxy_send_timeout  86400;
        proxy_buffering     off;

        # Allow large project bundle uploads / downloads.
        client_max_body_size 256m;
    }
}
NGINXEOF

    ln -sf "$NGINX_SITES_A/bonitoteam" "$NGINX_SITES_E/bonitoteam" 2>/dev/null || true
    nginx -t 2>/dev/null \
        && ok "nginx config valid" \
        || info "nginx -t reported errors (cert may not exist yet — normal before certbot)"
fi

# ── certbot ───────────────────────────────────────────────────────────────────
if "$SETUP_CERTBOT"; then
    step "certbot (Let's Encrypt)"
    if ! command -v certbot > /dev/null 2>&1; then
        if command -v apt-get > /dev/null 2>&1; then
            apt-get install -y certbot python3-certbot-nginx
        elif command -v dnf > /dev/null 2>&1; then
            dnf install -y certbot python3-certbot-nginx
        else
            info "certbot not found — install it manually and run:"
            info "  certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN"
            SETUP_CERTBOT=false
        fi
    fi
fi

if "$SETUP_CERTBOT"; then
    mkdir -p /var/www/certbot
    # nginx must serve port 80 for the ACME HTTP-01 challenge.
    systemctl start nginx || true
    if certbot --nginx -d "$DOMAIN" \
               --non-interactive --agree-tos \
               -m "admin@$DOMAIN" --redirect; then
        ok "TLS certificate obtained"
        # Install a renewal cron job (certbot's own timer may already exist on
        # some distros, but adding an explicit job is idempotent and safe).
        (crontab -l 2>/dev/null | grep -v 'certbot renew'; \
         echo "0 3 * * * certbot renew --quiet") | crontab -
        ok "certbot renewal cron installed"
    else
        echo ""
        echo "WARNING: certbot failed. Possible causes:"
        echo "  - DNS: $DOMAIN does not resolve to this server's public IP"
        echo "  - Firewall: ports 80 and 443 are not open"
        echo "  - Rate limit: too many recent certificate requests for $DOMAIN"
        echo ""
        echo "  Fix DNS/firewall and re-run, or manually:"
        echo "    certbot --nginx -d $DOMAIN"
    fi
fi

# ── Start the service ─────────────────────────────────────────────────────────
step "Start bonitoteam-server"
systemctl restart bonitoteam-server
sleep 2
if systemctl is-active --quiet bonitoteam-server; then
    ok "bonitoteam-server.service: active"
else
    echo "ERROR: service failed to start." >&2
    echo "  journalctl -u bonitoteam-server -e" >&2
    exit 1
fi

if "$SETUP_NGINX"; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    ok "nginx reloaded"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  BonitoTeam server running at https://$DOMAIN"
echo "============================================================"
echo ""
echo "  Worker install (run on each agent machine):"
echo "    curl -fsSL https://$DOMAIN/install.sh | sh"
echo ""
echo "  Logs:    journalctl -u bonitoteam-server -f"
echo "  Config:  $CONFIG_DIR/server.env"
echo "  State:   $DATA_DIR/state"
echo "  Projects: $DATA_DIR/projects"
echo ""
echo "  Firewall: only ports 80 and 443 need to be open."
echo "  Workers connect outbound — no inbound port required on worker machines."
