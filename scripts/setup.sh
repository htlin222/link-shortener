#!/usr/bin/env bash
# setup.sh — one-time provisioning from config.toml:
#   1. create the KV namespace (idempotent: id is cached back into config.toml)
#   2. render wrangler.toml from wrangler.toml.example
# Then deploy with `pnpm run deploy` and gate with `pnpm run gate`.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f config.toml ] || { echo "✗ config.toml not found. Run: cp config.example.toml config.toml  (then edit it)"; exit 1; }

# Read a flat TOML key: cfg <key>
cfg() {
  grep -E "^[[:space:]]*$1[[:space:]]*=" config.toml | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+#.*$//; s/^"//; s/"$//'
}

NAME="$(cfg worker_name)"
ACCOUNT_ID="$(cfg account_id)"
HOSTNAME="$(cfg hostname)"
KV_ID="$(cfg kv_id)"

[ -n "$NAME" ] && [ -n "$ACCOUNT_ID" ] && [ -n "$HOSTNAME" ] || {
  echo "✗ config.toml is missing worker_name / account_id / hostname"; exit 1;
}
export CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID"

if [ -z "$KV_ID" ]; then
  echo "→ Creating KV namespace…"
  OUT="$(wrangler kv namespace create LINKS 2>&1)" || { echo "$OUT"; exit 1; }
  KV_ID="$(printf '%s' "$OUT" | grep -oE '[0-9a-f]{32}' | head -1)"
  [ -n "$KV_ID" ] || { echo "✗ Could not parse KV namespace id from:"; echo "$OUT"; exit 1; }
  # cache it back into config.toml
  if grep -qE '^[[:space:]]*kv_id[[:space:]]*=' config.toml; then
    sed -i.bak -E "s|^[[:space:]]*kv_id[[:space:]]*=.*|kv_id = \"$KV_ID\"|" config.toml && rm -f config.toml.bak
  else
    printf '\nkv_id = "%s"\n' "$KV_ID" >> config.toml
  fi
  echo "  ✓ KV namespace: $KV_ID"
else
  echo "→ Reusing KV namespace: $KV_ID"
fi

echo "→ Rendering wrangler.toml…"
sed -e "s|__NAME__|$NAME|g" \
    -e "s|__ACCOUNT_ID__|$ACCOUNT_ID|g" \
    -e "s|__KV_ID__|$KV_ID|g" \
    -e "s|__HOSTNAME__|$HOSTNAME|g" \
    wrangler.toml.example > wrangler.toml
echo "  ✓ wrangler.toml ready"

cat <<EOF

Done. Next:
  pnpm run deploy     # publish the Worker to https://$HOSTNAME
  pnpm run gate       # put a Cloudflare Access login in front of /admin and /api
EOF
