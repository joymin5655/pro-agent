#!/usr/bin/env bash
# Tests for hooks/session-start.sh.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
hook="$root/hooks/session-start.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

assert() {
  # assert <description> <condition-exit-code>
  if [ "$2" -eq 0 ]; then
    pass=$((pass + 1)); echo "PASS $1"
  else
    fail=$((fail + 1)); echo "FAIL $1"
  fi
}

out1="$(CLAUDE_PROJECT_DIR="$tmp" CLAUDE_PLUGIN_ROOT="$root" bash "$hook")"
rc1=$?
assert "run 1 exit code is 0" "$rc1"
printf '%s' "$out1" | grep -q '# pro-agent 운영 규칙'
assert "rules title is printed" $?
if printf '%s' "$out1" | grep -q '이어서 할 일'; then r=1; else r=0; fi
assert "no resume notice without PROGRESS.md" "$r"

mkdir -p "$tmp/agent-notes"
printf '# 진행 메모\nMARKER-LINE-12345\n' > "$tmp/agent-notes/PROGRESS.md"
out2="$(CLAUDE_PROJECT_DIR="$tmp" CLAUDE_PLUGIN_ROOT="$root" bash "$hook")"
rc2=$?
assert "run 2 exit code is 0" "$rc2"
printf '%s' "$out2" | grep -q '이어서 할 일'
assert "resume notice present with PROGRESS.md" $?
printf '%s' "$out2" | grep -q 'MARKER-LINE-12345'
assert "progress content is printed" $?

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
