#!/bin/zsh
# Make this checkout's iPhone automation skill available to local Codex chats.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/install-codex-skill.sh

Register the iphone-use skill in ${CODEX_HOME:-$HOME/.codex}/skills.
Invoke it in Codex as: $iphone-use <task>
The iphone-use MCP is required separately. The skill can recover the GUI service.
EOF
}

if (( $# )); then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) print -u2 -- "Unknown argument: $1"; usage >&2; exit 1 ;;
  esac
fi

repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
skill_source="$repo_dir/codex/skills/iphone-use"
skill_parent="${CODEX_HOME:-$HOME/.codex}/skills"
skill_target="$skill_parent/iphone-use"

if [[ ! -f "$skill_source/SKILL.md" ]]; then
  print -u2 -- "Missing skill: $skill_source/SKILL.md"
  exit 1
fi
if [[ -e "$skill_target" || -L "$skill_target" ]]; then
  if [[ ! -L "$skill_target" || "$(readlink "$skill_target")" != "$skill_source" ]]; then
    print -u2 -- "A different skill already exists at $skill_target; left unchanged."
    exit 1
  fi
else
  mkdir -p "$skill_parent"
  ln -s "$skill_source" "$skill_target"
fi

print -r -- "Skill registered: $skill_target -> $skill_source"
print -r -- 'Use in Codex: $iphone-use <task>'
print -r -- 'If the skill is not visible, open a new chat or restart Codex.'
