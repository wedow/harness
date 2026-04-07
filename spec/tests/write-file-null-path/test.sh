#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

tool="${HARNESS_ROOT}/plugins/core/tools/write_file"
export HARNESS_CWD="${_tmpdir}"

# Test 1: missing path and content - should error
output=$(echo '{}' | "${tool}" --exec 2>&1) && {
  echo "FAIL: missing-path-should-error: expected non-zero exit"
  exit 1
}
assert_eq "missing-path-error-message" "$(echo "$output" | grep -c 'path is required')" "1"

# Test 2: missing path, content present - should error
output=$(echo '{"content":"hello"}' | "${tool}" --exec 2>&1) && {
  echo "FAIL: missing-path-with-content: expected non-zero exit"
  exit 1
}
assert_eq "missing-path-with-content-error" "$(echo "$output" | grep -c 'path is required')" "1"

# Test 3: explicit null path - should error
output=$(echo '{"path":null,"content":"hello"}' | "${tool}" --exec 2>&1) && {
  echo "FAIL: null-path: expected non-zero exit"
  exit 1
}
assert_eq "null-path-error" "$(echo "$output" | grep -c 'path is required')" "1"

# Test 4: happy path still works
target="${_tmpdir}/test_output.txt"
echo "{\"path\":\"${target}\",\"content\":\"hello world\"}" | "${tool}" --exec
assert_file_exists "${target}"
assert_file_contains "${target}" "hello world"
