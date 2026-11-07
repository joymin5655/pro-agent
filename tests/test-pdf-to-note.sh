#!/usr/bin/env bash
# Tests for skills/pdf/pdf-to-note.sh.
# Most cases use a stub converter (PRO_AGENT_ODL) so they run anywhere.
# The real-conversion case runs only when opendataloader-pdf and Java are installed.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
script="$root/skills/pdf/pdf-to-note.sh"
sample="$here/fixtures/sample.pdf"
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

has() { grep -q -F -- "$2" "$1"; }

# Stub converter: writes <out>/<stem>.md with 3 pages, one image on page 1.
# STUB_EMPTY_PAGE=<n> leaves that page without text.
stub="$tmp/stub-odl.sh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
in="$1"; shift
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
stem="$(basename "$in")"; stem="${stem%.*}"
mkdir -p "$out/${stem}_images"
printf 'png' > "$out/${stem}_images/imageFile1.png"
for p in 1 2 3; do
  printf '<!-- p.%s -->\n\n' "$p"
  if [ "${STUB_EMPTY_PAGE:-0}" = "$p" ]; then continue; fi
  printf '# Heading %s\n\nThis is the body text of page number %s in the stub.\n\n' "$p" "$p"
  if [ "$p" = 1 ]; then printf '![](<%s_images/imageFile1.png>)\n\n' "$stem"; fi
done > "$out/$stem.md"
STUB
chmod +x "$stub"

run() { PRO_AGENT_ODL="$stub" bash "$script" "$@"; }

# 1) usage error
bash "$script" > /dev/null 2>&1
assert "no arguments exits 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"

# 2) converter missing: exit 3 and the vault stays untouched
v1="$tmp/v1"; mkdir -p "$v1/.obsidian"
PRO_AGENT_ODL="$tmp/not-there" bash "$script" "$sample" "$v1" > "$tmp/o2" 2>&1
rc=$?
assert "missing converter exits 3" "$([ $rc -eq 3 ] && echo 0 || echo 1)"
assert "missing converter prints missing=tool" "$(has "$tmp/o2" 'missing=tool'; echo $?)"
assert "missing converter leaves the vault untouched" "$([ ! -e "$v1/PDF" ] && echo 0 || echo 1)"

# 3) converter present but Java missing: exit 3
fakebin="$tmp/fakebin"; mkdir -p "$fakebin"
printf '#!/bin/sh\nexit 0\n' > "$fakebin/opendataloader-pdf"; chmod +x "$fakebin/opendataloader-pdf"
PATH="$fakebin:$PATH" PRO_AGENT_JAVA="$tmp/no-java" bash "$script" "$sample" "$v1" > "$tmp/o3" 2>&1
rc=$?
assert "missing Java exits 3" "$([ $rc -eq 3 ] && echo 0 || echo 1)"
assert "missing Java prints missing=java" "$(has "$tmp/o3" 'missing=java'; echo $?)"
assert "missing Java leaves the vault untouched" "$([ ! -e "$v1/PDF" ] && echo 0 || echo 1)"

# 4) normal conversion with the stub
out="$(run "$sample" "$v1" 2>&1)"; rc=$?
assert "conversion exits 0" "$rc"
note="$v1/PDF/sample.md"
assert "note is written to PDF/" "$([ -f "$note" ] && echo 0 || echo 1)"
assert "original is copied to PDF/원본/" "$([ -f "$v1/PDF/원본/sample.pdf" ] && echo 0 || echo 1)"
head -n 1 "$note" | grep -q '^---$'
assert "note starts with front matter" $?
for key in 'title: "sample"' 'source: "[[PDF/원본/sample.pdf]]"' 'pages: 3' 'tags: [pdf]'; do
  has "$note" "$key"
  assert "front matter has $key" $?
done
grep -q '^converted: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$' "$note"
assert "front matter has converted date" $?
grep -q '^converter: .\+' "$note"
assert "front matter has converter" $?
for p in 1 2 3; do
  grep -q -x -F "<!-- p.$p --> [[PDF/원본/sample.pdf#page=$p|p.$p]]" "$note"
  assert "page $p marker and link line" $?
done
assert "page markers are exactly 3" "$([ "$(grep -c '^<!-- p\.[0-9]* -->' "$note")" -eq 3 ] && echo 0 || echo 1)"
assert "images moved next to the note" "$([ -f "$v1/PDF/sample_images/imageFile1.png" ] && echo 0 || echo 1)"
has "$note" '![](<sample_images/imageFile1.png>)'
assert "image link points to the moved folder" $?
printf '%s\n' "$out" | grep -q '^pages=3$'
assert "report has pages=3" $?
printf '%s\n' "$out" | grep -q '^images=1$'
assert "report has images=1" $?
real_v1="$(cd "$v1" && pwd -P)"
printf '%s\n' "$out" | grep -q "^note=$real_v1/PDF/sample.md$"
assert "report has absolute note path" $?
if printf '%s\n' "$out" | grep -q '^warn='; then r=1; else r=0; fi
assert "no warnings for a normal PDF" "$r"

# 5) same name again: nothing is overwritten
sum_before="$(shasum "$note" | cut -d' ' -f1)"
run "$sample" "$v1" > /dev/null 2>&1
assert "second run exits 0" $?
assert "second note gets a number" "$([ -f "$v1/PDF/sample-2.md" ] && echo 0 || echo 1)"
assert "second original gets the same number" "$([ -f "$v1/PDF/원본/sample-2.pdf" ] && echo 0 || echo 1)"
assert "first note is unchanged" "$([ "$(shasum "$note" | cut -d' ' -f1)" = "$sum_before" ] && echo 0 || echo 1)"
has "$v1/PDF/sample-2.md" '[[PDF/원본/sample-2.pdf#page=2|p.2]]'
assert "second note links to the numbered original" $?
assert "second images folder is numbered" "$([ -d "$v1/PDF/sample-2_images" ] && echo 0 || echo 1)"

# 6) characters that break Obsidian links
v2="$tmp/v2"; mkdir -p "$v2/.obsidian"
cp "$sample" "$tmp/a#b|c[d]e^f.pdf"
run "$tmp/a#b|c[d]e^f.pdf" "$v2" > /dev/null 2>&1
assert "unsafe file name converts" $?
assert "note name has no unsafe characters" "$([ -f "$v2/PDF/a-b-c-d-e-f.md" ] && echo 0 || echo 1)"
assert "copied original has a safe name" "$([ -f "$v2/PDF/원본/a-b-c-d-e-f.pdf" ] && echo 0 || echo 1)"
has "$v2/PDF/a-b-c-d-e-f.md" '[[PDF/원본/a-b-c-d-e-f.pdf#page=1|p.1]]'
assert "link target is safe" $?
has "$v2/PDF/a-b-c-d-e-f.md" 'title: "a#b|c[d]e^f"'
assert "title keeps the original name" $?

# 7) original already inside the vault: no copy, link to it
v3="$tmp/v3"; mkdir -p "$v3/.obsidian/x" "$v3/inbox"
cp "$sample" "$v3/inbox/paper.pdf"
run "$v3/inbox/paper.pdf" "$v3" > /dev/null 2>&1
assert "in-vault original converts" $?
assert "in-vault original is not copied" "$([ ! -e "$v3/PDF/원본" ] && echo 0 || echo 1)"
has "$v3/PDF/paper.md" '[[inbox/paper.pdf#page=3|p.3]]'
assert "in-vault original is linked in place" $?

# 8) custom folders
v4="$tmp/v4"; mkdir -p "$v4"
run --notes-dir Notes/Papers --originals-dir Raw "$sample" "$v4" > /dev/null 2>&1
assert "custom folders convert" $?
assert "note goes to the custom folder" "$([ -f "$v4/Notes/Papers/sample.md" ] && echo 0 || echo 1)"
assert "original goes to the custom folder" "$([ -f "$v4/Raw/sample.pdf" ] && echo 0 || echo 1)"
has "$v4/Notes/Papers/sample.md" '[[Raw/sample.pdf#page=1|p.1]]'
assert "link uses the custom folder" $?

# 9) pages without text are reported
v5="$tmp/v5"; mkdir -p "$v5"
out="$(STUB_EMPTY_PAGE=2 run "$sample" "$v5" 2>&1)"
printf '%s\n' "$out" | grep -q '^warn=empty-pages:2$'
assert "empty page 2 is reported" $?

# 10) prepare mode (Claude reads the PDF itself): header only, original copied
v6="$tmp/v6"; mkdir -p "$v6"
PRO_AGENT_ODL="$tmp/not-there" bash "$script" --prepare "$sample" "$v6" > "$tmp/o10" 2>&1
assert "prepare works without a converter" $?
has "$v6/PDF/sample.md" 'converter: claude'
assert "prepare header says converter: claude" $?
has "$v6/PDF/sample.md" 'pages: 3'
assert "prepare header has the page count" $?
assert "prepare copies the original" "$([ -f "$v6/PDF/원본/sample.pdf" ] && echo 0 || echo 1)"
if grep -q '^<!-- p\.' "$v6/PDF/sample.md"; then r=1; else r=0; fi
assert "prepare writes no page body" "$r"
grep -q '^link=PDF/원본/sample.pdf$' "$tmp/o10"
assert "prepare prints the link target" $?

# 11) --info and --check
bash "$script" --info "$sample" 2>&1 | grep -q '^pages=3$'
assert "--info reports 3 pages" $?
PRO_AGENT_ODL="$tmp/not-there" bash "$script" --check > /dev/null 2>&1
assert "--check exits 3 when the converter is missing" "$([ $? -eq 3 ] && echo 0 || echo 1)"
PRO_AGENT_ODL="$stub" bash "$script" --check > /dev/null 2>&1
assert "--check exits 0 with a converter" $?

# 12) bad input
bash "$script" "$tmp/nope.pdf" "$v1" > /dev/null 2>&1
assert "missing PDF exits 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
bash "$script" "$sample" "$tmp/no-such-vault" > /dev/null 2>&1
assert "missing vault exits 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
run --notes-dir ../escape "$sample" "$v1" > /dev/null 2>&1
assert "folder with .. exits 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
printf 'not a pdf' > "$tmp/fake.txt"
run "$tmp/fake.txt" "$v1" > /dev/null 2>&1
assert "non-PDF file exits 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"

# 13) real converter, only when installed
if bash "$script" --check > /dev/null 2>&1; then
  v7="$tmp/v7"; mkdir -p "$v7"
  out="$(bash "$script" "$sample" "$v7" 2>&1)"; rc=$?
  assert "real conversion exits 0" "$rc"
  rn="$v7/PDF/sample.md"
  assert "real note has 3 page markers" "$([ "$(grep -c '^<!-- p\.[0-9]* --> \[\[' "$rn")" -eq 3 ] && echo 0 || echo 1)"
  has "$rn" 'pages: 3'
  assert "real note says pages: 3" $?
  awk '/^<!-- p\.2 -->/{f=1;next} /^<!-- p\.3 -->/{f=0} f' "$rn" | grep -q 'ferry carries forty passengers'
  assert "page 2 text sits under the p.2 marker" $?
  grep -q '^converter: opendataloader-pdf' "$rn"
  assert "real note records the converter name" $?
else
  echo "SKIP real conversion (opendataloader-pdf and Java not both available)"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
