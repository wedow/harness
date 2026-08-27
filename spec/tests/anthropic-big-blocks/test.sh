#!/usr/bin/env bash
# Test: provider survives responses whose single blocks exceed MAX_ARG_STRLEN
# (~128KiB). GLM with a 131072-token output budget emits ~500KB thinking/text
# blocks; every jq --arg/--argjson on such a value failed execve with E2BIG
# ("Argument list too long"), killing the stream mid-response. All potentially
# large strings shuttle through temp files (--rawfile). The final assembled
# content ARRAY must still be an array — an earlier fix attempt reused a
# per-block temp file for the whole response content, corrupting every reply
# and taking down every live session (found the hard way).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

provider="${HARNESS_ROOT}/plugins/anthropic/providers/anthropic"
T="${_tmpdir}"

cat > "${T}/srv.py" <<'PY'
import os, socket, sys, json as _j
mode = os.environ["MODE"]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0)); s.listen(4)
sys.stdout.write(f'{s.getsockname()[1]}\n'); sys.stdout.flush()

def sse(events):
    body = ''.join(f'event: x\ndata: {e}\n\n' for e in events)
    return (b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: '
            + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body.encode())

E = lambda o: _j.dumps(o)
MSG_START = E({"type":"message_start","message":{}})
TXT_START = E({"type":"content_block_start","content_block":{"type":"text"}})
TXT_D     = lambda t: E({"type":"content_block_delta","delta":{"type":"text_delta","text":t}})
THK_START = E({"type":"content_block_start","content_block":{"type":"thinking"}})
THK_D     = lambda t: E({"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":t}})
TOOL_START= E({"type":"content_block_start","content_block":{"type":"tool_use","id":"c1","name":"bash"}})
TOOL_D    = lambda j: E({"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":j}})
STOP      = E({"type":"content_block_stop"})
MSG_DELTA = E({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}})
MSG_STOP  = E({"type":"message_stop"})

while True:
    conn, _ = s.accept(); conn.recv(65536)
    if mode == 'small':
        body = sse([MSG_START, TXT_START, TXT_D('hello world'), STOP, MSG_DELTA, MSG_STOP])
    elif mode == 'tool':
        body = sse([MSG_START, THK_START, THK_D('thinking hard'), STOP,
                    TOOL_START, TOOL_D('{"command":"echo hi"}'), STOP, MSG_STOP])
    else:  # big — single block far past MAX_ARG_STRLEN
        body = sse([MSG_START, TXT_START, TXT_D('x' * 300000), STOP, MSG_DELTA, MSG_STOP])
    conn.sendall(body); conn.close()
PY

run_mode() { # $1 = mode -> provider stdout, rc
  local mode="$1" port
  MODE="${mode}" python3 "${T}/srv.py" > "${T}.port" &
  local pid=$!
  for _ in $(seq 1 50); do [[ -s "${T}.port" ]] && break; sleep 0.1; done
  port="$(cat "${T}.port")"
  set +e
  out="$(echo '{"model":"m","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}' \
    | ANTHROPIC_API_URL="http://127.0.0.1:${port}/v1/messages" \
      ANTHROPIC_API_KEY=k ANTHROPIC_MAX_TOKENS=64 \
      "${provider}" --stream 2>"${T}.err")"
  local rc=$?
  set -e
  kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
  RESULT="${out}"; return "${rc}"
}

# 1. small: content is an ARRAY with text intact (guards the bad-fix failure
#    mode where the whole content became a bare string)
run_mode small
echo "${RESULT}" | jq -e '(.content|type)=="array" and .content[0].text=="hello world" and .stop_reason=="end_turn"' >/dev/null \
  || { echo "FAIL small: ${RESULT}"; exit 1; }

# 2. thinking + tool_use blocks intact, tool input parsed as object
run_mode tool
echo "${RESULT}" | jq -e '(.content|length)==2 and .content[0].thinking=="thinking hard" and .content[1].input.command=="echo hi"' >/dev/null \
  || { echo "FAIL tool: ${RESULT}"; exit 1; }

# 3. big: single 300KB block survives (pre-fix: jq --arg E2BIG kills stream)
run_mode big
echo "${RESULT}" | jq -e '(.content[0].text|length)==300000' >/dev/null \
  || { echo "FAIL big: $(echo "${RESULT}" | head -c 200) err: $(cat "${T}.err" | head -c 200)"; exit 1; }

echo "PASS"