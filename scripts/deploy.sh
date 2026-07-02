#!/bin/bash
set -e

# ── Cloudflare Tunnel + Caddy reverse proxy (generic, root/systemd) ──

: "${TUNNEL_TOKEN:?TUNNEL_TOKEN required (the eyJ... string)}"
: "${PUBLIC_HOSTNAME:?PUBLIC_HOSTNAME required}"
: "${LOCAL_PORT:?LOCAL_PORT required}"
: "${UPSTREAM:?UPSTREAM required}"

DASHBOARD_PORT="${DASHBOARD_PORT:-62852}"
EXTRA_PORT="${EXTRA_PORT:-7860}"
CADDY_VERSION="${CADDY_VERSION:-2.11.3}"
UPSTREAM_HOST="${UPSTREAM%%:*}"
UPSTREAM_PORT="${UPSTREAM##*:}"
UPSTREAM_TLS="${UPSTREAM_TLS:-$([ "$UPSTREAM_PORT" = "443" ] && echo true || echo false)}"

# Decode token
TOKEN_JSON=$(python3 -c "
import base64, json, sys
t = sys.argv[1]
d = json.loads(base64.urlsafe_b64decode(t + '=' * (-len(t) % 4)))
print(json.dumps({'AccountTag': d['a'], 'TunnelID': d['t'], 'TunnelSecret': d['s']}))
" "$TUNNEL_TOKEN")
ACCOUNT_TAG=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['AccountTag'])" "$TOKEN_JSON")
TUNNEL_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['TunnelID'])" "$TOKEN_JSON")
TUNNEL_SECRET=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['TunnelSecret'])" "$TOKEN_JSON")

# 1. cloudflared
echo "==> Installing cloudflared..."
curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# 2. tunnel config
echo "==> Configuring tunnel..."
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/${TUNNEL_ID}.json << EOF
{"AccountTag":"${ACCOUNT_TAG}","TunnelSecret":"${TUNNEL_SECRET}","TunnelID":"${TUNNEL_ID}"}
EOF
cat > /etc/cloudflared/config.yml << EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json
ingress:
  - hostname: ${PUBLIC_HOSTNAME}
    service: http://localhost:${LOCAL_PORT}
  - service: http_status:404
EOF
cloudflared tunnel ingress validate
cloudflared service install
systemctl enable --now cloudflared

# 3. Caddy
echo "==> Installing Caddy ${CADDY_VERSION}..."
curl -sL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" | tar xz -C /usr/local/bin caddy
chmod +x /usr/local/bin/caddy

# 4. Caddyfile
echo "==> Configuring Caddy..."
mkdir -p /etc/caddy
TLS_BLOCK=""
if [ "$UPSTREAM_TLS" = "true" ]; then
  TLS_BLOCK=$'\t\t\ttransport http {\n\t\t\t\ttls\n\t\t\t\tread_timeout 120s\n\t\t\t}'
fi
API_KEY_BLOCK=""
if [ -n "$API_KEY_ENV" ]; then
  API_KEY_BLOCK=$'\t\theader_up Authorization "Bearer {env.'${API_KEY_ENV}'}"\n\t\theader_up x-api-key {env.'${API_KEY_ENV}'}'
fi
cat > /etc/caddy/Caddyfile << EOF
:${LOCAL_PORT}, :${DASHBOARD_PORT}, :${EXTRA_PORT} {
\treverse_proxy ${UPSTREAM} {
\t\theader_up Host ${UPSTREAM_HOST}
${API_KEY_BLOCK}
${TLS_BLOCK}
\t}
}
EOF
caddy fmt --overwrite /etc/caddy/Caddyfile

# 5. Start
echo "==> Starting Caddy..."
pkill caddy 2>/dev/null || true
sleep 1
nohup caddy run --config /etc/caddy/Caddyfile > /tmp/caddy.log 2>&1 & disown
sleep 2
rm -f /root/.cloudflared/config.yml

echo ""
echo "==> Verification:"
echo -n "  cloudflared: "; systemctl is-active cloudflared
echo -n "  caddy: "; pgrep caddy > /dev/null && echo "active" || echo "NOT running"
echo -n "  port ${LOCAL_PORT}: "; ss -tlnp | grep ":${LOCAL_PORT}" > /dev/null && echo "listening" || echo "NOT listening"
echo -n "  local test: "; curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LOCAL_PORT}/"; echo ""
echo ""
echo "==> Done! Public endpoint: https://${PUBLIC_HOSTNAME}"
