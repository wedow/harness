#!/usr/bin/env bash
# Test: anthropic provider retries an empty streamed response (no content
# blocks, no stop_reason) once before failing loudly. Pre-fix, the empty
# message flowed through as a successful empty turn — the agent tool then
# reported "subagent completed with no output" (silent subagent death).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

provider="${HARNESS_ROOT}/plugins/anthropic/providers/anthropic"

# Fake SSE server on an ephemeral port. MODE=empty-then-good: first request
# streams an empty message, second a normal text turn. MODE=always-empty:
# every request streams an empty message. Request count in COUNT.
srv_script="$(mktemp)"
cat > "${srv_script}" <<'PY'
import os, socket, sys
mode = os.environ["MODE"]
count_path = os.environ["COUNT"]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0)); s.listen(4)
sys.stdout.write(f'{s.getsockname()[1]}\n'); sys.stdout.flush()

EMPTY = (b'event: message_start\ndata: {"type":"message_start","message":{}}\n\n'
         b'event: message_stop\ndata: {"type":"message_stop"}\n\n')
GOOD = (b'event: message_start\ndata: {"type":"message_start","message":{}}\n\n'
        b'event: content_block_start\ndata: {"type":"content_block_start","content_block":{"type":"text"}}\n\n'
        b'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"recovered"}}\n\n'
        b'event: content_block_stop\ndata: {"type":"content_block_stop"}\n\n'
        b'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
        b'event: message_stop\ndata: {"type":"message_stop"}\n\n')

while True:
    conn, _ = s.accept()
    conn.recv(65536)
    try:
        n = int(open(count_path).read() or 0) + 1
    except FileNotFoundError:
        n = 1
    open(count_path, 'w').write(str(n))
    body = GOOD if (mode == 'empty-then-good' and n > 1) or mode == 'always-good' else EMPTY
    conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n'
                 b'Content-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body)
    conn.close()
PY

port_file="$(mktemp)"
count_file="${_tmpdir}/count"
MODE="empty-then-good" COUNT="${count_file}" python3 "${srv_script}" >"${port_file}" &
server_pid=$!
trap 'kill ${server_pid} 2>/dev/null || true; wait ${server_pid} 2>/dev/null || true; rm -f "${srv_script}" "${port_file}"; teardown' EXIT
for _ in $(seq 1 100); do [[ -s "${port_file}" ]] && break; sleep 0.1; done
port="$(cat "${port_file}")"

export ANTHROPIC_API_KEY="test-key"
export ANTHROPIC_MAX_TOKENS=64
url="http://127.0.0.1:${port}/v1/messages"
req='{"model":"m","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}'

# 1. Empty-then-good: one retry recovers the turn.
: > "${count_file}"
out="$(echo "${req}" | ANTHROPIC_API_URL="${url}" "${provider}" --stream 2>&1)" || {
  echo "FAIL: provider failed on empty-then-good: ${out}"; exit 1; }
assert_json '.content[0].text' "${out}" "recovered"
assert_json '.stop_reason' "${out}" "end_turn"
assert_eq "two attempts" "$(cat "${count_file}")" "2"

# 2. Always-empty: loud failure after exactly one retry.
kill "${server_pid}" 2>/dev/null || true; wait "${server_pid}" 2>/dev/null || true
: > "${count_file}"
MODE="always-empty" COUNT="${count_file}" python3 "${srv_script}" >"${port_file}" &
server_pid=$!
for _ in $(seq 1 100); do [[ -s "${port_file}" ]] && break; sleep 0.1; done
port="$(cat "${port_file}")"; url="http://127.0.0.1:${port}/v1/messages"

rc=0
out="$(echo "${req}" | ANTHROPIC_API_URL="${url}" "${provider}" --stream 2>&1)" || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: always-empty should exit non-zero: ${out}"; exit 1; }
[[ "${out}" == *"empty response"* ]] || { echo "FAIL: expected empty-response marker: ${out}"; exit 1; }
assert_eq "retried exactly once" "$(cat "${count_file}")" "2"

echo "PASS"