#!/usr/bin/env bash
# A length-limit nudge must not overwrite web guidance at the next sequence.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

source "${HARNESS_ROOT}/plugins/core/lib/continue.sh"
msg_dir="${HARNESS_SESSION}/messages"
printf 'assistant response\n' > "${msg_dir}/0001-assistant.md"
printf 'web guidance\n' > "${msg_dir}/0002-user.md"

_length_continue "${msg_dir}" 0002 > "${_tmpdir}/result"
assert_file_contains "${msg_dir}/0002-user.md" 'web guidance'
assert_file_exists "${msg_dir}/0003-user.md"
assert_file_contains "${msg_dir}/0003-user.md" 'continuation: length'
