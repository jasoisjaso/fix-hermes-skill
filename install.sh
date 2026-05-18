#!/usr/bin/env bash
# Installs the fix-hermes skill into this machine's Claude Code (user scope).
# Run on the OTHER PC:  bash install.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/skills/fix-hermes"
mkdir -p "$DEST"
cp "$SRC/SKILL.md" "$SRC/fix-hermes.sh" "$DEST/"
chmod +x "$DEST/fix-hermes.sh"
echo "Installed -> $DEST"
echo "Open Claude Code in any project and run:  /fix-hermes"
