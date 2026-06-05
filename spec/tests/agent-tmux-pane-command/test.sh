#!/usr/bin/env bash
# Test: tmux subagent pane command safely quotes paths/prompts containing single quotes.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSION="${_tmpdir}/parent's session"
mkdir -p "${HARNESS_SESSION}/messages"
export TMUX="fake-tmux"
export HARNESS_CWD="${_tmpdir}/work dir with ' quote"
mkdir -p "${HARNESS_CWD}"
export HARNESS_SESSIONS="${_tmpdir}/unused"

fakebin="${_tmpdir}/bin"
mkdir -p "${fakebin}"
cat > "${fakebin}/tmux" <<'FAKE'
#!/usr/bin/env bash
log="${TMUX_LOG:?}"
case "$1" in
  split-window)
    shift
    while [[ "$1" == -* ]]; do
      case "$1" in
         -P) shift ;;
        -F) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$1" > "${log}"
    echo '%pane1'
    ;;
  list-panes)
    exit 1
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "${fakebin}/tmux"
export PATH="${fakebin}:${PATH}"
export TMUX_LOG="${_tmpdir}/tmux-cmd.log"

printf '{"prompt":"prompt with '\'' quote"}' | "${HARNESS_ROOT}/plugins/subagents/tools/agent" --exec >/dev/null
pane_cmd="$(cat "${TMUX_LOG}")"

# Command should be syntactically valid shell despite quoted paths/env values.
bash -n <<< "${pane_cmd}" || {
  echo "FAIL: pane command is not valid shell"
  printf '%s\n' "${pane_cmd}"
  exit 1
}

# It should pass the pre-created session id to harness stream.
if [[ "${pane_cmd}" != *" stream "* ]]; then
  echo "FAIL: pane command does not invoke harness stream"
  printf '%s\n' "${pane_cmd}"
  exit 1
fi

echo "PASS"