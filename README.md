# 🔗 link-shortener

A self-hosted URL shortener that runs entirely on the **Cloudflare** free tier:

- **One Cloudflare Worker** serves everything — admin UI, JSON API, and the redirects.
- **Workers KV** stores `slug → URL`.
- **Workers AI** powers a “✨ Suggest” button that proposes memorable slugs from the target page.
- **Cloudflare Access (Zero Trust)** is the login gate — only your allow-listed emails can mint links, while the short links themselves stay **public**.

Short links look like `https://link.yourdomain.com/my-name`.

```
┌──────────────────────────── one Worker on link.yourdomain.com ────────────────────────────┐
│  /admin           → admin UI ........... 🔒 Cloudflare Access (login required)              │
│  /api/*           → JSON API ........... 🔒 Cloudflare Access (login required)              │
│  /<slug>          → 302 → target URL ... 🌍 public, no login                                 │
└────────────────────────────────────────────────────────────────────────────────────────────┘
        slug → URL kept in Workers KV   ·   slug suggestions via Workers AI
```

## Why this design

Cloudflare Access normally gates a whole hostname — that would force a login on
your short links too. Instead, this project creates Access apps scoped to the
**`/admin` and `/api` paths only**, so the redirects remain open to the world
while the mint UI stays private. No GUI clicks required: it’s all API.

---

## Prerequisites

- A **Cloudflare account** with a domain (zone) added to it.
- [`pnpm`](https://pnpm.io) and Node 18+.
- [`wrangler`](https://developers.cloudflare.com/workers/wrangler/) (installed as a dev dependency by `pnpm install`).
- `jq` and `curl` (for the gate script).
- A Cloudflare **API token** for the gate, with the `Access: Apps and Policies — Edit` permission.

## Quick start

```bash
git clone https://github.com/htlin222/link-shortener.git
cd link-shortener
pnpm install

# 1. Configure (domain + account). config.toml is gitignored.
cp config.example.toml config.toml
$EDITOR config.toml          # set account_id, hostname, zone_name, gate_emails

# 2. Log in to Cloudflare, create the KV namespace, render wrangler.toml
wrangler login
pnpm run setup

# 3. Deploy the Worker to your custom domain
pnpm run deploy

# 4. Put the login gate in front of /admin and /api
echo 'CF_API_TOKEN=your-access-token' > .cf-gate.env   # gitignored
chmod 600 .cf-gate.env
pnpm run gate

# Done → open https://link.yourdomain.com/admin
```

`pnpm run setup` writes the KV namespace id back into `config.toml` and renders
`wrangler.toml` from `wrangler.toml.example`. Both `config.toml` and
`wrangler.toml` stay out of git.

---

## Configuration (`config.toml`)

| Key           | What it is                                                              |
| ------------- | ---------------------------------------------------------------------- |
| `account_id`  | Cloudflare Account ID (Dashboard → right sidebar).                      |
| `worker_name` | Name of the Worker / KV namespace.                                     |
| `hostname`    | Where short links live, e.g. `link.example.com`.                        |
| `zone_name`   | The root domain in Cloudflare that owns `hostname`.                     |
| `gate_emails` | Space-separated allow-list. Use `@example.com` to allow a whole domain. |
| `kv_id`       | Filled in automatically by `pnpm run setup`.                            |

## Commands

| Command               | What it does                                                      |
| --------------------- | ---------------------------------------------------------------- |
| `pnpm run setup`      | Create the KV namespace and render `wrangler.toml`.              |
| `pnpm run deploy`     | Publish the Worker (`wrangler deploy`).                          |
| `pnpm run gate`       | Gate `/admin` + `/api` with Cloudflare Access.                   |
| `pnpm run gate:status`| Show whether the gates exist.                                    |
| `pnpm run ungate`     | Remove the gates (the site stays up; it just becomes open).      |
| `pnpm run dev`        | Run locally. The API is unguarded locally via `DEV=true`.       |

### Local development

```bash
DEV=true wrangler dev
```

`DEV=true` lets the API work without a Cloudflare Access identity header so you
can test the UI on `localhost`. **Never set `DEV` in production** — the deployed
Worker refuses API writes unless they arrive through the Access gate.

## API

All `/api/*` routes require a valid Cloudflare Access session in production.

| Method & path           | Body                       | Result                                    |
| ----------------------- | -------------------------- | ----------------------------------------- |
| `GET /api/me`           | —                          | `{ email }` of the signed-in user.        |
| `GET /api/links`        | —                          | `{ links: [{slug, url, createdAt, createdBy}] }` |
| `POST /api/links`       | `{ url, slug? }`           | Creates a link (random slug if omitted).  |
| `DELETE /api/links/:slug` | —                        | Deletes a link.                           |
| `POST /api/suggest`     | `{ url }`                  | `{ suggestions: [...] }` from Workers AI. |

## How the gate works

`scripts/gate.sh` creates **one** Cloudflare Access self-hosted application
whose `destinations` cover both protected paths:

- `link.yourdomain.com/admin`
- `link.yourdomain.com/api`

It gets a single *allow* policy for your `gate_emails`. Anything else on the
host — i.e. `/<slug>` — is never matched by the app and stays public. Re-running
`pnpm run gate` updates the app in place (idempotent).

> **Why one app, not two?** Each Access application has its own audience (`aud`),
> and a login cookie is only valid for the app that issued it. If `/admin` and
> `/api` were separate apps, signing in to the admin UI would *not* authorize the
> `fetch` calls it makes to `/api` — the browser would fail them with
> “Failed to fetch”. One app covering both paths shares one session.

> If you use Claude Code, the [`cf-gate`](https://github.com/) skill does exactly
> this; `scripts/gate.sh` is a self-contained version so anyone can reproduce it.

## Security model

- **The Access gate is the only thing protecting `/admin` and `/api`.** The Worker
  trusts the `Cf-Access-Authenticated-User-Email` header that Cloudflare Access
  injects, and refuses any `/api` request that arrives without it (HTTP 403). That
  header is only trustworthy because the gated hostname is the *sole* way to reach
  the Worker.
- **`workers_dev = false`** is set so the Worker is **not** also exposed on an
  un-gated `*.workers.dev` URL. Leaving it enabled would let anyone bypass Access
  and spoof that header — keep it `false`.
- Only `http(s)` destinations are accepted, and slugs are restricted to
  `[A-Za-z0-9_-]`, so the redirect `Location` header can’t be injected and
  `javascript:`/`data:` targets are rejected.
- Short links are intentionally **public open redirects** — anyone with the link
  is sent onward. Don’t mint links to sensitive internal URLs.
- Optional hardening (not enabled): verify the `Cf-Access-Jwt-Assertion` JWT
  against `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs` inside the
  Worker for defense-in-depth.

## Cost

Everything here fits comfortably in Cloudflare’s free tier for personal use:
Workers, KV, Workers AI (with daily free neurons), and Zero Trust (free up to 50
users).

## License

MIT — see [LICENSE](LICENSE).
