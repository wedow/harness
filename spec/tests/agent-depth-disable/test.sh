#!/usr/bin/env bash
# Test: delegation depth hides the subagents plugin and hard-rejects direct use.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/subagents/hooks.d/sources/51-depth-gate"
subagents="$(cd "${HARNESS_ROOT}/plugins/subagents" && pwd)"
core="$(cd "${HARNESS_ROOT}/plugins/core" && pwd)"
payload() { jq -n --arg subagents "${subagents}" --arg core "${core}" '{sources:[$core,$subagents]}'; }
subagents_present() { echo "$1" | jq --arg s "${subagents}" '[.sources[]] | any(. == $s)'; }

assert_gate_invalid() {
  local name="$1" value="$2" out rc
  set +e
  out="$(payload | env "${name}=${value}" "${hook}" 2>&1)"
  rc=$?
  set -e
  [[ "${rc}" -ne 0 ]] || { echo "FAIL: ${name}=${value} did not fail closed"; exit 1; }
  [[ "${out}" == *"${name} must be a non-negative integer"* ]] \
    || { echo "FAIL: uncontrolled ${name}=${value} error: ${out}"; exit 1; }
}

for value in -1 nope; do
  assert_gate_invalid HARNESS_DEPTH "${value}"
  assert_gate_invalid RLM_MAX_DEPTH "${value}"
done

for depth in 0 1; do
  out="$(payload | HARNESS_DEPTH="${depth}" "${hook}")"
  [[ "$(subagents_present "${out}")" == "true" ]] \
    || { echo "FAIL: subagents removed at allowed depth ${depth}"; exit 1; }
done

out="$(payload | HARNESS_DEPTH=2 "${hook}")"
[[ "$(subagents_present "${out}")" == "false" ]] \
  || { echo "FAIL: subagents still present beyond maximum depth"; exit 1; }
echo "${out}" | jq -e --arg c "${core}" '[.sources[]] | any(. == $c)' >/dev/null \
  || { echo "FAIL: depth gate removed unrelated core source"; exit 1; }

agent="${HARNESS_ROOT}/plugins/subagents/tools/agent"
set +e
direct_out="$(printf '{"prompt":"must not run"}' | HARNESS_DEPTH=2 RLM_MAX_DEPTH=2 "${agent}" --exec 2>&1)"
direct_rc=$?
set -e
[[ "${direct_rc}" -ne 0 ]] || { echo "FAIL: direct agent execution succeeded beyond maximum depth"; exit 1; }
[[ "${direct_out}" == *"delegation depth 2 reached maximum 2"* ]] \
  || { echo "FAIL: unexpected depth error: ${direct_out}"; exit 1; }

fake_root="${_tmpdir}/fake-root"
mkdir -p "${fake_root}/bin"
cat > "${fake_root}/bin/harness" <<'FAKE'
#!/usr/bin/env bash
echo "fake child ran"
FAKE
chmod +x "${fake_root}/bin/harness"

assert_agent_invalid() {
  local name="$1" value="$2" out rc
  set +e
  out="$(printf '{"prompt":"must not run"}' | env HARNESS_ROOT="${fake_root}" \
    HARNESS_DEPTH=0 RLM_MAX_DEPTH=2 "${name}=${value}" "${agent}" --exec 2>&1)"
  rc=$?
  set -e
  [[ "${rc}" -ne 0 ]] || { echo "FAIL: direct agent accepted ${name}=${value}: ${out}"; exit 1; }
  [[ "${out}" == *"${name} must be a non-negative integer"* ]] \
    || { echo "FAIL: uncontrolled direct ${name}=${value} error: ${out}"; exit 1; }
}

for value in -1 nope; do
  assert_agent_invalid HARNESS_DEPTH "${value}"
  assert_agent_invalid RLM_MAX_DEPTH "${value}"
done

echo "PASS"
