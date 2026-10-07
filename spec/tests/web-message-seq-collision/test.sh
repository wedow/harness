#!/usr/bin/env bash
# A web insert can land after a driver chooses a sequence number. The driver
# must preserve that message and write its own to a new sequence.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

source "${HARNESS_ROOT}/plugins/core/lib/session.sh"
dir="${HARNESS_SESSION}"
cat > "${dir}/messages/0001-user.md" <<'MSG'
---
role: user
seq: 0001
---
first
MSG

# Inject the web write at the precise point after the driver's sequence
# scan. This was observed when _save_message then opened 0002-user.md with
# plain redirection, silently replacing the acknowledged web message.
_next_seq() {
  cat > "${dir}/messages/0002-user.md" <<'MSG'
---
role: user
seq: 0002
---
web guidance
MSG
  printf '0002\n'
}

_save_message "${dir}" 'driver message'
assert_file_contains "${dir}/messages/0002-user.md" 'web guidance'
assert_file_exists "${dir}/messages/0003-user.md"
assert_file_contains "${dir}/messages/0003-user.md" 'driver message'

echo PASS
