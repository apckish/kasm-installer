# Kasm Installer

One-line installer for [Kasm Workspaces](https://kasm.com) on fresh Ubuntu servers.

## What it does

1. Installs base packages (curl, certbot, ufw, cron)
2. Changes SSH port (customizable, default **22**)
3. Configures UFW firewall (allows custom SSH port + HTTPS 443)
4. Creates swap (auto-sized to match RAM, capped at 8GB)
5. Installs **Kasm Workspaces 1.18.0** (latest)
6. Issues **Let's Encrypt SSL** with auto-renewal
7. Pulls **Chrome** workspace image
8. Sets up **weekly auto-update** cron (Sundays 3 AM)

## Usage

SSH into a **fresh Ubuntu** server (22.04 or 24.04) as root, then run:

```bash
curl -sL https://raw.githubusercontent.com/apckish/kasm-installer/main/install.sh | bash -s -- YOUR_DOMAIN [SSH_PORT]
```

### Examples

```bash
# Default SSH port (22)
curl -sL https://raw.githubusercontent.com/apckish/kasm-installer/main/install.sh | bash -s -- mydomain.com

# Custom SSH port
curl -sL https://raw.githubusercontent.com/apckish/kasm-installer/main/install.sh | bash -s -- mydomain.com 2222
```

## Prerequisites

- Fresh **Ubuntu 22.04 or 24.04**
- Run as **root**
- **DNS A record** pointed to the server's IP before running
- Ports **443** and your chosen **SSH port** (default 22) open at your hosting provider

## After install

1. Open `https://YOUR_DOMAIN` in your browser
2. Log in with the admin credentials shown at the end of the install
3. Go to **Admin → Workspaces** to browse and one-click install any workspace image (browsers, desktops, dev tools, etc.)

## Auto-update

A cron job runs every Sunday at 3 AM to check for new Kasm versions and upgrade automatically. Logs are at `/var/log/kasm_update.log`.

## SSL renewal

Certbot auto-renews the Let's Encrypt certificate. A deploy hook automatically copies the renewed cert into Kasm and restarts the proxy.
