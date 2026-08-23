# pages.sh — route handlers. Server-rendered HTML; the only script is the
# vendored datastar bundle, which morphs full-view fragments we push over SSE.
# Requires http.sh sourced; HARNESS_SESSIONS and _new_session (via handler).

_HS="$HARNESS_ROOT/bin/harness"

# ---------------------------------------------------------------- layout --
_head() { # $1 = <title>, $2 = current session id (sidebar highlight)
  printf '<!doctype html><html><head><meta charset="utf-8">'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1">'
  printf '<title>%s</title><style>' "$(html_escape "$1")"
  cat <<'CSS'
html{height:100%}
body{font:14px/1.5 system-ui,sans-serif;max-width:48rem;margin:0 auto;padding:0 1rem;color:#222;height:100%;display:flex;flex-direction:column}
#main{flex:1;display:flex;flex-direction:column;min-height:0}
#view{flex:1;display:flex;flex-direction:column;min-height:0}
#scroll{flex:1;overflow-y:auto;padding:1rem 0;min-height:0}
.msg{border:1px solid #ddd;border-radius:6px;margin:.75rem 0;padding:.5rem .75rem}
.user{background:#f0f7ff}.assistant{background:#fafafa}
.msg pre{white-space:pre-wrap;overflow-wrap:anywhere;margin:.25rem 0;font:inherit}
.meta{color:#888;font-size:.8rem}
form{display:flex;gap:.5rem;margin:0;padding:1rem 0;background:inherit;position:sticky;bottom:0}
input[type=text]{flex:1;min-width:0;padding:.5rem;border:1px solid #ccc;border-radius:4px}
button{padding:.5rem 1rem}
#scrollbtn{position:fixed;bottom:5.5rem;right:1.5rem;border:none;border-radius:50%;width:2.5rem;height:2.5rem;font-size:1.2rem;cursor:pointer;box-shadow:0 1px 4px rgba(0,0,0,.25)}
#scrollbtn[hidden]{display:none}
#sidebar{position:fixed;top:0;bottom:0;left:0;width:230px;background:#f6f6f6;border-right:1px solid #ddd;padding:1rem;overflow-y:auto;transform:translateX(-100%);transition:transform .2s;z-index:20}
#sidebar.open{transform:none}
#sidebar form{padding:0}
#sidebar ul{list-style:none;padding:0;margin:1rem 0 0}
#sidebar a{display:block;padding:.35rem .5rem;border-radius:4px;text-decoration:none;color:#222;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#sidebar a.here{background:#dde7f5}
#menu{position:fixed;top:.75rem;left:.75rem;z-index:15;width:2.4rem;height:2.4rem;border:1px solid #ccc;background:#fff;border-radius:4px;cursor:pointer}
#sbhead{display:flex;justify-content:space-between;align-items:center;font-weight:600}
#sbclose{border:none;background:none;cursor:pointer;padding:.25rem .5rem}
#backdrop{position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:19}
#backdrop[hidden]{display:none}
@media (min-width:900px){
  #menu{display:none}
  #sidebar{transform:none}
  body{padding-left:250px}
}
@media (max-width:899px){
  body{max-width:none;padding:0 .5rem}
  #main{padding-left:3rem}
}
CSS
  printf '</style>'
  printf '<script type="module" src="/datastar.js"></script>'
  printf '</head><body>'
  _sidebar "${2:-}"
  printf '<main id="main">'
  cat
  printf '</main>'
  cat <<'JS'
<script>
(() => {
  const sb = document.getElementById('sidebar');
  const bd = document.getElementById('backdrop');
  const close = () => { sb.classList.remove('open'); bd.hidden = true; };
  document.getElementById('menu').onclick = () => { sb.classList.add('open'); bd.hidden = false; };
  document.getElementById('sbclose').onclick = close;
  bd.onclick = close;
  sb.addEventListener('click', e => { if (e.target.closest('a')) close(); });
  // draft preservation: survive reloads (incl. live-UI reload nudges) and tab close
  const inp = document.querySelector('#main form input[name=message]');
  if (inp) {
    const k = 'draft:' + location.pathname;
    const saved = localStorage.getItem(k);
    if (saved && !inp.value) { inp.value = saved; inp.focus(); }
    inp.addEventListener('input', () => localStorage.setItem(k, inp.value));
    inp.form.addEventListener('submit', () => localStorage.removeItem(k));
  }
  // stream watchdog: heartbeats morph #hb; if they stop or datastar gives
  // up, reload to reconnect and resync (drafts survive via localStorage)
  const hb = document.getElementById('hb');
  if (hb) {
    let lastBeat = Date.now();
    new MutationObserver(() => { lastBeat = Date.now(); }).observe(hb, {attributes: true, attributeFilter: ['data-t']});
    setInterval(() => { if (Date.now() - lastBeat > 45000) location.reload(); }, 5000);
    document.addEventListener('datastar-fetch', e => { if (e.detail?.type === 'retries-failed') location.reload(); });
  }
})();
</script>
JS
  printf '</body></html>'
}

_sidebar() { # $1 = current session id
  local id rows="" s
  while IFS= read -r s; do
    [[ -d "${HARNESS_SESSIONS}/${s}" ]] || continue
    rows+="<li><a href=\"/s/$(html_escape "${s}")\"$([[ "${s}" == "$1" ]] && printf ' class="here"')>$(html_escape "${s}")</a></li>"
  done < <(ls -1t "${HARNESS_SESSIONS}" 2>/dev/null | head -30)
  printf '<button id="menu" aria-label="toggle sidebar">&#9776;</button>'
  printf '<div id="backdrop" hidden></div>'
  printf '<nav id="sidebar">'
  printf '<div id="sbhead"><span>sessions</span><button id="sbclose" aria-label="close sidebar">&#10005;</button></div>'
  printf '<form method="post" action="/new"><input type="text" name="message" placeholder="new session…"><button>+</button></form>'
  printf '<ul>%s</ul>' "${rows}"
  printf '</nav>'
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
# SSE hub. Three push sources:
#   1. any session file change  -> full transcript re-render
#   2. web plugin file change   -> reload nudge (live UI edits)
#   3. heartbeat every 15s      -> keeps proxies honest and lets the client
#                                 watchdog detect a dead stream and reload
#   3. $dir/.ui/*.fifo        -> agent-pushed fragments, one HTML line each.
# Each connection gets its own fifo under .ui/ so sends can fan out over
# the whole directory; fifos are removed when the client disconnects.
handle_events() { # $1 = id
  local dir="${HARNESS_SESSIONS}/$1" sig last="" ui_sig ui_last="" fifo line beat=0
  [[ -d "${dir}" ]] || { handle_404; return; }
  respond_sse
  sse_patch '<div id="hb" hidden></div>' # initial beat so the watchdog arms immediately
  mkdir -p "${dir}/.ui" 2>/dev/null
  find "${dir}/.ui" -name '*.fifo' -mmin +30 -delete 2>/dev/null # stale ones from killed handlers
  fifo="${dir}/.ui/$$.fifo"
  mkfifo "${fifo}" 2>/dev/null
  trap 'rm -f "${fifo}"' EXIT
  exec 7<>"${fifo}"
  while :; do
    if IFS= read -r -t 0.5 line <&7; then
      [[ -n "${line}" ]] && { sse_patch "${line}" append || exit 0; }
      continue
    fi
    sig="$(_dir_sig "${dir}")"
    if [[ "${sig}" != "${last}" ]]; then
      sse_patch "$(_transcript "$1")" || exit 0
      last="${sig}"
    fi
    if (( ++beat % 30 == 0 )); then # every ~15s (30 x 0.5s)
      sse_patch "<div id=\"hb\" hidden data-t=\"$(date +%s)\"></div>" || exit 0
    fi
    ui_sig="$(_dir_sig "${HARNESS_ROOT}/plugins/web")"
    if [[ "${ui_sig}" != "${ui_last}" ]]; then
      if [[ -n "${ui_last}" ]]; then
        sse_patch '<div id="uireload" hidden data-init="location.reload()"></div>' append || exit 0
      fi
      ui_last="${ui_sig}"
    fi
  done
}

handle_new() { # empty message = create the session without launching an agent
  local msg; msg="$(_form_field message)"
  local dir; dir="$(_new_session)"
  [[ -n "${msg}" ]] && _launch_agent "${dir##*/}" "${msg}"
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
  _head "${id}" "${id}" <<EOF
<p class="meta">$(html_escape "${id}") $(html_escape "$2") <a href="/">← all sessions</a></p>
<div id="hb" hidden></div>
<div id="view" data-init="@get('/s/$(html_escape "${id}")/events', {retry: 'always', retryMaxCount: 99999, openWhenHidden: true})">
<div id="scroll">
$(_transcript "$1")
</div>
</div>
<button id="scrollbtn" hidden title="scroll to bottom">↓</button>
<form method="post" action="/s/$(html_escape "${id}")">
  <input type="text" name="message" placeholder="reply…" required autofocus>
  <button>send</button>
</form>
<script>
(() => {
  const scroll = document.getElementById('scroll');
  const btn = document.getElementById('scrollbtn');
  const nearBottom = () => scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 40;
  let stick = true; // autoscroll only while the user is at the bottom
  new MutationObserver(() => { if (stick) scroll.scrollTop = scroll.scrollHeight; })
    .observe(scroll, {childList: true, subtree: true, characterData: true});
  scroll.addEventListener('scroll', () => { stick = nearBottom(); btn.hidden = stick; });
  btn.addEventListener('click', () => { scroll.scrollTop = scroll.scrollHeight; });
  scroll.scrollTop = scroll.scrollHeight;
})();
</script>
EOF
}

# One awk pass over all message files — no per-message subprocess forks.
_transcript() { # $1 = id
  local dir="${HARNESS_SESSIONS}/$1"
  ls "${dir}/messages"/*.md >/dev/null 2>&1 || {
    printf '<div id="transcript"><p class="meta">(no messages yet)</p></div>'
    return
  }
  awk '
    function esc(s, t) {
      t = s
      gsub(/&/, "\\&amp;", t); gsub(/</, "\\&lt;", t)
      gsub(/>/, "\\&gt;", t);  gsub(/"/, "\\&quot;", t)
      return t
    }
    BEGIN { printf "<div id=\"transcript\">" }
    FNR == 1 { sep = 0; role = ""; open = 0; body = "" }
    !open && $0 == "---" { sep++; if (sep == 2) open = 1; next }
    !open && /^role: / { role = substr($0, 7); next }
    !open { next }
    { body = body $0 "\n" }
    ENDFILE {
      if (length(body) > 100000) body = substr(body, 1, 100000)
      printf "<div class=\"msg %s\"><div class=\"meta\">%s</div><pre>%s</pre></div>", esc(role), esc(role), esc(body)
    }
    END { print "</div>" }
  ' "${dir}/messages"/*.md
}

_dir_sig() { # fingerprint of a session dir: any file change (size or mtime)
  find "$1" -type f -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum
}