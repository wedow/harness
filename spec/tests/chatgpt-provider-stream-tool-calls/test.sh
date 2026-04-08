#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

provider="${HARNESS_ROOT}/plugins/chatgpt/providers/chatgpt"
receive_hook="${HARNESS_ROOT}/plugins/chatgpt/hooks.d/receive/10-save"

export HARNESS_PROVIDER="chatgpt"
export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}"

cat > "${HARNESS_HOME}/.auth-cache.json" <<'JSON'
{
  "chatgpt": [
    {
      "access_token": "test-access-token",
      "refresh_token": "test-refresh-token",
      "account_id": "test-account",
      "expires_at": "4102444800"
    }
  ]
}
JSON

mock_bin="${_tmpdir}/bin"
mkdir -p "${mock_bin}"

cat > "${mock_bin}/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null

printf '%s\n\n' \
  'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_123","name":"bash"}}' \
  'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"command\":\"pwd\"}"}' \
  'data: {"type":"response.completed","response":{"id":"resp_1","model":"gpt-5.4","status":"completed","usage":{"input_tokens":12,"output_tokens":3},"output":[]}}'
CURL
chmod +x "${mock_bin}/curl"

export PATH="${mock_bin}:${PATH}"

payload='{"model":"gpt-5.4","system":"","messages":[],"tools":[{"name":"bash","description":"Run a shell command","input_schema":{"type":"object"}}]}'

response="$(echo "${payload}" | "${provider}" --stream)"

assert_json '.output[0].type' "$response" "function_call"
assert_json '.output[0].call_id' "$response" "call_123"
assert_json '.output[0].name' "$response" "bash"
assert_json '.output[0].arguments' "$response" '{"command":"pwd"}'

assert_file_contains "${HARNESS_SESSION}/.stream" '{"type":"tool_start","id":"call_123","name":"bash","input":{"command":"pwd"}}'

out="$(echo "${response}" | "${receive_hook}")"

msg="$(ls -1 "${HARNESS_SESSION}/messages/"*-assistant.md)"
assert_file_exists "${msg}"
assert_file_contains "${msg}" "stop: tool_calls"

assert_json '.next_state' "$out" "tool_exec"
assert_json '.tool_calls[0].id' "$out" "call_123"
assert_json '.tool_calls[0].name' "$out" "bash"
assert_json '.tool_calls[0].input.command' "$out" "pwd"
