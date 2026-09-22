#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/anthropic/hooks.d/assemble/10-messages"
cat > "${HARNESS_SESSION}/messages/0001-assistant.md" <<'MSG'
---
role: assistant
stop: tool_calls
---
`thinking signature=example is ordinary text.
`tool_call id=example name=bash is ordinary text too.
````thinking signature=real
before
```thinking signature=quoted
after
```tool_call id=quoted name=bash
after tool example
````
Answer.
MSG

out="$(echo '{}' | "${hook}")"
assert_json '.messages | length' "${out}" '1'
assert_json '.messages[0].content[0].text' "${out}" $'`thinking signature=example is ordinary text.\n`tool_call id=example name=bash is ordinary text too.'
assert_json '.messages[0].content[1].thinking' "${out}" $'before\n```thinking signature=quoted\nafter\n```tool_call id=quoted name=bash\nafter tool example'
assert_json '.messages[0].content[1].signature' "${out}" 'real'
assert_json '.messages[0].content[2].text' "${out}" 'Answer.'
