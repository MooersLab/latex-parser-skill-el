#!/bin/sh
# Copy the body of an installed transcript-parser SKILL.md into
# prompts/transcript-parser.md, dropping the YAML front matter.
#
# Usage: sh scripts/sync-prompt.sh [PATH/TO/SKILL.md]
set -eu

skill="${1:-$HOME/.claude/skills/transcript-parser/SKILL.md}"
out="$(dirname "$0")/../prompts/transcript-parser.md"

if [ ! -r "$skill" ]; then
  echo "Cannot read $skill" >&2
  exit 1
fi

# Drop the first --- ... --- block and any blank lines right after it.
awk 'BEGIN { fm = 0; started = 0 }
     NR == 1 && $0 == "---" { fm = 1; next }
     fm == 1 { if ($0 == "---") fm = 2; next }
     started == 0 && $0 == "" { next }
     { started = 1; print }' "$skill" > "$out.tmp"
mv "$out.tmp" "$out"
echo "Updated $out from $skill"
