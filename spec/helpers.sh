# spec/helpers.sh — shared test utilities. source this from each test.sh.
SPEC_DIR="${SPEC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export HARNESS_ROOT="$(dirname "${SPEC_DIR}")"
export HARNESS_LOG=/dev/null
export HARNESS_STAGE="test"

_tmpdir=""

setup() {
  _tmpdir="$(mktemp -d)"
  export HARNESS_SESSION="${_tmpdir}/session"
  mkdir -p "${HARNESS_SESSION}/messages"
  export HARNESS_PROVIDER="mock"
}

teardown() {
  [[ -n "${_tmpdir}" && -d "${_tmpdir}" ]] && rm -rf "${_tmpdir}"
}
trap teardown EXIT

# assert_eq LABEL ACTUAL EXPECTED
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$label" "$expected" "$actual"
    return 1
  fi
}

# assert_json JQ_QUERY JSON EXPECTED
assert_json() {
  local query="$1" json="$2" expected="$3"
  local actual
  actual="$(echo "${json}" | jq -r "${query}")" || { echo "FAIL: jq error on '${query}'"; return 1; }
  assert_eq "${query}" "${actual}" "${expected}"
}

# assert_json_raw JQ_QUERY JSON EXPECTED — no -r, preserves quotes
assert_json_raw() {
  local query="$1" json="$2" expected="$3"
  local actual
  actual="$(echo "${json}" | jq "${query}")" || { echo "FAIL: jq error on '${query}'"; return 1; }
  assert_eq "${query}" "${actual}" "${expected}"
}

assert_file_exists() {
  [[ -f "$1" ]] || { echo "FAIL: file not found: $1"; return 1; }
}

assert_file_contains() {
  grep -qF "$2" "$1" || { echo "FAIL: '$2' not found in $1"; return 1; }
}

# portable timeout: uses GNU timeout if available, else background+kill
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "${secs}" "$@" || true
  else
    "$@" & local _pid=$!
    ( sleep "${secs}" && kill "${_pid}" 2>/dev/null ) & local _wd=$!
    wait "${_pid}" 2>/dev/null || true
    kill "${_wd}" 2>/dev/null || true; wait "${_wd}" 2>/dev/null || true
  fi
}

# pty_spawn CMD — run CMD inside a pty so signals like SIGINT aren't masked.
# Bridges util-linux `script -c CMD FILE` and BSD `script FILE shell -c CMD`.
# `exec` is required so $! in the caller resolves to script's pid (and pgid),
# not the wrapping subshell when this is invoked with `&`.
pty_spawn() {
  if [[ "$(uname)" == "Darwin" ]]; then
    exec script -q /dev/null bash -c "$1"
  else
    exec script -q -c "$1" /dev/null
  fi
}

# make_sources DIR — create a minimal source dir and export HARNESS_SOURCES
make_sources() {
  local dir="$1"
  mkdir -p "${dir}"
  export HARNESS_SOURCES="${dir}"
}
