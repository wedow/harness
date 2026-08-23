# pages.sh — route handlers. Server-rendered HTML; the only script is the
# vendored datastar bundle, which morphs full-view fragments we push over SSE.
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
CSS
  printf '</style>'
  printf '<script type="module" src="/datastar.js"></script>'
  printf '</head><body>'
  cat
  printf '</body></html>'
}

# ---------------------------------------------------------------- routes --
handle_asset() { # $1 = file name under plugins/web/public
  local f="${HARNESS_ROOT}/plugins/web/public/$1"
  [[ -f "${f}" ]] || { handle_404; return; }
  HEADERS+=("Content-Type: text/javascript")
  BODY="$(<"${f}")"
}

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
  BODY="$(_session_page "$1" "${meta}")"
}

# Live view: any change to the session on disk triggers a full re-render,
# pushed as a datastar patch over SSE.
handle_events() { # $1 = id
  local dir="${HARNESS_SESSIONS}/$1" sig last=""
  [[ -d "${dir}" ]] || { handle_404; return; }
  respond_sse
  while :; do
    sig="$(_dir_sig "${dir}")"
    if [[ "${sig}" != "${last}" ]]; then
      sse_patch "$(_transcript "$1")"
      last="${sig}"
    fi
    sleep 0.5
  done
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

_session_page() { # $1 = id, $2 = meta line
  local id=$1
  _head "${id}" <<EOF
<p class="meta">$(html_escape "${id}") $(html_escape "$2") <a href="/">← all sessions</a></p>
<div id="view" data-on-load="@get('/s/$(html_escape "${id}")/events')">
$(_transcript "$1")
</div>
<form method="post" action="/s/$(html_escape "${id}")">
  <input type="text" name="message" placeholder="reply…" required autofocus>
  <button>send</button>
</form>
EOF
}

# Full transcript fragment. Top-level element id lets datastar morph it in place.
_transcript() { # $1 = id
  local dir="${HARNESS_SESSIONS}/$1" f role body out=""
  while IFS= read -r f; do
    role="$(html_escape "$(sed -n 's/^role: //p' "${f}" | head -1)")"
    body="$(awk 'NR>1 && /^---/{p=1;next} p' "${f}" | head -c 100000)"
    out+="<div class=\"msg ${role}\"><div class=\"meta\">${role}</div><pre>$(html_escape "${body}")</pre></div>"
  done < <(ls -1 "${dir}/messages"/*.md 2>/dev/null | sort)
  printf '<div id="transcript">%s</div>' "${out:-<p class=\"meta\">(no messages yet)</p>}"
}

_dir_sig() { # fingerprint of a session dir: any file change (size or mtime)
  find "$1" -type f -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum
}