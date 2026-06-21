// link-shortener — a single Cloudflare Worker that:
//   • serves the admin UI at /admin          (gated by Cloudflare Access)
//   • serves a JSON API at  /api/*           (gated by Cloudflare Access)
//   • redirects short links  /<slug>  → target URL   (PUBLIC, no login)
//
// Storage: Workers KV (binding LINKS). Slug suggestions: Workers AI (binding AI).
//
// The gate is a Cloudflare Access "self-hosted" app scoped to the /admin and
// /api paths only, so the redirects stay public. See scripts/gate.sh.

const RESERVED = new Set([
  "admin", "api", "assets", "favicon.ico", "robots.txt", "_app", "static", "",
]);

// Slug: starts alphanumeric, then letters/numbers/-/_ , max 64 chars.
const SLUG_RE = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/;

// Unambiguous alphabet for random slugs (no 0/O/1/l/i).
const ALPHABET = "23456789abcdefghijkmnpqrstuvwxyz";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // ---- API (gated by Access) ----
    if (path === "/api" || path.startsWith("/api/")) {
      return handleApi(request, env, url);
    }

    // ---- Admin UI + static assets (gated by Access on /admin) ----
    if (path === "/admin" || path === "/admin/") {
      return env.ASSETS.fetch(new Request(url.origin + "/admin/index.html", request));
    }
    if (
      path.startsWith("/admin/") ||
      path.startsWith("/assets/") ||
      path === "/favicon.ico" ||
      path === "/robots.txt"
    ) {
      return env.ASSETS.fetch(request);
    }

    // ---- Root → admin ----
    if (path === "/") {
      return Response.redirect(url.origin + "/admin", 302);
    }

    // ---- Everything else is a short-link slug (PUBLIC) ----
    const slug = decodeURIComponent(path.slice(1).replace(/\/+$/, ""));
    if (!slug || RESERVED.has(slug)) {
      return new Response(notFoundHtml(slug), {
        status: 404,
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }
    const rec = await env.LINKS.get("link:" + slug, "json");
    if (!rec || !rec.url) {
      return new Response(notFoundHtml(slug), {
        status: 404,
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }
    return new Response(null, {
      status: 302,
      headers: { location: rec.url, "cache-control": "no-store" },
    });
  },
};

// ---------------------------------------------------------------------------

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

// Email injected by Cloudflare Access for an authenticated request.
function accessEmail(request) {
  return request.headers.get("Cf-Access-Authenticated-User-Email") || "";
}

async function handleApi(request, env, url) {
  const email = accessEmail(request);

  // Defense in depth: the /api path MUST sit behind Cloudflare Access. If the
  // identity header is missing we refuse, so a mis-configured (un-gated)
  // deployment can't be written to anonymously. Set DEV="true" for `wrangler dev`.
  if (!email && env.DEV !== "true") {
    return json(
      { error: "unauthorized — /api must be protected by Cloudflare Access (run scripts/gate.sh)" },
      403
    );
  }
  const me = email || "dev@localhost";

  const path = url.pathname;
  const method = request.method;

  if (path === "/api/me" && method === "GET") {
    return json({ email: me });
  }

  if (path === "/api/links" && method === "GET") {
    const list = await env.LINKS.list({ prefix: "link:" });
    const links = list.keys
      .map((k) => ({ slug: k.name.slice(5), ...(k.metadata || {}) }))
      .sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
    return json({ links });
  }

  if (path === "/api/links" && method === "POST") {
    const body = await request.json().catch(() => ({}));
    let target = (body.url || "").trim();
    let slug = (body.slug || "").trim();

    let parsed;
    try {
      parsed = new URL(target);
    } catch {
      return json({ error: "Enter a valid URL (including http:// or https://)" }, 400);
    }
    if (!/^https?:$/.test(parsed.protocol)) {
      return json({ error: "URL must start with http:// or https://" }, 400);
    }

    if (slug) {
      if (!SLUG_RE.test(slug)) {
        return json({ error: "Slug may use letters, numbers, - and _ (max 64, must start alphanumeric)" }, 400);
      }
      if (RESERVED.has(slug.toLowerCase())) {
        return json({ error: `"${slug}" is reserved` }, 400);
      }
      if (await env.LINKS.get("link:" + slug)) {
        return json({ error: `"${slug}" is already taken` }, 409);
      }
    } else {
      slug = await uniqueRandomSlug(env);
    }

    const rec = { url: parsed.toString(), createdAt: Date.now(), createdBy: me };
    await env.LINKS.put("link:" + slug, JSON.stringify(rec), { metadata: rec });
    return json({ slug, ...rec }, 201);
  }

  const del = path.match(/^\/api\/links\/(.+)$/);
  if (del && method === "DELETE") {
    const slug = decodeURIComponent(del[1]);
    await env.LINKS.delete("link:" + slug);
    return json({ ok: true });
  }

  if (path === "/api/suggest" && method === "POST") {
    const body = await request.json().catch(() => ({}));
    return json({ suggestions: await suggestSlugs(env, (body.url || "").trim()) });
  }

  return json({ error: "not found" }, 404);
}

async function uniqueRandomSlug(env, len = 6) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const bytes = crypto.getRandomValues(new Uint8Array(len));
    let s = "";
    for (let i = 0; i < len; i++) s += ALPHABET[bytes[i] % ALPHABET.length];
    if (!(await env.LINKS.get("link:" + s))) return s;
  }
  return "x" + Date.now().toString(36);
}

// Ask Workers AI for memorable slugs based on the target page's title + URL.
async function suggestSlugs(env, target) {
  if (!env.AI || !target) return [];
  let context = target;
  try {
    const r = await fetch(target, {
      headers: { "user-agent": "link-shortener-bot/1.0" },
      cf: { cacheTtl: 300, cacheEverything: true },
    });
    const html = await r.text();
    const m = html.match(/<title[^>]*>([^<]+)<\/title>/i);
    if (m) context = m[1].trim().slice(0, 120) + " — " + target;
  } catch {
    /* title fetch is best-effort */
  }

  let raw = "";
  try {
    const out = await env.AI.run("@cf/meta/llama-3.1-8b-instruct", {
      messages: [
        {
          role: "system",
          content:
            "You generate short, memorable URL slugs. Reply with ONLY a JSON array " +
            "of exactly 3 strings: lowercase, words joined by hyphens, max 20 chars, " +
            "no spaces, no quotes around the array elements other than JSON.",
        },
        { role: "user", content: `Suggest 3 slugs for this link:\n${context}` },
      ],
    });
    raw = out.response || "";
  } catch {
    return [];
  }

  let arr = [];
  try {
    arr = JSON.parse((raw.match(/\[[\s\S]*\]/) || ["[]"])[0]);
  } catch {
    arr = raw.split(/[\n,]+/);
  }

  const cleaned = [];
  for (let s of arr) {
    s = String(s)
      .toLowerCase()
      .replace(/[^a-z0-9-]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 40);
    if (SLUG_RE.test(s) && !RESERVED.has(s) && !cleaned.includes(s)) {
      if (!(await env.LINKS.get("link:" + s))) cleaned.push(s);
    }
    if (cleaned.length >= 3) break;
  }
  return cleaned;
}

function notFoundHtml(slug) {
  const s = (slug || "").replace(/[<>&"]/g, "");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>404 · link</title>
<style>
  :root{color-scheme:light dark}
  body{font:16px/1.6 system-ui,sans-serif;display:grid;place-items:center;
       min-height:100vh;margin:0;background:#0b0d12;color:#e6e8ee}
  .card{text-align:center;padding:2rem}
  h1{font-size:3rem;margin:0}
  code{background:#1b1f2a;padding:.15em .4em;border-radius:6px}
  a{color:#7aa2ff}
</style></head><body><div class="card">
  <h1>404</h1>
  <p>No short link for <code>/${s}</code>.</p>
  <p><a href="/admin">Create one →</a></p>
</div></body></html>`;
}
