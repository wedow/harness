#!/usr/bin/env bash
# Test: agent tool wraps child invocations in a wall-clock timeout (BUG-2 fix).
# A hung child is killed via `timeout` and a marked timeout error is surfaced
# with non-zero exit. Default 600s is overridable via HARNESS_AGENT_TIMEOUT.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

agent_tool="${HARNESS_ROOT}/plugins/subagents/tools/agent"
unset TMUX 2>/dev/null || true
export HARNESS_CWD="${_tmpdir}/work"; mkdir -p "${HARNESS_CWD}"

# Fake harness that hangs forever (would block parent indefinitely without timeout)
fake="${_tmpdir}/fake"; mkdir -p "${fake}/bin"
cat > "${fake}/bin/harness" <<'STUB'
#!/usr/bin/env bash
sleep 60
STUB
chmod +x "${fake}/bin/harness"

# Override the generous default (600s) so the test runs fast
export HARNESS_AGENT_TIMEOUT=1

start=$SECONDS
rc=0
out="$(echo '{"prompt":"hang"}' | HARNESS_ROOT="${fake}" "${agent_tool}" --exec 2>&1)" || rc=$?
elapsed=$(( SECONDS - start ))

# Should bail out within ~5s of the 1s timeout
[[ "${elapsed}" -lt 5 ]] || { echo "FAIL: timeout took too long: ${elapsed}s"; exit 1; }
[[ "${rc}" -ne 0 ]] || { echo "FAIL: timeout should produce non-zero exit"; exit 1; }
[[ "${out}" == *"timed out"* ]] || { echo "FAIL: expected 'timed out' marker, got: ${out}"; exit 1; }

echo "PASS"
