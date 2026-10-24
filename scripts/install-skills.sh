#!/usr/bin/env bash
# Installs claude-code-apple-skills + SwiftShip globally for Claude Code (~/.claude), per their READMEs.
# The project already vendors them in .claude/ (skills, agents, /apple:* commands) and .agents/skills (codex/agy).
set -euo pipefail
DIR="$HOME/.swiftship-src"; mkdir -p "$DIR"; cd "$DIR"
[[ -d claude-code-apple-skills ]] || git clone https://github.com/rshankras/claude-code-apple-skills
[[ -d SwiftShip ]] || git clone https://github.com/rshankras/SwiftShip
(cd claude-code-apple-skills && git pull -q) ; (cd SwiftShip && git pull -q && ./install.sh "$DIR/claude-code-apple-skills")
# Codex picks up skills from ~/.agents/skills (and project .agents/skills)
mkdir -p "$HOME/.agents/skills"
for d in "$DIR"/claude-code-apple-skills/skills/*/; do ln -sfn "$d" "$HOME/.agents/skills/apple-$(basename "$d")"; done
echo "Apple skills + SwiftShip installed."
