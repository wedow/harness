#!/usr/bin/env bash
# assemble-jsonl-perf — the JSONL-accumulation rewrite must produce identical
# output to the O(n^2) original on a mixed session (user/assistant/thinking/
# tool_calls/tool_results/errors), and stay under a time bound that the old
# quadratic append blows on large synthetic sessions.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sess="${HARNESS_SESSION##*/}"
mkdir -p "${HARNESS_SESSION}/messages"
m="${HARNESS_SESSION}/messages"

cat > "${m}/0001-user.md" <<'M'
---
role: user
seq: 0001
timestamp: 2026-09-22T15:00:00+00:00
---
List the files
M
cat > "${m}/0002-assistant.md" <<'M'
---
role: assistant
seq: 0002
timestamp: 2026-09-22T15:00:01+00:00
stop: tool_calls
---
````thinking signature=s1
consider

```
ls
```
````
```tool_call id=toolu_1 name=bash
{"command":"ls","intent":"list files"}
```
M
cat > "${m}/0003-tool_result.md" <<'M'
---
role: tool_result
seq: 0003
timestamp: 2026-09-22T15:00:02+00:00
call_id: toolu_1
tool: bash
error: true
intent: list files
---
error: boom
M
cat > "${m}/0004-user.md" <<'M'
---
role: user
seq: 0004
timestamp: 2026-09-22T15:00:03+00:00
---
steer: use the fast path
M
cat > "${m}/0005-assistant.md" <<'M'
---
role: assistant
seq: 0005
timestamp: 2026-09-22T15:00:04+00:00
stop: end
---
Done — text only.
M

hook="${HARNESS_ROOT}/plugins/anthropic/hooks.d/assemble/10-messages"
out="$(echo '{"model":"m"}' | "${hook}")"

# shape: messages array with merged consecutive users, thinking/tool_use/
# tool_result blocks, string content for the text-only assistant
assert_json '.messages | length' "${out}" "4"
assert_json '.messages[1].content[0].type' "${out}" "thinking"
assert_json '.messages[1].content[1].type' "${out}" "tool_use"
assert_json '.messages[1].content[1].input.command' "${out}" "ls"
assert_json '.messages[2].role' "${out}" "user"
assert_json '.messages[2].content[0].type' "${out}" "tool_result"
assert_json '.messages[2].content[0].is_error' "${out}" "true"
assert_json '.messages[2].content[1].type' "${out}" "text"
assert_json '.messages[2].content[1].text' "${out}" "steer: use the fast path"
assert_json '.messages[3].content' "${out}" "Done — text only."
assert_json '.model' "${out}" "m"

# perf guard: 150-message synthetic session must assemble in < 20s
# (the old quadratic append needs minutes at this size)
sess2="perfcheck"
d2="${HARNESS_SESSIONS}/${sess2}"
mkdir -p "${d2}/messages"
for i in $(seq -w 1 150); do
  printf -- '---\nrole: user\nseq: %s\ntimestamp: 2026-09-22T15:01:00+00:00\n---\nmessage body %s with some content to encode\n' "$i" "$i" \
    > "${d2}/messages/$i-user.md"
done
start=$SECONDS
echo '{}' | HARNESS_SESSION="${d2}" "${hook}" >/dev/null
elapsed=$(( SECONDS - start ))
(( elapsed < 20 )) || { echo "FAIL: assemble took ${elapsed}s for 150 messages"; exit 1; }
