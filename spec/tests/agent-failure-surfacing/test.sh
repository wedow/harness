#!/usr/bin/env bash
# Test: agent tool surfaces child failures instead of swallowing them.
# BUG-1 fix: child non-zero exit / no output must be marked errors and
# propagate non-zero so tool_exec flags error:true.
#
# - Inline branch: child non-zero exit -> "subagent failed (exit N): <stderr>", non-zero rc
# - Inline branch: child empty output -> marked failure, non-zero rc
# - Schema branch: hard child failure (non-zero exit) -> surface, do NOT retry
# - Schema branch: schema mismatch (valid output, fails validation) -> still retries (regression)
#
# Hermetic: stub bin/harness via an injected HARNESS_ROOT so no model is called.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

agent_tool="${HARNESS_ROOT}/plugins/subagents/tools/agent"
unset TMUX 2>/dev/null || true
export HARNESS_CWD="${_tmpdir}/work"; mkdir -p "${HARNESS_CWD}"

# ---------- Phase 1: inline branch — child exits non-zero with stderr ----------
fake1="${_tmpdir}/fake1"; mkdir -p "${fake1}/bin"
cat > "${fake1}/bin/harness" <<'STUB'
#!/usr/bin/env bash
echo "model not supported" >&2
exit 2
STUB
chmod +x "${fake1}/bin/harness"

rc=0
out="$(echo '{"prompt":"do x"}' | HARNESS_ROOT="${fake1}" "${agent_tool}" --exec 2>&1)" || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: inline non-zero exit should propagate"; exit 1; }
[[ "${out}" == *"subagent failed (exit 2)"* ]] || { echo "FAIL: expected marked failure, got: ${out}"; exit 1; }
[[ "${out}" == *"model not supported"* ]] || { echo "FAIL: expected stderr surfaced, got: ${out}"; exit 1; }

# ---------- Phase 2: inline branch — child produces no output (silent failure) ----------
fake2="${_tmpdir}/fake2"; mkdir -p "${fake2}/bin"
: > "${fake2}/bin/harness"
chmod +x "${fake2}/bin/harness"

rc=0
out="$(echo '{"prompt":"do x"}' | HARNESS_ROOT="${fake2}" "${agent_tool}" --exec 2>&1)" || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: silent no-output should propagate as failure"; exit 1; }
[[ "${out}" == *"subagent failed"* ]] || { echo "FAIL: expected marked failure, got: ${out}"; exit 1; }

# ---------- Phase 3: schema branch — hard child failure does NOT retry ----------
fake3="${_tmpdir}/fake3"; mkdir -p "${fake3}/bin"
export CALLS_FILE="${_tmpdir}/calls3"
cat > "${fake3}/bin/harness" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "${CALLS_FILE}" 2>/dev/null || echo 0) + 1 )); echo "$n" > "${CALLS_FILE}"
echo "fatal: api key invalid" >&2
exit 1
STUB
chmod +x "${fake3}/bin/harness"

rc=0
out="$(echo '{"prompt":"do x","schema":{"type":"object","required":["foo"]}}' \
  | HARNESS_ROOT="${fake3}" "${agent_tool}" --exec 2>&1)" || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: schema hard-failure should propagate"; exit 1; }
[[ "${out}" == *"subagent failed (exit 1)"* ]] || { echo "FAIL: expected marked failure, got: ${out}"; exit 1; }
[[ "${out}" == *"api key invalid"* ]] || { echo "FAIL: expected stderr surfaced, got: ${out}"; exit 1; }
# Should NOT have retried — only one call total
assert_eq "schema hard-fail no retry" "$(cat "${CALLS_FILE}")" "1"

# ---------- Phase 4: schema branch — schema mismatch still retries (regression) ----------
fake4="${_tmpdir}/fake4"; mkdir -p "${fake4}/bin"
export CALLS_FILE="${_tmpdir}/calls4"
cat > "${fake4}/bin/harness" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "${CALLS_FILE}" 2>/dev/null || echo 0) + 1 )); echo "$n" > "${CALLS_FILE}"
if (( n == 1 )); then
  printf '{"foo":1}\n'    # missing required "bar"
else
  printf '{"foo":1,"bar":2}\n'
fi
STUB
chmod +x "${fake4}/bin/harness"

out="$(echo '{"prompt":"do x","schema":{"type":"object","required":["foo","bar"]}}' \
  | HARNESS_ROOT="${fake4}" "${agent_tool}" --exec 2>&1)" || true
[[ "${out}" == '{"foo":1,"bar":2}' ]] || { echo "FAIL: schema retry should reach valid output, got: ${out}"; exit 1; }
assert_eq "schema retry happened (2 calls)" "$(cat "${CALLS_FILE}")" "2"

echo "PASS"
