#!/usr/bin/env bash
# Test: ACP stream loop uses read -t (timeout) for liveness checking
# Without read -t, a dead agent leaves the stream reader blocking forever.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

acp_stream="${HARNESS_ROOT}/plugins/core/commands/acp-stream"

# Verify _acp_stream_loop uses read -t (not bare read)
if ! grep -q 'read -t' "${acp_stream}"; then
  echo "FAIL: _acp_stream_loop has no read timeout — will block if agent dies"
  exit 1
fi

# Verify it checks process liveness via kill -0
if ! grep -q 'kill -0' "${acp_stream}"; then
  echo "FAIL: _acp_stream_loop does not check agent liveness"
  exit 1
fi

echo "PASS"
