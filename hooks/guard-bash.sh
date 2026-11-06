#!/usr/bin/env bash
# pro-agent PreToolUse(Bash) hook.
#
# NOTE: this is a text-pattern safety net, not a complete guard. It only
# catches common dangerous command shapes and can be bypassed (variables,
# scripts, encodings). Keep Claude Code's own permission prompts turned on.
#
# Reads the PreToolUse JSON from stdin, normalizes it (the escape sequences
# \n \r \t become spaces, then backslashes and quotes are deleted), then
# matches extended regexes. Precedence: deny > ask > allow.
# Allow prints nothing. Always exits 0.
set -u

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

# In the JSON a newline inside the command is the two characters backslash-n
# (same for \r and \t). Turn those into a space first, then delete backslash,
# double quote and single quote so escaped/quoted JSON becomes plain text.
text="$(printf '%s' "$input" | sed 's/\\[nrt]/ /g' | tr -d "\\\\\"'")"

emit() {
  # $1 = deny|ask, $2 = reason (must not contain quotes or backslashes)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"[pro-agent] %s"}}\n' "$1" "$2"
  exit 0
}

# Target terminator: whitespace, ; & | , } or end of text.
end='([[:space:];&|,}]|$)'
# shellcheck disable=SC2016  # literal $HOME is intended
tgt='(/|/\*|~|~/|~/\*|\$HOME|\$HOME/|\$HOME/\*|\$\{HOME\})'
nb='(^|[^a-zA-Z0-9_])'

has() { printf '%s' "$text" | grep -Eq "$1"; }

# ---- DENY ----
# rm with recursive + force flags (any order) aimed at root/home.
rm_flags='((-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*)|(-[a-zA-Z]*f[a-zA-Z]*[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*)|(-[a-zA-Z]*([rR][a-zA-Z]*f|f[a-zA-Z]*[rR])[a-zA-Z]*)|(--recursive[[:space:]]+--force)|(--force[[:space:]]+--recursive))'
if has "${nb}rm[[:space:]]+(-[a-zA-Z-]+[[:space:]]+)*${rm_flags}[[:space:]]+(-[a-zA-Z-]+[[:space:]]+)*${tgt}${end}"; then
  emit deny "루트나 홈 폴더 전체를 지우는 명령은 막았습니다. 지울 폴더를 정확히 지정하거나 보관 폴더로 옮겨 주세요."
fi

# git push --force / -f / +refspec (but not --force-with-lease etc.)
if has "${nb}git[[:space:]]+push([[:space:]]|\$)"; then
  if has 'git[[:space:]]+push([[:space:]]+[^[:space:]]+)*[[:space:]]+(--force([[:space:]]|,|}|$)|-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|,|}|$)|\+[^[:space:]])'; then
    emit deny "강제 푸시는 막았습니다. 꼭 필요하면 --force-with-lease를 쓰거나 직접 실행해 주세요."
  fi
fi

if has "${nb}git[[:space:]].*--no-verify"; then
  emit deny "--no-verify는 막았습니다. 검사가 실패한 원인을 고쳐 주세요."
fi

if has "${nb}mkfs(\.[a-zA-Z0-9]+)?([[:space:]]|,|}|\$)"; then
  emit deny "디스크를 포맷하는 명령은 막았습니다."
fi

# dd to a device is denied; of=/dev/null (benchmarks) is allowed.
if has "${nb}dd[[:space:]].*of=/dev/"; then
  if printf '%s' "$text" | grep -Eo 'of=/dev/[^[:space:],}]*' | grep -qvx 'of=/dev/null'; then
    emit deny "장치에 직접 쓰는 dd 명령은 막았습니다."
  fi
fi

if printf '%s' "$text" | grep -Fq ':(){ :|:& };:'; then
  emit deny "포크 폭탄 형태의 명령은 막았습니다."
fi

# ---- ASK ----
if has "${nb}git[[:space:]]+reset[[:space:]]+(.*[[:space:]])?--hard"; then
  emit ask "하드 리셋은 작업 내용을 잃을 수 있습니다. 실행해도 될까요?"
fi

if has "${nb}git[[:space:]]+clean[[:space:]]+(.*[[:space:]])?-[a-zA-Z]*f"; then
  emit ask "git clean은 추적 안 되는 파일을 지웁니다. 실행해도 될까요?"
fi

if has '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh)([[:space:]]|,|}|$)'; then
  emit ask "내려받은 스크립트를 바로 실행하려 합니다. 내용을 확인한 뒤 실행해도 될까요?"
fi

if has "${nb}sudo[[:space:]]"; then
  emit ask "관리자 권한(sudo) 명령입니다. 실행해도 될까요?"
fi

exit 0
