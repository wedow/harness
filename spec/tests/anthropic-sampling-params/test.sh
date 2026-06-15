#!/usr/bin/env bash
# anthropic provider includes optional sampling params (temperature/top_p/top_k)
# only when the corresponding env vars are set — these are populated by the send
# hook from variant .conf keys. When unset they must be absent so the real
# Anthropic API is never sent unexpected fields.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

provider="${HARNESS_ROOT}/plugins/anthropic/providers/anthropic"

mock_bin="${_tmpdir}/bin"
mkdir -p "${mock_bin}"
capture="${_tmpdir}/request.json"

cat > "${mock_bin}/curl" <<CURL
#!/usr/bin/env bash
set -euo pipefail
cat > "${capture}"
printf '%s' '{"model":"x","stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"ok"}]}'
CURL
chmod +x "${mock_bin}/curl"
export PATH="${mock_bin}:${PATH}"

export ANTHROPIC_API_KEY="test"
export ANTHROPIC_API_URL="http://mock/v1/messages"

payload='{"model":"m","system":"","messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}],"tools":[]}'

# With sampling params set (as the send hook exports them from a variant conf)
export ANTHROPIC_TEMPERATURE="0.6"
export ANTHROPIC_TOP_P="1"
export ANTHROPIC_TOP_K="40"
echo "${payload}" | "${provider}" >/dev/null
req="$(cat "${capture}")"
assert_json '.temperature' "${req}" "0.6"
assert_json '.top_p' "${req}" "1"
assert_json '.top_k' "${req}" "40"

# Without sampling params: fields must be absent
unset ANTHROPIC_TEMPERATURE ANTHROPIC_TOP_P ANTHROPIC_TOP_K
echo "${payload}" | "${provider}" >/dev/null
req="$(cat "${capture}")"
assert_json 'has("temperature")' "${req}" "false"
assert_json 'has("top_p")' "${req}" "false"
assert_json 'has("top_k")' "${req}" "false"
