#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

provider="${HARNESS_ROOT}/plugins/chatgpt/providers/chatgpt"
export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}"

cat > "${HARNESS_HOME}/.auth-cache.json" <<'JSON'
{
  "chatgpt": [
    {
      "access_token": "expired-access-token",
      "refresh_token": "refresh-token",
      "expires_at": "1"
    }
  ]
}
JSON

if ! "${provider}" --ready; then
  echo "FAIL: expired ChatGPT access token with refresh token should be ready"
  exit 1
fi

assert_not_ready() {
  local credentials="$1"
  local description="$2"
  jq -n --argjson credentials "${credentials}" '{chatgpt: [$credentials]}' > "${HARNESS_HOME}/.auth-cache.json"
  if "${provider}" --ready; then
    echo "FAIL: ${description} should not be ready"
    exit 1
  fi
}

assert_not_ready '{}' "empty ChatGPT credentials"
assert_not_ready '{"refresh_token":"refresh-token"}' "refresh-only ChatGPT credentials"
assert_not_ready '{"access_token":"expired-access-token","expires_at":"1"}' "expired ChatGPT access token without refresh token"
