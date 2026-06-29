#!/usr/bin/env bash
# Test: tmux branch robustness — provider env propagation (BUG-4), wall-clock
# timeout on the pane-poll loop (BUG-2), and failure surfacing (BUG-1).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

agent_tool="${HARNESS_ROOT}/plugins/subagents/tools/agent"
export TMUX="fake-tmux"
export HARNESS_CWD="${_tmpdir}/work"; mkdir -p "${HARNESS_CWD}"

fakebin="${_tmpdir}/bin"
mkdir -p "${fakebin}"

# ---------- Phase 1: BUG-4 — provider/model env always propagated to pane ----------
# Parent has HARNESS_MODEL/HARNESS_PROVIDER set; tool input does NOT pass them.
# The pane command must still export them so the fresh shell inherits them.
cat > "${fakebin}/tmux" <<'FAKE'
#!/usr/bin/env bash
log="${TMUX_LOG:?}"
case "$1" in
  split-window)
    shift
    while [[ "$1" == -* ]]; do
      case "$1" in -P) shift ;; -F) shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "$1" > "${log}"
    echo '%pane1'
    ;;
  list-panes) exit 1 ;;   # pane "exits" immediately
  *) exit 1 ;;
esac
FAKE
chmod +x "${fakebin}/tmux"
export PATH="${fakebin}:${PATH}"
export TMUX_LOG="${_tmpdir}/tmux-cmd.log"

export HARNESS_PROVIDER="fireworks"
export HARNESS_MODEL="fw-model"
# Tool input omits provider/model on purpose — must inherit from parent env.
out="$(printf '{"prompt":"do x"}' | "${agent_tool}" --exec 2>&1)" || true
pane_cmd="$(cat "${TMUX_LOG}")"

[[ "${pane_cmd}" == *"HARNESS_PROVIDER=fireworks"* ]] || {
  echo "FAIL: provider not propagated to pane cmd"; printf '%s\n' "${pane_cmd}"; exit 1; }
[[ "${pane_cmd}" == *"HARNESS_MODEL=fw-model"* ]] || {
  echo "FAIL: model not propagated to pane cmd"; printf '%s\n' "${pane_cmd}"; exit 1; }

# ---------- Phase 2: explicit input overrides parent env ----------
export TMUX_LOG="${_tmpdir}/tmux-cmd2.log"
out="$(printf '{"prompt":"do x","provider":"anthropic","model":"claude-3"}' \
  | "${agent_tool}" --exec 2>&1)" || true
pane_cmd="$(cat "${TMUX_LOG}")"
[[ "${pane_cmd}" == *"HARNESS_PROVIDER=anthropic"* ]] || { echo "FAIL: explicit provider not used"; exit 1; }
[[ "${pane_cmd}" == *"HARNESS_MODEL=claude-3"* ]] || { echo "FAIL: explicit model not used"; exit 1; }

# ---------- Phase 3: BUG-2 — pane-poll loop bounded by timeout, kills pane ----------
# Fake tmux where list-panes always succeeds (pane never exits on its own).
cat > "${fakebin}/tmux" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  split-window) shift; while [[ "$1" == -* ]]; do case "$1" in -P) shift ;; -F) shift 2 ;; *) shift ;; esac; done; echo '%pane1' ;;
  list-panes) exit 0 ;;   # pane always exists -> loop would spin forever
  kill-pane) printf 'kill-pane %s\n' "$*" >> "${KILL_LOG:?}"; exit 0 ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "${fakebin}/tmux"
export KILL_LOG="${_tmpdir}/kill.log"
export HARNESS_AGENT_TIMEOUT=1

start=$SECONDS
rc=0
out="$("${agent_tool}" --exec <<<'{"prompt":"hang"}' 2>&1)" || rc=$?
elapsed=$(( SECONDS - start ))
[[ "${elapsed}" -lt 5 ]] || { echo "FAIL: tmux timeout took too long: ${elapsed}s"; exit 1; }
[[ "${rc}" -ne 0 ]] || { echo "FAIL: tmux timeout should exit non-zero"; exit 1; }
[[ "${out}" == *"timed out"* ]] || { echo "FAIL: expected timeout marker, got: ${out}"; exit 1; }
assert_file_contains "${KILL_LOG}" "kill-pane"   # pane was killed on expiry

# ---------- Phase 4: BUG-1 — tmux child crash surfaced via exit-code marker ----------
# Fake tmux that simulates the pane crashing: writes a non-zero .exit_code to
# the session dir created by the agent tool, then list-panes returns 1 (pane
# "gone"). The agent tool must surface the failure and exit non-zero.
unset HARNESS_AGENT_TIMEOUT
cat > "${fakebin}/tmux" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  split-window)
    # Simulate the pane running, crashing, and writing its exit code marker.
    sess_dir="$(find "${HARNESS_SESSION}/.harness/sessions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
    [[ -n "${sess_dir}" ]] && echo "99" > "${sess_dir}/.exit_code"
    echo '%pane1'
    ;;
  list-panes) exit 1 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "${fakebin}/tmux"

rc=0
out="$(printf '{"prompt":"crash"}' | "${agent_tool}" --exec 2>&1)" || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: tmux child failure should propagate"; exit 1; }
[[ "${out}" == *"subagent failed (exit 99)"* ]] || { echo "FAIL: expected marked failure, got: ${out}"; exit 1; }

echo "PASS"
