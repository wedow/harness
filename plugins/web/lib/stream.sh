# shellcheck shell=bash
# Datastar receives complete journal batches, never provider token fragments.

# STREAM_AFTER is consumed by the HTTP handler after this parser returns.
# shellcheck disable=SC2034
_stream_query() {
  local query="$1" pair key value header_id="${HTTP_HEADERS[last-event-id]:-}"
  local -a pairs=()
  local -A seen=()
  STREAM_AFTER=0
  (( ${#query}<=16384 )) || return 1
  if [[ -n "${query}" ]]; then
    IFS='&' read -r -a pairs <<< "${query}"
    for pair in "${pairs[@]}"; do
      key="${pair%%=*}"; value="${pair#*=}"
      [[ "${pair}" == *=* && -n "${key}" && -z "${seen[$key]+x}" ]] || return 1
      seen["${key}"]=1
      case "${key}" in
        after)
          [[ "${value}" =~ ^[0-9]{1,12}$ ]] || return 1
          STREAM_AFTER=$((10#${value})) ;;
        datastar) (( ${#value}<=8192 )) || return 1 ;; # Opaque, never decoded or evaluated.
        *) return 1 ;;
      esac
    done
  fi
  if [[ -n "${HTTP_HEADERS[last-event-id]+x}" ]]; then
    [[ "${header_id}" =~ ^[0-9]{1,12}$ ]] || return 1
    STREAM_AFTER=$((10#${header_id}))
  fi
}

_stream_frame() {
  local feed="$1" cursor signals
  cursor="$(printf '%s' "${feed}" | jq -r '.cursor')" || return 1
  signals="$(printf '%s' "${feed}" | jq -c '{_chatFeed:tojson}')" || return 1
  printf 'event: datastar-patch-signals\nid: %s\ndata: signals %s\n\n' "${cursor}" "${signals}"
}

_stream_fingerprint() {
  # One metadata read catches atomic projections/publications and queue changes.
  stat -c '%i:%s:%y:%z' "${HARNESS_DATA}/HEAD" "${HARNESS_DATA}/state.json" \
    "${HARNESS_DATA}/components" "${HARNESS_DATA}/queue/requests/0-turn" \
    "${HARNESS_DATA}/queue/requests/1-summary" "${HARNESS_DATA}/queue/jobs" 2>/dev/null || true
}

_web_stream() {
  local cursor="$1" feed status previous_status fingerprint previous_fingerprint head rc ignored
  local parent="${PPID}" parent_start next_status next_heartbeat
  trap 'exit 0' PIPE TERM INT
  parent_start="$(process_start "${parent}")" || return 0
  if (( cursor>0 )); then feed="$(store_feed_forward "${cursor}")" || return 1
  else feed="$(store_feed 0 0 100)" || return 1; fi
  respond_stream
  _stream_frame "${feed}" || return 0
  # Advancing only after the complete frame means a partial socket write cannot
  # acknowledge a batch. Browser Last-Event-ID advances at the SSE blank line.
  cursor="$(printf '%s' "${feed}" | jq -r '.cursor')"
  previous_status="$(printf '%s' "${feed}" | jq -c '.status')"
  previous_fingerprint="$(_stream_fingerprint)"
  next_status=$((SECONDS+2)); next_heartbeat=$((SECONDS+30))
  while :; do
    head="$(cat "${HARNESS_DATA}/HEAD")" || return 0
    if (( head>cursor )); then
      feed="$(store_feed_forward "${cursor}")" || return 0
      _stream_frame "${feed}" || return 0
      cursor="$(printf '%s' "${feed}" | jq -r '.cursor')"
      previous_status="$(printf '%s' "${feed}" | jq -c '.status')"
      previous_fingerprint="$(_stream_fingerprint)"
      next_status=$((SECONDS+2)); next_heartbeat=$((SECONDS+30))
      continue
    fi
    fingerprint="$(_stream_fingerprint)"
    if [[ "${fingerprint}" != "${previous_fingerprint}" ]] || (( SECONDS>=next_status )); then
      # Lock/PID changes need no journal write, so periodically check their live
      # status as well. Unchanged status creates no network frame.
      process_alive "${parent}" "${parent_start}" || return 0
      status="$(store_status)" || return 0
      if [[ "${status}" != "${previous_status}" ]]; then
        feed="$(printf '%s' "${status}" | jq -c --argjson cursor "${cursor}" '{events:[],cursor:$cursor,has_more:false,status:.}')" || return 0
        _stream_frame "${feed}" || return 0
        previous_status="${status}"; next_heartbeat=$((SECONDS+30))
      fi
      previous_fingerprint="${fingerprint}"; next_status=$((SECONDS+2))
    fi
    if (( SECONDS>=next_heartbeat )); then
      printf ': keepalive\n\n' || return 0
      next_heartbeat=$((SECONDS+30))
    fi
    # The socket is also our wait primitive: EOF detects a disconnected peer
    # without heartbeats, while a timeout lets us inspect local durable state.
    # The read value is intentionally discarded; a GET stream has no next body.
    # shellcheck disable=SC2034
    if IFS= read -r -t 0.5 ignored; then return 0
    else rc=$?; (( rc>128 )) || return 0; fi
  done
}
