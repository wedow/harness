#!/usr/bin/env bash
# dispatch-sse-replay — end-to-end exercise of the send/dispatch path with
# the REAL anthropic provider against a replayed SSE stream (a local HTTP
# server): two tool calls including ~8KB args (fifo writes past PIPE_BUF)
# must dispatch, validate, publish atomically, and parse. Regression harness
# for the stream-corruption guards.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

ROOT="${HARNESS_ROOT}"
SB="${_tmpdir}"
mkdir -p "${HARNESS_SESSION}/messages" "${SB}/tools"
export HARNESS_SESSIONS="${SB}"
export HARNESS_SOURCES="${SB}:${ROOT}/plugins/core:${ROOT}/plugins/anthropic"
export HARNESS_PROVIDER=anthropic
export ANTHROPIC_API_KEY=test-key
export HARNESS_LOG="${SB}/log"
: > "${HARNESS_LOG}"
echo "cwd=${SB}" > "${HARNESS_SESSION}/session.conf"

cat > "${SB}/tools/size_tool" <<'T'
#!/usr/bin/env bash
case "${1:-}" in
  --exec) in="$(cat)"; echo "size_tool ok: $(printf '%s' "$in" | wc -c) bytes";;
  --schema) echo '{"name":"size_tool"}';;
  --describe) echo size tool;;
esac
T
chmod +x "${SB}/tools/size_tool"

# free port, then replay server with a two-tool-call turn (one ~8KB args)
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export ANTHROPIC_API_URL="http://127.0.0.1:${PORT}/v1/messages"
python3 - > "${SB}/server.out" 2>&1 <<'SRV' &
import sys, json, socket, http.server
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
# NB: server binds its own port printed to stdout; parent uses PORT env instead
SRV
# (server below binds PORT directly)
python3 - "${PORT}" > "${SB}/server.out" 2>&1 <<'SRV' &
import sys, json, http.server
port = int(sys.argv[1])
big = "x" * 8000
args1 = '{"command":"echo small","intent":"probe"}'
args2 = '{"payload":"' + big + '","intent":"big fifo write"}'
def ev(name, data):
    return f"event: {name}\ndata: {data}\n\n".encode()
body = b""
body += ev("message_start", '{"type":"message_start","message":{}}')
body += ev("content_block_start", '{"type":"content_block_start","index":0,"content_block":{"type":"text"}}')
body += ev("content_block_delta", '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Working."}}')
body += ev("content_block_stop", '{"type":"content_block_stop","index":0}')
for idx, cid, name, args in ((1,"call_small","bash",args1),(2,"call_big","size_tool",args2)):
    body += ev("content_block_start", json.dumps({"type":"content_block_start","index":idx,"content_block":{"type":"tool_use","id":cid,"name":name}}))
    for i in range(0, len(args), 64):
        body += ev("content_block_delta", json.dumps({"type":"content_block_delta","index":idx,"delta":{"type":"input_json_delta","partial_json":args[i:i+64]}}))
    body += ev("content_block_stop", json.dumps({"type":"content_block_stop","index":idx}))
body += ev("message_delta", '{"type":"message_delta","delta":{"stop_reason":"tool_use"}}')
body += ev("message_stop", '{"type":"message_stop"}')
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
SRV
SRVPID=$!
sleep 0.5

cleanup() { kill "${SRVPID}" 2>/dev/null || true; }
trap cleanup EXIT

out="$(echo '{"model":"m","messages":[{"role":"user","content":"go"}]}' \
  | timeout 30 "${ROOT}/plugins/core/hooks.d/send/10-send" 2>>"${SB}/log")" \
  || { echo "FAIL: send hook failed"; cat "${SB}/log"; exit 1; }

echo "${out}" | jq -e '.stop_reason == "tool_use" and .next_state == "receive"' >/dev/null \
  || { echo "FAIL: bad response: ${out:0:200}"; exit 1; }

# both dispatch artifacts present, parse, and carry correct results
for cid in call_small call_big; do
  f="${HARNESS_SESSION}/.tool_dispatch/${cid}.json"
  [[ -f "$f" ]] || { echo "FAIL: missing ${cid}"; ls "${HARNESS_SESSION}/.tool_dispatch"; exit 1; }
  jq -e 'has("result") and (.error | type == "boolean")' "$f" >/dev/null \
    || { echo "FAIL: ${cid} artifact unparseable"; cat "$f"; exit 1; }
done
grep -q 'size_tool ok: 8040 bytes' "${HARNESS_SESSION}/.tool_dispatch/call_big.json" \
  || { echo "FAIL: big fifo args corrupted"; cat "${HARNESS_SESSION}/.tool_dispatch/call_big.json"; exit 1; }

# atomic publish leaves no temp files behind
if ls "${HARNESS_SESSION}/.tool_dispatch"/*.tmp >/dev/null 2>&1; then
  echo "FAIL: temp dispatch artifacts left behind"; exit 1
fi