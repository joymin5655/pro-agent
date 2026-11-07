#!/usr/bin/env bash
# pdf-to-note.sh — put a PDF into a notes folder (Obsidian vault or plain markdown folder) as a note.
#
# Usage:
#   pdf-to-note.sh [--notes-dir DIR] [--originals-dir DIR] [--prepare] <pdf> <vault>
#   pdf-to-note.sh --check          # is the converter (opendataloader-pdf) + Java 11+ available?
#   pdf-to-note.sh --info <pdf>     # prints pages=N (or pages=unknown)
#
# Folders are relative to <vault>. Defaults: notes "PDF", originals "PDF/원본".
# --prepare copies the original and writes only the note header (for when Claude reads the PDF itself).
#
# Exit codes: 0 ok / 2 bad usage or input, or a save failure / 3 converter or Java missing / 4 conversion failed.
# Stdout (key=value): note, original, link, pages, converter, images, warn (may appear on several
# lines), missing (tool or java; with exit code 3).
#
# Test hooks: PRO_AGENT_ODL = converter command to use instead of opendataloader-pdf (Java is then
# not checked); PRO_AGENT_JAVA = the only java binary to try.

set -u

notes_rel="PDF"
orig_rel="PDF/원본"
mode="convert"
pos=()

die() { echo "$2" >&2; exit "$1"; }

# --- finding the converter and Java -----------------------------------------------------------

tool=""
custom=0
find_tool() {
  if [ -n "${PRO_AGENT_ODL:-}" ]; then
    custom=1
    [ -x "$PRO_AGENT_ODL" ] && tool="$PRO_AGENT_ODL"
  else
    tool="$(command -v opendataloader-pdf 2>/dev/null || true)"
    if [ -z "$tool" ]; then
      # uv tool / pipx default install folder, for when PATH is not updated yet.
      local c
      for c in "$HOME/.local/bin/opendataloader-pdf" "$HOME/.local/bin/opendataloader-pdf.exe"; do
        [ -x "$c" ] && { tool="$c"; break; }
      done
    fi
  fi
}

java_major() {
  "$1" -version 2>&1 | awk -F'"' '/version "/ {
    split($2, v, /[._-]/); print (v[1] == 1 ? v[2] : v[1]); exit }'
}

java_bin=""
java_note=""
find_java() {
  local c m cands
  if [ -n "${PRO_AGENT_JAVA:-}" ]; then
    cands=("$PRO_AGENT_JAVA")
  else
    cands=("$(command -v java 2>/dev/null || true)")
    [ -n "${JAVA_HOME:-}" ] && cands+=("$JAVA_HOME/bin/java")
    cands+=(/opt/homebrew/opt/openjdk/bin/java /usr/local/opt/openjdk/bin/java)
  fi
  for c in "${cands[@]}"; do
    if [ -z "$c" ] || [ ! -x "$c" ]; then continue; fi
    m="$(java_major "$c")"
    if [ -n "$m" ] && [ "$m" -ge 11 ] 2>/dev/null; then
      java_bin="$c"; java_note="$m"; return 0
    fi
    java_note="too-old-or-broken"
  done
  return 1
}

tool_version() {
  # opendataloader-pdf has no --version flag; ask the Python it was installed with.
  local py v
  py="$(head -n 1 "$1" 2>/dev/null | sed -n 's/^#! *//p')"
  if [ -n "$py" ] && [ -x "$py" ]; then
    v="$("$py" -I -c 'import importlib.metadata as m; print(m.version("opendataloader-pdf"))' 2>/dev/null || true)"
    [ -n "$v" ] && { echo "opendataloader-pdf $v"; return; }
  fi
  echo "opendataloader-pdf"
}

# Sets tool/java_bin or exits 3.
need_converter() {
  find_tool
  if [ -z "$tool" ]; then
    echo "missing=tool"
    die 3 "변환 도구(opendataloader-pdf)를 찾지 못했습니다."
  fi
  if [ "$custom" -eq 0 ] && ! find_java; then
    echo "missing=java"
    die 3 "Java 11 이상을 찾지 못했습니다(변환 도구에 필요)."
  fi
}

# --- small helpers ----------------------------------------------------------------------------

# Each method's answer counts only when it is an integer >= 1.
valid_pages() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] 2>/dev/null
}

count_pages() {
  local n=""
  if command -v pdfinfo > /dev/null 2>&1; then
    n="$(pdfinfo "$1" 2>/dev/null | awk '/^Pages:/ {print $2}')"
    valid_pages "$n" || n=""
  fi
  if [ -z "$n" ] && command -v mdls > /dev/null 2>&1; then
    n="$(mdls -raw -name kMDItemNumberOfPages "$1" 2>/dev/null)"
    valid_pages "$n" || n=""
  fi
  if [ -z "$n" ]; then
    # Last resort: count page objects (works for simple PDFs; unreliable with compressed object streams).
    n="$(LC_ALL=C grep -a -o -E '/Type[[:space:]]*/Page([^s]|$)' "$1" 2>/dev/null | wc -l | tr -d ' ')"
    valid_pages "$n" || n=""
  fi
  echo "${n:-unknown}"
}

safe_stem() {
  # Characters that break Obsidian links or file names become "-".
  local s c
  s="$(printf '%s' "$1" | tr '\n\r\t' '   ')"
  for c in '#' '|' '^' '[' ']' "\\" '/' ':' '*' '?' '"' '<' '>'; do
    s="${s//"$c"/-}"
  done
  s="$(printf '%s' "$s" | sed 's/^[ .]*//; s/[ .]*$//')"
  [ -n "$s" ] || s="document"
  printf '%s' "$s"
}

unsafe_link_path() {
  case "$1" in
    *$'\n'* | *$'\r'*) return 0 ;;
    *'#'* | *'|'* | *'['* | *']'* | *'^'* | *"\\"* | *':'* | *'*'* | *'?'* | *'"'* | *'<'* | *'>'*) return 0 ;;
  esac
  return 1
}

no_line_break() {
  # no_line_break <value> <what>: a line break would put fake lines into the key=value output and the header.
  case "$1" in
    *$'\n'* | *$'\r'*) die 2 "$2에 줄바꿈이 있어 멈춥니다." ;;
  esac
}

# Refuses a folder path in the vault that goes through a symlink (it could lead outside the vault).
check_no_symlink() {
  # check_no_symlink <vault> <relative folder>
  local rest="$2" part cur=""
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    [ -n "$part" ] || continue
    cur="${cur:+$cur/}$part"
    if [ -L "$1/$cur" ]; then die 2 "폴더 경로에 바로가기가 있어 멈춥니다: $cur"; fi
  done
}

check_rel_dir() {
  case "$1" in
    "" | /* | ../* | */../* | */.. | ..) die 2 "폴더는 노트 저장소 안의 상대 경로여야 합니다: $1" ;;
  esac
  no_line_break "$1" "폴더 이름"
  if unsafe_link_path "$1"; then
    die 2 "폴더 이름에 링크를 깨는 글자(# | ^ [ ] \\ : * ? \" < >)가 있습니다: $1"
  fi
}

# --- arguments --------------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --notes-dir) [ $# -ge 2 ] || die 2 "--notes-dir 값이 없습니다."; notes_rel="${2%/}"; shift 2 ;;
    --originals-dir) [ $# -ge 2 ] || die 2 "--originals-dir 값이 없습니다."; orig_rel="${2%/}"; shift 2 ;;
    --prepare) mode="prepare"; shift ;;
    --check) mode="check"; shift ;;
    --info) mode="info"; shift ;;
    -h | --help) sed -n '2,18p' "$0"; exit 0 ;;
    *) pos+=("$1"); shift ;;
  esac
done

if [ "$mode" = "check" ]; then
  find_tool
  rc=0
  if [ -n "$tool" ]; then echo "tool=ok $tool ($(tool_version "$tool"))"; else echo "tool=missing"; rc=3; fi
  if [ "$custom" -eq 1 ]; then
    echo "java=skipped"
  elif find_java; then
    echo "java=ok $java_bin (major $java_note)"
  else
    echo "java=missing"; rc=3
  fi
  exit "$rc"
fi

if [ "$mode" = "info" ]; then
  if [ "${#pos[@]}" -ne 1 ] || [ ! -f "${pos[0]}" ]; then die 2 "사용법: pdf-to-note.sh --info <pdf>"; fi
  f="${pos[0]}"
  no_line_break "$f" "PDF 경로"
  case "$f" in -*) f="./$f" ;; esac # same guard as the conversion path below
  echo "pages=$(count_pages "$f")"
  exit 0
fi

[ "${#pos[@]}" -eq 2 ] || die 2 "사용법: pdf-to-note.sh [--notes-dir DIR] [--originals-dir DIR] [--prepare] <pdf> <vault>"
pdf="${pos[0]}"
no_line_break "$pdf" "PDF 경로"
case "$pdf" in -*) pdf="./$pdf" ;; esac # a name starting with "-" must not be read as an option
vault_arg="${pos[1]}"
no_line_break "$vault_arg" "노트 저장소 경로"
[ -f "$pdf" ] || die 2 "PDF 파일이 없습니다: $pdf"
[ "$(head -c 4 "$pdf")" = "%PDF" ] || die 2 "PDF 파일이 아닙니다: $pdf"
[ -d "$vault_arg" ] || die 2 "노트 저장소 폴더가 없습니다: $vault_arg"
check_rel_dir "$notes_rel"
check_rel_dir "$orig_rel"

# Check the converter before touching the vault.
if [ "$mode" = "convert" ]; then need_converter; fi

vault="$(cd "$vault_arg" && pwd -P)"
no_line_break "$vault" "노트 저장소 경로"
check_no_symlink "$vault" "$notes_rel"
check_no_symlink "$vault" "$orig_rel"
pdf_abs="$(cd "$(dirname "$pdf")" && pwd -P)/$(basename "$pdf")"
src_name="$(basename "$pdf")"
src_stem="${src_name%.*}"
safe="$(safe_stem "$src_stem")"

# Original: link in place when it is already in the vault and its path is link-safe; otherwise copy.
copy_needed=1
link_path=""
warns=""
add_warn() { warns="${warns:+$warns$'\n'}warn=$1"; }
case "$pdf_abs" in
  "$vault"/*)
    rel="${pdf_abs#"$vault"/}"
    if unsafe_link_path "$rel"; then
      add_warn "in-vault-original-unsafe-name:copied"
    else
      copy_needed=0; link_path="$rel"
    fi
    ;;
esac

# Pick a name that overwrites nothing.
stem="$safe"
n=1
# A symlink (even a dangling one) counts as taken: writing through it could create a file elsewhere.
taken() { [ -e "$1" ] || [ -L "$1" ]; }
while taken "$vault/$notes_rel/$stem.md" || taken "$vault/$notes_rel/${stem}_images" ||
  { [ "$copy_needed" -eq 1 ] && taken "$vault/$orig_rel/$stem.pdf"; }; do
  n=$((n + 1)); stem="$safe-$n"
done
[ "$copy_needed" -eq 1 ] && link_path="$orig_rel/$stem.pdf"

pages="$(count_pages "$pdf")"
today="$(date +%Y-%m-%d)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

yaml_title="$(printf '%s' "$src_stem" | sed 's/\\/\\\\/g; s/"/\\"/g')"
write_header() {
  # write_header <converter> <pages>
  printf -- '---\ntitle: "%s"\nsource: "[[%s]]"\npages: %s\nconverted: %s\nconverter: %s\ntags: [pdf]\n---\n\n' \
    "$yaml_title" "$link_path" "$2" "$today" "$1"
}

body="$work/body.md"
conv_name="claude"
images=0
if [ "$mode" = "convert" ]; then
  conv_name="$(tool_version "$tool")"
  [ "$custom" -eq 1 ] && conv_name="$(basename "$tool")"
  conv_name="$(printf '%s' "$conv_name" | head -n 1 | tr -d '\r')"
  conv_out="$work/out"; mkdir -p "$conv_out"
  if [ -n "$java_bin" ]; then PATH="$(dirname "$java_bin"):$PATH"; export PATH; fi
  if ! "$tool" "$pdf_abs" -f markdown -o "$conv_out" -q --markdown-page-separator '<!-- p.%page-number% -->' > "$work/conv.log" 2>&1; then
    head -n 5 "$work/conv.log" >&2
    die 4 "변환에 실패했습니다."
  fi
  raw="$conv_out/$src_stem.md"
  [ -f "$raw" ] || raw="$(find "$conv_out" -maxdepth 1 -name '*.md' | head -n 1)"
  if [ -z "$raw" ] || [ ! -f "$raw" ]; then die 4 "변환 결과 파일이 없습니다."; fi
  old_images="$(basename "${raw%.md}")_images"

  # Page markers get an Obsidian link to the same page of the original; image folder gets the final name.
  LINK="$link_path" OLD="$old_images/" NEW="${stem}_images/" awk '
    BEGIN { link = ENVIRON["LINK"]; old = ENVIRON["OLD"]; new = ENVIRON["NEW"] }
    {
      line = $0
      if (line ~ /^<!-- p\.[0-9]+ -->[ \t]*$/) {
        p = line; sub(/^<!-- p\./, "", p); sub(/ -->.*$/, "", p)
        print "<!-- p." p " --> [[" link "#page=" p "|p." p "]]"
        next
      }
      out = ""
      while ((i = index(line, old)) > 0) {
        out = out substr(line, 1, i - 1) new
        line = substr(line, i + length(old))
      }
      print out line
    }' "$raw" > "$body"

  marker_count="$(grep -c '^<!-- p\.[0-9]* --> \[\[' "$body" || true)"
  [ "${marker_count:-0}" -gt 0 ] || die 4 "변환 결과에 쪽 표시가 없습니다(변환 도구 판이 맞지 않을 수 있음)."
  pages="$(grep '^<!-- p\.[0-9]* --> \[\[' "$body" | sed 's/^<!-- p\.\([0-9]*\) .*/\1/' | sort -n | tail -n 1)"

  # Pages with (almost) no text: scanned pages or pictures only. The threshold is 20 bytes (LC_ALL=C
  # counts bytes, not characters; a scanned page has no text at all, so the unit hardly matters).
  empty="$(LC_ALL=C awk '
    function flush() { if (page != "" && chars < 20) list = list (list == "" ? "" : ",") page }
    /^<!-- p\.[0-9]+ -->/ { flush(); page = $0; sub(/^<!-- p\./, "", page); sub(/ -->.*$/, "", page); chars = 0; next }
    /^!\[/ { next }
    { t = $0; gsub(/[ \t#|*_>`-]/, "", t); chars += length(t) }
    END { flush(); print list }' "$body")"
  [ -n "$empty" ] && add_warn "empty-pages:$empty"

  if [ -d "$conv_out/$old_images" ]; then
    images="$(find "$conv_out/$old_images" -type f | wc -l | tr -d ' ')"
  fi
fi

# --- write into the vault (nothing existing is overwritten) ------------------------------------
# Order: original, images, note last, so a note never points at a missing original or image folder.
# A failure leaves what was already saved in place (nothing is deleted).
# Checked again right before writing: conversion can take a while in a shared vault (this narrows the gap; it cannot close it in a shell script).
check_no_symlink "$vault" "$notes_rel"
check_no_symlink "$vault" "$orig_rel"

note="$vault/$notes_rel/$stem.md"
{
  write_header "$conv_name" "$pages"
  [ -f "$body" ] && cat "$body"
} > "$work/note.md"

mkdir -p "$vault/$notes_rel" || die 2 "노트 폴더를 만들 수 없습니다."
if [ "$copy_needed" -eq 1 ]; then
  mkdir -p "$vault/$orig_rel" || die 2 "원본 폴더를 만들 수 없습니다."
  cp -p "$pdf" "$work/original.pdf" || die 2 "원본 PDF를 복사하지 못했습니다: $pdf"
  mv -n "$work/original.pdf" "$vault/$orig_rel/$stem.pdf"
  [ -e "$work/original.pdf" ] && die 2 "원본을 저장하지 못했습니다(같은 이름이 생겼거나 쓰기 실패): $vault/$orig_rel/$stem.pdf"
fi
if [ "$images" -gt 0 ]; then
  mv -n "$conv_out/$old_images" "$vault/$notes_rel/${stem}_images"
  [ -e "$conv_out/$old_images" ] && die 2 "그림 폴더를 저장하지 못했습니다. 이미 저장된 원본은 그대로 있습니다: $vault/$link_path"
fi
mv -n "$work/note.md" "$note"
[ -e "$work/note.md" ] && die 2 "노트를 저장하지 못했습니다. 이미 저장된 원본·그림은 그대로 있습니다: $note"

echo "note=$note"
echo "original=$vault/$link_path"
echo "link=$link_path"
echo "pages=$pages"
echo "converter=$conv_name"
echo "images=$images"
[ -n "$warns" ] && printf '%s\n' "$warns"
exit 0
