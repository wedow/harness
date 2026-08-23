# http.sh — minimal HTTP primitives for the serve command.
# Per-connection process model: stdin/stdout is the socket.
# Handlers set STATUS / HEADERS[] / BODY; respond_request serializes.
# Streaming handlers bypass the triple and own the socket directly.

STATUS=200
HEADERS=()
BODY=""

respond()  { printf 'HTTP/1.1 %s %s\r\n' "$1" "$2"; }
header()   { printf '%s: %s\r\n' "$1" "$2"; }
end_headers() { printf '\r\n'; }

respond_request() {
  respond "$STATUS" "$(_status_reason "$STATUS")"
  local h
  for h in "${HEADERS[@]}"; do printf '%s\r\n' "$h"; done
  header Connection close
  end_headers
  printf '%s' "$BODY"
}

_status_reason() {
  case "$1" in
    200) echo OK ;; 303) echo "See Other" ;; 400) echo "Bad Request" ;;
    404) echo "Not Found" ;; 405) echo "Method Not Allowed" ;;
    500) echo "Internal Server Error" ;; *) echo OK ;;
  esac
}

# SSE escape hatch: emit headers then own the socket (caller streams).
respond_sse() {
  respond 200 OK
  header Content-Type "text/event-stream"
  header Cache-Control no-cache
  header Connection close
  end_headers
}

html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

urldecode() {
  local s=${1//+/ }
  printf '%b' "${s//%/\\x}"
}