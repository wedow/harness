#!/usr/bin/env bash
# tool-result-yaml — tool_done persists flat JSON results as readable YAML
# (block scalars for multi-line strings); other results are stored verbatim.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_done/10-save"

# 1. bash-style envelope: multi-line stdout renders as a block scalar.
envelope='{"exit":0,"elapsed_s":2.58,"timed_out":false,"stdout":"line one\nline two\n","stderr":""}'
input="$(jq -c -n --arg r "$envelope" '{call_id:"c1",name:"bash",input:{},result:$r,error:false,tool_calls:[]}')"
echo "${input}" | "$hook" >/dev/null

msg="${HARNESS_SESSION}/messages/0001-tool_result.md"
assert_file_exists "$msg"
assert_contains() { # LABEL FILE PATTERN
  grep -q "$3" "$2" || { echo "FAIL: $1 — pattern '$3' not in $2:"; cat "$2"; return 1; }
}
assert_contains "exit scalar"        "$msg" '^exit: 0$'
assert_contains "bool scalar"        "$msg" '^timed_out: false$'
assert_contains "stdout block start" "$msg" '^stdout: |$'
assert_contains "stdout line one"    "$msg" '^  line one$'
assert_contains "stdout line two"    "$msg" '^  line two$'

# 2. plain text result: stored verbatim.
input="$(jq -c -n --arg r "just text, not json" '{call_id:"c2",name:"bash",input:{},result:$r,error:false,tool_calls:[]}')"
echo "${input}" | "$hook" >/dev/null
msg2="${HARNESS_SESSION}/messages/0002-tool_result.md"
assert_contains "verbatim text" "$msg2" '^just text, not json$'

# 3. nested JSON result: stored verbatim (no partial reformatting).
input="$(jq -c -n --arg r '{"nested":{"a":1}}' '{call_id:"c3",name:"agent",input:{},result:$r,error:false,tool_calls:[]}')"
echo "${input}" | "$hook" >/dev/null
assert_contains "nested verbatim" "${HARNESS_SESSION}/messages/0003-tool_result.md" '^{"nested":{"a":1}}$'
# 4. pretty-printed (multi-line) JSON result renders too.
pretty="$(printf '%s' '{"exit":0,"stdout":"x\ny\n"}' | jq .)"
input="$(jq -c -n --arg r "$pretty" '{call_id:"c4",name:"bash",input:{},result:$r,error:false,tool_calls:[]}')"
echo "${input}" | "$hook" >/dev/null
msg4="${HARNESS_SESSION}/messages/0004-tool_result.md"
assert_contains "pretty stdout block" "$msg4" '^stdout: |$'
assert_contains "pretty stdout line" "$msg4" '^  x$'
