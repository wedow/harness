# Provider discovery and canonical request/response validation.
# Sourced by the runner and provider executables; calls never mutate caller env.

_provider_conf() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 0
  sed -n "s/^${key}=//p" "${file}" | head -1
}

_provider_entry() {
  local name="$1" src i
  local -a sources=()
  IFS=':' read -ra sources <<< "${HARNESS_SOURCES:-}"
  for (( i=${#sources[@]}-1; i>=0; i-- )); do
    src="${sources[i]}"
    if [[ -x "${src}/providers/${name}" ]]; then
      printf '%s\n' "${src}/providers/${name}"; return 0
    fi
    if [[ -f "${src}/providers/${name}.conf" ]]; then
      printf '%s\n' "${src}/providers/${name}.conf"; return 0
    fi
  done
}

_provider_cached_key() {
  local name="$1" cache="${HARNESS_HOME:-${HOME}/.harness}/.auth-cache.json"
  [[ -f "${cache}" ]] || return 0
  jq -r --arg name "${name}" '.[$name][0] | .key // .token // .access_token // empty' "${cache}"
}

_provider_auth_unlock() {
  local fd="${_PROVIDER_AUTH_FD:-}"
  [[ "${fd}" =~ ^[0-9]+$ ]] || return 0
  if [[ "${_PROVIDER_AUTH_OWNER:-}" == "${BASHPID}" ]]; then
    if (( ${_PROVIDER_AUTH_DEPTH:-1} > 1 )); then
      _PROVIDER_AUTH_DEPTH=$(( _PROVIDER_AUTH_DEPTH-1 )); return 0
    fi
    flock -u "${fd}" || true
  fi
  # An inherited descriptor shares the parent's flock. Close our copy without
  # issuing LOCK_UN, which would release the parent's ownership too.
  exec {fd}>&-
  unset _PROVIDER_AUTH_FD _PROVIDER_AUTH_OWNER _PROVIDER_AUTH_DEPTH
}

# All OAuth providers update the same cache; serialize refreshes, then release
# before inference. Kernel locks recover when a credential owner disappears.
_provider_auth_lock() {
  local home_dir="${HARNESS_HOME:-${HOME}/.harness}" fd
  if [[ "${_PROVIDER_AUTH_FD:-}" =~ ^[0-9]+$ ]]; then
    if [[ "${_PROVIDER_AUTH_OWNER:-}" == "${BASHPID}" ]]; then
      _PROVIDER_AUTH_DEPTH=$(( ${_PROVIDER_AUTH_DEPTH:-1}+1 )); return 0
    fi
    _provider_auth_unlock
  fi
  mkdir -p "${home_dir}"
  exec {fd}>"${home_dir}/.auth-cache.lock"
  _PROVIDER_AUTH_FD="${fd}"; _PROVIDER_AUTH_OWNER="${BASHPID}"; _PROVIDER_AUTH_DEPTH=1
  trap '_PROVIDER_AUTH_DEPTH=1; _provider_auth_unlock' EXIT
  if ! flock -x -w 60 "${fd}"; then
    _provider_auth_unlock
    echo 'timed out waiting for OAuth credential refresh' >&2
    return 1
  fi
}

# Source credentials are authoritative once we manage this cache. A standalone
# cache remains usable for integrations that do not have .auth.json sources.
harness_auth_refresh() (
  local home_dir="${HARNESS_HOME:-${HOME}/.harness}" src merged='{}' found=false temp=''
  local -a sources=()
  mkdir -p "${home_dir}"
  _provider_auth_lock || return
  trap '_provider_auth_unlock; [[ -z "${temp:-}" ]] || rm -f "${temp}"' EXIT
  IFS=':' read -ra sources <<< "${HARNESS_SOURCES:-}"
  for src in "${sources[@]}"; do
    [[ -f "${src}/.auth.json" ]] || continue
    found=true
    if ! merged="$(printf '%s' "${merged}" | jq -cs --slurpfile auth "${src}/.auth.json" '
        if ($auth | length) == 1 and ($auth[0] | type) == "object" then .[0] * $auth[0]
        else error("invalid auth source") end' 2>/dev/null)"; then
      echo 'invalid credential source JSON' >&2; return 1
    fi
  done
  [[ "${found}" == true || -f "${home_dir}/.auth-cache-managed" ]] || return 0
  temp="$(mktemp "${home_dir}/.auth-cache.json.XXXXXX")"
  printf '%s\n' "${merged}" > "${temp}"
  chmod 600 "${temp}"
  mv -f "${temp}" "${home_dir}/.auth-cache.json"
  temp=''
  : > "${home_dir}/.auth-cache-managed"
  chmod 600 "${home_dir}/.auth-cache-managed"
)

_provider_ready() {
  local name="$1" entry="$2" auth_env key cache expiry refresh
  if [[ "${entry}" != *.conf ]]; then
    "${entry}" --ready >/dev/null 2>&1
    return
  fi
  auth_env="$(_provider_conf "${entry}" auth_env)"
  [[ -z "${auth_env}" || "${auth_env}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ -n "${auth_env}" && -n "${!auth_env:-}" ]] && return 0
  key="$(_provider_cached_key "${name}")"
  [[ -n "${key}" ]] || return 1
  cache="${HARNESS_HOME:-${HOME}/.harness}/.auth-cache.json"
  expiry="$(jq -r --arg name "${name}" '.[$name][0].expires_at // "0"' "${cache}")"
  refresh="$(jq -r --arg name "${name}" '.[$name][0].refresh_token // empty' "${cache}")"
  [[ -n "${refresh}" || "${expiry}" == 0 ]] || { [[ "${expiry}" =~ ^[0-9]+$ ]] && (( $(date +%s) < expiry )); }
}

provider_resolve() {
  local provider="${1-${HARNESS_PROVIDER:-}}" model="${2-${HARNESS_MODEL:-}}"
  local src file entry protocol binary candidate settings_provider
  local -a sources=()
  IFS=':' read -ra sources <<< "${HARNESS_SOURCES:-}"
  [[ -n "${HARNESS_SOURCES:-}" ]] || { echo 'no provider sources configured' >&2; return 1; }

  for (( candidate=${#sources[@]}-1; candidate>=0; candidate-- )); do
    file="${sources[candidate]}/settings.conf"
    [[ -f "${file}" ]] || continue
    settings_provider="$(_provider_conf "${file}" provider)"
    [[ -n "${provider}" ]] || provider="${settings_provider}"
    if [[ -z "${model}" && "${provider}" == "${settings_provider}" ]]; then
      model="$(_provider_conf "${file}" model)"
    fi
    break
  done

  if [[ -z "${provider}" ]]; then
    local -A names=()
    for src in "${sources[@]}"; do
      for file in "${src}/providers/"*; do
        [[ -x "${file}" || -f "${file}" && "${file}" == *.conf ]] || continue
        candidate="${file##*/}"; names["${candidate%.conf}"]=1
      done
    done
    while IFS= read -r candidate; do
      [[ -n "${candidate}" ]] || continue
      entry="$(_provider_entry "${candidate}")"
      if _provider_ready "${candidate}" "${entry}"; then provider="${candidate}"; break; fi
    done < <(printf '%s\n' "${!names[@]}" | sort)
  fi
  [[ "${provider}" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo 'no ready provider found; select a provider or configure auth' >&2; return 1; }
  entry="$(_provider_entry "${provider}")"
  [[ -n "${entry}" ]] || { echo "provider '${provider}' not found" >&2; return 1; }
  protocol="${provider}"
  if [[ "${entry}" == *.conf ]]; then
    protocol="$(_provider_conf "${entry}" protocol)"
    [[ "${protocol}" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid protocol for provider '${provider}'" >&2; return 1; }
    [[ -n "${model}" ]] || model="$(_provider_conf "${entry}" model)"
    binary="$(_provider_entry "${protocol}")"
    [[ -x "${binary}" && "${binary}" != *.conf ]] || { echo "provider protocol '${protocol}' not found" >&2; return 1; }
  else
    binary="${entry}"
    [[ "${provider}" != claude ]] || protocol=anthropic
  fi
  [[ -n "${model}" ]] || model="$("${binary}" --defaults | sed -n 's/^model=//p' | head -1)"
  [[ -n "${model}" ]] || { echo "no model configured for '${provider}'" >&2; return 1; }
  jq -cn --arg provider "${provider}" --arg model "${model}" --arg binary "${binary}" --arg protocol "${protocol}" \
    '{provider:$provider,model:$model,binary:$binary,protocol:$protocol}'
}

_provider_validate_request() {
  jq -ce -s '
    def nonempty: type == "string" and length > 0;
    def block: if .type == "text" then (.text | type == "string")
      elif .type == "tool_call" then (.id | nonempty) and (.name | nonempty) and (.input | type == "object")
      else false end;
    if length != 1 then error("expected one request") else .[0] end
    | if type == "object" and (.messages | type == "array")
      and (.model == null or (.model | type == "string"))
      and (.system == null or (.system | type == "string" or type == "array"))
      and (.tools == null or ((.tools | type == "array") and all(.tools[]; (.name | nonempty) and (.description | type == "string") and (.input_schema | type == "object"))))
      and all(.messages[]; if .role == "user" then (.content | type == "string")
        elif .role == "assistant" then (.blocks | type == "array") and all(.blocks[]; block) and (.provider_state == null or (.provider_state | type == "object"))
        elif .role == "tool" then (.call_id | nonempty) and (.name | nonempty) and (.content | type == "string") and (.error == null or (.error | type == "boolean"))
        else false end)
      then . else error("invalid canonical request") end
    | [.messages[] | select(.role == "assistant") | .blocks[] | select(.type == "tool_call") | .id] as $ids
    | if ($ids | unique | length) == ($ids | length) then . else error("duplicate tool call IDs") end
  ' 2>/dev/null || { echo 'invalid canonical provider request' >&2; return 1; }
}

_provider_validate_response() {
  jq -ce -s '
    def nonempty: type == "string" and length > 0;
    if length != 1 then error("expected one response") else .[0] end
    | if type != "object" or (.blocks | type != "array") then error("invalid response") else . end
    | if all(.blocks[]; if .type == "text" then (.text | type == "string")
      elif .type == "tool_call" then (.id | nonempty) and (.name | nonempty) and (.input | type == "object")
      else false end) then . else error("malformed response block or tool arguments") end
    | [.blocks[] | select(.type == "tool_call") | .id] as $ids
    | if ($ids | unique | length) != ($ids | length) then error("duplicate tool call IDs") else . end
    | if (.stop == "tool_calls" and ($ids | length) > 0)
      or ((.stop == "end" or .stop == "length") and ($ids | length) == 0)
      then . else error("invalid or inconsistent stop reason") end
    | if any(.blocks[]; .type == "tool_call" or (.text | test("\\S"))) then . else error("empty provider response") end
    | if (.usage | type == "object") and all(.usage.input_tokens,.usage.output_tokens,.usage.total_tokens,.usage.cache_read_input_tokens,.usage.cache_creation_input_tokens;
        . == null or (type == "number" and . >= 0 and floor == .))
      then . else error("invalid response usage") end
    | .usage as $u
    | if $u.input_tokens != null and
        (($u.cache_read_input_tokens != null and $u.cache_read_input_tokens > $u.input_tokens)
         or ($u.cache_creation_input_tokens != null and $u.cache_creation_input_tokens > $u.input_tokens)
         or ($u.cache_read_input_tokens != null and $u.cache_creation_input_tokens != null and ($u.cache_read_input_tokens+$u.cache_creation_input_tokens) > $u.input_tokens))
      then error("cache tokens exceed total input") else . end
    | if $u.total_tokens != null and $u.input_tokens != null and $u.output_tokens != null and $u.total_tokens != ($u.input_tokens+$u.output_tokens)
      then error("inconsistent total usage") else . end
  ' 2>/dev/null || { echo 'invalid provider response: empty, malformed, duplicate calls, inconsistent stop reason, or invalid token usage' >&2; return 1; }
}

provider_call() (
  local request resolved provider model binary protocol entry upper key auth_env value field
  request="$(_provider_validate_request)" || return
  model="${2-$(printf '%s' "${request}" | jq -r '.model // empty')}"
  [[ -n "${model}" || $# -ge 2 ]] || model="${HARNESS_MODEL:-}"
  resolved="$(provider_resolve "${1-${HARNESS_PROVIDER:-}}" "${model}")" || return
  provider="$(printf '%s' "${resolved}" | jq -r '.provider')"
  model="$(printf '%s' "${resolved}" | jq -r '.model')"
  binary="$(printf '%s' "${resolved}" | jq -r '.binary')"
  protocol="$(printf '%s' "${resolved}" | jq -r '.protocol')"
  entry="$(_provider_entry "${provider}")"
  export HARNESS_PROVIDER="${provider}" HARNESS_MODEL="${model}"
  unset HARNESS_TOOL_FIFO
  if [[ "${entry}" == *.conf ]]; then
    upper="$(printf '%s' "${protocol}" | tr '[:lower:]' '[:upper:]')"
    [[ "${upper}" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo 'invalid variant protocol' >&2; return 1; }
    for field in url max_tokens temperature top_p top_k prompt_cache; do
      value="$(_provider_conf "${entry}" "${field}")"
      [[ -n "${value}" ]] || continue
      key="$(printf '%s' "${field}" | tr '[:lower:]' '[:upper:]')"
      [[ "${field}" != url ]] || key=API_URL
      export "${upper}_${key}=${value}"
    done
    auth_env="$(_provider_conf "${entry}" auth_env)"
    [[ -z "${auth_env}" || "${auth_env}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo 'invalid variant auth environment name' >&2; return 1; }
    key=""
    [[ -z "${auth_env}" ]] || key="${!auth_env:-}"
    [[ -n "${key}" ]] || key="$(_provider_cached_key "${provider}")"
    [[ -z "${auth_env}" || -n "${key}" ]] || { echo "credentials missing for '${provider}'" >&2; return 1; }
    unset "${upper}_AUTH_HEADER" "${upper}_API_KEY"
    [[ -z "${key}" ]] || export "${upper}_API_KEY=${key}"
  fi
  local response
  response="$(printf '%s' "${request}" | jq -c --arg model "${model}" '.model=$model' | "${binary}")" || return
  printf '%s' "${response}" | _provider_validate_response
)
