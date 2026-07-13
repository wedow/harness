#!/usr/bin/env bash
# Test: 50-depth-gate drops the rlm plugin from the sources list once
# delegation depth exceeds RLM_MAX_DEPTH (default 2). Mirrors 40-scope-providers:
# stdin/stdout is {sources:[...]}.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/sources/50-depth-gate"
rlm="${HARNESS_ROOT}/plugins/rlm"
core="${HARNESS_ROOT}/plugins/core"
payload() { jq -n --arg rlm "${rlm}" --arg core "${core}" '{sources:[$core,$rlm]}'; }
# echo OUT -> "true"/"false": is rlm still in the source list?
rlm_present() { echo "$1" | jq --arg r "${rlm}" '[.sources[]] | any(. == $r)'; }

# Unset (root, depth 0) and depths 1, 2 -> rlm stays.
out="$(payload | env -u HARNESS_DEPTH "${hook}")"
[[ "$(rlm_present "${out}")" == "true" ]] || { echo "FAIL: rlm removed when HARNESS_DEPTH unset"; exit 1; }
for d in 0 1 2; do
  out="$(payload | HARNESS_DEPTH="${d}" "${hook}")"
  [[ "$(rlm_present "${out}")" == "true" ]] || { echo "FAIL: rlm removed at depth ${d}"; exit 1; }
done

# Depths past the default threshold -> rlm gone, other plugins survive.
for d in 3 5; do
  out="$(payload | HARNESS_DEPTH="${d}" "${hook}")"
  [[ "$(rlm_present "${out}")" == "false" ]] || { echo "FAIL: rlm kept at depth ${d}"; exit 1; }
  echo "${out}" | jq -e --arg c "${core}" '[.sources[]] | any(. == $c)' >/dev/null \
    || { echo "FAIL: core dropped at depth ${d}"; exit 1; }
done

# RLM_MAX_DEPTH override shifts the boundary.
out="$(payload | HARNESS_DEPTH=3 RLM_MAX_DEPTH=3 "${hook}")"
[[ "$(rlm_present "${out}")" == "true" ]] || { echo "FAIL: rlm removed at depth==max (3)"; exit 1; }
out="$(payload | HARNESS_DEPTH=4 RLM_MAX_DEPTH=3 "${hook}")"
[[ "$(rlm_present "${out}")" == "false" ]] || { echo "FAIL: rlm kept at depth>max (4)"; exit 1; }

echo "PASS"
