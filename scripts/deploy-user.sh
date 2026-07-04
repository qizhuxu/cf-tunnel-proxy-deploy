#!/bin/bash
set -e

# ── Cloudflare Tunnel + Caddy reverse proxy (generic, user-level) ──
# Non-root deploy. All config from environment.
# Uses --token (remotely-managed). The eyJ... token is the connector token;
# ingress (PUBLIC_HOSTNAME → http://localhost:LOCAL_PORT) must be configured
# in Cloudflare dashboard/API for this tunnel. This script does NOT write local
# cloudflared config — it just runs cloudflared with --token.

# ── Required env ──
: "${TUNNEL_TOKEN:?TUNNEL_TOKEN required (the eyJ... string from Cloudflare dashboard)}"
: "${PUBLIC_HOSTNAME:?PUBLIC_HOSTNAME required (e.g. mimo.7786.pp.ua) — must be mapped to this tunnel in Cloudflare}"
: "${LOCAL_PORT:?LOCAL_PORT required (e.g. 8359) — must match the ingress service port configured in Cloudflare}"
: "${UPSTREAM:?UPSTREAM required (e.g. api-sgp-oc.xiaomimimo.com:443)}"

# PROXY_API_KEY: if set, Caddy rejects requests without "Authorization: Bearer <PROXY_API_KEY>".
# Strongly recommended for public endpoints — without it, anyone who finds your
# tunnel URL can use your upstream for free. If unset, the proxy is open.
if [ -z "$PROXY_API_KEY" ]; then
  echo "WARNING: PROXY_API_KEY unset — public endpoint is OPEN (no client auth)."
fi

# ── Optional env with defaults ──
DASHBOARD_PORT="${DASHBOARD_PORT:-62852}"
EXTRA_PORT="${EXTRA_PORT:-7860}"
SHIM_PORT="${SHIM_PORT:-$((LOCAL_PORT + 1))}"
CADDY_VERSION="${CADDY_VERSION:-2.11.3}"
# API_KEY_ENV: if set, inject {env.$API_KEY_ENV} as Authorization + x-api-key upstream. If unset, plain proxy.
UPSTREAM_HOST="${UPSTREAM%%:*}"
UPSTREAM_PORT="${UPSTREAM##*:}"
UPSTREAM_TLS="${UPSTREAM_TLS:-$([ "$UPSTREAM_PORT" = "443" ] && echo true || echo false)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/cf-tunnel-proxy"
LOG_DIR="$HOME/.local/log/cf-tunnel-proxy"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)}"
if [ -z "$PYTHON_BIN" ]; then
  echo "ERROR: python3/python required for OpenAI compatibility shim"
  exit 1
fi

# ── 1. Install cloudflared ──
echo "==> Installing cloudflared..."
if [ ! -f "$INSTALL_DIR/cloudflared" ]; then
  curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o "$INSTALL_DIR/cloudflared"
  chmod +x "$INSTALL_DIR/cloudflared"
fi
echo "  cloudflared: $($INSTALL_DIR/cloudflared --version 2>&1 | head -1)"

# ── 2. Start tunnel (--token, remotely-managed) ──
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1
echo "==> Starting tunnel (--token, remotely-managed)..."
echo "  NOTE: ingress '${PUBLIC_HOSTNAME} → http://localhost:${LOCAL_PORT}' must be configured"
echo "        for this tunnel in Cloudflare dashboard (Networks → Tunnels → Public Hostname)."
nohup "$INSTALL_DIR/cloudflared" tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" > "$LOG_DIR/cloudflared.log" 2>&1 & disown
echo "  tunnel PID: $(pgrep -f 'cloudflared tunnel' | head -1)"

# ── 3. Install Caddy ──
echo "==> Installing Caddy ${CADDY_VERSION}..."
if [ ! -f "$INSTALL_DIR/caddy" ]; then
  curl -sL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" | tar xz -C "$INSTALL_DIR" caddy
  chmod +x "$INSTALL_DIR/caddy"
fi
echo "  caddy: $($INSTALL_DIR/caddy version 2>&1)"

# ── 4. Build Caddyfile ──
echo "==> Configuring Caddy..."
API_KEY_LINE=""
if [ -n "$API_KEY_ENV" ]; then
  if [ -z "${!API_KEY_ENV}" ]; then
    echo "ERROR: API_KEY_ENV='$API_KEY_ENV' but env var \$$API_KEY_ENV is not set"
    exit 1
  fi
  API_KEY_LINE="        header_up Authorization \"Bearer {env.${API_KEY_ENV}}\""$'\n'"        header_up x-api-key {env.${API_KEY_ENV}}"
fi

# AUTH_BLOCK: if PROXY_API_KEY set, reject clients without that bearer token.
# {env.PROXY_API_KEY} is a Caddy placeholder — Caddy reads it from its process
# env at config load. The Caddyfile on disk contains no secret.
AUTH_BLOCK=""
if [ -n "$PROXY_API_KEY" ]; then
  AUTH_BLOCK=$'    @unauth {\n        not header Authorization "Bearer {env.PROXY_API_KEY}"\n    }\n    respond @unauth 401\n'
fi

cat > "$CONFIG_DIR/Caddyfile" << EOF
:${LOCAL_PORT}, :${DASHBOARD_PORT}, :${EXTRA_PORT} {
${AUTH_BLOCK}    reverse_proxy 127.0.0.1:${SHIM_PORT} {
        header_up Host ${UPSTREAM_HOST}
${API_KEY_LINE}
    }
}
EOF
"$INSTALL_DIR/caddy" fmt --overwrite "$CONFIG_DIR/Caddyfile"

# ── 5. Start OpenAI compatibility shim ──
echo "==> Starting OpenAI compatibility shim..."
pkill -f "openai_compat_proxy.py" 2>/dev/null || true
sleep 1
nohup env UPSTREAM="$UPSTREAM" UPSTREAM_TLS="$UPSTREAM_TLS" SHIM_PORT="$SHIM_PORT" \
  "$PYTHON_BIN" "$SCRIPT_DIR/openai_compat_proxy.py" --host 127.0.0.1 --port "$SHIM_PORT" \
  > "$LOG_DIR/openai_compat_proxy.log" 2>&1 & disown
sleep 1
echo "  shim PID: $(pgrep -f 'openai_compat_proxy.py' | head -1)"

# ── 6. Start Caddy ──
echo "==> Starting Caddy..."
pkill caddy 2>/dev/null || true
sleep 1
nohup "$INSTALL_DIR/caddy" run --config "$CONFIG_DIR/Caddyfile" > "$LOG_DIR/caddy.log" 2>&1 & disown
sleep 2

# ── 7. Verify ──
echo ""
echo "==> Verification:"
echo -n "  cloudflared: "; pgrep -f "cloudflared tunnel" > /dev/null && echo "running (PID $(pgrep -f 'cloudflared tunnel' | head -1))" || echo "NOT running"
echo -n "  shim: "; pgrep -f "openai_compat_proxy.py" > /dev/null && echo "running (PID $(pgrep -f 'openai_compat_proxy.py' | head -1))" || echo "NOT running"
echo -n "  caddy: "; pgrep caddy > /dev/null && echo "running (PID $(pgrep caddy | head -1))" || echo "NOT running"
echo -n "  port ${LOCAL_PORT}: "; ss -tlnp 2>/dev/null | grep ":${LOCAL_PORT}" > /dev/null && echo "listening" || echo "checking..."
if [ -n "$PROXY_API_KEY" ]; then
  echo -n "  local (no key, expect 401): "; curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LOCAL_PORT}/" 2>/dev/null; echo ""
  echo -n "  local (with key, expect 200): "; curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $PROXY_API_KEY" "http://localhost:${LOCAL_PORT}/" 2>/dev/null; echo ""
  echo -n "  public (no key, expect 401): "; curl -s -o /dev/null -w "%{http_code}" "https://${PUBLIC_HOSTNAME}/" 2>/dev/null; echo ""
  echo -n "  public (with key, expect 200): "; curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $PROXY_API_KEY" "https://${PUBLIC_HOSTNAME}/" 2>/dev/null; echo ""
else
  echo -n "  local test: "; curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LOCAL_PORT}/" 2>/dev/null; echo ""
  echo -n "  public test: "; curl -s -o /dev/null -w "%{http_code}" "https://${PUBLIC_HOSTNAME}/" 2>/dev/null; echo ""
fi
echo ""
echo "==> Done! Public endpoint: https://${PUBLIC_HOSTNAME}"
if [ -n "$PROXY_API_KEY" ]; then
  echo "   Client auth: REQUIRED (Authorization: Bearer \$PROXY_API_KEY)"
else
  echo "   Client auth: NONE (open proxy — set PROXY_API_KEY to enable)"
fi
if [ -n "$API_KEY_ENV" ]; then
  echo "   Upstream auth: injected via env \$$API_KEY_ENV"
else
  echo "   Upstream auth: none (plain proxy to upstream)"
fi
echo ""
echo "==> Stop: pkill cloudflared; pkill caddy; pkill -f openai_compat_proxy.py"
echo "==> Logs: $LOG_DIR/"
