---
name: fix-hermes
description: Use this skill when the user reports Hermes Agent failing against their Claude Max subscription — symptoms like "Third-party apps now draw from your extra usage" 400s, "Custom betas are only available for API key users", Hermes API retries exhausting, or Hermes breaking right after re-authenticating on claude.ai. Diagnoses and repairs the Hermes -> Meridian -> Claude Max auth path.
version: 1.0.0
---

# Fix Hermes (Meridian -> Claude Max auth)

Hermes Agent reaches Claude through a local **Meridian** proxy (default `http://127.0.0.1:3456`) that uses the bundled Claude Code SDK so requests bill against the user's **Claude Max** plan instead of API "extra usage". A `claude.ai` re-auth reliably breaks this two independent ways:

1. **Stale SDK creds** — Meridian was started before the re-auth and caches the old credential, so it identifies as third-party OAuth -> `400 Third-party apps now draw from your extra usage`. Fix: restart Meridian.
2. **auth.json footgun (recurs every re-auth)** — the re-auth re-imports the `claude_code` anthropic credential in `~/.hermes/auth.json` with `base_url: null`, so any failover hits `api.anthropic.com` directly -> instant "third-party" 400. Fix: re-patch `base_url` to the Meridian URL. This is **not** one-time; it must be re-applied after every re-auth.

Meridian itself is essentially never the root cause — it's collateral damage from re-auth.

## How to run

Execute the bundled script and report its output to the user:

```bash
bash "$CLAUDE_SKILL_DIR/fix-hermes.sh"
```

(If `$CLAUDE_SKILL_DIR` is unset, use `~/.claude/skills/fix-hermes/fix-hermes.sh`.)

The script is **idempotent and safe to re-run**. It performs all 8 checks/repairs, restarts Meridian only when needed, and ends with a live PONG test through Meridian. Exit 0 = healthy.

## Interpreting the result

- **Exit 0 / "Hermes is healthy"** — done. Tell the user it's fixed and what was repaired (the script prints which fields it patched and whether Meridian was restarted).
- **Step 1 fails (`authMethod` not `claude.ai`/`firstParty`)** — the credential itself is wrong. The user must run the interactive flow themselves; it cannot be scripted:

      claude auth login --claudeai

  Do **not** suggest `claude setup-token` or `hermes model` option 1 — those produce an API-billing token that does **not** route through Max. After they complete it, re-run this skill.
- **Step 2 fails (token leak)** — remove the offending `CLAUDE_CODE_OAUTH_TOKEN` line from the named file, then re-run.
- **Step 8 live test fails** despite 1–7 passing — likely Anthropic tightened content-fingerprinting again; check `~/.hermes/logs/meridian.log` and the `hermes-scrub` plugin (`~/.config/meridian/hermes-scrub.js`), and consult the detailed history in the user's `reference_hermes_anthropic_auth.md` memory.

## Notes

- Overridable via env: `MERIDIAN_URL`, `HERMES_DIR`.
- The script backs up `auth.json` to `auth.json.bak-<epoch>` before patching.
- Using Meridian with a Max account violates Anthropic's Consumer ToS (Feb 2026); the user has accepted this risk — do not re-litigate it, just fix the breakage.
