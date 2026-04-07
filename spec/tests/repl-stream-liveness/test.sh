#!/usr/bin/env bash
# Test: REPL _render_stream uses read -t (timeout) for liveness checking
# Without read -t, a dead agent leaves the stream reader blocking forever.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

repl="${HARNESS_ROOT}/plugins/core/commands/repl"

# Verify _render_stream uses read -t (not bare read)
# The fix changes: while IFS= read -r event <&5
# To: if ! IFS= read -t 2 -r event <&5
if ! grep -q 'read -t' "${repl}"; then
  echo "FAIL: _render_stream has no read timeout — will block if agent dies"
  exit 1
fi

# Verify _render_stream checks agent liveness via kill -0
if ! grep -q 'kill -0' "${repl}"; then
  echo "FAIL: _render_stream does not check agent liveness"
  exit 1
fi

echo "PASS"
