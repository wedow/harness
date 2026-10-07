#!/usr/bin/env bash
# read-file-tag-header — read_file emits a tag=<md5-8> snapshot header on
# successful reads (edit_file's staleness check) and passes errors through
# without a tag.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/read_file"
export HARNESS_CWD="${_tmpdir}"

printf 'hello\nworld\n' > "${_tmpdir}/t.txt"

# successful read: first line is the tag, matches md5-8
out="$(echo '{"path":"t.txt"}' | "${tool}" --exec)" || { echo "$out"; exit 1; }
first="$(head -1 <<< "$out")"
assert_eq "tag header" "${first%%=*}" "tag"
assert_eq "tag value is md5-8" "${first#tag=}" "$(md5sum "${_tmpdir}/t.txt" | cut -c1-8)"
sed -n '2p' <<< "$out" | grep -qE '^1#[A-Z]{2}:hello$' \
  || { echo "FAIL: anchored content line wrong: $(sed -n '2p' <<< "$out")"; exit 1; }

# tag tracks content changes
printf 'changed\n' > "${_tmpdir}/t.txt"
out="$(echo '{"path":"t.txt"}' | "${tool}" --exec)"
assert_eq "tag updated" "$(head -1 <<< "$out")" "tag=$(md5sum "${_tmpdir}/t.txt" | cut -c1-8)"

# error path: no tag line
out="$(echo '{"path":"missing.txt"}' | "${tool}" --exec 2>&1)" && { echo "FAIL: should error"; exit 1; }
echo "$out" | grep -q '^tag=' && { echo "FAIL: tag on error"; exit 1; }
echo "$out" | grep -q 'file not found' || { echo "FAIL: no error text"; exit 1; }