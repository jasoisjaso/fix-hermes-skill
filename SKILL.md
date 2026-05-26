---
name: fix-hermes
description: Use this skill when the user reports Hermes Agent failing against their Claude Max subscription — symptoms like "Third-party apps now draw from your extra usage" 400s, "Custom betas are only available for API key users", Hermes API retries exhausting, or Hermes breaking right after re-authenticating on claude.ai. Diagnoses and repairs the Hermes -> Meridian -> Claude Max auth path.
version: 1.1.0
---

# Fix Hermes (Meridian -> Claude Max auth)

Hermes Agent reaches Claude through a local **Meridian** proxy (default `http://127.0.0.1:3456`) that uses the bundled Claude Code SDK so requests bill against the user's **Claude Max** plan instead of API "extra usage". Three root causes account for nearly all failures:

1. **Stale SDK creds** — Meridian was started before a re-auth and caches the old credential → `400 Third-party apps now draw from your extra usage`. Fix: restart Meridian.
2. **auth.json footgun (recurs every re-auth)** — re-auth re-imports the `claude_code` anthropic credential with `base_url: null`, so failover hits `api.anthropic.com` directly → instant "third-party" 400. Fix: re-patch `base_url` to the Meridian URL. **Not one-time** — recurs on every re-auth; the **auth-watcher daemon** auto-heals this within 20 s.
3. **`CLAUDE_CODE_OAUTH_TOKEN` in shell RC file** (`~/.bashrc`, `~/.profile`, etc.) — this token exports into every session and routes requests directly to Anthropic as a third-party OAuth app, bypassing Meridian entirely. Causes persistent 401/400 that survive all other repairs. Fix: remove the export line.

Meridian itself is essentially never the root cause — it's collateral damage.

## How to run

Execute the bundled script and report its output to the user:

```bash
bash "$CLAUDE_SKILL_DIR/fix-hermes.sh"
```

(If `$CLAUDE_SKILL_DIR` is unset, use `~/.claude/skills/fix-hermes/fix-hermes.sh`.)

The script is **idempotent and safe to re-run**. It performs all 9 checks/repairs, restarts Meridian only when needed, installs the auth-watcher daemon if absent, and ends with a live PONG test through Meridian. Exit 0 = healthy.

## Interpreting the result

- **Exit 0 / "Hermes is healthy"** — done. Tell the user what was repaired (the script prints which fields it patched and whether Meridian was restarted).
- **Step 1 fails (`authMethod` not `claude.ai`/`firstParty`)** — the credential itself is wrong. The user must run the interactive flow themselves; it cannot be scripted:

      claude auth login --claudeai

  Do **not** suggest `claude setup-token` or `hermes model` option 1 — those produce an API-billing token that does **not** route through Max. After they complete it, re-run this skill.

- **Step 2 fails (token leak)** — remove the offending `CLAUDE_CODE_OAUTH_TOKEN` export from the named file, then `unset CLAUDE_CODE_OAUTH_TOKEN` in the current shell, then re-run. Check **all** shell RC files (`~/.bashrc`, `~/.bash_profile`, `~/.profile`, `~/.zshrc`); the token may appear in more than one.

- **Step 9 live test fails** despite 1–8 passing — likely Anthropic tightened content-fingerprinting again; check `~/.hermes/logs/meridian.log` and the `hermes-scrub` plugin (`~/.config/meridian/hermes-scrub.js`).

## auth-watcher daemon

The skill bundles `auth-watcher.sh`. Step 8 installs it to `~/.hermes/auth-watcher.sh` and adds a startup hook to `~/.bashrc` so it survives WSL restarts. The daemon polls `auth.json` every 20 s and re-patches any `base_url: null` fields automatically — eliminating the need to run `/fix-hermes` after every routine token refresh.

## Notes

- Overridable via env: `MERIDIAN_URL`, `HERMES_DIR`.
- The script backs up `auth.json` to `auth.json.bak-<epoch>` before patching.
- The auth-watcher logs to `/tmp/hermes-auth-watcher.log`.
