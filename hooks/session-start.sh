#!/usr/bin/env bash
# pro-agent SessionStart hook: prints the operating rules and, if present,
# the project's progress note. Plain stdout is added to Claude's context.
# Never fails: always exits 0.
set -u

root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$root" ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
fi
project="${CLAUDE_PROJECT_DIR:-$PWD}"

if [ -f "$root/rules/operating-rules.md" ]; then
  cat "$root/rules/operating-rules.md" 2>/dev/null
fi

progress="$project/agent-notes/PROGRESS.md"
if [ -f "$progress" ]; then
  echo
  echo "## 이어서 할 일이 있습니다"
  echo "첫 답변에서 아래 진행 메모를 1~2줄로 알리고, 이어서 진행할지 물어보세요."
  echo
  head -n 40 "$progress" 2>/dev/null
fi

exit 0
