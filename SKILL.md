---
name: cf-tunnel-proxy-deploy
description: Deploy a generic Cloudflare Tunnel + Caddy reverse proxy. Use when user asks to set up a tunnel-based reverse proxy exposing a local/upstream service through a Cloudflare Tunnel hostname. User supplies the tunnel token, public hostname, and local port; the skill installs cloudflared + Caddy and wires them up. Optional API key injection for upstreams that need auth.
---

# Cloudflare Tunnel + Caddy Reverse Proxy (generic)

Deploy a reverse proxy behind a Cloudflare Tunnel. Unlike `mimo-proxy-deploy` (which hardcodes MiMo credentials), this skill is **generic**: the user provides the tunnel token, public hostname, and listening port; the upstream and optional API-key env var are also configurable.

## Architecture

```
Client → Cloudflare Tunnel → Caddy (:LOCAL_PORT) → UPSTREAM
```

- `cloudflared` connects to Cloudflare Edge using `TUNNEL_TOKEN` (locally-managed: the skill decodes the token, writes the credentials JSON + `config.yml` ingress `PUBLIC_HOSTNAME → http://localhost:LOCAL_PORT`, and runs cloudflared against it).
- `Caddy` listens on `LOCAL_PORT` (plus `DASHBOARD_PORT`/`EXTRA_PORT` to survive Cloudflare Dashboard port overrides) and reverse-proxies to `UPSTREAM`. If `API_KEY_ENV` is set, Caddy injects `Authorization: Bearer {env.$API_KEY_ENV}` and `x-api-key` on every upstream request, so clients need zero auth.

## Required environment variables

| Variable | Description |
|----------|-------------|
| `TUNNEL_TOKEN` | The `eyJ...` tunnel token (base64 of `{"a","t","s"}`). Get it from Cloudflare dashboard → Networking → Tunnels → your tunnel → Add a replica. |
| `PUBLIC_HOSTNAME` | Public domain mapped to the tunnel (e.g. `argo-yg.7786.pp.ua`). Not derivable from the token — must be provided. |
| `LOCAL_PORT` | Caddy listening port (e.g. `8088`). Also used in cloudflared ingress `→ http://localhost:LOCAL_PORT`. |
| `UPSTREAM` | Backend to proxy to, `host:port` (e.g. `api-sgp-oc.xiaomimimo.com:443`). |

## Optional environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY_ENV` | _(unset)_ | Env var name holding the API key to inject as `Authorization` + `x-api-key`. If unset, plain reverse proxy (no auth injection). Example: `MIMO_API_KEY`. |
| `DASHBOARD_PORT` | `62852` | Extra Caddy listen port (Cloudflare Dashboard may push traffic here). |
| `EXTRA_PORT` | `7860` | Another extra listen port. |
| `CADDY_VERSION` | `2.11.3` | Caddy release version. |

## Deployment

### Non-root (containers, ordinary users) — recommended for Claw environments

```bash
export TUNNEL_TOKEN="eyJ..."
export PUBLIC_HOSTNAME="argo-yg.7786.pp.ua"
export LOCAL_PORT="8088"
export UPSTREAM="api-sgp-oc.xiaomimimo.com:443"
export API_KEY_ENV="MIMO_API_KEY"        # optional
export MIMO_API_KEY="sk-..."             # the actual key, if API_KEY_ENV set

bash scripts/deploy-user.sh
```

Installs to `~/.local/bin/`, config in `~/.config/cf-tunnel-proxy/`, logs in `~/.local/log/cf-tunnel-proxy/`.

### Root (systemd)

```bash
sudo TUNNEL_TOKEN="..." PUBLIC_HOSTNAME="..." LOCAL_PORT="..." UPSTREAM="..." bash scripts/deploy.sh
```

## Token note

`TUNNEL_TOKEN` is the **data-plane** credential. It lets cloudflared connect to Cloudflare Edge. It does **not** authorize Cloudflare REST API calls (listing replicas / connections needs a separate `CF_API_TOKEN` — control plane). See `README.md` for verifying per-replica connectivity.

## Troubleshooting

- **502 from public URL**: Cloudflare Dashboard overrode the local port — Caddy listens on `DASHBOARD_PORT`/`EXTRA_PORT` too to absorb this.
- **`TUNNEL_TOKEN` decode failed**: token is not a valid `eyJ...` string — re-copy from Cloudflare dashboard.
- **403 / 401 from upstream**: the upstream API key is wrong/missing, or `API_KEY_ENV` points to an unset env var.
- **Caddy not running**: `pgrep caddy` / log `~/.local/log/cf-tunnel-proxy/caddy.log`.
- **Tunnel not connecting**: `pgrep cloudflared` / log `~/.local/log/cf-tunnel-proxy/cloudflared.log`.
- **Stop**: `pkill cloudflared; pkill caddy`.
