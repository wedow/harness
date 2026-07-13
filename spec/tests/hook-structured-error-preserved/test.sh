#!/usr/bin/env bash
# Test: a failing hook that already emitted structured error JSON keeps that
# error as the pipeline result instead of being replaced by a generic hook error.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

# shellcheck disable=SC1091
source "${HARNESS_ROOT}/bin/harness"

mock_src="${_tmpdir}/mock-src"
mkdir -p "${mock_src}/hooks.d/send"
cat > "${mock_src}/hooks.d/send/10-provider-fail" <<'HOOK'
#!/usr/bin/env bash
echo "chatgpt API error: model unsupported" >&2
jq -n '{error: "chatgpt API error: model unsupported"}'
exit 1
HOOK
chmod +x "${mock_src}/hooks.d/send/10-provider-fail"

_HARNESS_SOURCES=("${mock_src}")

rc=0
out="$(echo '{}' | call send)" || rc=$?
assert_eq "exit-code" "$rc" "1"
assert_json '.error' "$out" "chatgpt API error: model unsupported"

if [[ "$(echo "$out" | jq -r '.error')" == hook\ * ]]; then
  echo "FAIL: structured hook error was replaced by generic hook failure"
  exit 1
fi

echo "PASS"