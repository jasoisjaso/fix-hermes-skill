#!/usr/bin/env bash
# auth-watcher.sh — auto-patches auth.json whenever Claude Code token refresh clobbers base_url
# Runs as a background daemon. Start via: bash ~/.hermes/auth-watcher.sh &

HERMES_DIR="${HERMES_DIR:-$HOME/.hermes}"
AUTH_JSON="$HERMES_DIR/auth.json"
MERIDIAN_URL="${MERIDIAN_URL:-http://127.0.0.1:3456}"
LOG="$HERMES_DIR/auth-watcher.log"
POLL_SEC=20

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "auth-watcher started (PID $$), polling every ${POLL_SEC}s"

patch_if_needed() {
  [[ -f "$AUTH_JSON" ]] || return
  local nulls
  nulls=$(python3 -c "
import json, sys
with open('$AUTH_JSON') as f:
    d = json.load(f)
creds = d.get('credentials', [])
bad = [i for i,c in enumerate(creds) if c.get('base_url') is None]
print(len(bad))
" 2>/dev/null)

  if [[ "${nulls:-0}" -gt 0 ]]; then
    log "Detected $nulls null base_url(s) — patching..."
    cp "$AUTH_JSON" "${AUTH_JSON}.bak-$(date +%s)"
    python3 -c "
import json
with open('$AUTH_JSON') as f:
    d = json.load(f)
patched = 0
for c in d.get('credentials', []):
    if c.get('base_url') is None:
        c['base_url'] = '$MERIDIAN_URL'
        patched += 1
    # reset any stale 'exceeded' status
    if c.get('status') in ('exceeded', 'disabled'):
        c['status'] = 'active'
with open('$AUTH_JSON', 'w') as f:
    json.dump(d, f, indent=2)
print(patched)
"
    log "Patched. Restarting Meridian..."
    # Kill existing Meridian
    pkill -f "meridian" 2>/dev/null || true
    sleep 1
    # Relaunch
    MERIDIAN_BIN=$(command -v meridian 2>/dev/null || ls ~/.hermes/bin/meridian 2>/dev/null || ls ~/.local/bin/meridian 2>/dev/null)
    if [[ -n "$MERIDIAN_BIN" ]]; then
      nohup "$MERIDIAN_BIN" >> "$HERMES_DIR/logs/meridian.log" 2>&1 &
      log "Meridian restarted (PID $!)"
    else
      log "WARNING: meridian binary not found — restart manually"
    fi
  fi
}

while true; do
  patch_if_needed
  sleep "$POLL_SEC"
done
