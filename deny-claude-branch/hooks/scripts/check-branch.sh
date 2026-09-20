#!/bin/bash
# Claude Code PreToolUse フック: claude/* ブランチでの git commit を抑止・ブロックするスクリプト
set -euo pipefail

# 必須コマンド (jq, git) が存在しない場合は処理をスキップして正常終了（ツールの実行を妨げない）
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# 標準入力からフックのペイロード JSON を受け取る
input=$(cat)

# 実行対象のツールが Bash 以外の場合はチェック不要のため終了
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

# コマンドに 'git' と 'commit' の両方が含まれていない場合は終了
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
if [[ "$command" != *git* || "$command" != *commit* ]]; then
  exit 0
fi

# 作業ディレクトリ (cwd) の特定: ペイロード指定値 -> 環境変数 CLAUDE_PROJECT_DIR -> カレントディレクトリ
# cwd が未指定、または Git リポジトリ外 (/private/tmp など) の場合は CLAUDE_PROJECT_DIR にフォールバックする
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
if [ -z "$cwd" ] || ! git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cwd="${CLAUDE_PROJECT_DIR:-${cwd:-$PWD}}"
fi

# 対象ディレクトリの Git カレントブランチ名を取得
branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# ブランチ名が claude/* の場合、実行を拒否 (deny) する JSON レスポンスを出力
if [[ "$branch" == claude/* ]]; then
  reason='claude/* のブランチ使用禁止です。現在の作業に適した作業ブランチ名に変更してからコミットしてください'
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi

exit 0
