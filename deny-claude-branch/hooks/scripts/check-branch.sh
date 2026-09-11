#!/bin/bash
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
if [[ "$command" != *git* || "$command" != *commit* ]]; then
  exit 0
fi

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
if [ -z "$cwd" ]; then
  cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [[ "$branch" == claude/* ]]; then
  reason='claude/* のブランチ使用禁止です。現在の作業に適した作業ブランチ名をユーザーに提案してください'
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi

exit 0
