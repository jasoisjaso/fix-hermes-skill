#!/usr/bin/env bash
# fix-hermes.sh — diagnose & repair Hermes Agent -> Meridian -> Claude Max auth.
# Idempotent and safe to re-run. Exit 0 = healthy/fixed, non-zero = needs a human.
#
# Background: Hermes talks to a local Meridian proxy (default :3456) which uses the
# bundled Claude Code SDK so requests bill against the Claude Max plan. A claude.ai
# re-auth breaks this two ways, both handled below:
#   (1) Meridian caches SDK credentials from before the re-auth -> restart it.
#   (2) The re-auth re-imports the auth.json claude_code credential with
#       base_url:null -> failover hits api.anthropic.com direct -> "third-party" 400.
# This is NOT one-time: (2) recurs on EVERY re-auth, so we always re-patch.

set -uo pipefail

MERIDIAN_URL="${MERIDIAN_URL:-http://127.0.0.1:3456}"
HERMES_DIR="${HERMES_DIR:-$HOME/.hermes}"
AUTH_JSON="$HERMES_DIR/auth.json"
ENV_FILE="$HERMES_DIR/.env"
CREDS="$HOME/.claude/.credentials.json"
UNIT="$HOME/.config/systemd/user/meridian.service"
SCRUB_PLUGINS="$HOME/.config/meridian/plugins.json"

ok(){   printf '  \033[32m✔\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
err(){  printf '  \033[31mx\033[0m %s\n' "$1"; }
hdr(){  printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

FAIL=0; RESTART=0

hdr "1. claude.ai identity (must be claude.ai / firstParty / max)"
AS="$(HOME="$HOME" claude auth status 2>/dev/null)"
am=$(printf '%s' "$AS" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('authMethod',''))" 2>/dev/null)
ap=$(printf '%s' "$AS" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('apiProvider',''))" 2>/dev/null)
st=$(printf '%s' "$AS" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('subscriptionType',''))" 2>/dev/null)
if [ "$am" = "claude.ai" ] && [ "$ap" = "firstParty" ]; then
  ok "authMethod=$am apiProvider=$ap subscription=$st"
else
  err "authMethod='$am' apiProvider='$ap' — NOT first-party."
  err "Run the interactive flow yourself, then re-run this skill:  claude auth login --claudeai"
  err "(Do NOT use 'claude setup-token' / 'hermes model' option 1 — that bills API usage, not Max.)"
  FAIL=1
fi

hdr "2. CLAUDE_CODE_OAUTH_TOKEN leak (must be unset everywhere)"
leak=0
[ -f "$UNIT" ]     && grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "$UNIT"     && { err "set in $UNIT — remove that line"; leak=1; }
[ -f "$ENV_FILE" ] && grep -q '^CLAUDE_CODE_OAUTH_TOKEN' "$ENV_FILE" && { err "set in $ENV_FILE — remove that line"; leak=1; }
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && { warn "set in current shell env (harmless for the service, but unset it)"; }
[ "$leak" = 0 ] && ok "not set in meridian.service or ~/.hermes/.env" || FAIL=1

hdr "3. auth.json — re-patch base_url nulls + reset stale status"
if [ -f "$AUTH_JSON" ]; then
  cp "$AUTH_JSON" "$AUTH_JSON.bak-$(date +%s)"
  CHG=$(python3 - "$AUTH_JSON" "$MERIDIAN_URL" <<'PY'
import json,sys
p,url=sys.argv[1],sys.argv[2]
d=json.load(open(p)); n=0
for c in d.get('credential_pool',{}).get('anthropic',[]):
    if not c.get('base_url'): c['base_url']=url; n+=1
    if c.get('last_status') not in (None,'ok'): c['last_status']=None; n+=1
json.dump(d,open(p,'w'),indent=2)
print(n)
PY
)
  if [ "${CHG:-0}" -gt 0 ]; then warn "patched $CHG field(s) -> base_url=$MERIDIAN_URL ; will restart Meridian"; RESTART=1
  else ok "all anthropic credentials already point at Meridian, status clean"; fi
else
  err "$AUTH_JSON missing — is Hermes installed for this user?"; FAIL=1
fi

hdr "4. .env base URL"
if [ -f "$ENV_FILE" ] && grep -q "^ANTHROPIC_BASE_URL=$MERIDIAN_URL\$" "$ENV_FILE"; then
  ok "ANTHROPIC_BASE_URL=$MERIDIAN_URL"
else
  warn "ANTHROPIC_BASE_URL not exactly $MERIDIAN_URL in $ENV_FILE — check manually"
fi

hdr "5. Meridian freshness (must have started AFTER last re-auth)"
if systemctl --user is-active meridian >/dev/null 2>&1; then
  ms=$(date -d "$(systemctl --user show meridian -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || echo 0)
  cs=$([ -f "$CREDS" ] && stat -c %Y "$CREDS" || echo 0)
  if [ "$cs" -gt "$ms" ]; then warn "credentials ($(date -d @$cs '+%H:%M:%S')) newer than Meridian start ($(date -d @$ms '+%H:%M:%S')) — stale creds; will restart"; RESTART=1
  else ok "Meridian started after the current credentials"; fi
else
  warn "Meridian not active — will start it"; RESTART=1
fi

if [ "$RESTART" = 1 ] && [ "$FAIL" = 0 ]; then
  hdr "6. Restart Meridian"
  systemctl --user restart meridian && ok "restarted" || { err "restart failed"; FAIL=1; }
  for i in $(seq 1 15); do curl -fsS -m 2 "$MERIDIAN_URL/" >/dev/null 2>&1 && break; sleep 1; done
else
  hdr "6. Restart Meridian"; ok "not needed"
fi

hdr "7. Content-scrub plugin (anti content-fingerprinting)"
if [ -f "$SCRUB_PLUGINS" ] && grep -q 'hermes-scrub' "$SCRUB_PLUGINS"; then
  R=$(curl -s -m 5 -X POST "$MERIDIAN_URL/plugins/reload" 2>/dev/null)
  echo "$R" | grep -q '"status":"active"' && ok "hermes-scrub active" || warn "reload response: $R"
else
  warn "hermes-scrub not registered in $SCRUB_PLUGINS — fingerprinting 400s may return"
fi

hdr "8. Live test through Meridian"
if [ "$FAIL" = 0 ]; then
  for attempt in 1 2 3; do
    RES=$(curl -s -m 60 "$MERIDIAN_URL/v1/messages" -H 'content-type: application/json' \
      -H 'x-api-key: placeholder' -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-opus-4-7","max_tokens":16,"messages":[{"role":"user","content":"reply with exactly: PONG"}]}')
    VERDICT=$(printf '%s' "$RES" | python3 -c "import sys,json;d=json.load(sys.stdin);print('OK' if d.get('type')=='message' else 'FAIL '+json.dumps(d)[:400])" 2>/dev/null || echo "FAIL unparseable: ${RES:0:300}")
    case "$VERDICT" in
      OK) ok "Meridian -> Claude Max returned a valid message (attempt $attempt)"; break;;
      *)  warn "attempt $attempt: $VERDICT"; [ "$attempt" = 3 ] && { err "live test failed"; FAIL=1; }; sleep 3;;
    esac
  done
else
  warn "skipped — fix the failures above first"
fi

hdr "RESULT"
if [ "$FAIL" = 0 ]; then ok "Hermes is healthy and billing against Claude Max."; exit 0
else err "Unresolved — see ✗ lines above."; exit 1; fi
