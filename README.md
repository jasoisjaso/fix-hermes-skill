fix-hermes — portable Claude Code skill
=======================================

WHAT IT DOES
  One command (/fix-hermes) that diagnoses and repairs the
  Hermes Agent -> Meridian -> Claude Max auth path. Handles the two
  faults a claude.ai re-auth always causes: stale Meridian creds
  (restart) and the auth.json base_url:null footgun (re-patch).
  Idempotent and safe to re-run anytime.

INSTALL ON THE OTHER PC
  1. Copy this whole "fix-hermes-skill" folder to the other machine
     (USB, scp, syncthing — whatever you use).
  2. On that machine:   bash install.sh
     (installs to ~/.claude/skills/fix-hermes/)
  3. Open Claude Code in any project and type:   /fix-hermes

  Manual alternative (no installer):
     mkdir -p ~/.claude/skills/fix-hermes
     cp SKILL.md fix-hermes.sh ~/.claude/skills/fix-hermes/
     chmod +x ~/.claude/skills/fix-hermes/fix-hermes.sh

RUN WITHOUT CLAUDE CODE
  The script is standalone:   bash fix-hermes.sh
  Exit 0 = healthy/fixed.

ASSUMPTIONS (same setup as this PC)
  - Hermes installed for the user, ~/.hermes/{auth.json,.env} present
  - Meridian as a systemd --user service named "meridian", port 3456
  - hermes-scrub plugin at ~/.config/meridian/
  Override if different:  MERIDIAN_URL=... HERMES_DIR=... bash fix-hermes.sh

ONE THING THAT CAN'T BE SCRIPTED
  If it reports the identity is not claude.ai/firstParty, run the
  interactive flow yourself, then re-run:
     claude auth login --claudeai
  Do NOT use 'claude setup-token' or 'hermes model' option 1 —
  those bill API usage, not your Max plan.
