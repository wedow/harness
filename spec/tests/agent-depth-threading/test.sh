#!/usr/bin/env bash
# Test: the agent tool threads HARNESS_DEPTH to spawned subagents as parent+1.
# Uses a fake tmux that captures the pane command (same scaffold as
# agent-tmux-pane-command), so no real model or pane is spawned.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSION="${_tmpdir}/parent"
mkdir -p "${HARNESS_SESSION}/messages"
export TMUX="fake-tmux"
export HARNESS_CWD="${_tmpdir}/work"
mkdir -p "${HARNESS_CWD}"
export HARNESS_SESSIONS="${_tmpdir}/unused"
export HARNESS_AGENT_CONCURRENCY=7
export RLM_MAX_DEPTH=5
export HARNESS_RUN_ID=test-run

fakebin="${_tmpdir}/bin"; mkdir -p "${fakebin}"
cat > "${fakebin}/tmux" <<'FAKE'
#!/usr/bin/env bash
log="${TMUX_LOG:?}"
case "$1" in
  split-window)
    shift
    while [[ "$1" == -* ]]; do case "$1" in -P) shift;; -F) shift 2;; *) shift;; esac; done
    printf '%s\n' "$1" > "${log}"; echo '%pane1' ;;
  list-panes) exit 1 ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "${fakebin}/tmux"
export PATH="${fakebin}:${PATH}"
export TMUX_LOG="${_tmpdir}/tmux-cmd.log"

# Parent below the limit -> child pane reaches the leaf depth.
printf '{"prompt":"do thing"}' | HARNESS_DEPTH=1 "${HARNESS_ROOT}/plugins/subagents/tools/agent" --exec >/dev/null
pane_cmd="$(cat "${TMUX_LOG}")"
grep -q 'HARNESS_DEPTH=2' <<< "${pane_cmd}" \
  || { echo "FAIL: child depth not incremented 1->2"; printf '%s\n' "${pane_cmd}"; exit 1; }
grep -q "HARNESS_AGENT_SESSION_ROOT=${HARNESS_SESSION}" <<< "${pane_cmd}" \
  || { echo "FAIL: top-level session not propagated as concurrency root"; printf '%s\n' "${pane_cmd}"; exit 1; }
grep -q 'HARNESS_AGENT_CONCURRENCY=7' <<< "${pane_cmd}" \
  || { echo "FAIL: concurrency limit not propagated"; printf '%s\n' "${pane_cmd}"; exit 1; }
grep -q 'RLM_MAX_DEPTH=5' <<< "${pane_cmd}" \
  || { echo "FAIL: non-default maximum depth not propagated"; printf '%s\n' "${pane_cmd}"; exit 1; }
grep -q 'HARNESS_RUN_ID=test-run' <<< "${pane_cmd}" \
  || { echo "FAIL: harness run id not propagated"; printf '%s\n' "${pane_cmd}"; exit 1; }

# Root (HARNESS_DEPTH unset) -> child gets HARNESS_DEPTH=1.
: > "${TMUX_LOG}"
inherited_root="${_tmpdir}/top-session"
printf '{"prompt":"do thing"}' | env -u HARNESS_DEPTH HARNESS_AGENT_SESSION_ROOT="${inherited_root}" \
  "${HARNESS_ROOT}/plugins/subagents/tools/agent" --exec >/dev/null
pane_cmd="$(cat "${TMUX_LOG}")"
grep -q 'HARNESS_DEPTH=1' <<< "${pane_cmd}" \
  || { echo "FAIL: root child depth not set to 1"; printf '%s\n' "${pane_cmd}"; exit 1; }
grep -q "HARNESS_AGENT_SESSION_ROOT=${inherited_root}" <<< "${pane_cmd}" \
  || { echo "FAIL: nested child replaced inherited concurrency root"; printf '%s\n' "${pane_cmd}"; exit 1; }

echo "PASS"
