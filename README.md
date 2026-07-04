# cf-tunnel-proxy-deploy

Generic **Cloudflare Tunnel + Caddy reverse proxy** one-shot deploy skill. The user supplies the tunnel token, public hostname, and listening port; the skill installs `cloudflared` + `Caddy` + a small Python compatibility shim and wires them together. Optional client-side auth (`PROXY_API_KEY`) and upstream API-key injection (`API_KEY_ENV`). The shim removes OpenAI-client `"[undefined]"` JSON sentinels before forwarding chat completions to MiMo.

This is the generic version of [`mimo-proxy-deploy`](https://github.com/qizhuxu/mimo-proxy-deploy) — no hardcoded tunnel credentials, domain, or upstream.

## Architecture

```
Client (Authorization: Bearer <PROXY_API_KEY>) → Cloudflare Tunnel → Caddy (:LOCAL_PORT) → OpenAI compatibility shim (:SHIM_PORT) → UPSTREAM
```

- `cloudflared` (**remotely-managed**): runs `cloudflared tunnel run --token "$TUNNEL_TOKEN"`. Does NOT decode the token or write local config — ingress (`PUBLIC_HOSTNAME → http://localhost:LOCAL_PORT`) must be pre-configured in the Cloudflare dashboard.
- `Caddy`: listens on `LOCAL_PORT` (+ `DASHBOARD_PORT`/`EXTRA_PORT` to survive Cloudflare Dashboard port overrides), enforces client auth, injects upstream API-key headers, then reverse-proxies to the local shim.
- `OpenAI compatibility shim`: listens on `SHIM_PORT` and forwards to `UPSTREAM`. For `POST /v1/chat/completions` JSON bodies, it removes `"[undefined]"` sentinels that some OpenAI-compatible clients serialize for unset optional parameters. It preserves valid falsey values (`false`, `0`) and message `content` text.
- Two independent auth layers:
  - `PROXY_API_KEY` (optional): if set, requires `Authorization: Bearer <PROXY_API_KEY>` from clients (401 otherwise). Recommended for public endpoints.
  - `API_KEY_ENV` (optional): if set, Caddy injects `Authorization: Bearer {env.$API_KEY_ENV}` + `x-api-key` before the shim forwards upstream, so clients need zero upstream credentials.

## Required env

| Variable | Example | Notes |
|----------|---------|-------|
| `TUNNEL_TOKEN` | `eyJhIjoi...` | The `eyJ...` string from Cloudflare dashboard → Networking → Tunnels → your tunnel → Add a replica. Data-plane credential. |
| `PUBLIC_HOSTNAME` | `mimo.7786.pp.ua` | Public domain mapped to the tunnel. **Not derivable from the token** — must be provided. |
| `LOCAL_PORT` | `8359` | Caddy listen port. Must match the ingress service port configured in Cloudflare. |
| `UPSTREAM` | `api-sgp-oc.xiaomimimo.com:443` | Backend `host:port` to proxy to. |

## Optional env

| Variable | Default | Notes |
|----------|---------|-------|
| `PROXY_API_KEY` | _(unset)_ | If set, Caddy requires `Authorization: Bearer <PROXY_API_KEY>` from clients (401 otherwise). Recommended for public endpoints. |
| `API_KEY_ENV` | _(unset)_ | Env var name holding the upstream API key to inject as `Authorization` + `x-api-key`. If unset → no upstream auth injection. |
| `DASHBOARD_PORT` | `62852` | Extra Caddy listen port. |
| `EXTRA_PORT` | `7860` | Another extra listen port. |
| `SHIM_PORT` | `LOCAL_PORT + 1` | Local-only Python shim port. Caddy forwards to this port. |
| `PYTHON_BIN` | auto-detect | Python executable for the compatibility shim. |
| `CADDY_VERSION` | `2.11.3` | Caddy release. |
| `UPSTREAM_TLS` | auto (`true` if port 443) | Force `true`/`false`. |

## Quick start

```bash
cp env.example .env && edit .env
source .env
bash scripts/deploy-user.sh    # non-root
# or: sudo bash scripts/deploy.sh   # root + systemd
```

Test (if `PROXY_API_KEY` set):
```bash
curl -H "Authorization: Bearer $PROXY_API_KEY" https://${PUBLIC_HOSTNAME}/
```
Without the header you get `401`.

## Files

```
SKILL.md                 # Claude Code skill definition
scripts/deploy-user.sh   # non-root deploy (containers, Claw, ordinary users)
scripts/deploy.sh        # root deploy (systemd)
scripts/openai_compat_proxy.py  # local JSON-body normalization shim
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

Run the same skill on multiple machines with the same `TUNNEL_TOKEN` + `PUBLIC_HOSTNAME`. All `cloudflared` processes become replicas of one tunnel; Cloudflare Edge load-balances across them (geographic closest wins; no round-robin). Failover is automatic. The public hostname is shared — you can't route to a specific replica via the domain. `PROXY_API_KEY` (if set) is shared across all replicas.

## Troubleshooting

- **401 from public URL**: `PROXY_API_KEY` set — send `Authorization: Bearer <key>`.
- **Invalid tunnel secret / Unauthorized in cloudflared log**: `TUNNEL_TOKEN` wrong/revoked — re-copy from Cloudflare dashboard.
- **502 public**: Cloudflare Dashboard overrode the port — Caddy also listens on `DASHBOARD_PORT`/`EXTRA_PORT`.
- **400 `Param Incorrect` from `/v1/chat/completions`**: check that the shim is running (`pgrep -f openai_compat_proxy.py`) and Caddy is proxying to `127.0.0.1:$SHIM_PORT`; the shim removes OpenAI-client `"[undefined]"` optional params before forwarding.
- **401/403 upstream**: `API_KEY_ENV` points to an unset env var, or key invalid.
- **Shim down**: `pgrep -f openai_compat_proxy.py` / `~/.local/log/cf-tunnel-proxy/openai_compat_proxy.log`
- **Caddy down**: `pgrep caddy` / `~/.local/log/cf-tunnel-proxy/caddy.log`
- **Tunnel down**: `pgrep cloudflared` / `~/.local/log/cf-tunnel-proxy/cloudflared.log`
- **Stop**: `pkill cloudflared; pkill caddy; pkill -f openai_compat_proxy.py`
