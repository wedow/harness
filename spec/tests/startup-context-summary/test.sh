#!/usr/bin/env bash
# Test: startup reports the AGENTS.md and skills files that were loaded, while
# keeping the diagnostic metadata out of the next state sent to providers.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

project="${_tmpdir}/project"
bundle="${_tmpdir}/bundle"
home="${_tmpdir}/home"
mkdir -p "${project}/.harness/skills/local" \
  "${project}/.agents/skills/project" \
  "${bundle}/skills/bundled" \
  "${home}/.agents/skills/global" \
  "${home}/.agents/skills/override" \
  "${project}/work"

printf 'project instructions\n' > "${project}/AGENTS.md"
cat > "${bundle}/skills/bundled/SKILL.md" <<'SKILL'
---
name: bundled
description: bundled skill
---
SKILL
cat > "${home}/.agents/skills/global/SKILL.md" <<'SKILL'
---
name: global
description: global skill
---
SKILL
cat > "${home}/.agents/skills/override/SKILL.md" <<'SKILL'
---
name: override
description: global override
---
SKILL
cat > "${project}/.harness/skills/local/SKILL.md" <<'SKILL'
---
name: local
description: local skill
---
SKILL
cat > "${project}/.agents/skills/project/SKILL.md" <<'SKILL'
---
name: override
description: project override
---
SKILL

hook="${HARNESS_ROOT}/plugins/core/hooks.d/start/15-context-summary"
summary="$(printf '{}' | HARNESS_CWD="${project}/work" HOME="${home}" \
  HARNESS_SOURCES="${bundle}:${project}/.harness" "${hook}")"

assert_json '.startup_summary.agents | length' "${summary}" "1"
assert_json '.startup_summary.agents[0]' "${summary}" "${project}/AGENTS.md"
assert_json '.startup_summary.skills | length' "${summary}" "4"
assert_json '.startup_summary.skills[] | select(.name == "override") | .path' \
  "${summary}" "${project}/.agents/skills/project/SKILL.md"
assert_json '.startup_summary.skills[] | select(.name == "bundled") | .path' \
  "${summary}" "${bundle}/skills/bundled/SKILL.md"

# The user-facing diagnostic is written to stderr and includes both sections.
source "${HARNESS_ROOT}/bin/harness"
diagnostic="$(_print_startup_summary "${summary}" 2>&1)"
[[ "${diagnostic}" == *"Harness context:"* ]] || { echo "FAIL: missing context header"; exit 1; }
[[ "${diagnostic}" == *"${project}/AGENTS.md"* ]] || { echo "FAIL: missing AGENTS path"; exit 1; }
[[ "${diagnostic}" == *"bundled: ${bundle}/skills/bundled/SKILL.md"* ]] \
  || { echo "FAIL: missing skill path"; exit 1; }

# Verify agent_loop removes the summary before forwarding context to the next
# state, so discovery paths never reach a provider request.
loop_session="${_tmpdir}/loop-session"
mkdir -p "${loop_session}"
context_log="${_tmpdir}/next-context.json"
_refresh_sources() { :; }
call() {
  local stage="$1" payload
  payload="$(cat)"
  if [[ "${stage}" == "start" ]]; then
    printf '%s' "${summary}" | jq '. + {next_state: "done"}'
  else
    printf '%s' "${payload}" > "${context_log}"
    jq -n '{output: "ok"}'
  fi
}

agent_loop "${loop_session}" >/dev/null 2>"${_tmpdir}/loop.stderr"
if jq -e '.startup_summary' "${context_log}" >/dev/null 2>&1; then
  echo "FAIL: startup summary leaked into next state context"
  exit 1
fi

echo "PASS"
