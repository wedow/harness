#!/usr/bin/env bash
# edit-v2-edits — repo-local edit_file v2: replace/insert/delete shapes,
# string content, multi-edit bottom-up application, shift reporting.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/edit_file"
[[ -x "${tool}" ]] || { echo "FAIL: ${tool} missing or not executable"; exit 1; }
export HARNESS_CWD="${_tmpdir}"

f="${_tmpdir}/src.txt"
printf 'alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\ngolf\nhotel\n' > "${f}"

# anchors: read via hashline to get real ones
hl() { awk -f "${HARNESS_ROOT}/plugins/core/lib/hashline.awk" "$1"; }
a3="$(hl "${f}" | sed -n '3p' | cut -d: -f1)"   # 3#XX charlie
a4="$(hl "${f}" | sed -n '4p' | cut -d: -f1)"   # 4#XX delta
a8="$(hl "${f}" | sed -n '8p' | cut -d: -f1)"   # 8#XX hotel

# 1. replace_range over 2 lines + insert after a later line in one call
out="$(jq -c -n --arg a3 "$a3" --arg a4 "$a4" --arg a8 "$a8" \
  '{path:"src.txt",edits:[
     {at:$a3,end:$a4,content:["CHARLIE","DELTA","DELTA2"]},
     {after:$a8,content:["INDIA"]}]}' | "${tool}" --exec)" || { echo "FAIL: call errored"; echo "$out"; exit 1; }

assert_eq "replace applied" "$(sed -n '3p' "${f}")" "CHARLIE"
assert_eq "replace applied 2" "$(sed -n '5p' "${f}")" "DELTA2"
assert_eq "lines below shifted" "$(sed -n '6p' "${f}")" "echo"
assert_eq "insert at end" "$(tail -1 "${f}")" "INDIA"
echo "${out}" | grep -q "shift 1" || { echo "FAIL: no shift info"; echo "$out"; exit 1; }
echo "${out}" | grep -q "fresh anchors" || { echo "FAIL: no fresh anchors"; echo "$out"; exit 1; }

# 2. delete: content null over one line
out="$(jq -c -n --arg a1 "$(hl "${f}" | sed -n '1p' | cut -d: -f1)" \
  '{path:"src.txt",edits:[{at:$a1,content:null}]}' | "${tool}" --exec)"
assert_eq "delete line 1" "$(sed -n '1p' "${f}")" "bravo"

# 3. insert at top: after "0"
out="$(jq -c -n '{path:"src.txt",edits:[{after:"0",content:["TOP"]}]}' | "${tool}" --exec)"
assert_eq "insert at top" "$(sed -n '1p' "${f}")" "TOP"

# 4. content as a single string with newlines
a2="$(hl "${f}" | sed -n '2p' | cut -d: -f1)"
out="$(jq -c -n --arg a2 "$a2" '{path:"src.txt",edits:[{after:$a2,content:"x\ny"}]}' | "${tool}" --exec)"
assert_eq "string content line 1" "$(sed -n '3p' "${f}")" "x"
assert_eq "string content line 2" "$(sed -n '4p' "${f}")" "y"
# 5. out-of-order listing: later-line edit listed FIRST, earlier edit grows
#    (the apply order and report-shift must be position-based, not array-based)
f2="${_tmpdir}/ooo.txt"
printf 'a1\na2\na3\na4\na5\na6\na7\na8\n' > "${f2}"
a8="$(hl "${f2}" | sed -n '8p' | cut -d: -f1)"
a2="$(hl "${f2}" | sed -n '2p' | cut -d: -f1)"
a3="$(hl "${f2}" | sed -n '3p' | cut -d: -f1)"
out="$(jq -c -n --arg a8 "$a8" --arg a2 "$a2" --arg a3 "$a3" \
  '{path:"ooo.txt",edits:[
     {at:$a8,content:["e1","e2","e3"]},
     {at:$a2,end:$a3,content:["b1","b2","b3","b4","b5"]}]}' | "${tool}" --exec)" || { echo "$out"; exit 1; }
assert_eq "ooo line 1" "$(sed -n '1p' "${f2}")" "a1"
assert_eq "ooo line 2" "$(sed -n '2p' "${f2}")" "b1"
assert_eq "ooo line 6" "$(sed -n '6p' "${f2}")" "b5"
assert_eq "ooo line 7 (a4 follows)" "$(sed -n '7p' "${f2}")" "a4"
assert_eq "ooo line 10 (a7 follows)" "$(sed -n '10p' "${f2}")" "a7"
assert_eq "ooo line 11" "$(sed -n '11p' "${f2}")" "e1"
assert_eq "ooo total 13" "$(awk 'END{print NR}' "${f2}")" "13"
# the later-line edit's fresh anchors must reflect the +3 shift from above
echo "${out}" | grep -q "^11#" || { echo "FAIL: later edit not re-anchored at 11"; echo "$out"; exit 1; }

# 6. two inserts at the same anchor keep array order
f3="${_tmpdir}/same.txt"
printf 'x\ny\n' > "${f3}"
a1="$(hl "${f3}" | sed -n '1p' | cut -d: -f1)"
"${tool}" --exec <<< "$(jq -c -n --arg a1 "$a1" \
  '{path:"same.txt",edits:[{after:$a1,content:["first"]},{after:$a1,content:["second"]}]}')" >/dev/null
assert_eq "same-anchor order" "$(sed -n '2p' "${f3}")" "first"
assert_eq "same-anchor order 2" "$(sed -n '3p' "${f3}")" "second"
