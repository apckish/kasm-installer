#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  Kasm Workspaces – one-line installer for fresh Ubuntu servers
#
#  Usage:
#    curl -sL https://raw.githubusercontent.com/apckish/kasm-installer/main/install.sh | bash
#
#  The script will prompt for domain and SSH port interactively.
# ──────────────────────────────────────────────────────────────

KASM_TARBALL_URL="https://kasm-static-content.s3.amazonaws.com/kasm_release_1.18.0.09f70a.tar.gz"
KASM_CHROME_IMAGE="kasmweb/chrome:1.18.0-rolling-weekly"

# ── Helpers ───────────────────────────────────────────────────
log()  { echo -e "\n\033[1;32m>>>\033[0m $*"; }
err()  { echo -e "\n\033[1;31m!!!\033[0m $*" >&2; exit 1; }

# ── Pre-flight checks ────────────────────────────────────────
[[ $(id -u) -eq 0 ]] || err "Run as root."

# ── Interactive prompts (read from /dev/tty for curl|bash) ────
read -rp "Enter your domain (e.g. mydomain.com): " KASM_DOMAIN < /dev/tty
[[ -n "$KASM_DOMAIN" ]] || err "Domain cannot be empty."

read -rp "Enter SSH port [22]: " SSH_PORT < /dev/tty
SSH_PORT="${SSH_PORT:-22}"

log "Starting Kasm install for $KASM_DOMAIN (SSH port: $SSH_PORT)"

# ── 1. Wait for apt lock & system update ──────────────────────
WAIT_SEC=0
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    log "Another package manager is running. Waiting for it to finish (usually 2-5 min) …"
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        MINS=$((WAIT_SEC / 60))
        SECS=$((WAIT_SEC % 60))
        printf "\r    ⏳ Waited %dm %02ds … (typically finishes within 5 min)" "$MINS" "$SECS"
        sleep 5
        WAIT_SEC=$((WAIT_SEC + 5))
    done
    MINS=$((WAIT_SEC / 60))
    SECS=$((WAIT_SEC % 60))
    printf "\r    ✔ Lock released after %dm %02ds.                                  \n" "$MINS" "$SECS"
fi
log "Updating system …"
apt-get update -qq
apt-get upgrade -y -qq > /dev/null
log "Installing base packages …"
apt-get install -y -qq curl sudo cron certbot ufw > /dev/null

# ── 2. SSH port ───────────────────────────────────────────────
log "Changing SSH port to $SSH_PORT …"
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
if ! grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config; then
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi

# Also handle sshd_config.d drop-ins (Ubuntu 24.04+)
if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] && sed -i "s/^Port .*/Port $SSH_PORT/" "$f"
    done
fi

systemctl restart sshd || systemctl restart ssh || true

# ── 3. Firewall ──────────────────────────────────────────────
log "Configuring firewall …"
ufw default deny incoming > /dev/null 2>&1 || true
ufw default allow outgoing > /dev/null 2>&1 || true
ufw allow "$SSH_PORT"/tcp > /dev/null 2>&1 || true
ufw allow 80/tcp > /dev/null 2>&1 || true
ufw allow 443/tcp > /dev/null 2>&1 || true
ufw --force enable > /dev/null 2>&1 || true

# ── 4. Swap (auto-sized based on RAM) ────────────────────────
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$RAM_MB" -le 2048 ]; then
    SWAP_SIZE="${RAM_MB}M"
elif [ "$RAM_MB" -le 8192 ]; then
    SWAP_SIZE="${RAM_MB}M"
else
    SWAP_SIZE="8G"
fi
log "Detected ${RAM_MB}MB RAM → creating ${SWAP_SIZE} swap …"
if [ ! -f /swapfile ]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
    log "Swap already exists, skipping."
fi

# ── 5. Download & install Kasm ────────────────────────────────
log "Downloading Kasm …"
cd /tmp
TARBALL_FILE=$(basename "$KASM_TARBALL_URL")
curl -# -O "$KASM_TARBALL_URL"
tar -xf "$TARBALL_FILE"

log "Installing Kasm (this takes a few minutes) …"
bash kasm_release/install.sh --accept-eula --swap-size 0 -L 443 2>&1 | tee /tmp/kasm_install.log

ADMIN_PASS=$(grep -oP 'admin@kasm.local.*?Password:\s*\K\S+' /tmp/kasm_install.log || echo "CHECK_LOG")
USER_PASS=$(grep -oP 'user@kasm.local.*?Password:\s*\K\S+' /tmp/kasm_install.log || echo "CHECK_LOG")

# ── 6. Let's Encrypt SSL ─────────────────────────────────────
log "Issuing Let's Encrypt certificate for $KASM_DOMAIN …"
certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email -d "$KASM_DOMAIN" \
    --pre-hook "docker stop kasm_proxy" \
    --post-hook "docker start kasm_proxy"

cp "/etc/letsencrypt/live/$KASM_DOMAIN/fullchain.pem" /opt/kasm/current/certs/kasm_nginx.crt
cp "/etc/letsencrypt/live/$KASM_DOMAIN/privkey.pem"   /opt/kasm/current/certs/kasm_nginx.key
docker restart kasm_proxy

# Auto-renewal deploy hook
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/kasm.sh << 'HOOK'
#!/bin/bash
cp /etc/letsencrypt/live/$RENEWED_LINEAGE/fullchain.pem /opt/kasm/current/certs/kasm_nginx.crt
cp /etc/letsencrypt/live/$RENEWED_LINEAGE/privkey.pem   /opt/kasm/current/certs/kasm_nginx.key
docker restart kasm_proxy
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/kasm.sh

# ── 7. Pull Chrome workspace image ───────────────────────────
log "Pulling Chrome workspace image …"
docker pull "$KASM_CHROME_IMAGE"

# ── 8. Weekly auto-update cron ────────────────────────────────
log "Setting up auto-update cron …"
cat > /opt/kasm/auto_update.sh << 'UPDATER'
#!/bin/bash
set -euo pipefail
LOG="/var/log/kasm_update.log"
LATEST_URL=$(curl -sL "https://kasm.com/downloads" \
    | grep -oP 'https://[^"]+kasm_release_[0-9]+\.[0-9]+\.[0-9]+\.[a-z0-9]+\.tar\.gz' \
    | sort -V | tail -1)
LATEST_VER=$(echo "$LATEST_URL" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')
CURRENT=$(docker inspect kasm_api --format '{{.Config.Image}}' 2>/dev/null \
    | grep -oP '[\d.]+' | head -1 || echo "unknown")

if [ -z "$LATEST_URL" ] || [ "$CURRENT" = "$LATEST_VER" ]; then
    echo "$(date): Up to date ($CURRENT)" >> "$LOG"
    exit 0
fi

echo "$(date): Upgrading $CURRENT → $LATEST_VER" >> "$LOG"
cd /tmp
curl -# -O "$LATEST_URL"
TARBALL=$(basename "$LATEST_URL")
tar -xf "$TARBALL"
bash kasm_release/upgrade.sh --accept-eula 2>&1 >> "$LOG"
echo "$(date): Upgrade complete" >> "$LOG"
UPDATER
chmod +x /opt/kasm/auto_update.sh

# Cron entries: SSL renewal twice daily + Kasm update every Sunday 3 AM
( crontab -l 2>/dev/null || true
  echo "0 */12 * * * certbot renew --quiet"
  echo "0 3 * * 0 /opt/kasm/auto_update.sh"
) | sort -u | crontab -

# ── Done ──────────────────────────────────────────────────────
log "════════════════════════════════════════════"
log " Kasm Workspaces installed successfully!"
log "════════════════════════════════════════════"
echo ""
echo "  URL:     https://$KASM_DOMAIN"
echo "  Admin:   admin@kasm.local / $ADMIN_PASS"
echo "  User:    user@kasm.local  / $USER_PASS"
echo "  SSH:     port $SSH_PORT"
echo ""
echo "  Auto-update: every Sunday 3 AM (log: /var/log/kasm_update.log)"
echo "  SSL:         auto-renews via certbot"
echo ""
echo "  Next step: log into the admin panel → Workspaces to"
echo "  browse and one-click install any workspace image."
echo ""
