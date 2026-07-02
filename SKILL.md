---
name: cf-tunnel-proxy-deploy
description: Deploy a generic Cloudflare Tunnel + Caddy reverse proxy. Use when user asks to set up a tunnel-based reverse proxy exposing a local/upstream service through a Cloudflare Tunnel hostname. User supplies the tunnel token, public hostname, and local port; the skill installs cloudflared + Caddy and wires them up. Optional client-side API key auth (PROXY_API_KEY) and upstream API-key injection.
---

# Cloudflare Tunnel + Caddy Reverse Proxy (generic)

Deploy a reverse proxy behind a Cloudflare Tunnel. Unlike `mimo-proxy-deploy` (which hardcodes MiMo credentials), this skill is **generic**: the user provides the tunnel token, public hostname, and listening port; the upstream, upstream API-key env var, and client-side auth key are also configurable.

## Architecture

```
Client (Authorization: Bearer <PROXY_API_KEY>) → Cloudflare Tunnel → Caddy (:LOCAL_PORT) → UPSTREAM
```

- `cloudflared` connects to Cloudflare Edge via `cloudflared tunnel run --token "$TUNNEL_TOKEN"` (**remotely-managed**). The skill does NOT decode the token or write a local `config.yml` — ingress (`PUBLIC_HOSTNAME → http://localhost:LOCAL_PORT`) must be pre-configured in the Cloudflare dashboard for this tunnel.
- `Caddy` listens on `LOCAL_PORT` (plus `DASHBOARD_PORT`/`EXTRA_PORT` to survive Cloudflare Dashboard port overrides) and reverse-proxies to `UPSTREAM`. Two independent auth concerns:
  - **Client auth** (`PROXY_API_KEY`, optional): if set, Caddy rejects requests without `Authorization: Bearer <PROXY_API_KEY>` (401). Strongly recommended for public endpoints.
  - **Upstream auth** (`API_KEY_ENV`, optional): if set, Caddy injects `Authorization: Bearer {env.$API_KEY_ENV}` + `x-api-key` on every upstream request, so end clients need zero upstream credentials.

## Required environment variables

| Variable | Description |
|----------|-------------|
| `TUNNEL_TOKEN` | The `eyJ...` tunnel token (data-plane). Get it from Cloudflare dashboard → Networking → Tunnels → your tunnel → Add a replica. |
| `PUBLIC_HOSTNAME` | Public domain mapped to the tunnel (e.g. `mimo.7786.pp.ua`). Not derivable from the token — must be provided. |
| `LOCAL_PORT` | Caddy listening port (e.g. `8359`). Must match the ingress service port configured in Cloudflare. |
| `UPSTREAM` | Backend to proxy to, `host:port` (e.g. `api-sgp-oc.xiaomimimo.com:443`). |

## Optional environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXY_API_KEY` | _(unset)_ | If set, Caddy requires `Authorization: Bearer <PROXY_API_KEY>` from clients (rejects others with 401). Strongly recommended for public endpoints. Shared across all replicas of a tunnel. |
| `API_KEY_ENV` | _(unset)_ | Env var name holding the upstream API key to inject as `Authorization` + `x-api-key`. If unset, no upstream auth injection. Example: `MIMO_API_KEY`. |
| `DASHBOARD_PORT` | `62852` | Extra Caddy listen port (Cloudflare Dashboard may push traffic here). |
| `EXTRA_PORT` | `7860` | Another extra listen port. |
| `CADDY_VERSION` | `2.11.3` | Caddy release version. |
| `UPSTREAM_TLS` | auto (`true` if UPSTREAM port is 443) | Force `true`/`false`. |

## Deployment

### Non-root (containers, ordinary users) — recommended for Claw environments

```bash
export TUNNEL_TOKEN="eyJ..."
export PUBLIC_HOSTNAME="mimo.7786.pp.ua"
export LOCAL_PORT="8359"
export UPSTREAM="api-sgp-oc.xiaomimimo.com:443"
export PROXY_API_KEY="sk-..."            # optional but recommended (client auth)
export API_KEY_ENV="MIMO_API_KEY"        # optional (upstream auth injection)
export MIMO_API_KEY="sk-..."             # the actual upstream key, if API_KEY_ENV set

bash scripts/deploy-user.sh
```

Installs to `~/.local/bin/`, config in `~/.config/cf-tunnel-proxy/`, logs in `~/.local/log/cf-tunnel-proxy/`.

### Root (systemd)

```bash
sudo TUNNEL_TOKEN="..." PUBLIC_HOSTNAME="..." LOCAL_PORT="..." UPSTREAM="..." \
     PROXY_API_KEY="..." API_KEY_ENV="..." MIMO_API_KEY="..." bash scripts/deploy.sh
```

## Token note

`TUNNEL_TOKEN` is the **data-plane** credential. It lets cloudflared connect to Cloudflare Edge. It does **not** authorize Cloudflare REST API calls (listing replicas / connections needs a separate `CF_API_TOKEN` — control plane). See `README.md` for verifying per-replica connectivity.

## Troubleshooting

- **401 from public URL**: `PROXY_API_KEY` is set — send `Authorization: Bearer <PROXY_API_KEY>`. If you didn't set it, the deploy script prints a warning and the endpoint is open.
- **`Invalid tunnel secret` / `Unauthorized` in cloudflared log**: the `TUNNEL_TOKEN` is wrong or revoked — re-copy from Cloudflare dashboard. Do NOT fall back to a different token.
- **502 from public URL**: Cloudflare Dashboard overrode the local port — Caddy listens on `DASHBOARD_PORT`/`EXTRA_PORT` too to absorb this.
- **403 / 401 from upstream**: the upstream API key is wrong/missing, or `API_KEY_ENV` points to an unset env var.
- **Caddy not running**: `pgrep caddy` / log `~/.local/log/cf-tunnel-proxy/caddy.log`.
- **Tunnel not connecting**: `pgrep cloudflared` / log `~/.local/log/cf-tunnel-proxy/cloudflared.log`.
- **Stop**: `pkill cloudflared; pkill caddy`.
