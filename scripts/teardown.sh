#!/bin/bash
# Stop and remove Cloudflare Tunnel + Caddy reverse proxy

echo "==> Stopping Caddy..."
pkill caddy 2>/dev/null && echo "  Caddy stopped" || echo "  Caddy not running"

echo "==> Stopping cloudflared..."
systemctl stop cloudflared 2>/dev/null && echo "  cloudflared stopped" || echo "  cloudflared not running (or no systemd)"
systemctl disable cloudflared 2>/dev/null
pkill -f "cloudflared tunnel" 2>/dev/null || true

echo "==> Removing files..."
read -r TUNNEL_ID < <(ls /etc/cloudflared/*.json 2>/dev/null | head -1 | xargs -I{} basename {} .json 2>/dev/null)
rm -f /usr/local/bin/caddy /usr/local/bin/cloudflared
rm -rf /etc/cloudflared /etc/caddy
rm -f /tmp/caddy.log

echo "==> Done. Service fully removed."
