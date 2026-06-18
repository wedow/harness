#!/usr/bin/env bash
# Test: tmux subagent spawning retiles into an even grid after each pane,
# and spills into a new window when the current one is too full to split.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSION="${_tmpdir}/parent"
mkdir -p "${HARNESS_SESSION}/messages"
export TMUX="fake-tmux"
export HARNESS_CWD="${_tmpdir}/work"
mkdir -p "${HARNESS_CWD}"
export HARNESS_SESSIONS="${_tmpdir}/unused"

fakebin="${_tmpdir}/bin"
mkdir -p "${fakebin}"
cat > "${fakebin}/tmux" <<'FAKE'
#!/usr/bin/env bash
log="${TMUX_LOG:?}"
echo "$*" >> "${log}"
case "$1" in
  split-window)
    [[ "${SPLIT_FAILS:-0}" == 1 ]] && exit 1
    echo '%pane1'
    ;;
  new-window)   echo '%pane2' ;;
  select-layout) exit 0 ;;
  list-panes)   exit 1 ;;
  *)            exit 0 ;;
esac
FAKE
chmod +x "${fakebin}/tmux"
export PATH="${fakebin}:${PATH}"

# --- Phase A: split succeeds -> retile current window, no new window ---
export TMUX_LOG="${_tmpdir}/log-a"
: > "${TMUX_LOG}"
printf '{"prompt":"hi"}' | "${HARNESS_ROOT}/plugins/subagents/tools/agent" --exec >/dev/null

if ! grep -q 'select-layout -t %pane1 tiled' "${TMUX_LOG}"; then
  echo "FAIL: did not retile the new pane's window with 'tiled'"
  cat "${TMUX_LOG}"
  exit 1
fi
if grep -q '^new-window' "${TMUX_LOG}"; then
  echo "FAIL: opened a new window even though split succeeded"
  cat "${TMUX_LOG}"
  exit 1
fi

# --- Phase B: split fails (no space) -> spill to a new window, then retile ---
export TMUX_LOG="${_tmpdir}/log-b"
: > "${TMUX_LOG}"
SPLIT_FAILS=1 bash -c 'printf "{\"prompt\":\"hi\"}" | "$1" --exec >/dev/null' \
  _ "${HARNESS_ROOT}/plugins/subagents/tools/agent"

if ! grep -q '^new-window' "${TMUX_LOG}"; then
  echo "FAIL: did not spill into a new window when split had no space"
  cat "${TMUX_LOG}"
  exit 1
fi
if ! grep -q 'select-layout -t %pane2 tiled' "${TMUX_LOG}"; then
  echo "FAIL: did not retile the spilled window with 'tiled'"
  cat "${TMUX_LOG}"
  exit 1
fi

echo "PASS"
