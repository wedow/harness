#!/usr/bin/env bash
# Test: web _launch_agent serializes agent runs per session (one in-flight
# driver at a time). Pre-fix, it used `flock -n 9` and ignored the result,
# so every message spawned a CONCURRENT `harness agent` driver on the same
# session — duplicate subagents and racing writes to messages/, .tool_dispatch
# fifos, and agent slots. Post-fix the lock blocks: the second message queues
# behind the first run.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sessions="${_tmpdir}/sessions"
mkdir -p "${sessions}"
export HARNESS_SESSIONS="${sessions}"

# Source the real pages.sh (needs http.sh first); then point _HS at a stub.
source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

# Stub runner: records run windows under a global lock so overlaps are visible.
log="${_tmpdir}/runs.log"
_HS="${_tmpdir}/harness-stub"
cat > "${_HS}" <<'STUB'
#!/usr/bin/env bash
(
  flock 11
  printf 'start %s\n' "$2" >> "${RUNS_LOG}"
  sleep 1
  printf 'end %s\n' "$2" >> "${RUNS_LOG}"
) 11>"${RUNS_LOCK}"
STUB
chmod +x "${_HS}"
export RUNS_LOG="${log}" RUNS_LOCK="${_tmpdir}/runs.lock"

sid="20260101-000000-1"
mkdir -p "${sessions}/${sid}"

# Two rapid sends while the first run is in flight. _launch_agent is
# fire-and-forget (HTTP returns immediately), so poll for completion -- the
# second run must queue behind the first (post-fix) rather than overlap.
_launch_agent "${sid}" "first"
_launch_agent "${sid}" "second"
for _ in {1..100}; do
  [[ "$(grep -c '^end ' "${log}" 2>/dev/null || true)" == "2" ]] && break
  sleep 0.1
done

# Both messages processed exactly once, serially (no overlapping windows).
assert_eq "start count" "$(grep -c '^start ' "${log}")" "2"
assert_eq "end count" "$(grep -c '^end ' "${log}")" "2"
overlaps="$(awk 'NR>1 && $1=="start" && prev!="end" {bad=1} {prev=$1} END{print bad+0}' "${log}")"
assert_eq "no overlapping runs" "${overlaps}" "0"

echo "PASS"