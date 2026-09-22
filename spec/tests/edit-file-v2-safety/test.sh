#!/usr/bin/env bash
# edit-v2-safety — tag staleness, atomicity on bad anchors, overlap
# rejection, no-op detection, CRLF preservation.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/edit_file"
[[ -x "${tool}" ]] || { echo "FAIL: ${tool} missing or not executable"; exit 1; }
export HARNESS_CWD="${_tmpdir}"
hl() { awk -f "${HARNESS_ROOT}/plugins/core/lib/hashline.awk" "$1"; }

f="${_tmpdir}/safe.txt"
printf 'one\ntwo\nthree\nfour\nfive\n' > "${f}"
before="$(cat "${f}")"

# 1. stale tag: refuse, file untouched
tag_now="$(md5sum "${f}" | cut -c1-8)"
bad_tag="deadbeef"
[[ "${bad_tag}" != "${tag_now}" ]] || bad_tag="00000000"
out="$(jq -c -n --arg t "$bad_tag" --arg a "$(hl "${f}" | sed -n '2p' | cut -d: -f1)" \
  '{path:"safe.txt",tag:$t,edits:[{at:$a,content:["XX"]}]}' | "${tool}" --exec 2>&1)" && {
  echo "FAIL: stale tag should error"; exit 1
}
echo "$out" | grep -q "changed since read" || { echo "FAIL: wrong stale-tag message: $out"; exit 1; }
assert_eq "stale: file untouched" "$(cat "${f}")" "$before"

# 2. current tag passes
out="$(jq -c -n --arg t "$tag_now" --arg a "$(hl "${f}" | sed -n '2p' | cut -d: -f1)" \
  '{path:"safe.txt",tag:$t,edits:[{at:$a,content:["TWO"]}]}' | "${tool}" --exec)" || { echo "$out"; exit 1; }
assert_eq "fresh tag edit applied" "$(sed -n '2p' "${f}")" "TWO"

# 3. atomicity: one invalid anchor among valid ones -> nothing written
printf 'one\ntwo\nthree\nfour\nfive\n' > "${f}"
good="$(hl "${f}" | sed -n '1p' | cut -d: -f1)"
out="$(jq -c -n --arg g "$good" \
  '{path:"safe.txt",edits:[{at:$g,content:["ONE"]},{at:"3#ZZ",content:["X"]}]}' | "${tool}" --exec 2>&1)" && {
  echo "FAIL: invalid anchor should error"; exit 1
}
echo "$out" | grep -qi "mismatch\|invalid" || { echo "FAIL: no anchor error: $out"; exit 1; }
assert_eq "atomic: file untouched" "$(cat "${f}")" "one
two
three
four
five"

# 4. overlapping ranges rejected
a1="$(hl "${f}" | sed -n '1p' | cut -d: -f1)"
a3="$(hl "${f}" | sed -n '3p' | cut -d: -f1)"
out="$(jq -c -n --arg a1 "$a1" --arg a3 "$a3" \
  '{path:"safe.txt",edits:[{at:$a1,end:$a3,content:["x"]},{at:$a3,content:["y"]}]}' | "${tool}" --exec 2>&1)" && {
  echo "FAIL: overlap should error"; exit 1
}
echo "$out" | grep -qi "overlap" || { echo "FAIL: no overlap message: $out"; exit 1; }

# 5. no-op detection: identical content -> error, mentions no change
a1="$(hl "${f}" | sed -n '1p' | cut -d: -f1)"
out="$(jq -c -n --arg a1 "$a1" '{path:"safe.txt",edits:[{at:$a1,content:["one"]}]}' | "${tool}" --exec 2>&1)" && {
  echo "FAIL: no-op should error"; exit 1
}
echo "$out" | grep -qi "no change" || { echo "FAIL: no no-op message: $out"; exit 1; }

# 6. CRLF preserved on inserted lines
printf 'a\r\nb\r\n' > "${f}"
a1="$(hl "${f}" | sed -n '1p' | cut -d: -f1)"
"${tool}" --exec <<< "$(jq -c -n --arg a1 "$a1" '{path:"safe.txt",edits:[{after:$a1,content:["mid"]}]}')" >/dev/null
grep -q $'^mid\r$' "${f}" || { echo "FAIL: inserted line lacks CRLF"; od -c "${f}"; exit 1; }