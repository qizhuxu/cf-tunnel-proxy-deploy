# cf-tunnel-proxy-deploy

Generic **Cloudflare Tunnel + Caddy reverse proxy** one-shot deploy skill. The user supplies the tunnel token, public hostname, and listening port; the skill installs `cloudflared` + `Caddy` and wires them together. Optional API-key injection for upstreams that need auth.

This is the generic version of [`mimo-proxy-deploy`](https://github.com/qizhuxu/mimo-proxy-deploy) — no hardcoded tunnel credentials, domain, or upstream.

## Architecture

```
Client → Cloudflare Tunnel → Caddy (:LOCAL_PORT) → UPSTREAM
```

- `cloudflared` (locally-managed): decodes `TUNNEL_TOKEN` → writes credentials JSON + `config.yml` ingress (`PUBLIC_HOSTNAME → http://localhost:LOCAL_PORT`) → runs.
- `Caddy`: listens on `LOCAL_PORT` (+ `DASHBOARD_PORT`/`EXTRA_PORT` to survive Cloudflare Dashboard port overrides). Reverse-proxies to `UPSTREAM`. If `API_KEY_ENV` is set, injects `Authorization: Bearer {env.$API_KEY_ENV}` + `x-api-key` so clients need zero auth.

## Required env

| Variable | Example | Notes |
|----------|---------|-------|
| `TUNNEL_TOKEN` | `eyJhIjoi...` | The `eyJ...` string from Cloudflare dashboard → Networking → Tunnels → your tunnel → Add a replica. Data-plane credential. |
| `PUBLIC_HOSTNAME` | `argo-yg.7786.pp.ua` | Public domain mapped to the tunnel. **Not derivable from the token** — must be provided. |
| `LOCAL_PORT` | `8088` | Caddy listen port + cloudflared ingress target. |
| `UPSTREAM` | `api-sgp-oc.xiaomimimo.com:443` | Backend `host:port` to proxy to. |

## Optional env

| Variable | Default | Notes |
|----------|---------|-------|
| `API_KEY_ENV` | _(unset)_ | Env var name holding the API key to inject as `Authorization` + `x-api-key`. If unset → plain proxy. |
| `DASHBOARD_PORT` | `62852` | Extra Caddy listen port. |
| `EXTRA_PORT` | `7860` | Another extra listen port. |
| `CADDY_VERSION` | `2.11.3` | Caddy release. |
| `UPSTREAM_TLS` | auto (`true` if port 443) | Force `true`/`false`. |

## Quick start

```bash
cp env.example .env && edit .env
source .env
bash scripts/deploy-user.sh    # non-root
# or: sudo bash scripts/deploy.sh   # root + systemd
```

Test:
```bash
curl https://${PUBLIC_HOSTNAME}/
```

## Files

```
SKILL.md                 # Claude Code skill definition
scripts/deploy-user.sh   # non-root deploy (containers, Claw, ordinary users)
scripts/deploy.sh        # root deploy (systemd)
scripts/teardown.sh      # uninstall
env.example              # env template
```

## Token vs API token — what each can do

| Credential | Plane | Can run cloudflared | Can list replicas/connections | Can fetch ingress config |
|------------|-------|---------------------|-------------------------------|--------------------------|
| `TUNNEL_TOKEN` (`eyJ...`) | data | ✅ | ❌ | ❌ |
| `CF_API_TOKEN` (separate) | control | ❌ | ✅ `GET /accounts/{id}/cfd_tunnel/{id}/connections` | ✅ `GET .../configurations` |

The `TUNNEL_TOKEN` is `base64({"a":AccountTag,"t":TunnelID,"s":TunnelSecret})` — the three data-plane credentials packed. It lets cloudflared connect but cannot query the control-plane API. To verify a specific replica is live (per-claw connectivity), you need a separate `CF_API_TOKEN` with `Cloudflare Tunnel: Read`.

## Multiple replicas (one tunnel, many hosts)

Run the same skill on multiple machines with the same `TUNNEL_TOKEN` + `PUBLIC_HOSTNAME`. All `cloudflared` processes become replicas of one tunnel; Cloudflare Edge load-balances across them (geographic closest wins; no round-robin). Failover is automatic. The public hostname is shared — you can't route to a specific replica via the domain.

## Troubleshooting

- **502 public**: Cloudflare Dashboard overrode the port — Caddy also listens on `DASHBOARD_PORT`/`EXTRA_PORT`.
- **token decode failed**: re-copy the `eyJ...` string.
- **401/403 upstream**: `API_KEY_ENV` points to an unset env var, or key invalid.
- **Caddy down**: `pgrep caddy` / `~/.local/log/cf-tunnel-proxy/caddy.log`
- **Tunnel down**: `pgrep cloudflared` / `~/.local/log/cf-tunnel-proxy/cloudflared.log`
- **Stop**: `pkill cloudflared; pkill caddy`
