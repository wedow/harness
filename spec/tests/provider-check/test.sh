#!/usr/bin/env bash
# Provider diagnostics use a canonical fixture; no network or real credentials.
# shellcheck disable=SC1091,SC2154,SC2016
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
repo="$(cd "${HARNESS_ROOT}" && pwd)"
origin="${_tmpdir}/origin"
mkdir -p "${origin}/home/providers" "${origin}/home/tools" "${origin}/data" "${origin}/cwd/.harness/providers" "${_tmpdir}/deny-network"
printf '%s\n' '{"fixture":[{"key":"PRIVATE_FIXTURE_KEY"}]}' > "${origin}/home/.auth-cache.json"
printf '%s\n' '{"fixture":[{"key":"PRIVATE_SOURCE_KEY"}]}' > "${origin}/home/.auth.json"
printf 'permanent chat sentinel\n' > "${origin}/data/state.json"
printf 'working directory sentinel\n' > "${origin}/cwd/sentinel"
printf 'protocol=fixture_check\nmodel=home-model\nauth_env=FIXTURE_CHECK_KEY\nmax_tokens=99999\n' > "${origin}/home/providers/fixture.conf"
printf 'protocol=fixture_check\nmodel=local-model\nauth_env=FIXTURE_CHECK_KEY\nmax_tokens=99999\n' > "${origin}/cwd/.harness/providers/fixture.conf"
cat > "${origin}/home/providers/fixture_check" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --defaults) printf 'model=fixture-model\n'; exit 0 ;;
  --ready) exit 0 ;;
esac
[[ $# == 0 ]]
[[ "${HARNESS_HOME}" != "${ORIGIN}/home" && "${HARNESS_DATA}" != "${ORIGIN}/data" && "${HARNESS_CWD}" != "${ORIGIN}/cwd" ]]
[[ "${HARNESS_SOURCES}" == "${HARNESS_HOME}" && "${FIXTURE_CHECK_MAX_TOKENS}" == 4096 && "${HARNESS_CURL_MAX_TIME}" == 120 ]]
[[ "${ANTHROPIC_MAX_TOKENS}" == 4096 && "${OPENAI_MAX_TOKENS}" == 4096 && "${CHATGPT_MAX_TOKENS}" == 4096 ]]
[[ "${FIXTURE_CHECK_API_KEY}" == PRIVATE_FIXTURE_KEY ]]
[[ "${HARNESS_MODEL}" == "${EXPECTED_MODEL}" && -d "${HARNESS_ROOT}/lib" && "${HARNESS_ROOT}" == "${HARNESS_DATA}/code/"* ]]
request="$(cat)"
printf '%s\n' "${request}" >> "${CHECK_CAPTURE}/requests.jsonl"
number="$(wc -l < "${CHECK_CAPTURE}/requests.jsonl")"
printf '%s\n' "${HARNESS_HOME}" > "${CHECK_CAPTURE}/private-home"
[[ "${number}" -le 5 ]]
# Simulate private OAuth/cache/data writes. Their original counterparts must stay.
printf '{"fixture":[{"key":"PRIVATE_FIXTURE_KEY"}],"refreshed":true}\n' > "${HARNESS_HOME}/.auth-cache.json"
printf '{"private_refresh":true}\n' > "${HARNESS_HOME}/.auth.json"
printf 'temporary data\n' > "${HARNESS_DATA}/sentinel"
printf 'temporary cwd\n' > "${HARNESS_CWD}/sentinel"
if [[ "${CHECK_FAIL:-}" == transport ]]; then
  printf 'PRIVATE_TRANSPORT_ERROR\n' >&2
  printf 'PRIVATE_MALFORMED_BODY\n'
  exit 1
fi
if [[ "${number}" == 5 ]]; then
  printf '%s' "${request}" | jq -e '
    .messages[-3].role=="assistant" and .messages[-3].provider_state.opaque=="PRIVATE_NATIVE_CONTINUATION" and
    .messages[-2].role=="tool" and .messages[-2].call_id==.messages[-3].blocks[-1].id and
    .messages[-2].name=="diagnostic_echo" and (.messages[-2].content|fromjson|.result)=="HARNESS_PROVIDER_CHECK_OK"' >/dev/null
fi
jq -cn --argjson number "${number}" --arg fail "${CHECK_FAIL:-}" '
  (if $number==1 then 0 else 1000 end) as $read |
  {blocks:(if $number==4 and $fail!="tool" then
      [{type:"text",text:"PRIVATE_RESPONSE_TEXT"},{type:"tool_call",id:"diagnostic-call-fixed",name:"diagnostic_echo",input:{value:"HARNESS_PROVIDER_CHECK_TOOL"}}]
    else [{type:"text",text:(if $fail=="marker" then "PRIVATE_WRONG_MARKER" else "HARNESS_PROVIDER_CHECK_OK" end)}] end),
   stop:(if $number==4 and $fail!="tool" then "tool_calls" else "end" end),
   usage:{input_tokens:(if $number>2 then 1008 else 1000 end),output_tokens:1,total_tokens:(if $number>2 then 1009 else 1001 end),
     cache_read_input_tokens:(if $number==4 then null else $read end),cache_creation_input_tokens:(if $number==1 then 1000 elif $number==4 then null else 0 end)},
   provider_state:{protocol:"fixture",opaque:"PRIVATE_NATIVE_CONTINUATION"}}'
PROVIDER
cat > "${origin}/home/tools/diagnostic_echo" <<'TOOL'
#!/usr/bin/env bash
printf 'a tool must never run\n' > "${ORIGIN}/tool-was-run"
exit 99
TOOL
cat > "${_tmpdir}/deny-network/curl" <<'CURL'
#!/usr/bin/env bash
echo 'unexpected network access in provider-check fixture' >&2
exit 99
CURL
# Snapshot creation can read the original plugin directory as a whole, but
# inherited source paths must never recopy individual live provider files.
export CHECK_REAL_CP="$(command -v cp)" CHECK_REPO="${repo}"
cat > "${_tmpdir}/deny-network/cp" <<'COPY'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "${argument}" == "${CHECK_REPO}/plugins/"* ]]; then
    echo 'attempted to recopy an unpinned bundled provider' >&2
    exit 99
  fi
done
exec "${CHECK_REAL_CP}" "$@"
COPY
chmod +x "${origin}/home/providers/fixture_check" "${origin}/home/tools/diagnostic_echo" "${_tmpdir}/deny-network/curl" "${_tmpdir}/deny-network/cp"
export ORIGIN="${origin}" HARNESS_HOME="${origin}/home" HARNESS_DATA="${origin}/data" HARNESS_CWD="${origin}/cwd"
export HARNESS_SOURCES="${repo}/plugins/anthropic:${origin}/home:${origin}/cwd/.harness" EXPECTED_MODEL=local-model
export PATH="${_tmpdir}/deny-network:${PATH}"
before="$(find "${origin}" -type f -print0 | sort -z | xargs -0 sha256sum)"

run_check() {
  local name="$1" fail="${2:-}" model="${3:-}"
  CHECK_CAPTURE="${_tmpdir}/${name}"; export CHECK_CAPTURE CHECK_FAIL="${fail}"
  mkdir -p "${CHECK_CAPTURE}"
  if [[ -n "${model}" ]]; then "${repo}/scripts/check-provider.sh" fixture "${model}"
  else "${repo}/scripts/check-provider.sh" fixture; fi
}

run_check success > "${_tmpdir}/success-report" 2> "${_tmpdir}/success-error"
[[ ! -s "${_tmpdir}/success-error" ]]
jq -e '.success and .provider=="fixture" and .model=="local-model" and (.code_digest|test("^[0-9a-f]{64}$")) and
  ([.calls[].phase]==["warm","repeat","appended","tool_call","tool_result"]) and
  (.calls|length)==5 and all(.calls[];.success and .elapsed_s>=0 and (.prefix_hash|test("^[0-9a-f]{64}$"))) and
  .calls[0].prefix_bytes>16000 and .calls[0].prefix_bytes<20000 and
  .calls[0].prefix_hash==.calls[1].prefix_hash and .calls[2].prefix_hash!=.calls[1].prefix_hash and
  .calls[0].cache_read_ratio==0 and .calls[1].cache_read_ratio==1 and
  .calls[3].usage.cache_read_input_tokens==null and .calls[3].cache_read_ratio==null' "${_tmpdir}/success-report" >/dev/null
jq -se '(.[0].messages[0].content|rtrimstr("</chat>")) as $prefix |
  length==5 and .[0]==.[1] and
  (.[2].messages[0].content|startswith($prefix)) and
  (.[0].messages[0].content|split("\n")|length)==130 and
  .[4].messages[-2].call_id==.[4].messages[-3].blocks[-1].id' "${_tmpdir}/success/requests.jsonl" >/dev/null
[[ ! -d "$(cat "${_tmpdir}/success/private-home")" ]]
if rg -q 'PRIVATE_|blocks|provider_state|headers|api_key|access_token' "${_tmpdir}/success-report"; then echo 'FAIL: private response or credential data leaked into report' >&2; exit 1; fi

for fail in marker tool transport; do
  if run_check "failure-${fail}" "${fail}" > "${_tmpdir}/${fail}-report" 2> "${_tmpdir}/${fail}-error"; then
    echo "FAIL: ${fail} unexpectedly passed" >&2; exit 1
  fi
  jq -e '.success==false and .calls[-1].success==false' "${_tmpdir}/${fail}-report" >/dev/null
  expected=1; [[ "${fail}" != tool ]] || expected=4
  assert_eq "${fail} stops remaining calls" "$(jq '.calls|length' "${_tmpdir}/${fail}-report")" "${expected}"
  [[ ! -s "${_tmpdir}/${fail}-error" ]]
  if rg -q PRIVATE_ "${_tmpdir}/${fail}-report"; then echo 'FAIL: failure body leaked into report' >&2; exit 1; fi
done
EXPECTED_MODEL=explicit-model run_check model '' explicit-model > "${_tmpdir}/model-report"
assert_json '.model' "$(cat "${_tmpdir}/model-report")" explicit-model
after="$(find "${origin}" -type f -print0 | sort -z | xargs -0 sha256sum)"
assert_eq 'origin credentials, provider variants, tools, chat data, and cwd remain unchanged' "${after}" "${before}"
[[ ! -e "${origin}/tool-was-run" ]]
printf 'PASS: five synthetic calls, cache counters, stable append prefix, native tool identity, isolation, and failure reports\n'
