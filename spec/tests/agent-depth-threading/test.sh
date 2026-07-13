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

# Parent at depth 2 -> child pane env must carry HARNESS_DEPTH=3.
printf '{"prompt":"do thing"}' | HARNESS_DEPTH=2 "${HARNESS_ROOT}/plugins/subagents/tools/agent" --exec >/dev/null
pane_cmd="$(cat "${TMUX_LOG}")"
grep -q 'HARNESS_DEPTH=3' <<< "${pane_cmd}" \
  || { echo "FAIL: child depth not incremented 2->3"; printf '%s\n' "${pane_cmd}"; exit 1; }

# Root (HARNESS_DEPTH unset) -> child gets HARNESS_DEPTH=1.
: > "${TMUX_LOG}"
printf '{"prompt":"do thing"}' | env -u HARNESS_DEPTH "${HARNESS_ROOT}/plugins/subagents/tools/agent" --exec >/dev/null
pane_cmd="$(cat "${TMUX_LOG}")"
grep -q 'HARNESS_DEPTH=1' <<< "${pane_cmd}" \
  || { echo "FAIL: root child depth not set to 1"; printf '%s\n' "${pane_cmd}"; exit 1; }

echo "PASS"
