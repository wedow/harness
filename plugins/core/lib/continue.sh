#!/usr/bin/env bash
# continue.sh — stop:length continuation, shared by provider receive hooks.
#
# max_tokens is "not done, out of room", not a final answer: ending the turn
# there hands back a truncated message masquerading as output. _length_continue
# saves a synthetic nudge user message and emits the assemble routing; the
# continuation count is capped (HARNESS_LENGTH_CONTINUATIONS, default 2) and
# resets on fresh turns (tool_calls) and completion (end) — see the callers.

_length_continue() { # $1 = msg_dir, $2 = next padded seq
  local msg_dir="$1" nseq="$2" cap n
  cap="${HARNESS_LENGTH_CONTINUATIONS:-2}"
  n="$(cat "${HARNESS_SESSION}/.length_cont" 2>/dev/null || echo 0)"
  n=$(( n + 1 ))
  if (( n > cap )); then
    jq -n --arg m "output token limit hit ${n} times (continuation cap ${cap}); turn aborted" '{error: $m}'
    return 1
  fi
  echo "${n}" > "${HARNESS_SESSION}/.length_cont"
  cat > "${msg_dir}/${nseq}-user.md" <<NUDGE
---
role: user
seq: ${nseq}
timestamp: $(date -Iseconds)
continuation: length
---
[output token limit reached — response was cut off and saved]

Continue exactly where you left off. Do not repeat already-emitted content. If a tool call was cut off mid-way, re-issue it from its beginning.
NUDGE
  echo '{"next_state": "assemble"}'
}

_length_cont_reset() { # call on fresh turns / completion
  rm -f "${HARNESS_SESSION}/.length_cont" 2>/dev/null || true
}