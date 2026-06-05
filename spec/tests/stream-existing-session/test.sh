#!/usr/bin/env bash
# Test: harness stream can run against an existing session id and preserves its message.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}/hooks.d/resolve" "${HARNESS_HOME}/hooks.d/assemble" "${HARNESS_HOME}/hooks.d/send" "${HARNESS_HOME}/hooks.d/receive"
cat > "${HARNESS_HOME}/hooks.d/resolve/10-mock" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
jq -n '{provider:"mock", model:"mock"}'
HOOK
cat > "${HARNESS_HOME}/hooks.d/assemble/10-empty" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
jq -n '{request:{}}'
HOOK
cat > "${HARNESS_HOME}/hooks.d/send/10-send" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
jq -n '{content:[{type:"text", text:"streamed answer"}], model:"mock", stop_reason:"end_turn", usage:{input_tokens:0, output_tokens:0}, next_state:"receive"}'
HOOK
cat > "${HARNESS_HOME}/hooks.d/receive/10-text" <<'HOOK'
#!/usr/bin/env bash
response="$(cat)"
msg_dir="${HARNESS_SESSION}/messages"
mkdir -p "${msg_dir}"
last="$(ls -1 "${msg_dir}/" 2>/dev/null | sort -n | tail -1)"
if [[ -z "${last}" ]]; then seq="0001"; else seq="$(printf '%04d' $(( 10#${last%%-*} + 1 )))"; fi
text="$(echo "${response}" | jq -r '.content[0].text')"
cat > "${msg_dir}/${seq}-assistant.md" <<EOF
---
role: assistant
seq: ${seq}
---
${text}
EOF
printf '%s\n' "$(jq -cn --arg text "${text}" '{type:"text", text:$text}')" >> "${HARNESS_SESSION}/.stream"
printf '%s' "${text}" | jq -Rs '{next_state:"done", output:.}'
HOOK
chmod +x "${HARNESS_HOME}"/hooks.d/*/*

export HARNESS_SESSIONS="${_tmpdir}/sessions"
session_id="existing-session"
session_dir="${HARNESS_SESSIONS}/${session_id}"
mkdir -p "${session_dir}/messages"

output="$("${HARNESS_ROOT}/bin/harness" stream "${session_id}" "hello stream")"

assert_file_contains "${session_dir}/messages/0001-user.md" "hello stream"
assert_file_contains "${session_dir}/messages/0002-assistant.md" "streamed answer"
if [[ "${output}" != *"session: ${session_id}"* || "${output}" != *"streamed answer"* ]]; then
  echo "FAIL: stream output did not include session id and streamed answer"
  printf '%s\n' "${output}"
  exit 1
fi

echo "PASS"