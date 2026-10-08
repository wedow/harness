# http.sh — minimal HTTP primitives for the serve command.
# Per-connection process model: stdin/stdout is the socket.
# Handlers set STATUS / HEADERS[] / BODY; respond_request serializes.

STATUS=200
HEADERS=()
declare -A HTTP_HEADERS=() # request headers (set by the handler; read for negotiation)
BODY=""

respond()  { printf 'HTTP/1.1 %s %s\r\n' "$1" "$2"; }
header()   { printf '%s: %s\r\n' "$1" "$2"; }
end_headers() { printf '\r\n'; }

_accepts_gzip() {
  local value="${HTTP_HEADERS[accept-encoding]:-}" item coding param q
  local gzip_seen=false gzip_ok=false wildcard_ok=false
  local -a entries params
  [[ -n "${value}" ]] || return 1
  IFS=',' read -r -a entries <<< "${value}"
  for item in "${entries[@]}"; do
    coding="${item%%;*}"
    [[ "${coding,,}" =~ ^[[:space:]]*(gzip|\*)[[:space:]]*$ ]] || continue
    coding="${BASH_REMATCH[1]}"
    q=1
    if [[ "${item}" == *';'* ]]; then
      IFS=';' read -r -a params <<< "${item#*;}"
      for param in "${params[@]}"; do
        param="${param,,}"
        if [[ "${param}" =~ ^[[:space:]]*q[[:space:]]*= ]]; then
          if [[ "${param}" =~ ^[[:space:]]*q[[:space:]]*=[[:space:]]*(0(\.[0-9]{0,3})?|1(\.0{0,3})?)[[:space:]]*$ ]]; then
            q="${BASH_REMATCH[1]}"
          else
            q=0
          fi
        fi
      done
    fi
    if [[ "${coding}" == gzip ]]; then
      gzip_seen=true
      [[ "${q}" =~ ^0(\.0{0,3})?$ ]] || gzip_ok=true
    else
      [[ "${q}" =~ ^0(\.0{0,3})?$ ]] || wildcard_ok=true
    fi
  done
  if [[ "${gzip_seen}" == true ]]; then
    [[ "${gzip_ok}" == true ]]
  else
    [[ "${wildcard_ok}" == true ]]
  fi
}

respond_request() {
  respond "$STATUS" "$(_status_reason "$STATUS")"
  local h z=""
  # Stateless per-response compression: transcripts are highly repetitive
  # markup (~7x smaller). Compressed bytes go via a temp file — bash command
  # substitution strips NULs and would corrupt the stream.
  if [[ "${#BODY}" -gt 511 ]] && _accepts_gzip; then
    z="$(mktemp)"
    printf '%s' "$BODY" | gzip -c > "${z}"
  fi
  for h in "${HEADERS[@]}"; do printf '%s\r\n' "$h"; done
  # Feed responses and the client must stay current across server restarts.
  header Cache-Control "no-store"
  # Explicit framing (bytes, not chars: transcripts carry UTF-8) so proxies
  # never have to buffer close-delimited responses.
  if [[ -n "${z}" ]]; then
    header Content-Encoding gzip
    header Content-Length "$(wc -c < "${z}" | tr -d ' ')"
  else
    header Content-Length "$(printf '%s' "$BODY" | wc -c)"
  fi
  header Connection close
  end_headers
  if [[ -n "${z}" ]]; then
    cat "${z}"
    rm -f "${z}"
  else
    printf '%s' "$BODY"
  fi
}

_status_reason() {
  case "$1" in
    200) echo OK ;; 303) echo "See Other" ;; 400) echo "Bad Request" ;;
    403) echo Forbidden ;; 413) echo "Content Too Large" ;;
    404) echo "Not Found" ;; 405) echo "Method Not Allowed" ;;
    409) echo Conflict ;;
    415) echo "Unsupported Media Type" ;;
    500) echo "Internal Server Error" ;; *) echo OK ;;
  esac
}
