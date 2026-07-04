#!/bin/bash
set -e

# ── Cloudflare Tunnel + Caddy reverse proxy (generic, root/systemd) ──
# Uses --token (remotely-managed). Ingress must be configured in Cloudflare.

: "${TUNNEL_TOKEN:?TUNNEL_TOKEN required (the eyJ... string)}"
: "${PUBLIC_HOSTNAME:?PUBLIC_HOSTNAME required — must be mapped to this tunnel in Cloudflare}"
: "${LOCAL_PORT:?LOCAL_PORT required — must match ingress service port in Cloudflare}"
: "${UPSTREAM:?UPSTREAM required (e.g. api-sgp-oc.xiaomimimo.com:443)}"

# PROXY_API_KEY: if set, Caddy rejects requests without "Authorization: Bearer <PROXY_API_KEY>".
# Strongly recommended for public endpoints. If unset, the proxy is open.
if [ -z "$PROXY_API_KEY" ]; then
  echo "WARNING: PROXY_API_KEY unset — public endpoint is OPEN (no client auth)."
fi

DASHBOARD_PORT="${DASHBOARD_PORT:-62852}"
EXTRA_PORT="${EXTRA_PORT:-7860}"
SHIM_PORT="${SHIM_PORT:-$((LOCAL_PORT + 1))}"
CADDY_VERSION="${CADDY_VERSION:-2.11.3}"
UPSTREAM_HOST="${UPSTREAM%%:*}"
UPSTREAM_PORT="${UPSTREAM##*:}"
UPSTREAM_TLS="${UPSTREAM_TLS:-$([ "$UPSTREAM_PORT" = "443" ] && echo true || echo false)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)}"
if [ -z "$PYTHON_BIN" ]; then
  echo "ERROR: python3/python required for OpenAI compatibility shim"
  exit 1
fi

# 1. cloudflared
echo "==> Installing cloudflared..."
curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# 2. tunnel service (--token, remotely-managed)
echo "==> Installing cloudflared service (--token)..."
echo "  NOTE: ingress '${PUBLIC_HOSTNAME} → http://localhost:${LOCAL_PORT}' must be in Cloudflare."
# systemd service with the token; cloudflared reads TUNNEL_TOKEN env
cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel (cf-tunnel-proxy-deploy)
After=network-online.target
[Service]
Environment="TUNNEL_TOKEN=${TUNNEL_TOKEN}"
ExecStart=/usr/local/bin/cloudflared --no-autoupdate tunnel run --token \$TUNNEL_TOKEN
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cloudflared

# 3. Caddy
echo "==> Installing Caddy ${CADDY_VERSION}..."
curl -sL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" | tar xz -C /usr/local/bin caddy
chmod +x /usr/local/bin/caddy

# 4. Caddyfile
echo "==> Configuring Caddy..."
mkdir -p /etc/caddy
API_KEY_LINE=""
if [ -n "$API_KEY_ENV" ]; then
  if [ -z "${!API_KEY_ENV}" ]; then
    echo "ERROR: API_KEY_ENV='$API_KEY_ENV' but env var \$$API_KEY_ENV is not set"
    exit 1
  fi
  API_KEY_LINE="        header_up Authorization \"Bearer {env.${API_KEY_ENV}}\""$'\n'"        header_up x-api-key {env.${API_KEY_ENV}}"
fi

AUTH_BLOCK=""
if [ -n "$PROXY_API_KEY" ]; then
  AUTH_BLOCK=$'    @unauth {\n        not header Authorization "Bearer {env.PROXY_API_KEY}"\n    }\n    respond @unauth 401\n'
fi

cat > /etc/caddy/Caddyfile << EOF
:${LOCAL_PORT}, :${DASHBOARD_PORT}, :${EXTRA_PORT} {
${AUTH_BLOCK}    reverse_proxy 127.0.0.1:${SHIM_PORT} {
        header_up Host ${UPSTREAM_HOST}
${API_KEY_LINE}
    }
}
EOF
caddy fmt --overwrite /etc/caddy/Caddyfile

# 5. Start OpenAI compatibility shim
cp "$SCRIPT_DIR/openai_compat_proxy.py" /usr/local/bin/openai_compat_proxy.py
chmod +x /usr/local/bin/openai_compat_proxy.py
echo "==> Starting OpenAI compatibility shim..."
pkill -f "openai_compat_proxy.py" 2>/dev/null || true
sleep 1
nohup env UPSTREAM="$UPSTREAM" UPSTREAM_TLS="$UPSTREAM_TLS" SHIM_PORT="$SHIM_PORT" \
  "$PYTHON_BIN" /usr/local/bin/openai_compat_proxy.py --host 127.0.0.1 --port "$SHIM_PORT" \
  > /tmp/openai_compat_proxy.log 2>&1 & disown
sleep 1

# 6. Start Caddy (nohup inherits PROXY_API_KEY from env for {env.PROXY_API_KEY} substitution)
echo "==> Starting Caddy..."
pkill caddy 2>/dev/null || true
sleep 1
nohup caddy run --config /etc/caddy/Caddyfile > /tmp/caddy.log 2>&1 & disown
sleep 2

echo ""
echo "==> Verification:"
echo -n "  cloudflared: "; systemctl is-active cloudflared
echo -n "  shim: "; pgrep -f "openai_compat_proxy.py" > /dev/null && echo "active" || echo "NOT running"
echo -n "  caddy: "; pgrep caddy > /dev/null && echo "active" || echo "NOT running"
echo -n "  port ${LOCAL_PORT}: "; ss -tlnp | grep ":${LOCAL_PORT}" > /dev/null && echo "listening" || echo "NOT listening"
echo -n "  local test: "; curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LOCAL_PORT}/"; echo ""
echo ""
echo "==> Done! Public endpoint: https://${PUBLIC_HOSTNAME}"
if [ -n "$PROXY_API_KEY" ]; then
  echo "   Client auth: REQUIRED (Authorization: Bearer \$PROXY_API_KEY)"
else
  echo "   Client auth: NONE (open proxy)"
fi
