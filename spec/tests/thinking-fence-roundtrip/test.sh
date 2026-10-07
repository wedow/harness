#!/usr/bin/env bash
# thinking-fence-roundtrip — thinking containing bare ``` fences must not
# terminate its block: save emits a growing fence, assemble closes on the
# exact length, the transcript renderer does the same. Legacy 3-fence
# messages keep parsing.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

save_hook="${HARNESS_ROOT}/plugins/anthropic/hooks.d/receive/10-save"
asm_hook="${HARNESS_ROOT}/plugins/anthropic/hooks.d/assemble/10-messages"
export HARNESS_ROOT="${HARNESS_ROOT}"

# 1. save: thinking with embedded fences -> 4-backtick fence in the message
jq -c -n --arg t 'consider:

```
ls -la
```

done' '{model:"m",stop_reason:"end_turn",content:[{type:"thinking",thinking:$t,signature:"s1"},{type:"text",text:"Answer."}]}' \
  | "${save_hook}" >/dev/null
msg="${HARNESS_SESSION}/messages/0001-assistant.md"
assert_file_exists "${msg}"
grep -q '^````thinking signature=s1$' "${msg}" || { echo "FAIL: no 4-fence open"; cat "${msg}"; exit 1; }
grep -q '^````$' "${msg}" || { echo "FAIL: no 4-fence close"; exit 1; }

# 2. assemble round trip: thinking text intact, text block separate
out="$(echo '{}' | "${asm_hook}")"
assert_json '.messages[0].content[0].thinking' "$out" 'consider:

```
ls -la
```

done'
assert_json '.messages[0].content[1].text' "$out" 'Answer.'

# 3. renderer: think segment keeps the embedded fence; call/text segments separate
cat > "${HARNESS_SESSION}/messages/0002-assistant.md" <<'MSG'
---
role: assistant
seq: 0002
stop: tool_calls
---
````thinking signature=s2
think of

```
rm -rf
```
````
```tool_call id=t9 name=bash
{"command":"ls","intent":"probe"}
```
MSG
source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"
export HARNESS_SESSIONS="$(dirname "${HARNESS_SESSION}")"
html="$(_transcript "$(basename "${HARNESS_SESSION}")")"
echo "${html}" | grep -qF 'rm -rf' || { echo "FAIL: embedded fence content lost from think segment"; exit 1; }
echo "${html}" | grep -qF '<summary>bash · probe</summary>' \
  || { echo "FAIL: tool_call after growing-fence thinking mis-parsed"; exit 1; }
