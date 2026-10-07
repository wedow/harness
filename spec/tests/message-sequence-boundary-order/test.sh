#!/usr/bin/env bash
# Sequence 10000 must follow 9999 in model context and the web transcript.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSION="${HARNESS_SESSIONS}/boundary"
mkdir -p "${HARNESS_SESSION}/messages"
cat > "${HARNESS_SESSION}/messages/9999-user.md" <<'MSG'
---
role: user
seq: 9999
---
older message
MSG
cat > "${HARNESS_SESSION}/messages/10000-user.md" <<'MSG'
---
role: user
seq: 10000
---
newer message
MSG

failed=0
for provider in openai anthropic chatgpt; do
  result="$(printf '{}\n' | "${HARNESS_ROOT}/plugins/${provider}/hooks.d/assemble/10-messages")"
  if [[ "${provider}" == anthropic ]]; then
    first="$(printf '%s\n' "${result}" | jq -r '.messages[0].content[0].text')"
    second="$(printf '%s\n' "${result}" | jq -r '.messages[0].content[1].text')"
  else
    first="$(printf '%s\n' "${result}" | jq -r '.messages[0] | tostring')"
    second="$(printf '%s\n' "${result}" | jq -r '.messages[1] | tostring')"
  fi
  if [[ "${first}" != *'older message'* || "${second}" != *'newer message'* ]]; then
    echo "FAIL: ${provider} assembled 10000 before 9999"
    failed=1
  fi
done

source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"
html="$(_transcript boundary)"
if [[ "${html}" != *'older message'*'newer message'* ]]; then
  echo 'FAIL: web transcript rendered 10000 before 9999'
  failed=1
fi

exit "${failed}"
