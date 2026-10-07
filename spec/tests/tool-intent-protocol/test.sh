#!/usr/bin/env bash
# tool-intent-protocol — `intent` is a standard optional tool input key:
# declared by all core tool schemas, ignored during execution, persisted by
# tool_done as frontmatter on the tool_result message for UI consumers.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

# 1. All four core tools declare `intent` as an optional string input.
for tool in bash read_file edit_file write_file; do
  bin="${HARNESS_ROOT}/plugins/core/tools/${tool}"
  schema="$("${bin}" --schema)"
  assert_json '.input_schema.properties.intent.type' "$schema" "string"
  assert_eq "${tool}: intent not required" \
    "$(echo "$schema" | jq -r '.input_schema.required | index("intent") // "absent"')" \
    "absent"
done

# 2. Tools ignore it during execution.
out="$(echo '{"command":"echo hi","intent":"greet the user"}' \
  | "${HARNESS_ROOT}/plugins/core/tools/bash" --exec)"
assert_json '.stdout' "$out" "hi"

# 3. tool_done persists intent on the tool_result message.
hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_done/10-save"
echo '{"call_id":"c1","name":"bash","input":{"command":"echo hi","intent":"check specs"},"result":"done","error":false,"tool_calls":[]}' \
  | "$hook" >/dev/null
msg_file="${HARNESS_SESSION}/messages/0001-tool_result.md"
assert_file_exists "$msg_file"
grep -q '^intent: check specs$' "$msg_file" || {
  echo "FAIL: intent frontmatter missing from ${msg_file}"; cat "$msg_file"; exit 1
}

# 4. Messages without intent stay clean (no empty frontmatter line).
echo '{"call_id":"c2","name":"bash","input":{"command":"echo hi"},"result":"done","error":false,"tool_calls":[]}' \
  | "$hook" >/dev/null
if grep -q '^intent:' "${HARNESS_SESSION}/messages/0002-tool_result.md"; then
  echo "FAIL: empty intent line written"; cat "${HARNESS_SESSION}/messages/0002-tool_result.md"; exit 1
fi