# pages.sh — route handlers. Pure server-rendered HTML, no assets.
# Requires http.sh sourced; HARNESS_SESSIONS and _new_session (via handler).

_HS="$HARNESS_ROOT/bin/harness"

# ---------------------------------------------------------------- layout --
_head() { # $1 = <title>, stdin = body
  printf '<!doctype html><html><head><meta charset="utf-8">'
  printf '<title>%s</title><style>' "$(html_escape "$1")"
  cat <<'CSS'
body{font:14px/1.5 system-ui,sans-serif;max-width:48rem;margin:2rem auto;padding:0 1rem;color:#222}
.msg{border:1px solid #ddd;border-radius:6px;margin:.75rem 0;padding:.5rem .75rem}
.user{background:#f0f7ff}.assistant{background:#fafafa}
.msg pre{white-space:pre-wrap;margin:.25rem 0;font:inherit}
.meta{color:#888;font-size:.8rem}
form{display:flex;gap:.5rem;margin:1rem 0}
input[type=text]{flex:1;padding:.5rem;border:1px solid #ccc;border-radius:4px}
button{padding:.5rem 1rem}
#live{color:#555}
CSS
  printf '</style></head><body>'
  cat
  printf '</body></html>'
}

# ---------------------------------------------------------------- routes --
handle_home() {
  local id rows=""
  while IFS= read -r id; do
    [[ -d "${HARNESS_SESSIONS}/${id}" ]] || continue
    rows+="<li><a href=\"/s/$(html_escape "$id")\">$(html_escape "$id")</a></li>"
  done < <(ls -1t "${HARNESS_SESSIONS}" 2>/dev/null)
  HEADERS+=("Content-Type: text/html; charset=utf-8")
  BODY="$(_head "harness" <<EOF
<h1>harness sessions</h1>
<form method="post" action="/new">
  <input type="text" name="message" placeholder="start a new session…" required>
  <button>send</button>
</form>
<ul>${rows:-<li>(none)</li>}</ul>
EOF
)"
}

handle_session() { # $1 = id
  local dir="${HARNESS_SESSIONS}/$1"
  [[ -d "${dir}" ]] || { handle_404; return; }
  local meta
  meta="$(grep -hE '^(model|provider)=' "${dir}/session.conf" 2>/dev/null | tr '\n' ' ')"
  HEADERS+=("Content-Type: text/html; charset=utf-8")
  BODY="$(_transcript_html "$1" "${dir}" "${meta}")"
}

handle_new() {
  local msg; msg="$(_form_field message)"
  [[ -n "${msg}" ]] || { handle_400 "empty message"; return; }
  local dir; dir="$(_new_session)"
  _launch_agent "${dir##*/}" "${msg}"
  STATUS=303
  HEADERS+=("Location: /s/${dir##*/}")
}

handle_send() { # $1 = session id, message from form body
  local dir="${HARNESS_SESSIONS}/$1"
  [[ -d "${dir}" ]] || { handle_404; return; }
  local msg; msg="$(_form_field message)"
  [[ -n "${msg}" ]] || { handle_400 "empty message"; return; }
  _launch_agent "$1" "${msg}"
  STATUS=303
  HEADERS+=("Location: /s/$1")
}

handle_stream() { # $1 = session id — SSE translation of .stream JSONL
  local dir="${HARNESS_SESSIONS}/$1" ev tailpid i
  [[ -d "${dir}" ]] || { handle_404; return; }
  respond_sse
  # wait briefly for the stream file (agent may not have created it yet)
  for (( i=0; i<50; i++ )); do
    [[ -e "${dir}/.stream" ]] && break
    sleep 0.1; printf ': hb\n\n'
  done
  exec 5< <(exec tail -c +1 -f "${dir}/.stream" 2>/dev/null)
  tailpid=$!
  while IFS= read -r -t 15 ev <&5; do
    [[ -n "${ev}" ]] || continue
    printf 'data: %s\n\n' "${ev}"
    [[ "$(jq -r '.type // empty' <<<"${ev}" 2>/dev/null)" == done ]] && break
  done
  # heartbeat while quiet; exit once tail is gone
  while kill -0 "${tailpid}" 2>/dev/null; do printf ': hb\n\n'; sleep 15; done
  exit 0
}

handle_404() { STATUS=404; HEADERS+=("Content-Type: text/plain"); BODY="not found"; }
handle_400() { STATUS=400; HEADERS+=("Content-Type: text/plain"); BODY="${1:-bad request}"; }

# ---------------------------------------------------------------- helpers --
# form body -> urldecoded field value (single-value fields only)
_form_field() {
  local name=$1 pair k v
  while IFS='&' read -rd '&' pair; do
    k="${pair%%=*}"
    [[ "${k}" == "${name}" ]] && { urldecode "${pair#*=}"; return; }
  done < <(printf '%s&' "${BODY:-}")
}

# serialize agent runs per session (one in-flight turn at a time)
_launch_agent() { # $1 = session id, $2 = message
  local id=$1 dir="${HARNESS_SESSIONS}/$1"
  (
    flock -n 9
    "${_HS}" agent "${id}" "$2" >>"${dir}/serve.log" 2>&1
  ) 9>"${dir}/.lock" &>/dev/null &
}

_transcript_html() { # $1 = id, $2 = dir, $3 = meta line
  local id=$1 dir=$2 meta=$3 f role body out=""
  while IFS= read -r f; do
    role="$(sed -n 's/^role: //p' "${f}" | head -1)"
    body="$(awk 'NR>1 && /^---/{p=1;next} p' "${f}" | head -c 100000)"
    out+="<div class=\"msg ${role}\"><div class=\"meta\">${role}</div><pre>$(html_escape "${body}")</pre></div>"
  done < <(ls -1 "${dir}/messages"/*.md 2>/dev/null | sort)
  _head "${id}" <<EOF
<p class="meta">$(html_escape "${id}") $(html_escape "${meta}") <a href="/">← all sessions</a></p>
${out:-'<p class="meta">(no messages yet)</p>'}
<div id="live"></div>
<form method="post" action="/s/$(html_escape "${id}")">
  <input type="text" name="message" placeholder="reply…" required autofocus>
  <button>send</button>
</form>
<script>
const live = document.getElementById('live');
const es = new EventSource('/s/$(html_escape "${id}")/stream');
es.onmessage = e => {
  const ev = JSON.parse(e.data);
  if (ev.type === 'done') { es.close(); return; }
  if (ev.type === 'text') live.append(ev.text);
  if (ev.type === 'tool_start') live.append('\\n[' + ev.name + '] ');
  if (ev.type === 'error') live.append('\\n[error] ' + ev.message);
};
</script>
EOF
}