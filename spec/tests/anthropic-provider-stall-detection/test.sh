#!/usr/bin/env bash
# BUG-3: providers issue `curl ... --max-time 300` with no inactivity detector.
# A stalled stream (TCP open, zero bytes — the actual failure mode in the
# runaway trace) burns the full 300s before erroring. With --speed-limit 1
# --speed-time 60, curl aborts a zero-byte stream in ~60s.
#
# This test uses REAL curl against a local stall server (accepts the TCP
# connection, never writes a byte). A mock curl would not exercise curl's
# inactivity detector and so could not prove the fix.
#
# Production default is --speed-time 60; this test overrides it to 2s via
# HARNESS_CURL_SPEED_TIME so it runs in seconds instead of a minute.
# Pre-fix:  no --speed-time flag, so curl blocks until the outer `timeout 30`
#           kills it (rc=124, elapsed≈30s) → fails the <25s assertion.
# Post-fix: --speed-time 2 fires at ~2s → provider exits 1, elapsed≈3-5s → passes.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

provider="${HARNESS_ROOT}/plugins/anthropic/providers/anthropic"

# Stall server: bind an ephemeral port, accept one connection, then hang.
# Writes nothing — matching the worst-case trace (one stream never sent
# message_start). The OS-chosen port is printed to stdout for the parent.
stall_script="$(mktemp)"
cat > "${stall_script}" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0))
s.listen(1)
sys.stdout.write(f'{s.getsockname()[1]}\n'); sys.stdout.flush()
conn, _ = s.accept()  # accept, then never write / never close
time.sleep(3600)
PY

port_file="$(mktemp)"
python3 "${stall_script}" >"${port_file}" &
server_pid=$!
trap 'kill ${server_pid} 2>/dev/null || true; wait ${server_pid} 2>/dev/null || true; rm -f "${stall_script}" "${port_file}"; teardown' EXIT

# Wait for the server to print its chosen port.
for _ in $(seq 1 100); do
  [[ -s "${port_file}" ]] && break
  sleep 0.1
done
port="$(cat "${port_file}")"
[[ -n "${port}" ]] || { echo "FAIL: stall server did not start"; exit 1; }

export ANTHROPIC_API_KEY="test-key"
export ANTHROPIC_API_URL="http://127.0.0.1:${port}/v1/messages"
# Shrink the inactivity window so the test is fast (production default is 60).
export HARNESS_CURL_SPEED_TIME=2

payload='{"model":"claude-sonnet-4-test","system":"","messages":[{"role":"user","content":"hi"}],"tools":[]}'

start=$(date +%s)
set +e
echo "${payload}" | timeout 30 "${provider}" --stream >/dev/null 2>&1
rc=$?
set -e
end=$(date +%s)
elapsed=$((end - start))

# Provider must exit non-zero: curl aborts (rc 28 from --speed-time) and the
# provider then exits 1 because got_message_start is false.
[[ "${rc}" -ne 0 ]] || { echo "FAIL: expected non-zero exit, got ${rc}"; exit 1; }

# The decisive assertion: abort must land well under the 300s --max-time
# backstop. Pre-fix this is ~30s (outer timeout); post-fix ~3-5s.
[[ "${elapsed}" -lt 25 ]] || {
  echo "FAIL: abort took ${elapsed}s (>25s); --speed-time not firing"
  exit 1
}

echo "OK: aborted in ${elapsed}s with exit ${rc} (inactivity detection fired)"
