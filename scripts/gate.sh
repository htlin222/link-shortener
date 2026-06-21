#!/usr/bin/env bash
# gate.sh — put a Cloudflare Access (Zero Trust) login gate in front of the
# admin UI and API ONLY, leaving the short-link redirects public.
#
# It creates two self-hosted Access apps scoped to paths:
#   <hostname>/admin   and   <hostname>/api
# so visiting /<slug> never asks anyone to log in.
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

app_id() {
  curl -sS "${AUTH[@]}" "$API/accounts/$ACCT/access/apps?per_page=1000" \
    | jq -r --arg d "$1" 'first(.result[] | select(.domain==$d) | .id) // empty'
}

gate_one() {
  local domain="$1" inc body id
  inc="$(includes)"
  body="$(jq -n --arg n "link-shortener: $domain" --arg d "$domain" --argjson inc "$inc" \
    '{name:$n, domain:$d, type:"self_hosted", session_duration:"24h", app_launcher_visible:false,
      policies:[{name:"allow", decision:"allow", include:$inc}]}')"
  id="$(app_id "$domain")"
  if [ -n "$id" ]; then
    curl -sS -X PUT "${AUTH[@]}" -H 'content-type: application/json' \
      "$API/accounts/$ACCT/access/apps/$id" -d "$body" >/dev/null
    echo "  ✓ updated gate on $domain"
  else
    curl -sS -X POST "${AUTH[@]}" -H 'content-type: application/json' \
      "$API/accounts/$ACCT/access/apps" -d "$body" \
      | jq -r '"  ✓ gated \(.result.domain) (\(.result.id))"'
  fi
}

ungate_one() {
  local domain="$1" id
  id="$(app_id "$domain")"
  if [ -n "$id" ]; then
    curl -sS -X DELETE "${AUTH[@]}" "$API/accounts/$ACCT/access/apps/$id" >/dev/null
    echo "  ✓ removed gate on $domain"
  else
    echo "  • no gate on $domain"
  fi
}

case "${1:-gate}" in
  gate)
    echo "→ Gating $HOST/admin and $HOST/api"
    gate_one "$HOST/admin"
    gate_one "$HOST/api"
    echo "  allow: $EMAILS"
    echo "  (short links https://$HOST/<slug> stay public)"
    ;;
  ungate)
    echo "→ Removing gates on $HOST"
    ungate_one "$HOST/admin"
    ungate_one "$HOST/api"
    ;;
  status)
    for d in "$HOST/admin" "$HOST/api"; do
      id="$(app_id "$d")"
      [ -n "$id" ] && echo "$d → app $id (gated)" || echo "$d → not gated"
    done
    ;;
  *)
    echo "usage: scripts/gate.sh [gate|ungate|status]"; exit 1;;
esac
