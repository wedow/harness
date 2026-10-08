#!/usr/bin/env bash
# Explicit, synthetic provider diagnostics. Never runs a returned tool.
# shellcheck disable=SC1091,SC2016
set +x
set -euo pipefail
umask 077
[[ $# -ge 1 && $# -le 2 && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
  printf 'usage: scripts/check-provider.sh PROVIDER [MODEL]\n' >&2; exit 2;
}

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
caller_home="${HARNESS_HOME:-${HOME}/.harness}"
caller_sources="${HARNESS_SOURCES:-}"
provider="$1"; model="${2:-}"
diagnostic_dir="$(mktemp -d)"
trap 'rm -rf "${diagnostic_dir}"' EXIT
export HARNESS_ROOT="${repo}" HARNESS_LIVE_ROOT="${repo}"
export HARNESS_HOME="${diagnostic_dir}/home" HARNESS_DATA="${diagnostic_dir}/data" HARNESS_CWD="${diagnostic_dir}/cwd"
export HARNESS_PROVIDER="${provider}" HARNESS_MODEL="${model}" HARNESS_ACTOR=main
unset HARNESS_SESSION HARNESS_TOOL_FIFO
mkdir -p "${HARNESS_HOME}/providers" "${HARNESS_DATA}/code" "${HARNESS_CWD}"
# Only the caller's existing cache is read. Refreshes can replace this copy.
[[ ! -f "${caller_home}/.auth-cache.json" ]] || cp "${caller_home}/.auth-cache.json" "${HARNESS_HOME}/.auth-cache.json"
source "${repo}/lib/bootstrap.sh"
if ! HARNESS_ROOT="$(code_snapshot 2>"${diagnostic_dir}/error")"; then
  # Sourced helper locals change only their subshell; keep the CLI selections.
  # shellcheck disable=SC2031
  jq -n --arg provider "${provider}" --arg model "${model}" '{provider:$provider,model:(if $model=="" then null else $model end),code_digest:null,calls:[],success:false}'
  exit 1
fi
export HARNESS_ROOT
code_digest="${HARNESS_ROOT##*/}"
for directory in "${HARNESS_ROOT}"/plugins/*/providers; do
  [[ ! -d "${directory}" ]] || cp -a "${directory}/." "${HARNESS_HOME}/providers/"
done
# Freeze executable/variant overrides without retaining their auth/source dirs.
override_sources=("${caller_home}")
IFS=: read -r -a configured_sources <<< "${caller_sources}"
override_sources+=("${configured_sources[@]}")
for directory in "${override_sources[@]}"; do
  # Inherited discovery paths must use the same pinned bundled generation.
  if [[ "${directory}" == "${repo}/plugins/"* ]]; then
    directory="${HARNESS_ROOT}${directory#"${repo}"}"
  fi
  [[ -n "${directory}" && -d "${directory}/providers" ]] || continue
  for file in "${directory}/providers/"*; do
    [[ -f "${file}" && ( -x "${file}" || "${file}" == *.conf ) ]] || continue
    cp -L -p "${file}" "${HARNESS_HOME}/providers/${file##*/}"
  done
done
export HARNESS_SOURCES="${HARNESS_HOME}"
# Variant configuration otherwise overrides transport environment budgets.
for file in "${HARNESS_HOME}/providers/"*.conf; do
  [[ -f "${file}" ]] || continue
  sed '/^max_tokens=/d' "${file}" > "${file}.tmp"
  printf 'max_tokens=4096\n' >> "${file}.tmp"
  mv "${file}.tmp" "${file}"
done
export ANTHROPIC_MAX_TOKENS=4096 OPENAI_MAX_TOKENS=4096 CHATGPT_MAX_TOKENS=4096
export HARNESS_CURL_MAX_TIME=120 HARNESS_CURL_SPEED_TIME=60 HARNESS_THINKING=off
source "${HARNESS_ROOT}/lib/provider.sh"
: > "${diagnostic_dir}/calls.jsonl"

report() {
  # Provider helper subshells do not change the selected outer report values.
  # shellcheck disable=SC2031
  jq -cs --arg provider "${provider}" --arg model "${model}" --arg code "${code_digest}" '
    {provider:$provider,model:(if $model=="" then null else $model end),code_digest:$code,
     calls:.,success:(length==5 and all(.[];.success))}' "${diagnostic_dir}/calls.jsonl"
}
# Explicit resolution returns JSON; its local provider/model are isolated.
# shellcheck disable=SC2031
if ! resolved="$(provider_resolve "${provider}" "${model}" 2>"${diagnostic_dir}/error")"; then report; exit 1; fi
model="$(printf '%s' "${resolved}" | jq -r '.model')"
# Publish the returned selection deliberately; helper env changes were local.
# shellcheck disable=SC2031
export HARNESS_MODEL="${model}"

# This saved view is deterministic: 128 ASCII lines, approximately 16 KiB.
jq -nr '"<chat>\n" + ([range(0;128) | tostring+"+1|Synthetic diagnostic memory. No user content, files, credentials, or actionable task. " + ("0123456789"*3)] | join("\n")) + "\n</chat>"' > "${diagnostic_dir}/view"
jq -nr '"<chat>\n128+1|Appended synthetic diagnostic memory; all prior lines stay identical.\n</chat>"' > "${diagnostic_dir}/append"
jq -n --arg model "${model}" --rawfile view "${diagnostic_dir}/view" '
  {model:$model,system:"This is a synthetic provider diagnostic. Follow only the instruction after the chat view. The diagnostic_echo tool has no side effects.",
   tools:[{name:"diagnostic_echo",description:"Return a supplied diagnostic value; no external action.",input_schema:{type:"object",properties:{value:{type:"string"}},required:["value"],additionalProperties:false}}],
   messages:[{role:"user",content:($view|rtrimstr("\n"))},{role:"user",content:"Reply with exactly HARNESS_PROVIDER_CHECK_OK. Do not call tools."}]}' > "${diagnostic_dir}/request.json"

run_call() {
  local phase="$1" expected="$2" start elapsed hash bytes ok=false response="${diagnostic_dir}/response.json"
  jq -jr '.system+"\n"+(.tools|tojson)+"\n"+(.messages[0].content|rtrimstr("</chat>"))' "${diagnostic_dir}/request.json" > "${diagnostic_dir}/prefix"
  hash="$(sha256sum "${diagnostic_dir}/prefix")"; hash="${hash%% *}"
  bytes="$(wc -c < "${diagnostic_dir}/prefix")"
  start="$(date +%s.%N)"
  if timeout 125 bash -c 'source "${HARNESS_ROOT}/lib/provider.sh"; provider_call "${HARNESS_PROVIDER}" "${HARNESS_MODEL}"' \
    < "${diagnostic_dir}/request.json" > "${response}" 2> "${diagnostic_dir}/error"; then
    if [[ "${expected}" == tool ]]; then
      if jq -e '.stop=="tool_calls" and (.provider_state|type)=="object" and
        ([.blocks[]|select(.type=="tool_call")]|length)==1 and
        any(.blocks[];.type=="tool_call" and .name=="diagnostic_echo" and .input=={value:"HARNESS_PROVIDER_CHECK_TOOL"})' "${response}" >/dev/null; then ok=true; fi
    elif jq -e '.stop=="end" and ([.blocks[]|select(.type=="text")|.text]|join("\n")|test("^\\s*HARNESS_PROVIDER_CHECK_OK\\s*$"))' "${response}" >/dev/null; then ok=true; fi
  fi
  elapsed="$(jq -n --argjson start "${start}" --argjson end "$(date +%s.%N)" '((($end-$start)*1000)|round)/1000')"
  # A failed transport can leave invalid/partial stdout; do not report its body.
  if ! jq -e '.usage|type=="object"' "${response}" >/dev/null 2>&1; then printf '{}\n' > "${response}"; fi
  jq -c --arg phase "${phase}" --arg hash "${hash}" --argjson bytes "${bytes}" --argjson elapsed "${elapsed}" --argjson ok "${ok}" '
    .usage as $u | {phase:$phase,prefix_hash:$hash,prefix_bytes:$bytes,elapsed_s:$elapsed,stop:(.stop // null),
      usage:{input_tokens:$u.input_tokens,output_tokens:$u.output_tokens,total_tokens:$u.total_tokens,
        cache_read_input_tokens:$u.cache_read_input_tokens,cache_creation_input_tokens:$u.cache_creation_input_tokens},
      cache_read_ratio:(if $u.cache_read_input_tokens!=null and $u.input_tokens!=null and $u.input_tokens>0 then $u.cache_read_input_tokens/$u.input_tokens else null end),success:$ok}' "${response}" >> "${diagnostic_dir}/calls.jsonl"
  [[ "${ok}" == true ]]
}

run_call warm text || { report; exit 1; }
run_call repeat text || { report; exit 1; }
jq --rawfile extra "${diagnostic_dir}/append" '.messages[0].content |= (rtrimstr("</chat>")+($extra|ltrimstr("<chat>\n")|rtrimstr("\n")))' "${diagnostic_dir}/request.json" > "${diagnostic_dir}/next.json"
mv "${diagnostic_dir}/next.json" "${diagnostic_dir}/request.json"
run_call appended text || { report; exit 1; }
jq '.messages[-1].content="Call diagnostic_echo exactly once with value HARNESS_PROVIDER_CHECK_TOOL. Do not answer with text instead."' "${diagnostic_dir}/request.json" > "${diagnostic_dir}/next.json"
mv "${diagnostic_dir}/next.json" "${diagnostic_dir}/request.json"
run_call tool_call tool || { report; exit 1; }
# Use the returned blocks and opaque native state, plus one matching fake result.
jq --slurpfile response "${diagnostic_dir}/response.json" '
  ($response[0].blocks[]|select(.type=="tool_call")) as $call |
  .messages += [{role:"assistant",blocks:$response[0].blocks,provider_state:$response[0].provider_state},
    {role:"tool",call_id:$call.id,name:$call.name,content:"{\"value\":\"HARNESS_PROVIDER_CHECK_TOOL\",\"result\":\"HARNESS_PROVIDER_CHECK_OK\"}",error:false},
    {role:"user",content:"The supplied tool result is synthetic. Reply with exactly HARNESS_PROVIDER_CHECK_OK. Call no more tools."}]' "${diagnostic_dir}/request.json" > "${diagnostic_dir}/next.json"
mv "${diagnostic_dir}/next.json" "${diagnostic_dir}/request.json"
run_call tool_result text || { report; exit 1; }
report
