#!/usr/bin/env bash
# stream-renderer — shared terminal renderer for stream events.
# Source this and call _render_stream <stream_file> <agent_pid>.
# Requires: jq on PATH.

_render_stream() {
  local stream_file="$1" agent_pid="$2"
  # Use exec fd + process substitution to avoid pipe subshell.
  exec 5< <(tail -c +1 -f "${stream_file}" 2>/dev/null)
  local tail_pid=$!
  local event etype last_type=""
  while true; do
    if ! IFS= read -t 2 -r event <&5; then
      kill -0 "${agent_pid}" 2>/dev/null || break
      continue
    fi
    etype="$(echo "${event}" | jq -r '.type // empty' 2>/dev/null)" || continue
    # Extract text with sentinel to preserve trailing newlines.
    local _t
    case "${etype}" in
      text)
        [[ "${last_type}" == "thinking" ]] && printf '\n'
        _t="$(echo "${event}" | jq -j '.text'; printf x)"; printf '%s' "${_t%x}"
        last_type=text ;;
      thinking)
        _t="$(echo "${event}" | jq -j '.text'; printf x)"; printf '\033[2m%s\033[0m' "${_t%x}"
        last_type=thinking ;;
      tool_start)
        local _name _input _cmd
        _name="$(echo "${event}" | jq -r '.name')"
        _input="$(echo "${event}" | jq -r '.input // empty')"
        printf '\n\033[90m[tool: %s]\033[0m' "${_name}"
        # Show arguments so user knows what's happening
        if [[ "${_name}" == "bash" ]]; then
          _cmd="$(echo "${_input}" | jq -r '.command // empty')"
          [[ -n "${_cmd}" ]] && printf ' \033[2m%s\033[0m' "${_cmd}"
        elif [[ -n "${_input}" && "${_input}" != "{}" && "${_input}" != "null" ]]; then
          local _args
          _args="$(echo "${_input}" | jq -r 'to_entries | map("\(.key)=\(.value | tostring)") | join(", ")')"
          [[ -n "${_args}" && "${_args}" != "" ]] && printf ' \033[2m(%s)\033[0m' "${_args}"
        fi
        printf ' '
        last_type=tool_start ;;
      tool_done)
        if [[ "$(echo "${event}" | jq -r '.error')" == "true" ]]; then
          printf '\n\033[31m(error)\033[0m\n'
        else
          printf '\n\033[32m(done)\033[0m\n'
        fi
        last_type=tool_done ;;
      tool_output)
        _t="$(echo "${event}" | jq -j '.text'; printf x)"; printf '\n%s' "${_t%x}"
        last_type=tool_output ;;
      error)
        printf '\n\033[31merror: %s\033[0m\n' "$(echo "${event}" | jq -r '.message')"
        last_type=error ;;
      done) break ;;
    esac
  done
  exec 5<&-
  kill "${tail_pid}" 2>/dev/null || true
  wait "${tail_pid}" 2>/dev/null || true
}