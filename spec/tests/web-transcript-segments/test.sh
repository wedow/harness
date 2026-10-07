#!/usr/bin/env bash
# web-transcript-segments — assistant messages render as segments (thinking
# and tool_call blocks collapse; tool_call input gets YAML + intent labels),
# and every message shows its timestamp.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

sess="${HARNESS_SESSIONS}/s1"
mkdir -p "${sess}/messages"
cat > "${sess}/messages/0001-user.md" <<'EOF'
---
role: user
seq: 0001
timestamp: 2026-09-19T04:40:14+00:00
---
Break up the transcript rendering
EOF
cat > "${sess}/messages/0002-assistant.md" <<'EOF'
---
role: assistant
seq: 0002
timestamp: 2026-09-19T04:41:02+00:00
stop: tool_calls
---
```thinking
Pondering the renderer.
```

```tool_call id=call_1 name=bash
{"command":"sed -n 1p pages.sh","intent":"inspect renderer"}
```
EOF
cat > "${sess}/messages/0003-tool_result.md" <<'EOF'
---
role: tool_result
seq: 0003
timestamp: 2026-09-19T04:41:03+00:00
call_id: call_1
tool: bash
error: false
intent: inspect renderer
---
exit: 0
EOF

html="$(_transcript s1)"

has() { echo "${html}" | grep -qF "$1" || { echo "FAIL: missing '$1'"; return 1; } }

# timestamps visible on every message type
has 'user · 09-19 04:40:14'
has 'assistant · 09-19 04:41:02'
has 'inspect renderer · 09-19 04:41:03'
# thinking and tool_call collapse; call labeled name · intent; YAML body
has '<details class="seg think" id="m0002s1"><summary>thinking</summary>'
has '<details class="seg call" id="m0002s2"><summary>bash · inspect renderer</summary>'
# stable ids on collapsibles: morph pairing + open-state preservation
has 'id="m0002s1"'
has 'id="m0002s2"'
has 'id="m0003"'
has 'command: sed -n 1p pages.sh'
# tool_result collapse with error handling
has '<details class="msg tool_result" id="m0003"><summary>'
# escaped content stays escaped
echo "${html}" | grep -qF 'Pondering the renderer.'