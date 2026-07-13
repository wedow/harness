#!/usr/bin/env bash
# Test: agent tool `schema` field. When set, the subagent is instructed to emit
# a JSON object matching the schema; the tool extracts it (stripping any code
# fence), validates that required keys are present, retries on mismatch, and
# returns compact validated JSON. Absent `schema`, output is unchanged prose.
#
# Hermetic: stub bin/harness via an injected HARNESS_ROOT so no model is called.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

agent_tool="${HARNESS_ROOT}/plugins/subagents/tools/agent"
unset TMUX 2>/dev/null || true
export HARNESS_CWD="${_tmpdir}/work"; mkdir -p "${HARNESS_CWD}"

# ---------- Phase A: invalid-then-valid, fenced, with leading prose ----------
fakeA="${_tmpdir}/fakeA"; mkdir -p "${fakeA}/bin"
export CALLS_FILE="${_tmpdir}/callsA" PROMPTS_LOG="${_tmpdir}/promptsA" SUBCMD_FILE="${_tmpdir}/subcmdA"
cat > "${fakeA}/bin/harness" <<'STUB'
#!/usr/bin/env bash
echo "$1" > "${SUBCMD_FILE}"     # the dispatched subcommand ($2 is the prompt)
prompt="$2"
n=$(( $(cat "${CALLS_FILE}" 2>/dev/null || echo 0) + 1 )); echo "$n" > "${CALLS_FILE}"
printf '%s\n====\n' "$prompt" >> "${PROMPTS_LOG}"
if (( n == 1 )); then
  printf '```json\n{"foo":1}\n```\n'                 # missing required key "bar"
else
  printf 'sure, here you go:\n```json\n{"foo":1,"bar":2}\n```\n'
fi
STUB
chmod +x "${fakeA}/bin/harness"

out="$(echo '{"prompt":"do x","schema":{"type":"object","required":["foo","bar"]}}' \
  | HARNESS_ROOT="${fakeA}" "${agent_tool}" --exec)"

assert_eq "validated compact json" "${out}" '{"foo":1,"bar":2}'
assert_eq "retried once (2 calls)" "$(cat "${CALLS_FILE}")" "2"
assert_file_contains "${PROMPTS_LOG}" "JSON Schema"               # instruction injected
assert_file_contains "${PROMPTS_LOG}" "previous reply was invalid" # retry feedback fed back
assert_eq "schema branch dispatches the agent subcommand (not 'run')" "$(cat "${SUBCMD_FILE}")" "agent"

# ---------- Phase B: valid on first try -> no needless retry ----------
fakeB="${_tmpdir}/fakeB"; mkdir -p "${fakeB}/bin"
export CALLS_FILE="${_tmpdir}/callsB" PROMPTS_LOG="${_tmpdir}/promptsB"
cat > "${fakeB}/bin/harness" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "${CALLS_FILE}" 2>/dev/null || echo 0) + 1 )); echo "$n" > "${CALLS_FILE}"
printf '{"ok":true}\n'                               # raw JSON, no fence
STUB
chmod +x "${fakeB}/bin/harness"
out="$(echo '{"prompt":"q","schema":{"type":"object","required":["ok"]}}' \
  | HARNESS_ROOT="${fakeB}" "${agent_tool}" --exec)"
assert_eq "valid first try compact" "${out}" '{"ok":true}'
assert_eq "no needless retry (1 call)" "$(cat "${CALLS_FILE}")" "1"

# ---------- Phase C: no schema -> unchanged prose passthrough ----------
fakeC="${_tmpdir}/fakeC"; mkdir -p "${fakeC}/bin"
export SUBCMD_FILE="${_tmpdir}/subcmdC"
cat > "${fakeC}/bin/harness" <<'STUB'
#!/usr/bin/env bash
echo "$1" > "${SUBCMD_FILE}"
printf 'a plain free-form answer\n'
STUB
chmod +x "${fakeC}/bin/harness"
out="$(echo '{"prompt":"hello"}' | HARNESS_ROOT="${fakeC}" "${agent_tool}" --exec)"
assert_eq "no-schema passthrough" "${out}" 'a plain free-form answer'
assert_eq "inline branch dispatches the agent subcommand (not 'run')" "$(cat "${SUBCMD_FILE}")" "agent"

# ---------- Phase D: OpenAI structured-output json_schema envelope is accepted ----------
fakeD="${_tmpdir}/fakeD"; mkdir -p "${fakeD}/bin"
export CALLS_FILE="${_tmpdir}/callsD"
cat > "${fakeD}/bin/harness" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "${CALLS_FILE}" 2>/dev/null || echo 0) + 1 )); echo "$n" > "${CALLS_FILE}"
if (( n == 1 )); then
  printf '{"title":"Only title"}\n'
else
  printf '{"title":"Only title","authors":["Ada"]}\n'
fi
STUB
chmod +x "${fakeD}/bin/harness"
out="$(cat <<'JSON' | HARNESS_ROOT="${fakeD}" "${agent_tool}" --exec
{"prompt":"extract","schema":{"type":"json_schema","name":"paper","schema":{"type":"object","properties":{"title":{"type":"string"},"authors":{"type":"array","items":{"type":"string"}}},"required":["title","authors"],"additionalProperties":false},"strict":true}}
JSON
)"
assert_eq "json_schema envelope validates nested schema" "${out}" '{"title":"Only title","authors":["Ada"]}'
assert_eq "json_schema envelope retry happened" "$(cat "${CALLS_FILE}")" "2"

# ---------- schema field advertised in --schema ----------
assert_json '.input_schema.properties.schema.type' "$("${agent_tool}" --schema)" "object"

echo "PASS"
