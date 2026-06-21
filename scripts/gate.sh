#!/usr/bin/env bash
# gate.sh — put a Cloudflare Access (Zero Trust) login gate in front of the
# admin UI and API ONLY, leaving the short-link redirects public.
#
# It creates ONE self-hosted Access application whose destinations cover both
# paths:   <hostname>/admin   and   <hostname>/api
# Using a single app (not one per path) is important: each Access app has its
# own audience (aud), and a login cookie is only valid for the app that issued
# it. Two separate apps would mean a session for /admin does NOT authorize the
# /api fetches the UI makes — the browser would report "Failed to fetch".
# Short links (/<slug>) are never matched by the app, so they stay public.
#
# Needs a Cloudflare API token with "Access: Apps and Policies: Edit".
# Put it in `.cf-gate.env` (gitignored) as:  CF_API_TOKEN=xxxxx
# Everything else (account id, hostname, allowed emails) is read from config.toml.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .cf-gate.env ] && { set -a; . ./.cf-gate.env; set +a; }
: "${CF_API_TOKEN:?Set CF_API_TOKEN (Access: Apps and Policies: Edit) in .cf-gate.env or the environment}"
[ -f config.toml ] || { echo "✗ config.toml not found"; exit 1; }

cfg() {
  grep -E "^[[:space:]]*$1[[:space:]]*=" config.toml | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+#.*$//; s/^"//; s/"$//'
}

ACCT="$(cfg account_id)"
HOST="$(cfg hostname)"
EMAILS="$(cfg gate_emails)"
API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer $CF_API_TOKEN")
APP_NAME="link-shortener: $HOST"

[ -n "$ACCT" ] && [ -n "$HOST" ] && [ -n "$EMAILS" ] || {
  echo "✗ config.toml needs account_id, hostname and gate_emails"; exit 1;
}

includes() {
  local e
  for e in $EMAILS; do
    if [[ $e == @* ]]; then jq -n --arg d "${e#@}" '{email_domain:{domain:$d}}'
    else jq -n --arg e "$e" '{email:{email:$e}}'; fi
  done | jq -s '.'
}

# Find our app by a destination uri (works regardless of name changes).
app_id() {
  curl -sS "${AUTH[@]}" "$API/accounts/$ACCT/access/apps?per_page=1000" \
    | jq -r --arg u "$HOST/admin" \
        'first(.result[] | select((.destinations // []) | any(.uri == $u)) | .id) // empty'
}

cmd_gate() {
  local inc body id
  inc="$(includes)"
  body="$(jq -n --arg n "$APP_NAME" --arg admin "$HOST/admin" --arg api "$HOST/api" --argjson inc "$inc" \
    '{name:$n, type:"self_hosted", session_duration:"24h", app_launcher_visible:false,
      destinations:[{type:"public",uri:$admin},{type:"public",uri:$api}],
      policies:[{name:"allow", decision:"allow", include:$inc}]}')"
  id="$(app_id)"
  echo "→ Gating $HOST/admin and $HOST/api (single Access app)"
  if [ -n "$id" ]; then
    curl -sS -X PUT "${AUTH[@]}" -H 'content-type: application/json' \
      "$API/accounts/$ACCT/access/apps/$id" -d "$body" \
      | jq -r 'if .success then "  ✓ updated app \(.result.id)" else "  ✗ \(.errors)" end'
  else
    curl -sS -X POST "${AUTH[@]}" -H 'content-type: application/json' \
      "$API/accounts/$ACCT/access/apps" -d "$body" \
      | jq -r 'if .success then "  ✓ created app \(.result.id)" else "  ✗ \(.errors)" end'
  fi
  echo "  allow: $EMAILS"
  echo "  (short links https://$HOST/<slug> stay public)"
}

cmd_ungate() {
  local id; id="$(app_id)"
  if [ -n "$id" ]; then
    curl -sS -X DELETE "${AUTH[@]}" "$API/accounts/$ACCT/access/apps/$id" >/dev/null
    echo "  ✓ removed gate on $HOST (app $id)"
  else
    echo "  • no gate found on $HOST"
  fi
}

cmd_status() {
  local id; id="$(app_id)"
  [ -n "$id" ] || { echo "$HOST → not gated"; return 0; }
  curl -sS "${AUTH[@]}" "$API/accounts/$ACCT/access/apps/$id" \
    | jq '{host:"'"$HOST"'", id:.result.id, aud:.result.aud,
           destinations:[.result.destinations[]?.uri]}'
}

case "${1:-gate}" in
  gate)   cmd_gate ;;
  ungate) cmd_ungate ;;
  status) cmd_status ;;
  *)      echo "usage: scripts/gate.sh [gate|ungate|status]"; exit 1 ;;
esac
