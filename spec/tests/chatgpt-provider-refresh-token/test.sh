#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

provider="${HARNESS_ROOT}/plugins/chatgpt/providers/chatgpt"

export HARNESS_PROVIDER="chatgpt"
export HARNESS_HOME="${_tmpdir}/home"
mkdir -p "${HARNESS_HOME}"

auth_source="${_tmpdir}/source"
make_sources "${auth_source}"

cat > "${auth_source}/.auth.json" <<'JSON'
{
  "chatgpt": [
    {
      "access_token": "expired-access-token",
      "refresh_token": "stale-refresh-token",
      "account_id": "test-account",
      "expires_at": "1"
    }
  ]
}
JSON

cp "${auth_source}/.auth.json" "${HARNESS_HOME}/.auth-cache.json"

mock_bin="${_tmpdir}/bin"
mkdir -p "${mock_bin}"

cat > "${mock_bin}/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

url=""
prev=""
for arg in "$@"; do
  if [[ "${prev}" == "-d" ]]; then
    prev=""
    continue
  fi
  case "${arg}" in
    http://*|https://*) url="${arg}" ;;
  esac
  prev="${arg}"
done

if [[ "${url}" == "https://auth.openai.com/oauth/token" ]]; then
  content_type=""
  refresh_body=""
  prev=""
  for arg in "$@"; do
    if [[ "${prev}" == "-H" ]]; then
      [[ "${arg}" == Content-Type:* ]] && content_type="${arg}"
      prev=""
      continue
    fi
    if [[ "${prev}" == "-d" ]]; then
      if [[ -n "${refresh_body}" ]]; then
        refresh_body="${refresh_body}&${arg}"
      else
        refresh_body="${arg}"
      fi
      prev=""
      continue
    fi
    case "${arg}" in
      -H|-d) prev="${arg}" ;;
      *) prev="" ;;
    esac
  done

  [[ "${content_type}" == "Content-Type: application/x-www-form-urlencoded" ]] || {
    echo "wrong refresh content type: ${content_type}" >&2
    exit 1
  }
  [[ "${refresh_body}" == *"grant_type=refresh_token"* ]] || {
    echo "missing refresh grant_type: ${refresh_body}" >&2
    exit 1
  }
  [[ "${refresh_body}" == *"refresh_token=stale-refresh-token"* ]] || {
    echo "missing refresh token: ${refresh_body}" >&2
    exit 1
  }
  [[ "${refresh_body}" == *"client_id=app_EMoamEEZ73f0CkXaXp7hrann"* ]] || {
    echo "missing client_id: ${refresh_body}" >&2
    exit 1
  }

  printf '%s\n' '{"access_token":"refreshed-access-token","refresh_token":"refreshed-refresh-token","expires_in":3600}'
  exit 0
fi

if [[ "${url}" == "https://chatgpt.com/backend-api/codex/responses" ]]; then
  body="$(cat)"
  [[ -n "${body}" ]] || { echo "missing request body" >&2; exit 1; }

  auth_header=""
  account_header=""
  prev=""
  for arg in "$@"; do
    if [[ "${prev}" == "-H" ]]; then
      case "${arg}" in
        Authorization:*) auth_header="${arg}" ;;
        ChatGPT-Account-ID:*) account_header="${arg}" ;;
      esac
    fi
    prev="${arg}"
  done

  [[ "${auth_header}" == "Authorization: Bearer refreshed-access-token" ]] || {
    echo "wrong auth header: ${auth_header}" >&2
    exit 1
  }
  [[ "${account_header}" == "ChatGPT-Account-ID: test-account" ]] || {
    echo "wrong account header: ${account_header}" >&2
    exit 1
  }

  printf '%s\n' 'data: {"type":"response.completed","response":{"id":"resp_1","model":"gpt-5.4","status":"completed","usage":{"input_tokens":1,"output_tokens":1},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}}'
  exit 0
fi

echo "unexpected url: ${url}" >&2
exit 1
CURL
chmod +x "${mock_bin}/curl"

export PATH="${mock_bin}:${PATH}"

payload='{"model":"gpt-5.4","system":"","messages":[],"tools":[]}'
response="$(echo "${payload}" | "${provider}")"

assert_json '.output[0].content[0].text' "${response}" "ok"

auth_json="$(cat "${auth_source}/.auth.json")"
cache_json="$(cat "${HARNESS_HOME}/.auth-cache.json")"

assert_json '.chatgpt[0].access_token' "${auth_json}" "refreshed-access-token"
assert_json '.chatgpt[0].refresh_token' "${auth_json}" "refreshed-refresh-token"
assert_json '.chatgpt[0].access_token' "${cache_json}" "refreshed-access-token"
assert_json '.chatgpt[0].refresh_token' "${cache_json}" "refreshed-refresh-token"

now="$(date +%s)"
auth_exp="$(echo "${auth_json}" | jq -r '.chatgpt[0].expires_at')"
cache_exp="$(echo "${cache_json}" | jq -r '.chatgpt[0].expires_at')"

[[ "${auth_exp}" != "0" && "${auth_exp}" -gt "${now}" ]] || {
  echo "FAIL: auth source expires_at was not refreshed: ${auth_exp}"
  exit 1
}
[[ "${cache_exp}" != "0" && "${cache_exp}" -gt "${now}" ]] || {
  echo "FAIL: auth cache expires_at was not refreshed: ${cache_exp}"
  exit 1
}
