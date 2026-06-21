---
name: on-board
description: Deploy your own copy of this link-shortener end-to-end on Cloudflare. Use when someone has cloned the link-shortener repo and wants to stand it up from scratch — configure their domain, create the KV namespace, deploy the Worker to a custom domain, and put a Cloudflare Access login gate in front of the admin UI and API. Covers every gotcha (KV --remote, custom-domain DNS conflicts, single Access app, login email matching).
---

# On-board: deploy link-shortener end-to-end

Walk a brand-new user from a fresh `git clone` to a working, gated URL
shortener on **their** Cloudflare account and domain. Follow these steps in
order. Turn the checklist into TodoWrite items and tick them off.

The end state:
- `https://<their-host>/<slug>` → public 302 redirects (no login).
- `https://<their-host>/admin` → admin UI behind a Cloudflare Access login.
- `https://<their-host>/api/*` → JSON API behind the same gate.

> Run every command from the **repo root**. Ask the user before any
> irreversible step (deleting a DNS record, deleting an Access app).

## 0. Prerequisites — verify, don't assume

```bash
node -v            # >= 18
pnpm -v            # package manager
jq --version       # used by the gate script
wrangler --version # Cloudflare CLI (>=4)
```

If `wrangler` is missing it will be installed by `pnpm install` (it's a
devDependency); call it via `pnpm exec wrangler` thereafter.

Authenticate wrangler against the user's Cloudflare account:

```bash
wrangler login          # opens a browser; the user approves
wrangler whoami         # confirm the account + email are the user's
```

The domain you'll use **must already be a zone in this Cloudflare account**
(check at dash.cloudflare.com). If it isn't, stop and have the user add it
first — nothing here can proceed without the zone.

## 1. Gather config

Ask the user (one at a time, or collect together):

| Field         | Example              | Where to find it                          |
| ------------- | -------------------- | ----------------------------------------- |
| `account_id`  | `3a77…80`            | Cloudflare dash → right sidebar, or `wrangler whoami` |
| `hostname`    | `link.example.com`   | the subdomain the short links live on     |
| `zone_name`   | `example.com`        | the root domain that owns `hostname`      |
| `gate_emails` | `you@example.com`    | space-separated allow-list; `@example.com` allows a whole domain |
| `worker_name` | `link-shortener`     | usually leave as default                  |

Then write `config.toml` (gitignored):

```bash
cp config.example.toml config.toml
# edit config.toml with the values above; leave kv_id empty
```

## 2. Install + provision

```bash
pnpm install
pnpm run setup     # creates the KV namespace, writes kv_id back into config.toml,
                   # and renders wrangler.toml from the template
```

`setup` is idempotent — re-running reuses the KV namespace recorded in
`config.toml`.

## 3. Deploy the Worker

```bash
pnpm run deploy
```

**If deploy fails with `Hostname '<host>' already has externally managed DNS
records`:** the chosen subdomain is already taken by another service (a CNAME,
A record, email tracking, etc.). Do **not** silently delete it. Options to
offer the user:
1. **Pick a different subdomain** (e.g. `go.` / `s.` / `short.`): edit
   `hostname` in `config.toml`, re-run `pnpm run setup`, then `pnpm run deploy`.
2. **Free the hostname**: if the user confirms the existing record is unused,
   delete it in the dashboard (or via the API) and redeploy.

Confirm the deploy output ends with `<host> (custom domain)`. `workers_dev` is
`false` in the config on purpose (see Gotchas) — the Worker is reachable
**only** on the custom domain.

## 4. Gate it with Cloudflare Access

The gate needs a Cloudflare API token (this is the **only** dashboard step):

1. dash.cloudflare.com → My Profile → API Tokens → Create Token → Custom token.
2. Permission: **Account → Access: Apps and Policies → Edit**. Scope it to the
   user's account.
3. Save the token into a gitignored env file:

```bash
cp .cf-gate.env.example .cf-gate.env
# put the token in: CF_API_TOKEN=...
chmod 600 .cf-gate.env
pnpm run gate
```

`gate` creates **one** Access self-hosted app whose destinations cover both
`<host>/admin` and `<host>/api`, with an allow policy for `gate_emails`. Short
links stay public.

## 5. Verify (prove it, don't assume)

```bash
# Public redirect must work without login. Seed a temp key (NOTE: --remote!),
# probe, then delete. KV writes can take up to ~60s to be globally visible.
NS=$(grep -E '^kv_id' config.toml | sed -E 's/.*= *"?([^"]+)"?.*/\1/')
wrangler kv key put  --remote --namespace-id "$NS" "link:onboard-test" '{"url":"https://example.com/"}'
sleep 30
HOST=$(grep -E '^hostname' config.toml | sed -E 's/.*= *"?([^"]+)"?.*/\1/')
curl -s -o /dev/null -w 'public  /onboard-test -> %{http_code} %{redirect_url}\n' "https://$HOST/onboard-test"   # expect 302 -> example.com
curl -s -o /dev/null -w 'gated   /api/me       -> %{http_code} %{redirect_url}\n' "https://$HOST/api/me"          # expect 302 -> cloudflareaccess.com
curl -s -o /dev/null -w 'gated   /admin        -> %{http_code} %{redirect_url}\n' "https://$HOST/admin"           # expect 302 -> cloudflareaccess.com
wrangler kv key delete --remote --namespace-id "$NS" "link:onboard-test"
```

Then have the user open `https://<host>/admin` in a browser, log in with an
allowed email, and mint a real link.

## Gotchas (these are real — they bit the original author)

- **KV `--remote`**: in wrangler v4, `wrangler kv key put|get|delete` default to
  the **local** simulated store. A deployed Worker reads production KV, so always
  pass `--remote` when seeding/inspecting real data. (`pnpm run setup` already
  uses the right path for namespace creation.)
- **Custom-domain DNS conflict**: see step 3. A subdomain that already has a DNS
  record can't be auto-claimed by the Worker.
- **One Access app, not two**: each Access app has its own audience (`aud`); a
  login cookie only authorizes the app that issued it. If `/admin` and `/api`
  were separate apps, the admin UI's `fetch()` to `/api` would fail with
  "Failed to fetch". `gate.sh` correctly uses a single app with two
  destinations — don't split it.
- **"That account does not have access" at login**: the authenticated email
  isn't in an allow rule. Check `gate_emails` lists each address separately
  (space-separated), re-run `pnpm run gate`, and confirm the user logs in with
  the exact allowed address (Gmail ignores dots, so `a.b@gmail.com` and
  `ab@gmail.com` are the same account).
- **`workers_dev = false`**: keep it. If the Worker is also served on a
  `*.workers.dev` URL, that URL is NOT behind Access, and the API trusts the
  `Cf-Access-Authenticated-User-Email` header — anyone could spoof it and bypass
  the gate. The single gated custom domain must be the only entry point.
- **Static-asset cache**: after editing the admin UI, redeploy and hard-refresh
  the browser (Cmd/Ctrl+Shift+R) — the old `index.html` is cached.

## Optional: their own GitHub repo

```bash
gh repo create <name> --public --source=. --remote=origin --push
```

`config.toml`, `wrangler.toml`, and `.cf-gate.env` are gitignored, so no
secrets are pushed — verify with `git ls-files | grep -E 'config.toml|wrangler.toml|cf-gate.env'` (should print nothing).
