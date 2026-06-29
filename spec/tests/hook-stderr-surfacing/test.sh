#!/usr/bin/env bash
# Test: when a hook in a pipeline exits non-zero, the real cause (its stderr)
# must be surfaced inline in the error message — not just a generic file
# pointer to HARNESS_LOG. BUG-6: error reporting hid the underlying cause.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

# Source harness to get call() and supporting machinery. Sourcing is safe —
# main() only runs when bin/harness is executed directly (see bottom of file).
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/bin/harness"

# Mock source dir with a send hook that fails with KNOWN stderr (simulates a
# provider curl stall, the original BUG-6 forensic scenario).
mock_src="${_tmpdir}/mock-src"
mkdir -p "${mock_src}/hooks.d/send"
cat > "${mock_src}/hooks.d/send/10-fail" <<'HOOK'
#!/usr/bin/env bash
echo "earlier warning line" >&2
echo "curl: (28) Operation timed out after 30001 milliseconds" >&2
exit 3
HOOK
chmod +x "${mock_src}/hooks.d/send/10-fail"

_HARNESS_SOURCES=("${mock_src}")

# Run call() — should fail with rc=3 and produce error JSON in stdout.
rc=0
out="$(echo '{}' | call send)" || rc=$?

# Exit code propagates from the failing hook.
assert_eq "exit-code" "$rc" "3"

# Defensively extract .error (test must FAIL cleanly, not error, when missing).
err_msg="$(printf '%s' "$out" | jq -r '.error // empty' 2>/dev/null)" || true

# The real stderr cause must be surfaced inline in the error message.
[[ "${err_msg}" == *"Operation timed out after 30001 milliseconds"* ]] || {
  echo "FAIL: error message should contain the real stderr cause"
  echo "got: ${err_msg:-<empty>}"
  exit 1
}

# The failing hook's identity should be identifiable (which hook died).
[[ "${err_msg}" == *"10-fail"* ]] || {
  echo "FAIL: error message should identify which hook failed"
  echo "got: ${err_msg:-<empty>}"
  exit 1
}

# The generic file-pointer-only fallback must no longer be the whole message.
if [[ "${err_msg}" == "hook pipeline failed (check"* ]]; then
  echo "FAIL: error message fell back to generic wrapper without cause"
  exit 1
fi

echo "PASS"
