#!/usr/bin/env bash
# Test: the model-turn budget counts SENDS (model responses), not raw state
# transitions, and breaking on it is a loud failure.
#
# Pre-fix: iterations counted every state hop (x3 cap). A tool turn costs ~5
# states, so HARNESS_MAX_TURNS=100 actually allowed ~60 model turns — long
# implementer subagents died mid-work at the cap, and the break returned 0,
# so the agent tool extracted a mid-turn assistant message and passed it off
# as the subagent's final output (silent truncated transcript).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}"

# Minimal cycling hooks: assemble -> send -> receive -> assemble ...
mkdir -p "${HARNESS_HOME}/hooks.d/start"
cat > "${HARNESS_HOME}/hooks.d/start/10-cycle" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
echo '{"next_state":"assemble"}'
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/start/10-cycle"

for stage in assemble receive; do
  mkdir -p "${HARNESS_HOME}/hooks.d/${stage}"
  next="send"; [[ "${stage}" == "receive" ]] && next="assemble"
  cat > "${HARNESS_HOME}/hooks.d/${stage}/10-cycle" <<HOOK
#!/usr/bin/env bash
cat >/dev/null
echo '{"next_state":"${next}"}'
HOOK
  chmod +x "${HARNESS_HOME}/hooks.d/${stage}/10-cycle"
done
mkdir -p "${HARNESS_HOME}/hooks.d/send"
cat > "${HARNESS_HOME}/hooks.d/send/10-cycle" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
echo '{"next_state":"receive"}'
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/send/10-cycle"

# Only our hooks: filter the source list down to HARNESS_HOME.
mkdir -p "${HARNESS_HOME}/hooks.d/sources"
cat > "${HARNESS_HOME}/hooks.d/sources/30-walk-dirs" <<HOOK  # override by basename
#!/usr/bin/env bash
jq -n --arg h "${HARNESS_HOME}" '{sources: [\$h]}'
HOOK
chmod +x "${HARNESS_HOME}/hooks.d/sources/30-walk-dirs"

session_dir="${HARNESS_SESSION}"
touch "${session_dir}/.stream"

# 1. Budget counts sends: with MAX_TURNS=2 the loop survives far more than
#    2*3 state hops and dies only after 4 sends (x2 slack), non-zero rc.
export HARNESS_MAX_TURNS=2
rc=0
bash -c "
  source '${HARNESS_ROOT}/bin/harness'
  _refresh_sources
  agent_loop '${session_dir}'
" >/dev/null 2>&1 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: agent_loop should fail loudly on turn cap"; exit 1; }

# 2. The cap break leaves a stream error event with the cause.
grep -q '"type":"error"' "${session_dir}/.stream" || { echo "FAIL: no error event in stream"; exit 1; }
grep -q 'max model turns' "${session_dir}/.stream" || { echo "FAIL: error event lacks cause"; exit 1; }

echo "PASS"