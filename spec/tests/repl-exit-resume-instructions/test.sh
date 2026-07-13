#!/usr/bin/env bash
# Test: REPL prints resume instructions on shutdown.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
export HARNESS_ROOT="$(cd "${HARNESS_ROOT}" && pwd)"

export HARNESS_HOME="${_tmpdir}/home"
export HARNESS_SESSIONS="${HARNESS_HOME}/sessions"
mkdir -p "${HARNESS_SESSIONS}"

mock_src="${_tmpdir}/mock_src"
mkdir -p "${mock_src}/providers"
cat > "${mock_src}/providers/mock" <<'PROV'
#!/usr/bin/env bash
case "${1:-}" in
  --describe) echo "mock provider"; exit 0 ;;
  --ready) exit 0 ;;
  --defaults) echo "model=mock"; exit 0 ;;
esac
jq -n '{content:[{type:"text", text:"unused"}], model:"mock", stop_reason:"end_turn", usage:{input_tokens:0, output_tokens:0}}'
PROV
chmod +x "${mock_src}/providers/mock"
export HARNESS_SOURCES="${mock_src}"
export HARNESS_PROVIDER="mock"
export HARNESS_MODEL="mock"

session_id="20260712-212354-581532"
mkdir -p "${HARNESS_SESSIONS}/${session_id}"
printf 'cwd=%s\n' "${PWD}" > "${HARNESS_SESSIONS}/${session_id}/session.conf"
mkdir -p "${HARNESS_SESSIONS}/${session_id}/messages"
cat > "${HARNESS_SESSIONS}/${session_id}/messages/0001-assistant.md" <<'MSG'
---
role: assistant
tokens_in: 100
tokens_out: 25
tokens_total: 125
tokens_cache_read: 80
tokens_cache_write: 10
---
first
MSG
cat > "${HARNESS_SESSIONS}/${session_id}/messages/0002-assistant.md" <<'MSG'
---
role: assistant
tokens_in: 50
tokens_out: 5
tokens_total: 55
tokens_cache_read: 40
tokens_cache_write: 0
---
second
MSG

repl="${HARNESS_ROOT}/plugins/core/commands/repl"
output="$(printf '/quit\n' | bash "${repl}" "${session_id}" 2>&1)"

if [[ "${output}" != *"Token usage: total=180 input=150 (+ 120 cached, + 10 written) output=30"* ]]; then
  echo "FAIL: repl did not print token usage stats on shutdown"
  echo "${output}"
  exit 1
fi

if [[ "${output}" != *"Token usage: total=180 input=150 (+ 120 cached, + 10 written) output=30"$'\n'"To continue this session, run harness resume ${session_id}"* ]]; then
  echo "FAIL: token usage stats were not printed before resume instructions"
  echo "${output}"
  exit 1
fi

if [[ "${output}" != *"To continue this session, run harness resume ${session_id}"* ]]; then
  echo "FAIL: repl did not print resume instructions on shutdown"
  echo "${output}"
  exit 1
fi

count="$(grep -c "To continue this session" <<<"${output}")"
assert_eq "resume instruction count" "${count}" "1"

echo "PASS"
