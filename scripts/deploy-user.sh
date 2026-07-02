#!/bin/bash
set -e

# ── Cloudflare Tunnel + Caddy reverse proxy (generic, user-level) ──
# Non-root deploy. All config from environment.

# ── Required env ──
: "${TUNNEL_TOKEN:?TUNNEL_TOKEN required (the eyJ... string from Cloudflare dashboard)}"
: "${PUBLIC_HOSTNAME:?PUBLIC_HOSTNAME required (e.g. argo-yg.7786.pp.ua)}"
: "${LOCAL_PORT:?LOCAL_PORT required (e.g. 8088)}"
: "${UPSTREAM:?UPSTREAM required (e.g. api-sgp-oc.xiaomimimo.com:443)}"

# ── Optional env with defaults ──
DASHBOARD_PORT="${DASHBOARD_PORT:-62852}"
EXTRA_PORT="${EXTRA_PORT:-7860}"
CADDY_VERSION="${CADDY_VERSION:-2.11.3}"
# API_KEY_ENV: if set, inject {env.$API_KEY_ENV} as Authorization + x-api-key. If unset, plain proxy.
# UPSTREAM_TLS: default true if port 443, else false
UPSTREAM_HOST="${UPSTREAM%%:*}"
UPSTREAM_PORT="${UPSTREAM##*:}"
UPSTREAM_TLS="${UPSTREAM_TLS:-$([ "$UPSTREAM_PORT" = "443" ] && echo true || echo false)}"

INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/cf-tunnel-proxy"
LOG_DIR="$HOME/.local/log/cf-tunnel-proxy"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"

# ── 0. Decode TUNNEL_TOKEN → AccountTag / TunnelID / TunnelSecret ──
echo "==> Decoding TUNNEL_TOKEN..."
TOKEN_JSON=$(python3 -c "
import base64, json, sys
t = sys.argv[1]
d = json.loads(base64.urlsafe_b64decode(t + '=' * (-len(t) % 4)))
print(json.dumps({'AccountTag': d['a'], 'TunnelID': d['t'], 'TunnelSecret': d['s']}))
" "$TUNNEL_TOKEN")
ACCOUNT_TAG=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['AccountTag'])" "$TOKEN_JSON")
TUNNEL_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['TunnelID'])" "$TOKEN_JSON")
TUNNEL_SECRET=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['TunnelSecret'])" "$TOKEN_JSON")
echo "  TunnelID: $TUNNEL_ID"
echo "  AccountTag: $ACCOUNT_TAG"

# ── 1. Install cloudflared ──
echo "==> Installing cloudflared..."
if ! command -v cloudflared &>/dev/null || [ ! -f "$INSTALL_DIR/cloudflared" ]; then
  curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o "$INSTALL_DIR/cloudflared"
  chmod +x "$INSTALL_DIR/cloudflared"
fi
echo "  cloudflared: $($INSTALL_DIR/cloudflared --version 2>&1 | head -1)"

# ── 2. Configure tunnel (locally-managed: write credentials JSON + config.yml) ──
echo "==> Configuring tunnel..."
cat > "$CONFIG_DIR/${TUNNEL_ID}.json" << EOF
{"AccountTag":"${ACCOUNT_TAG}","TunnelSecret":"${TUNNEL_SECRET}","TunnelID":"${TUNNEL_ID}"}
EOF

cat > "$CONFIG_DIR/config.yml" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: $CONFIG_DIR/${TUNNEL_ID}.json
ingress:
  - hostname: ${PUBLIC_HOSTNAME}
    service: http://localhost:${LOCAL_PORT}
  - service: http_status:404
EOF

pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1
echo "==> Starting tunnel..."
nohup "$INSTALL_DIR/cloudflared" tunnel --config "$CONFIG_DIR/config.yml" run > "$LOG_DIR/cloudflared.log" 2>&1 & disown
echo "  tunnel PID: $(pgrep -f 'cloudflared tunnel' | head -1)"

# ── 3. Install Caddy ──
echo "==> Installing Caddy ${CADDY_VERSION}..."
if ! command -v caddy &>/dev/null || [ ! -f "$INSTALL_DIR/caddy" ]; then
  curl -sL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" | tar xz -C "$INSTALL_DIR" caddy
  chmod +x "$INSTALL_DIR/caddy"
fi
echo "  caddy: $($INSTALL_DIR/caddy version 2>&1)"

# ── 4. Build Caddyfile ──
echo "==> Configuring Caddy..."
TLS_LINE=""
if [ "$UPSTREAM_TLS" = "true" ]; then
  TLS_LINE=$'        transport http {\n            tls\n            read_timeout 120s\n        }'
fi
API_KEY_LINE=""
if [ -n "$API_KEY_ENV" ]; then
  if [ -z "${!API_KEY_ENV}" ]; then
    echo "ERROR: API_KEY_ENV='$API_KEY_ENV' but env var \$$API_KEY_ENV is not set"
    exit 1
  fi
  API_KEY_LINE=$'        header_up Authorization "Bearer {env.'"${API_KEY_ENV}"'}"\n        header_up x-api-key {env.'"${API_KEY_ENV}"'}'
fi

cat > "$CONFIG_DIR/Caddyfile" << EOF
:${LOCAL_PORT}, :${DASHBOARD_PORT}, :${EXTRA_PORT} {
    reverse_proxy ${UPSTREAM} {
        header_up Host ${UPSTREAM_HOST}
${API_KEY_LINE}
${TLS_LINE}
    }
}
EOF
"$INSTALL_DIR/caddy" fmt --overwrite "$CONFIG_DIR/Caddyfile"

# ── 5. Start Caddy ──
echo "==> Starting Caddy..."
pkill caddy 2>/dev/null || true
sleep 1
nohup "$INSTALL_DIR/caddy" run --config "$CONFIG_DIR/Caddyfile" > "$LOG_DIR/caddy.log" 2>&1 & disown
sleep 2

# ── 6. Verify ──
echo ""
echo "==> Verification:"
echo -n "  cloudflared: "; pgrep -f "cloudflared tunnel" > /dev/null && echo "running (PID $(pgrep -f 'cloudflared tunnel' | head -1))" || echo "NOT running"
echo -n "  caddy: "; pgrep caddy > /dev/null && echo "running (PID $(pgrep caddy | head -1))" || echo "NOT running"
echo -n "  port ${LOCAL_PORT}: "; ss -tlnp 2>/dev/null | grep ":${LOCAL_PORT}" > /dev/null && echo "listening" || echo "checking..."
echo -n "  local test: "; curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LOCAL_PORT}/" 2>/dev/null; echo ""
echo -n "  public test: "; curl -s -o /dev/null -w "%{http_code}" "https://${PUBLIC_HOSTNAME}/" 2>/dev/null; echo ""
echo ""
echo "==> Done! Public endpoint: https://${PUBLIC_HOSTNAME}"
echo "   Client needs no API key — Caddy injects it" ${API_KEY_ENV:+"(via env \$$API_KEY_ENV)"}
echo ""
echo "==> Stop: pkill cloudflared; pkill caddy"
echo "==> Logs: $LOG_DIR/"
