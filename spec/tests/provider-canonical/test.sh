#!/usr/bin/env bash
# Canonical transports, opaque continuation, cache framing, and auth isolation.
# The spec helpers assign _tmpdir; jq and child-shell programs expand their own variables.
# shellcheck disable=SC1091,SC2154,SC2016
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
repo="$(cd "${HARNESS_ROOT}" >/dev/null && pwd)"
source "${repo}/lib/provider.sh"
test_dir="${_tmpdir}/provider"
mkdir -p "${test_dir}/home"
cat > "${test_dir}/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${CURL_EXIT:-0}" == 0 ]] || exit "${CURL_EXIT}"
cat > "${CAPTURE}"
cat "${RESPONSE}"
MOCK
chmod +x "${test_dir}/curl"
printf '%s' '{"model":"m","messages":[{"role":"user","content":"hi"}],"system":"sys","tools":[]}' > "${test_dir}/request"
printf '%s' '{"stop_reason":"end_turn","usage":{},"content":[{"type":"text","text":"hello"}]}' > "${test_dir}/anthropic"
printf '%s' '{"choices":[{"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":{}}' > "${test_dir}/openai"
printf '%s' '{"stop_reason":"tool_use","content":[{"type":"thinking","thinking":"hidden","signature":"sig"},{"type":"text","text":"before"},{"type":"tool_use","id":"call1","name":"bash","input":{"command":"echo hi"}},{"type":"text","text":"after"}],"usage":{"input_tokens":10,"output_tokens":3,"cache_read_input_tokens":5}}' > "${test_dir}/anthropic-tools"
printf '%s' '{"choices":[{"message":{"role":"assistant","content":"before","reasoning_content":"hidden","tool_calls":[{"id":"call1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hi\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":3}}' > "${test_dir}/openai-tools"
printf '%s\n\n' 'data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"r1","encrypted_content":"opaque"}}' 'data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"m1","role":"assistant","content":[{"type":"output_text","text":"before"}]}}' 'data: {"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"f1","call_id":"call1","name":"bash","arguments":"{\"command\":\"echo hi\"}"}}' 'data: {"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":3}}}' > "${test_dir}/chatgpt-tools"
printf '%s' '{"chatgpt":[{"access_token":"test","expires_at":"0","account_id":"account"}]}' > "${test_dir}/home/.auth-cache.json"
export PATH="${test_dir}:${PATH}" CAPTURE="${test_dir}/captured" HARNESS_ROOT="${repo}"
export HARNESS_HOME="${test_dir}/home" HARNESS_SESSION="${test_dir}/session"
export HARNESS_SOURCES="${repo}/plugins/anthropic:${repo}/plugins/openai:${repo}/plugins/chatgpt"
export ANTHROPIC_API_KEY=test OPENAI_API_KEY=test
mkdir -p "${HARNESS_SESSION}"
printf 'sentinel\n' > "${HARNESS_SESSION}/.stream"
checks=0
check() { if [[ "$1" == jq ]]; then "$@" >/dev/null; else "$@"; fi; checks=$((checks+1)); }
run_provider() { RESPONSE="${test_dir}/$2" "${repo}/plugins/$1/providers/$1" < "${test_dir}/request" > "${test_dir}/actual"; }
reject() {
  if RESPONSE="${test_dir}/$2" "${repo}/plugins/$1/providers/$1" < "${test_dir}/request" > "${test_dir}/actual" 2> "${test_dir}/stderr"; then
    echo "expected $1 to reject $2" >&2; exit 1
  fi
  [[ ! -s "${test_dir}/actual" && -s "${test_dir}/stderr" ]]
}
check run_provider anthropic anthropic
check jq -e '.stop=="end" and .blocks[0].text=="hello"' "${test_dir}/actual"
check jq -e '.stream==null and .messages[0].content[0].text=="hi" and .cache_control.type=="ephemeral"' "${test_dir}/captured"
check run_provider openai openai
check jq -e '.stream==null and .messages[0].role=="system" and .messages[1].role=="user"' "${test_dir}/captured"
for provider in anthropic openai chatgpt; do
  check run_provider "${provider}" "${provider}-tools"
  check jq -e '.stop=="tool_calls" and ([.blocks[]|select(.type=="tool_call")]|length)==1 and .provider_state.protocol!=null' "${test_dir}/actual"
  cp "${test_dir}/actual" "${test_dir}/$provider-normalized"
  jq -s '{model:"m",system:"sys",tools:[],messages:[{role:"user",content:"hi"},{role:"assistant",blocks:.[0].blocks,provider_state:.[0].provider_state},{role:"tool",call_id:"call1",name:"bash",content:"ok",error:false}]}' "${test_dir}/actual" > "${test_dir}/continuation"
  check env RESPONSE="${test_dir}/$provider-tools" "${repo}/plugins/$provider/providers/$provider" < "${test_dir}/continuation" > "${test_dir}/actual"
  case "$provider" in
    anthropic) check jq -e '.messages[1].content[0].thinking=="hidden" and .messages[1].content[0].signature=="sig" and .messages[2].content[0].tool_use_id=="call1"' "${test_dir}/captured" ;;
    openai) check jq -e '.messages[2].reasoning_content=="hidden" and .messages[3].tool_call_id=="call1"' "${test_dir}/captured" ;;
    chatgpt) check jq -e '.input[1].encrypted_content=="opaque" and .input[4].call_id=="call1" and .input[4].type=="function_call_output"' "${test_dir}/captured" ;;
  esac
done
jq '.content += [.content[2]]' "${test_dir}/anthropic-tools" > "${test_dir}/anthropic-duplicate"
jq '.choices[0].message.tool_calls += [.choices[0].message.tool_calls[0]]' "${test_dir}/openai-tools" > "${test_dir}/openai-duplicate"
jq '.choices[0].message.tool_calls[0].function.arguments="{broken"' "${test_dir}/openai-tools" > "${test_dir}/openai-malformed"
jq '.choices[0].message.tool_calls[0].function.arguments="[]"' "${test_dir}/openai-tools" > "${test_dir}/openai-array-args"
jq '.content[2].input=[]' "${test_dir}/anthropic-tools" > "${test_dir}/anthropic-array-args"
jq '.stop_reason="max_tokens"' "${test_dir}/anthropic-tools" > "${test_dir}/anthropic-truncated-call"
printf '%s' '{"stop_reason":"end_turn","content":[]}' > "${test_dir}/anthropic-empty"
printf '%s' '{"content":[{"type":"text","text":"hello"}]}' > "${test_dir}/anthropic-no-stop"
printf '%s' '{"error":{"message":"server failed"}}' > "${test_dir}/openai-error"
printf '%s' '{broken' > "${test_dir}/openai-invalid-json"
printf '%s\n\n' 'data: {"type":"response.output_text.delta","delta":"half a reply"}' > "${test_dir}/chatgpt-incomplete"
printf '%s\n\n' 'data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","call_id":"call1","name":"bash","arguments":"{broken"}]}}}' > "${test_dir}/chatgpt-malformed"
printf '%s\n\n' 'data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","call_id":"call1","name":"bash","arguments":"{}"},{"type":"function_call","call_id":"call1","name":"bash","arguments":"{}"}]}}}' > "${test_dir}/chatgpt-duplicate"
for fixture in anthropic-duplicate anthropic-array-args anthropic-truncated-call anthropic-empty anthropic-no-stop; do check reject anthropic "$fixture"; done
for fixture in openai-duplicate openai-malformed openai-array-args openai-error openai-invalid-json; do check reject openai "$fixture"; done
for fixture in chatgpt-incomplete chatgpt-malformed chatgpt-duplicate; do check reject chatgpt "$fixture"; done
jq '.stop_reason="max_tokens"' "${test_dir}/anthropic" > "${test_dir}/anthropic-length"
check run_provider anthropic anthropic-length
check jq -e '.stop=="length"' "${test_dir}/actual"
check test "$(cat "${HARNESS_SESSION}/.stream")" = sentinel
# Large text must travel over stdin, never jq argv.
jq -n '{model:"m",system:"sys",tools:[],messages:[{role:"user",content:("x"*300000)}]}' > "${test_dir}/large"
check env RESPONSE="${test_dir}/anthropic" "${repo}/plugins/anthropic/providers/anthropic" < "${test_dir}/large" > "${test_dir}/actual"
check jq -e '(.messages[0].content[0].text|length)==300000' "${test_dir}/captured"
# Resolver uses high-priority overrides and leaves variant env in the subprocess.
mkdir -p "${test_dir}/local/providers"
printf '%s\n' 'protocol=openai' 'model=override-model' 'url=https://example.invalid/messages' 'auth_env=TEST_VARIANT_KEY' > "${test_dir}/local/providers/zai.conf"
export HARNESS_SOURCES="${HARNESS_SOURCES}:${test_dir}/local" TEST_VARIANT_KEY=test
check jq -e '.model=="override-model" and .protocol=="openai"' < <(provider_resolve zai '')
old_url="${OPENAI_API_URL-unset}"
check env RESPONSE="${test_dir}/openai" bash -c 'source "$HARNESS_ROOT/lib/provider.sh"; provider_call zai ""' < "${test_dir}/request" > "${test_dir}/actual"
check jq -e '.model=="override-model"' "${test_dir}/captured"
check test "${OPENAI_API_URL-unset}" = "$old_url"

# Whole view blocks stay byte-identical as new lines append; cache controls are
# directives and are not part of the cached content. The last whole block moves.
for n in 7 8; do
  jq -n --argjson n "$n" '{model:"m",system:"sys",tools:[],messages:[{role:"user",content:("<chat>\n"+([range(0;$n)|tostring+"+1|summary"]|join("\n"))+"\n</chat>")},{role:"user",content:"next"}]}' > "${test_dir}/view-request"
  check env RESPONSE="${test_dir}/anthropic" "${repo}/plugins/anthropic/providers/anthropic" < "${test_dir}/view-request" > "${test_dir}/actual"
  cp "${CAPTURE}" "${test_dir}/view-$n"
  check jq -e -s '(.[1].messages[0].content[:4]|map(.text)|join("")) == .[0].messages[0].content' "${test_dir}/view-request" "${CAPTURE}"
done
check jq -e '.messages[0].content[1].cache_control.type=="ephemeral" and .messages[0].content[2].cache_control==null' "${test_dir}/view-7"
check jq -e '.messages[0].content[1].cache_control==null and .messages[0].content[2].cache_control.type=="ephemeral" and .system[0].cache_control.type=="ephemeral"' "${test_dir}/view-8"
check jq -e -s '.[0].messages[0].content[1].text==.[1].messages[0].content[1].text' "${test_dir}/view-7" "${test_dir}/view-8"
check env ANTHROPIC_API_URL=https://example.invalid/messages RESPONSE="${test_dir}/anthropic" "${repo}/plugins/anthropic/providers/anthropic" < "${test_dir}/view-request" > "${test_dir}/actual"
check jq -e '.cache_control==null and (.system|type)=="string" and (.messages[0].content|length)==2 and .messages[0].content[0].cache_control==null' "${CAPTURE}"
check env CURL_EXIT=28 bash -c 'if RESPONSE="$1/anthropic" "$2/plugins/anthropic/providers/anthropic" < "$1/request" > "$1/actual" 2> "$1/stderr"; then exit 1; fi; [[ ! -s "$1/actual" && -s "$1/stderr" ]]' bash "${test_dir}" "${repo}"

# Serialize OAuth refreshes without holding the credential lock during inference.
mkdir -p "${test_dir}/oauth-bin" "${test_dir}/auth-source"
export OAUTH_CAPTURE="${test_dir}/oauth-capture" OAUTH_RESPONSE="${test_dir}/oauth-response" OAUTH_COUNT="${test_dir}/oauth-count"
cat > "${test_dir}/oauth-bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *oauth/token*)
    sleep 0.1
    printf 'refresh\n' >> "$OAUTH_COUNT"
    printf '%s' '{"access_token":"refreshed","refresh_token":"new-refresh","expires_in":3600}'
    ;;
  *)
    # Inference must not inherit the descriptor used to refresh credentials.
    for descriptor in /proc/$$/fd/*; do
      [[ "$(readlink "$descriptor" 2>/dev/null || true)" != "${HARNESS_HOME}/.auth-cache.lock" ]] || exit 88
    done
    for arg in "$@"; do
      if [[ "$arg" == 'Authorization: Bearer refreshed' ]]; then printf 'authenticated\n' >> "$OAUTH_COUNT"; fi
    done
    # Concurrent requests use separate captures to keep this fake transport atomic.
    cat > "${OAUTH_CAPTURE}.$$"
    cat "$OAUTH_RESPONSE"
    ;;
esac
MOCK
chmod +x "${test_dir}/oauth-bin/curl"
export PATH="${test_dir}/oauth-bin:${PATH}" HARNESS_SOURCES="${repo}/plugins/anthropic:${repo}/plugins/chatgpt:${test_dir}/auth-source"
for provider in claude chatgpt; do
  jq -n --arg p "$provider" '{($p):[{access_token:"expired",refresh_token:"old-refresh",expires_at:"1",account_id:"account"}]}' > "${HARNESS_HOME}/.auth-cache.json"
  cp "${HARNESS_HOME}/.auth-cache.json" "${test_dir}/auth-source/.auth.json"
  : > "$OAUTH_COUNT"
  if [[ "$provider" == claude ]]; then
    cp "${test_dir}/anthropic" "$OAUTH_RESPONSE"
    binary="${repo}/plugins/anthropic/providers/claude"
  else
    printf '%s\n\n' 'data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}],"usage":{}}}' > "$OAUTH_RESPONSE"
    binary="${repo}/plugins/chatgpt/providers/chatgpt"
  fi
  pids=()
  for n in 1 2 3 4; do
    "$binary" < "${test_dir}/request" > "${test_dir}/oauth-output.$n" 2> "${test_dir}/oauth-stderr.$n" &
    pids+=("$!")
  done
  harness_auth_refresh &
  pids+=("$!")
  for pid in "${pids[@]}"; do check wait "$pid"; done
  for n in 1 2 3 4; do check jq -e '.blocks[0].text=="hello" and .stop=="end"' "${test_dir}/oauth-output.$n"; done
  check jq -e --arg p "$provider" '.[$p][0].access_token=="refreshed" and .[$p][0].refresh_token=="new-refresh" and (.[$p][0].expires_at|tonumber)>1' "${HARNESS_HOME}/.auth-cache.json"
  check jq -e --arg p "$provider" '.[$p][0].access_token=="refreshed"' "${test_dir}/auth-source/.auth.json"
  check test "$(wc -l < "$OAUTH_COUNT" | tr -d ' ')" = 5
  check flock -n "${HARNESS_HOME}/.auth-cache.lock" true
  if [[ "$provider" == claude ]]; then
    for capture in "${OAUTH_CAPTURE}."*; do
      check jq -e '.system[0].text|contains("Claude Code")' "$capture"
      check jq -e '.system[1].text=="sys"' "$capture"
    done
  fi
  rm -f "${OAUTH_CAPTURE}."*
done

# Lock ownership must survive neither process death nor accidental unlocking
# from an inherited subshell. Nested acquisition keeps the outer owner locked.
check bash -s -- "${repo}" "${test_dir}/lock-home" <<'LOCK_CHECK'
set -euo pipefail
source "$1/lib/provider.sh"
export HARNESS_HOME="$2"
mkdir -p "$HARNESS_HOME"
holder=""; contender=""
cleanup_lock_check() {
  local pid
  for pid in "$holder" "$contender"; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  _PROVIDER_AUTH_DEPTH=1; _provider_auth_unlock
}
trap cleanup_lock_check EXIT
wait_marker() {
  local count
  for ((count=0;count<200;count++)); do [[ -f "$1" ]] && return 0; sleep .01; done
  printf 'FAIL: auth lock marker never appeared\n' >&2; return 1
}
(
  _provider_auth_lock
  : > "$HARNESS_HOME/held"
  while :; do sleep .1; done
) & holder=$!
wait_marker "$HARNESS_HOME/held"
if flock -n "$HARNESS_HOME/.auth-cache.lock" true; then exit 1; fi
kill -KILL "$holder"; wait "$holder" 2>/dev/null || true; holder=""
_provider_auth_lock
trap cleanup_lock_check EXIT
_provider_auth_lock
_provider_auth_unlock
if flock -n "$HARNESS_HOME/.auth-cache.lock" true; then exit 1; fi
(_provider_auth_unlock)
if flock -n "$HARNESS_HOME/.auth-cache.lock" true; then exit 1; fi
(
  : > "$HARNESS_HOME/contending"
  _provider_auth_lock
  : > "$HARNESS_HOME/acquired"
  _provider_auth_unlock
) & contender=$!
wait_marker "$HARNESS_HOME/contending"
[[ ! -f "$HARNESS_HOME/acquired" ]]
_provider_auth_unlock
wait "$contender"; contender=""
[[ -f "$HARNESS_HOME/acquired" ]]
flock -n "$HARNESS_HOME/.auth-cache.lock" true
[[ -z "${_PROVIDER_AUTH_FD:-}" ]]
LOCK_CHECK

# Source auth overrides unmanaged cached credentials; deleting the sources then
# clears only a cache we previously managed. Failed merges preserve the cache.
mkdir -p "${test_dir}/merge-home" "${test_dir}/merge-local"
export HARNESS_HOME="${test_dir}/merge-home"
export HARNESS_SOURCES="${HARNESS_HOME}:${test_dir}/merge-local"
printf '%s' '{"demo":[{"type":"key","key":"cache-fixture"}]}' > "${HARNESS_HOME}/.auth-cache.json"
check harness_auth_refresh
check jq -e '.demo[0].key=="cache-fixture"' "${HARNESS_HOME}/.auth-cache.json"
printf '%s' '{"demo":[{"type":"key","key":"global-fixture"}]}' > "${HARNESS_HOME}/.auth.json"
printf '%s' '{"demo":[{"type":"key","key":"local-fixture"}]}' > "${test_dir}/merge-local/.auth.json"
check harness_auth_refresh
check jq -e '.demo[0].key=="local-fixture"' "${HARNESS_HOME}/.auth-cache.json"
check test -f "${HARNESS_HOME}/.auth-cache-managed"
printf '{broken' > "${test_dir}/merge-local/.auth.json"
if harness_auth_refresh > "${test_dir}/merge-output" 2> "${test_dir}/merge-error"; then echo 'invalid auth source accepted' >&2; exit 1; fi
check test ! -s "${test_dir}/merge-output"
check jq -e '.demo[0].key=="local-fixture"' "${HARNESS_HOME}/.auth-cache.json"
rm "${HARNESS_HOME}/.auth.json" "${test_dir}/merge-local/.auth.json"
check harness_auth_refresh
check jq -e '.=={}' "${HARNESS_HOME}/.auth-cache.json"
check test "$(stat -c %a "${HARNESS_HOME}/.auth-cache.json")" = 600

# Exercise the real auth command with an isolated CLI bootstrap and credential
# hook. Only provider/index/type metadata may appear in list output.
mkdir -p "${test_dir}/auth-repo/bin" "${test_dir}/auth-repo/lib"
cp "${repo}/lib/provider.sh" "${test_dir}/auth-repo/lib/provider.sh"
cat > "${test_dir}/auth-repo/bin/harness" <<'MOCK'
source "${HARNESS_ROOT}/lib/provider.sh"
_refresh_sources() { harness_auth_refresh; }
_die() { printf '%s\n' "$*" >&2; exit 1; }
call() { printf '%s' '{"type":"key","key":"entirely-local-fixture-secret"}'; }
MOCK
auth_command() { HARNESS_ROOT="${test_dir}/auth-repo" "${repo}/plugins/auth/commands/auth" "$@"; }
check auth_command set demo > "${test_dir}/auth-output" 2> "${test_dir}/auth-error"
check jq -e '.demo[0].key=="entirely-local-fixture-secret"' "${HARNESS_HOME}/.auth-cache.json"
check test "$(auth_command list)" = 'demo [0] type=key'
check test "$(auth_command list demo)" = '  [0] type=key'
check auth_command rm demo 0 > "${test_dir}/auth-output" 2> "${test_dir}/auth-error"
check jq -e '.demo==[]' "${HARNESS_HOME}/.auth-cache.json"
printf 'PASS: %s canonical transport checks\n' "$checks"
