#!/usr/bin/env bash
# pro-agent PreToolUse(Bash) hook.
#
# NOTE: this is a text-pattern safety net, not a complete guard. It only
# catches common dangerous command shapes and can be bypassed (variables,
# scripts, encodings). Keep Claude Code's own permission prompts turned on.
#
# Flow: read the PreToolUse JSON from stdin -> take only the command string ->
# unescape it and join backslash-newline lines -> split it two ways and judge
# every command of both:
#   (a) at ; && || & | ( ) { } ` and newlines even inside quotes, so code in a
#       string (bash -c '...') is judged too; quoted values are grouped into one
#       word only to skip option values;
#   (b) at top-level separators only, so a quoted value or $(...) holding
#       ( & ; | cannot cut a command off from its later options.
# Per command: strip prefixes (shell keywords, redirections, sudo, env, timeout
# and other wrappers, bash -c) -> judge it by name. Dangerous words are always
# judged after grouped words are split apart again.
# Precedence: deny > ask > allow. Allow prints nothing. Always exits 0.
# Works on bash 3.2 (macOS) and Linux bash; only POSIX sed/grep/tr/awk are used.
set -u
export LC_ALL=C # byte-wise: fast, and no "illegal byte sequence" on odd input

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

mark="$(printf '\001')" # stands in for an escaped (shell) backslash
sep="$(printf '\002')"  # command separator while splitting
spc="$(printf '\003')"  # a space inside one quoted/escaped word
nl="$(printf '\004')"   # newline while unescaping JSON

emit() {
  # $1 = deny|ask, $2 = reason (must not contain quotes or backslashes)
  # Read the rest of the judging loop's input first: exiting while its writer
  # still writes leaves "write error: Broken pipe" on stderr where SIGPIPE is
  # ignored (GitHub Actions runners, for one). Outside the loop stdin is the
  # event, already read to the end.
  cat > /dev/null 2>&1
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"[pro-agent] %s"}}\n' "$1" "$2"
  exit 0
}

ask_reason=""
add_ask() { [ -z "$ask_reason" ] && ask_reason="$1"; return 0; }
fetch_reason="내려받은 스크립트를 바로 실행하려 합니다. 내용을 확인한 뒤 실행해도 될까요?"

assign_re='^[A-Za-z_][A-Za-z0-9_]*='
redir_re='^[0-9]*[<>]'
redir_op_re='^[0-9]*(>|>>|<|<<|<<<|<<-|<>)$' # operator only: its target is the next word

# unsp <text>: UNSP = text with the grouping placeholder turned back into
# spaces. No subshell for short text; bash 3.2 ${s//x/y} is slow on long text.
unsp() {
  if [ "${#1}" -le 2000 ]; then
    UNSP="${1//$spc/ }"
  else
    UNSP="$(printf '%s' "$1" | tr "$spc" ' ')"
  fi
}

# ---- 1. Extract + normalize -------------------------------------------------

# Print the value of "command" in tool_input. If it cannot be found, sed prints
# the whole input unchanged, so we check more text rather than less.
extract_command() {
  printf '%s' "$1" | tr '\n\r' '  ' |
    sed -E 's/.*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/'
}

# Per line, char by char: inside quotes (or after a backslash) a space becomes
# $spc, so a quoted value stays one word. A backslash (mark) escapes the next
# char outside single quotes. A line ending in an odd run of backslashes is
# joined with the next line; any other line end resets the quote state.
group_quotes() {
  awk '
    BEGIN { M = "\001"; SP = "\003"; S1 = "\047"; D1 = "\042" }
    {
      n = length($0); cont = 0
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == M && q != S1) {
          if (i == n) { cont = 1; break }
          d = substr($0, ++i, 1)
          if (d == " " || d == "\t") d = SP
          printf "%s%s", c, d
          continue
        }
        if (q == "") { if (c == S1 || c == D1) q = c }
        else if (c == q) q = ""
        else if (c == " " || c == "\t") c = SP
        printf "%s", c
      }
      if (!cont) { printf "\n"; q = "" }
    }'
}

# View (b): one line per top-level command (split only at ; && || & ( ) { } and
# newlines outside quotes and substitutions; | stays as the stage separator).
# Inside quotes, $(...), <(...), `...` and ${...}, spaces and newlines become
# $spc and | becomes \005, so a quoted value or substitution stays in its word
# and cannot cut a command off from its later options. Quotes and backslashes
# are dropped; &>, >&, <& lose the &. Only commands that hold quotes,
# substitutions or escapes are printed: the others look the same in view (a).
# Comments and here-document bodies are skipped (an apostrophe there would
# otherwise open a quote that swallows the later commands).
top_commands() {
  awk '
    function add(s) { part[++np] = s }
    function last_char() { return np ? substr(part[np], length(part[np]), 1) : "" }
    function emit(   j) {
      if (special && np) { for (j = 1; j <= np; j++) printf "%s", part[j]; printf "\n" }
      np = 0; special = 0
    }
    function inner(c) { return (c == " " || c == "\t" || c == "\n") ? SP : (c == "|" ? PI : c) }
    function push(t) { ctx[++sp] = t; special = 1 }
    BEGIN { M = "\001"; SP = "\003"; PI = "\005"; S1 = "\047"; D1 = "\042"; BQ = "\140"; sp = 0; ctx[0] = "T"; nh = 0; hc = 1 }
    {
      if (nh && !cont) {                       # here-document body: text, not code
        ln = $0
        if (hs[hc]) sub(/^[ \t]+/, "", ln)
        if (ln == hd[hc] && ++hc > nh) { nh = 0; hc = 1 }
        next
      }
      cont = 0
      n = length($0)
      for (i = 1; i <= n + 1; i++) {
        c = i <= n ? substr($0, i, 1) : "\n"
        nx = i < n ? substr($0, i + 1, 1) : (i == n ? "\n" : "")
        t = ctx[sp]
        if (c == M && t != "S") {              # backslash: the next character is literal
          special = 1
          if (i == n) { cont = 1; break }      # line continuation: drop the newline too
          d = substr($0, ++i, 1)
          if (d != S1 && d != D1 && d != M) add(t == "T" && d != " " && d != "\t" && d != "|" ? d : inner(d))
          continue
        }
        if (t == "S") { if (c == S1) sp--; else if (c != M) add(inner(c)); continue }
        if (c == "$" && nx == "{") { push("P"); add("${"); i++; continue }
        if (t == "D" || t == "P") {
          if (t == "D" && c == D1) sp--
          else if (t == "P" && c == "}") { sp--; add("}") }
          else if (t == "P" && (c == S1 || c == D1)) push(c == S1 ? "S" : "D")
          else if (c == "$" && nx == "(") { push("C"); add("$("); i++ }
          else if (c == BQ) { push("B"); add(BQ) }
          else add(inner(c))
          continue
        }
        # code: T = top level, C = inside $( <( >( or a nested (, B = inside `...`
        if (c == "#" && (np == 0 || index(t == "T" ? " \t|" : " \t;&|(" SP PI, last_char()))) { i = n; continue } # comment
        if (c == "<" && nx == "<") {        # here-document (<<< finds no end word): keep its end word
          j = i + 2; strip = substr($0, j, 1) == "-"; j += strip
          while (substr($0, j, 1) == " " || substr($0, j, 1) == "\t") j++
          for (w = ""; j <= n; j++) {
            d = substr($0, j, 1)
            if (index(" \t;&|<>()", d)) break
            if (d != S1 && d != D1 && d != M) w = w d
          }
          if (w ~ /^[A-Za-z_]/) { hd[++nh] = w; hs[nh] = strip } # not a shift like 1 << 2
          add("<<"); i++; continue
        }
        if (c == S1) { push("S"); continue }
        if (c == D1) { push("D"); continue }
        if (c == BQ) { if (t == "B") sp--; else push("B"); add(BQ); continue }
        if ((c == "$" || c == "<" || c == ">") && nx == "(") { push("C"); add(c "("); i++; continue }
        if (t != "T") {
          if (c == "(") push("C")
          else if (c == ")" && t == "C") sp--
          add(inner(c))
          continue
        }
        if (c == "\n" || c == ";" || c == "(" || c == ")" || c == "{" || c == "}") { emit(); continue }
        if (c == "&") {
          if (nx == "&") { emit(); i++ }
          else if (!(nx == ">" || last_char() == ">" || last_char() == "<")) emit()
          continue                             # &> >& <& are redirections: the & is dropped
        }
        if (c == "|") {
          if (nx == "|") { emit(); i++ } else { if (nx == "&") i++; add("|") }
          continue
        }
        add(c)
      }
    }
    END { emit() }'
}

# Undo JSON escapes: a shell backslash becomes $mark, \n and \r become newlines.
unescape() {
  sed -E -e 's/\\\\/'"$mark"'/g' -e 's/\\"/"/g' -e 's/\\[nr]/'"$nl"'/g' -e 's/\\t/ /g' |
    tr "$nl" '\n'
}

# shellcheck disable=SC2016  # literal $HOME in the sed replacement is intended
home_norm() { sed -E 's/\$\{HOME\}/$HOME/g'; }

# View (a): group quoted values, then delete backslashes and quotes (so r''m or
# r\m cannot hide a command). Newlines become ';' (a command boundary).
normalize() {
  group_quotes | tr '\n' ';' | tr -d "\\\\\"'$mark" | home_norm
}

# ---- 2. Split ---------------------------------------------------------------

# One pipeline per output line: cut at ; && || single & ( ) { } `. The
# redirections &> >& <& are not separators.
split_pipelines() {
  sed -E -e 's/\|\|/'"$sep"'/g' -e 's/\|&/|/g' -e 's/&&/'"$sep"'/g' \
    -e 's/&>/>/g' -e 's/>&/>/g' -e 's/<&/</g' \
    -e 's/[;&(){}`]/'"$sep"'/g' | tr "$sep" '\n'
}

# ---- 3. Strip prefixes ------------------------------------------------------

# opt_len <letters that take a value> <|long|options|that|take|one|> <word> [<next word>]
# When <word> is an option, set NOPT to the words it uses (2 when its value is
# the next word: -u root, -nu root, --user root) and return 0; return 1 when it
# is not an option. A value attached to the letter (-uroot, -n10) uses one word.
opt_len() {
  local w="$3" pre
  NOPT=1
  case "$w" in
    --|--*=*) return 0 ;;
    --?*)
      case "$2" in *"|${w#--}|"*) [ $# -ge 4 ] && NOPT=2 ;; esac
      return 0 ;;
    -?*)
      if [ -n "$1" ]; then
        pre="${w#-}"; pre="${pre%%["$1"]*}" # letters before the first one that takes a value
        [ $((${#pre} + 2)) -eq "${#w}" ] && [ $# -ge 4 ] && NOPT=2
      fi
      return 0 ;;
  esac
  return 1
}

# Input: the words of one command. Sets CMD (command name without path),
# RESTW (array: its arguments, still grouped), SUDO (1 if sudo was used) and
# FIRST (the name reached first, before any `bash -c` unwrapping; used for the
# curl | sh check).
strip_prefix() {
  CMD=""; RESTW=(); SUDO=0; FIRST=""
  local w name n opt has_c resplit=0 vals longs
  while [ $# -gt 0 ]; do
    if [ "$resplit" = 1 ]; then # the rest is code in a string: split it again
      resplit=0; unsp "$*"
      # shellcheck disable=SC2086  # intentional word splitting; globbing is off (set -f)
      set -- $UNSP
      continue
    fi
    w="$1"; name="${w##*/}"
    if [[ $w =~ $assign_re ]]; then shift; continue; fi
    if [[ $w =~ $redir_re ]]; then # redirection before the command name
      shift
      [[ $w =~ $redir_op_re ]] && [ $# -gt 0 ] && shift
      continue
    fi
    case "$w" in *"$spc"*) resplit=1; continue ;; esac # a name holding spaces is code
    case "$w" in if|then|else|elif|do|while|until|'!') shift; continue ;; esac
    case "$name" in
      env)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -S|--split-string|-S*|--split-string=*)
              # the string holds more words for env (options too): split it here
              w="${1#--split-string}"; w="${w#=}"; w="${w#-S}"; shift
              unsp "$w $*"
              # shellcheck disable=SC2086  # intentional word splitting; globbing is off (set -f)
              set -- $UNSP ;;
            *) opt_len uCP '|unset|chdir|' "$1" ${2+"$2"} || break; shift "$NOPT" ;;
          esac
        done ;;
      sudo|exec|command|builtin|nohup|time|nice|timeout|caffeinate|stdbuf|ionice|setsid)
        [ "$name" = sudo ] && SUDO=1
        case "$name" in
          sudo) vals=aCcDgpRrTtUu longs='|user|group|host|prompt|close-from|other-user|role|type|chdir|chroot|command-timeout|auth-type|login-class|' ;;
          exec) vals=a longs='' ;;
          time) vals=of longs='|output|format|' ;; # GNU time
          nice) vals=n longs='|adjustment|' ;;
          timeout) vals=sk longs='|signal|kill-after|' ;;
          caffeinate) vals=tw longs='' ;;
          stdbuf) vals=ioe longs='|input|output|error|' ;;
          ionice) vals=cnpPu longs='|class|classdata|pid|pgid|uid|' ;;
          *) vals='' longs='' ;;
        esac
        shift
        while [ $# -gt 0 ] && opt_len "$vals" "$longs" "$1" ${2+"$2"}; do shift "$NOPT"; done
        [ "$name" = timeout ] && [ $# -gt 0 ] && shift ;; # timeout: the duration comes first
      eval) shift; resplit=1 ;;
      bash|sh|zsh|dash|ksh)
        [ -z "$FIRST" ] && FIRST="$name"
        # Read the shell's options; `-c` (also -lc, -ec) means the next word is code.
        n=2; has_c=0
        while [ "$n" -le $# ]; do
          opt="${!n}"
          case "$opt" in
            -o|+o|-O|+O|--rcfile|--init-file) n=$((n + 2)) ;;
            --*) n=$((n + 1)) ;;
            -*c*) has_c=1; n=$((n + 1)); break ;;
            -*|+*) n=$((n + 1)) ;;
            *) break ;; # a script file: the shell is the command
          esac
        done
        if [ "$has_c" = 1 ] && [ "$n" -le $# ]; then shift $((n - 1)); resplit=1; else break; fi ;;
      *) break ;;
    esac
  done
  CMD="${1-}"; CMD="${CMD##*/}"
  [ -z "$FIRST" ] && FIRST="$CMD"
  [ $# -gt 0 ] && shift
  RESTW=("$@")
}

# ---- 4. Judge one command ---------------------------------------------------

# Judge functions get the words already split apart again.
judge_rm() {
  local rec=0 frc=0 hit=0 past=0 w
  for w in "$@"; do
    if [ "$past" = 0 ]; then
      case "$w" in
        --) past=1; continue ;;
        --recursive) rec=1; continue ;;
        --force) frc=1; continue ;;
        --*) continue ;;
        -?*)
          case "$w" in *[rR]*) rec=1 ;; esac
          case "$w" in *f*) frc=1 ;; esac
          continue ;;
      esac
    fi
    # shellcheck disable=SC2016,SC2088  # literal $HOME and ~ are intended (matching text, not expanding)
    case "$w" in
      /|'/*'|'~'|'~/'|'~/*'|'$HOME'|'$HOME/'|'$HOME/*') hit=1 ;;
    esac
  done
  if [ "$rec" = 1 ] && [ "$frc" = 1 ] && [ "$hit" = 1 ]; then
    emit deny "루트나 홈 폴더 전체를 지우는 명령은 막았습니다. 지울 폴더를 정확히 지정하거나 보관 폴더로 옮겨 주세요."
  fi
}

judge_dd() {
  local w
  for w in "$@"; do
    case "$w" in
      of=/dev/null|of=/dev/zero|of=/dev/stdout|of=/dev/stderr|of=/dev/tty|of=/dev/fd/*) ;;
      of=/dev/*) emit deny "장치에 직접 쓰는 dd 명령은 막았습니다." ;;
    esac
  done
}

# Gets the grouped words. Skips git's global options (-C path, -c k=v,
# --no-pager ...) with their values as one word each, then splits the rest.
judge_git() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env) shift; [ $# -gt 0 ] && shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -eq 0 ] && return 0
  unsp "$*"
  # shellcheck disable=SC2086  # intentional word splitting; globbing is off (set -f)
  set -- $UNSP
  local sub="${1-}" w
  [ -z "$sub" ] && return 0
  shift
  for w in "$@"; do
    if [ "$w" = "--no-verify" ]; then
      emit deny "--no-verify는 막았습니다. 검사가 실패한 원인을 고쳐 주세요."
    fi
  done
  case "$sub" in
    push)
      for w in "$@"; do
        case "$w" in
          --force) emit deny "강제 푸시는 막았습니다. 꼭 필요하면 --force-with-lease를 쓰거나 직접 실행해 주세요." ;;
          --*) ;;
          -*f*|+*) emit deny "강제 푸시는 막았습니다. 꼭 필요하면 --force-with-lease를 쓰거나 직접 실행해 주세요." ;;
        esac
      done ;;
    reset)
      for w in "$@"; do
        [ "$w" = "--hard" ] && add_ask "하드 리셋은 작업 내용을 잃을 수 있습니다. 실행해도 될까요?"
      done ;;
    clean)
      for w in "$@"; do
        case "$w" in
          --force) add_ask "git clean은 추적 안 되는 파일을 지웁니다. 실행해도 될까요?" ;;
          --*) ;;
          -*f*) add_ask "git clean은 추적 안 되는 파일을 지웁니다. 실행해도 될까요?" ;;
        esac
      done ;;
  esac
}

judge_stage() {
  if [ "${#RESTW[@]}" -gt 0 ]; then set -- "${RESTW[@]}"; else set --; fi
  case "$CMD" in
    git) judge_git "$@" ;;
    rm|dd)
      unsp "$*"
      # shellcheck disable=SC2086  # intentional word splitting; globbing is off (set -f)
      set -- $UNSP
      if [ "$CMD" = rm ]; then judge_rm "$@"; else judge_dd "$@"; fi ;;
    mkfs|mkfs.*) emit deny "디스크를 포맷하는 명령은 막았습니다." ;;
  esac
  return 0
}

# A pipeline is stages joined by |. curl/wget followed by a shell = ask.
# Split in-process (no subshell per pipeline): long commands stay fast.
judge_pipeline() {
  local stage fetched=0
  local -a stages
  [ -z "$1" ] && return 0
  local IFS='|'
  # shellcheck disable=SC2206  # split on | on purpose; globbing is off (set -f)
  stages=($1)
  IFS=$' \t\n'
  [ "${#stages[@]}" -eq 0 ] && return 0
  for stage in "${stages[@]}"; do
    # shellcheck disable=SC2086  # intentional word splitting; globbing is off (set -f)
    strip_prefix $stage
    if [ "$fetched" = 1 ]; then
      case "$FIRST" in
        sh|bash|zsh|dash|ksh) add_ask "$fetch_reason" ;;
      esac
    fi
    [ "$SUDO" = 1 ] && add_ask "관리자 권한(sudo) 명령입니다. 실행해도 될까요?"
    [ -z "$CMD" ] && continue
    judge_stage
    case "$CMD" in curl|wget) fetched=1 ;; esac
  done
}

# ---- main -------------------------------------------------------------------

cmd="$(extract_command "$input")"
text="$(printf '%s\n' "$cmd" | unescape | normalize)"                # view (a)
top="$(printf '%s\n' "$cmd" | unescape | top_commands | home_norm)"  # view (b)
# For the whole-text checks: grouping undone, and the & of redirections such as
# 2>&1 or &> dropped (as in split_pipelines) so it is not a command boundary.
plain="$(printf '%s' "$text" | tr "$spc" ' ' | sed -E -e 's/&>/>/g' -e 's/>&/>/g' -e 's/<&/</g')"

# Fork bomb: checked on the whole text, whitespace allowed anywhere.
ws='[[:space:]]*'
if printf '%s' "$plain" | grep -Eq ":${ws}\\(${ws}\\)${ws}\\{${ws}:${ws}\\|${ws}:${ws}&${ws}\\}${ws};${ws}:"; then
  emit deny "포크 폭탄 형태의 명령은 막았습니다."
fi

# A download handed to a shell without a pipe, checked before splitting: a
# shell, eval, source or . in command position (text start or after ; & | ( {
# or `, optionally behind NAME=value, a redirection such as 2>/dev/null, sudo,
# env, exec, then, elif, do ... and their arguments) followed in the same
# command (no ; & | between) by $(...), `...`
# or <(...) that runs curl or wget. Covers bash -c "$(curl ...)",
# bash <(curl ...), bash < <(curl ...), bash <<< "$(curl ...)",
# source <(curl ...), . <(curl ...), eval "$(curl ...)" and /usr/bin/curl.
# Shell words that are only arguments (printf . "$(curl ...)") do not count.
start='(^|[;&|({`])[[:space:]]*'
pre='(([A-Za-z_][A-Za-z0-9_]*=[^;&|[:space:]]*|[0-9]*[<>][^;&|[:space:]]*|sudo|env|command|builtin|exec|nohup|time|nice|then|do|else|elif|if|while|until|!)[[:space:]]+([^;&|]*[[:space:]])?)?'
run='([^;&|[:space:]]*/)?(sh|bash|zsh|dash|ksh|eval|source|\.)'
subst='(\$\(|`|<\()'
dl='(curl|wget)([[:space:]]|$)'
if printf '%s' "$plain" | grep -Eq "${start}${pre}${run}([[:space:]][^;&|]*)?${subst}([^;&|)]*[^A-Za-z0-9_.-])?${dl}"; then
  add_ask "$fetch_reason"
fi

set -f # no glob expansion for words like /*
# `|| [ -n "$pipeline" ]`: a last line without a newline (a command that ends
# in a lone backslash) is still judged.
while IFS= read -r pipeline || [ -n "$pipeline" ]; do
  judge_pipeline "$pipeline"
done < <(printf '%s' "$text" | split_pipelines; printf '\n%s\n' "$top")

[ -n "$ask_reason" ] && emit ask "$ask_reason"
exit 0
