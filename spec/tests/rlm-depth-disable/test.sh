#!/usr/bin/env bash
# Test: 50-depth-gate drops the rlm plugin from the sources list once
# delegation depth exceeds RLM_MAX_DEPTH (default 2). Mirrors 40-scope-providers:
# stdin/stdout is {sources:[...]}.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/sources/50-depth-gate"
rlm="$(cd "${HARNESS_ROOT}/plugins/rlm" && pwd)"
core="$(cd "${HARNESS_ROOT}/plugins/core" && pwd)"
payload() { jq -n --arg rlm "${rlm}" --arg core "${core}" '{sources:[$core,$rlm]}'; }
# echo OUT -> "true"/"false": is rlm still in the source list?
rlm_present() { echo "$1" | jq --arg r "${rlm}" '[.sources[]] | any(. == $r)'; }

assert_invalid() {
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
  assert_invalid HARNESS_DEPTH "${value}"
  assert_invalid RLM_MAX_DEPTH "${value}"
done

# Unset (root, depth 0) and depth 1 -> rlm stays.
out="$(payload | env -u HARNESS_DEPTH "${hook}")"
[[ "$(rlm_present "${out}")" == "true" ]] || { echo "FAIL: rlm removed when HARNESS_DEPTH unset"; exit 1; }
for d in 0 1; do
  out="$(payload | HARNESS_DEPTH="${d}" "${hook}")"
  [[ "$(rlm_present "${out}")" == "true" ]] || { echo "FAIL: rlm removed at depth ${d}"; exit 1; }
done

# At and past the default threshold, agents are leaves: rlm is gone while
# unrelated plugins survive.
for d in 2 3 5; do
  out="$(payload | HARNESS_DEPTH="${d}" "${hook}")"
  [[ "$(rlm_present "${out}")" == "false" ]] || { echo "FAIL: rlm kept at depth ${d}"; exit 1; }
  echo "${out}" | jq -e --arg c "${core}" '[.sources[]] | any(. == $c)' >/dev/null \
    || { echo "FAIL: core dropped at depth ${d}"; exit 1; }
done

# RLM_MAX_DEPTH override shifts the boundary.
out="$(payload | HARNESS_DEPTH=2 RLM_MAX_DEPTH=3 "${hook}")"
[[ "$(rlm_present "${out}")" == "true" ]] || { echo "FAIL: rlm removed below override maximum"; exit 1; }
out="$(payload | HARNESS_DEPTH=3 RLM_MAX_DEPTH=3 "${hook}")"
[[ "$(rlm_present "${out}")" == "false" ]] || { echo "FAIL: rlm kept at override maximum"; exit 1; }

echo "PASS"
