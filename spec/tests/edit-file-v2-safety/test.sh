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
tag() { md5sum "$1" | cut -c1-8; }

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
out="$(jq -c -n --arg t "$(tag "$f")" --arg g "$good" \
  '{path:"safe.txt",tag:$t,edits:[{at:$g,content:["ONE"]},{at:"3#ZZ",content:["X"]}]}' | "${tool}" --exec 2>&1)" && {
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
out="$(jq -c -n --arg t "$(tag "$f")" --arg a1 "$a1" --arg a3 "$a3" \
  '{path:"safe.txt",tag:$t,edits:[{at:$a1,end:$a3,content:["x"]},{at:$a3,content:["y"]}]}' | "${tool}" --exec 2>&1)" && {
  echo "FAIL: overlap should error"; exit 1
}
echo "$out" | grep -qi "overlap" || { echo "FAIL: no overlap message: $out"; exit 1; }

# 5. no-op detection: identical content -> error, mentions no change
a1="$(hl "${f}" | sed -n '1p' | cut -d: -f1)"
out="$(jq -c -n --arg t "$(tag "$f")" --arg a1 "$a1" '{path:"safe.txt",tag:$t,edits:[{at:$a1,content:["one"]}]}' | "${tool}" --exec 2>&1)" && {
  echo "FAIL: no-op should error"; exit 1
}
echo "$out" | grep -qi "no change" || { echo "FAIL: no no-op message: $out"; exit 1; }

# 6. CRLF preserved on inserted lines
printf 'a\r\nb\r\n' > "${f}"
a1="$(hl "${f}" | sed -n '1p' | cut -d: -f1)"
"${tool}" --exec <<< "$(jq -c -n --arg t "$(tag "$f")" --arg a1 "$a1" '{path:"safe.txt",tag:$t,edits:[{after:$a1,content:["mid"]}]}')" >/dev/null
grep -q $'^mid\r$' "${f}" || { echo "FAIL: inserted line lacks CRLF"; od -c "${f}"; exit 1; }

# 7. omitted content must not be interpreted as an explicit deletion
printf 'one\ntwo\nthree\n' > "${f}"
before="$(cat "${f}")"
a1="$(hl "${f}" | sed -n '1p' | cut -d: -f1)"
a3="$(hl "${f}" | sed -n '3p' | cut -d: -f1)"
out="$(jq -c -n --arg t "$(tag "$f")" --arg a1 "$a1" --arg a3 "$a3" \
  '{path:"safe.txt",tag:$t,edits:[{at:$a1},{at:$a3,content:["THREE"]}]}' | "${tool}" --exec 2>&1)" && {
  echo "FAIL: omitted content should error"; exit 1
}
echo "$out" | grep -q "content is required" || { echo "FAIL: wrong missing-content message: $out"; exit 1; }
assert_eq "missing content: file untouched" "$(cat "${f}")" "$before"
"${tool}" --schema | jq -e '.input_schema.properties.edits.items.required | index("content")' >/dev/null \
  || { echo "FAIL: schema should require content in every edit"; exit 1; }

# 8. endpoint anchors alone cannot detect a changed line inside a range
printf 'first\noriginal\nlast\n' > "${f}"
tag_before="$(tag "$f")"
a1="$(hl "${f}" | sed -n '1p' | cut -d: -f1)"
a3="$(hl "${f}" | sed -n '3p' | cut -d: -f1)"
printf 'first\nintervening change\nlast\n' > "${f}"
before="$(cat "${f}")"
out="$(jq -c -n --arg t "$tag_before" --arg a1 "$a1" --arg a3 "$a3" \
  '{path:"safe.txt",tag:$t,edits:[{at:$a1,end:$a3,content:["replacement"]}]}' | "${tool}" --exec 2>&1)" && {
  echo "FAIL: stale interior edit should error"; exit 1
}
echo "$out" | grep -q "changed since read" || { echo "FAIL: wrong stale-interior message: $out"; exit 1; }
assert_eq "stale interior: intervening change preserved" "$(cat "${f}")" "$before"
out="$(jq -c -n --arg a1 "$a1" --arg a3 "$a3" \
  '{path:"safe.txt",edits:[{at:$a1,end:$a3,content:["replacement"]}]}' | "${tool}" --exec 2>&1)" && {
  echo "FAIL: edit without a snapshot tag should error"; exit 1
}
echo "$out" | grep -q "tag is required" || { echo "FAIL: wrong missing-tag message: $out"; exit 1; }
assert_eq "missing tag: intervening change preserved" "$(cat "${f}")" "$before"
"${tool}" --schema | jq -e '.input_schema.required | index("tag")' >/dev/null \
  || { echo "FAIL: schema should require tag"; exit 1; }

# 9. A failed final move must leave the destination intact. Force work files
# onto another filesystem, then simulate a cross-device copy interrupted after
# truncating the destination (the fallback used by mv across filesystems).
if [[ -d /dev/shm && -w /dev/shm && "$(stat -c %d /dev/shm)" != "$(stat -c %d "${_tmpdir}")" ]]; then
  printf 'original\n' > "${f}"
  before="$(cat "${f}")"
  a1="$(hl "${f}" | sed -n '1p' | cut -d: -f1)"
  mkdir -p "${_tmpdir}/fake-bin"
  real_mv="$(command -v mv)"
  cat > "${_tmpdir}/fake-bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$2" == "${EDIT_TEST_TARGET}" ]]; then
  stat -c %d "$1" > "${EDIT_TEST_SOURCE_DEVICE}"
  if [[ "$(stat -c %d "$1")" != "$(stat -c %d "$2")" ]]; then
    printf 'partial copy\n' > "$2"
  fi
  exit 1
fi
exec "${EDIT_TEST_REAL_MV}" "$@"
SH
  chmod +x "${_tmpdir}/fake-bin/mv"
  out="$(jq -c -n --arg t "$(tag "$f")" --arg a1 "$a1" \
    '{path:"safe.txt",tag:$t,edits:[{at:$a1,content:["replacement"]}]}' | \
    env PATH="${_tmpdir}/fake-bin:${PATH}" TMPDIR=/dev/shm \
      EDIT_TEST_TARGET="${f}" EDIT_TEST_SOURCE_DEVICE="${_tmpdir}/source-device" \
      EDIT_TEST_REAL_MV="${real_mv}" "${tool}" --exec 2>&1)" && {
    echo "FAIL: injected final move failure should error"; exit 1
  }
  assert_eq "failed move: file untouched" "$(cat "${f}")" "${before}"
  assert_eq "work is on destination filesystem" "$(cat "${_tmpdir}/source-device")" "$(stat -c %d "${f}")"
fi
