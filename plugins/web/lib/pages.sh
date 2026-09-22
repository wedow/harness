# pages.sh — route handlers. Server-rendered HTML; the only script is the
# vendored datastar bundle, which morphs full-view fragments we push over SSE.
# Requires http.sh sourced; HARNESS_SESSIONS and _new_session (via handler).

_HS="$HARNESS_ROOT/bin/harness"
source "${HARNESS_ROOT}/plugins/core/lib/session.sh"

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
.msg pre,#live pre{white-space:pre-wrap;overflow-wrap:anywhere;margin:.25rem 0;font:inherit}
.meta{color:#888;font-size:.8rem}
.msg>summary{cursor:pointer;color:#666;font-size:.9rem}
.seg{margin:.35rem 0}
.seg>summary{cursor:pointer;color:#888;font-size:.8rem}
.seg pre{margin:.15rem 0 .15rem .5rem}
form{display:flex;gap:.5rem;margin:0;padding:1rem 0;background:inherit;position:sticky;bottom:0}
input[type=text],textarea{flex:1;min-width:0;padding:.5rem;border:1px solid #ccc;border-radius:4px;font:inherit}
button{padding:.5rem 1rem}
#stop-btn{padding:0 0 .25rem}
#stop-btn button{background:#c22;color:#fff;border:none}
#stop-btn[hidden]{display:none} /* form{display:flex} would override [hidden] */
#run-error:not(:empty){background:#fff0ee;border:1px solid #d66;border-radius:4px;padding:.5rem .75rem;white-space:pre-wrap}
#scrollbtn{position:fixed;bottom:5.5rem;right:1.5rem;border:none;border-radius:50%;width:2.5rem;height:2.5rem;font-size:1.2rem;cursor:pointer;box-shadow:0 1px 4px rgba(0,0,0,.25)}
#scrollbtn[hidden]{display:none}
#sidebar{position:fixed;top:0;bottom:0;left:0;width:230px;background:#f6f6f6;border-right:1px solid #ddd;padding:1rem;overflow-y:auto;transform:translateX(-100%);transition:transform .2s;z-index:20}
#sidebar.open{transform:none}
#sidebar form{padding:0}
#sidebar ul{list-style:none;padding:0;margin:1rem 0 0}
#sidebar li{display:flex;align-items:center;gap:.35rem}
#sidebar a{flex:1;min-width:0;padding:.35rem .5rem;border-radius:4px;text-decoration:none;color:#222;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#sidebar .spin{flex:none}
#sidebar a.here{background:#dde7f5}
.spin{display:inline-block;animation:spin 1s linear infinite;color:#0866ff}
@keyframes spin{to{transform:rotate(360deg)}}
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
  const inp = document.querySelector('#main form [name=message]');
  if (inp) {
    // textarea: Enter sends, Shift+Enter inserts a newline
    if (inp.tagName === 'TEXTAREA') {
      inp.addEventListener('keydown', e => {
        if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); inp.form.requestSubmit(); }
      });
    }
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
    // Frozen mobile tabs: timers and the stream both die while hidden, so a
    // stale beat after backgrounding says nothing. Reset the window on
    // return and only judge staleness in the foreground — reloads fired
    // mid-resume raced the radio and landed on Chrome error pages.
    document.addEventListener('visibilitychange', () => { if (!document.hidden) lastBeat = Date.now(); });
    setInterval(() => { if (!document.hidden && Date.now() - lastBeat > 45000) location.reload(); }, 5000);
    document.addEventListener('datastar-fetch', e => { if (e.detail?.type === 'retries-failed') location.reload(); });
  }
})();
</script>
JS
  printf '</body></html>'
}
# Sidebar order = conversational activity: newest message wins. Never the
# session dir's own mtime — the UI itself writes there (.ui fifos, serve.log,
# .lock), which made merely opening a session bump it to the top.
_session_order() {
  local s m
  for s in "${HARNESS_SESSIONS}"/*/; do
    [[ -d "${s}messages" ]] || continue
    m="$(stat -c %Y "${s}messages" 2>/dev/null || echo 0)"
    printf '%s %s\n' "${m}" "${s%/}"
  done | sort -rn | awk '{n=$NF; sub(/.*\//, "", n); print n}'
}

# Agent-running probe: the agent subshell holds fd 9 on .lock for its whole
# lifetime, so an open-fd check (fuser, no locking) is the signal. Never use
# flock -n to probe — it could steal the lock and drop a queued turn.
_agent_running() { # $1 = session dir — ANY lock-fd holder (incl. stragglers)
  fuser "${1}/.lock" >/dev/null 2>&1
}

# A real driver process for the session. _agent_running (fd holders) stays
# true for minutes after the driver exits: fd 9 is inherited by the whole
# tree, including orphaned tool commands living out their watchdog. Acting
# on that signal alone orphaned a web-sent message (2026-08-25 18:44: the
# insert path fired on a dead session — message saved, no driver launched).
# NB: pgrep -f can match an investigator's own grep cmdlines; transient and
# harmless next to the false-negative cost of fd-holder checking.
_driver_alive() { # $1 = session id
  # id followed by a space (message arg) or end of cmdline (resume mode)
  pgrep -f "commands/agent ${1}( |\$)" >/dev/null 2>&1
}

# Insert a user message into a RUNNING session: the message lands in the
# transcript immediately and the in-flight loop picks it up at its next
# assemble — i.e. before the next LLM API call — instead of waiting out the
# whole turn (which can run for hours with subagents).
_insert_live_message() { # $1 = session dir, $2 = message; rc 1 = insert failed
  local dir="$1" msg="$2" seq file temp
  mkdir -p "${dir}/messages"
  seq="$(_claim_message_seq "${dir}")" || return 1
  file="${dir}/messages/${seq}-user.md"
  temp="$(mktemp "${dir}/messages/.write.XXXXXX")" || return 1
  if ! cat > "${temp}" <<EOF
---
role: user
seq: ${seq}
timestamp: $(date -Iseconds)
---
${msg}
EOF
  then
    rm -f "${temp}"
    return 1
  fi
  if ! ln "${temp}" "${file}"; then
    rm -f "${temp}"
    return 1
  fi
  rm -f "${temp}"
}

# Live subagent count: child sessions with no exit marker AND a live process
# running them (a killed pane leaves .started with no .exit_code forever).
_subagent_count() { # $1 = session dir
  local d name c=0
  for d in "${1}/.harness/sessions"/*/; do
    name="${d%/}"; name="${name##*/}"
    if [[ -f "${d}/.exit_code" ]]; then continue; fi
    if pgrep -f "sessions/${name}" >/dev/null 2>&1; then c=$(( c + 1 )); fi
  done
  echo "${c}"
}

# Status line while a turn is in flight, e.g. "agent working… · 2 subagents ·
# 1 queued". Prints nothing and returns 1 when idle.
_agent_status_line() { # $1 = session id
  local dir="${HARNESS_SESSIONS}/$1" sub queued out
  _driver_alive "$1" || return 1
  sub="$(_subagent_count "${dir}")"
  queued="$(_web_queued_count "${dir}")"
  out="&#10227; agent working…"
  if (( sub > 0 )); then out+=" · ${sub} subagent"; (( sub > 1 )) && out+="s"; fi
  if (( queued > 0 )); then out+=" · ${queued} queued, waiting for current turn"; fi
  printf '%s' "${out}"
}
# Kill the current turn: every process holding the session run-lock fd IS the
# driver tree (launcher subshell, agent loop, hooks, provider curl, tools).
# TERM first — the agent tool's TERM trap kills its pane, whose stream trap
# kills the subagent loop — then hard-kill any survivors after a grace.
_stop_agent() { # $1 = session id
  local dir="${HARNESS_SESSIONS}/$1" p
  [[ -f "${dir}/.lock" ]] || return 0
  for p in $(fuser "${dir}/.lock" 2>/dev/null); do kill -TERM "${p}" 2>/dev/null || true; done
  for _ in $(seq 1 20); do
    fuser "${dir}/.lock" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  for p in $(fuser "${dir}/.lock" 2>/dev/null); do kill -KILL "${p}" 2>/dev/null || true; done
}

# Stop button (morph target alongside agent-status so it appears only while
# a turn is in flight).
_stop_btn() { # $1 = session id
  if _driver_alive "$1"; then
    printf '<form id="stop-btn" method="post" action="/s/%s/stop"><button title="stop the current turn">&#9632; stop</button></form>' "$1"
  else
    printf '<form id="stop-btn" hidden></form>'
  fi
}

_sb_spin() { # $1 = session id — sidebar spinner span (morph target for live updates)
  if _driver_alive "$1"; then
    printf '<span id="sb-%s" class="spin">&#10227;</span>' "$1"
  else
    printf '<span id="sb-%s" hidden></span>' "$1"
  fi
}

# One patch morphing #agent-status and every sidebar spinner. Targets are
# rendered (possibly hidden) on every session page, so plain id morph works.
_status_fragment() { # $1 = current session id
  local cur=$1 out s
  local line; line="$(_agent_status_line "${cur}")"
  if [[ -n "${line}" ]]; then
    out="<div id="agent-status" class="meta">${line}</div>"
  else
    out='<div id="agent-status" hidden></div>'
  fi
  out+="$(_stop_btn "${cur}")"
  while IFS= read -r s; do
    out+="$(_sb_spin "${s}")"
  done < <(_session_order | head -30)
  printf '%s' "${out}"
}

# Sidebar list as its own morph target so the hub can push title changes.
_sb_label() { # $1 = session id — title if set, else the id
  local t="$(sed -n 's/^title=//p' "${HARNESS_SESSIONS}/$1/session.conf" 2>/dev/null | head -1)"
  html_escape "${t:-$1}"
}

_sb_ul() { # $1 = current session id
  local rows="" s
  while IFS= read -r s; do
    [[ -d "${HARNESS_SESSIONS}/${s}" ]] || continue
    rows+="<li><a href=\"/s/$(html_escape "${s}")\"$([[ "${s}" == "$1" ]] && printf ' class="here"')>$(_sb_label "${s}")</a>$(_sb_spin "${s}")</li>"
  done < <(_session_order | head -30)
  printf '<ul id="sblist">%s</ul>' "${rows}"
}

_sidebar() { # $1 = current session id
  printf '<button id="menu" aria-label="toggle sidebar">&#9776;</button>'
  printf '<div id="backdrop" hidden></div>'
  printf '<nav id="sidebar">'
  printf '<div id="sbhead"><span>sessions</span><button id="sbclose" aria-label="close sidebar">&#10005;</button></div>'
  printf '<form method="post" action="/new"><input type="text" name="message" placeholder="new session…"><button>+</button></form>'
  _sb_ul "$1"
  printf '</nav>'
}

_titles_sig() { # fingerprint of the sidebar's titles — push #sblist when it changes
  local s
  _session_order | head -30 | while IFS= read -r s; do
    printf '%s:%s\n' "${s}" "$(sed -n 's/^title=//p' "${HARNESS_SESSIONS}/${s}/session.conf" 2>/dev/null)"
  done | md5sum
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
    rows+="<li><a href=\"/s/$(html_escape "$id")\">$(_sb_label "$id")</a></li>"
  done < <(_session_order)
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
  local dir="${HARNESS_SESSIONS}/$1" ui_sig ui_last="" fifo line beat=0 st_last="" ti_last=""
  local msg_cur="" msg_last="" changed removed max_old full f
  local ssz stream_off=0 stream_partial="" stream_prefix_len=0 stream_prefix_sig="" stream_replaced
  local force_full=false ev delta escaped live_buf="" live_last="" error_text="" error_last=""
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
    # --- transcript deltas: per-message-file change detection ---
    # Existing messages morph by id; new messages append inside #transcript.
    # .stream churn does not trigger renders.
    msg_cur="$(stat -c '%n %y %s' "${dir}"/messages/*.md 2>/dev/null | sort)"
    if [[ "${msg_cur}" != "${msg_last}" ]]; then
      if [[ -z "${msg_last}" ]]; then
        sse_patch "$(_transcript "$1")" || exit 0
      else
        changed="$(comm -13 <(printf '%s\n' "${msg_last}") <(printf '%s\n' "${msg_cur}") | awk '{print $1}')"
        removed="$(comm -23 <(printf '%s\n' "${msg_last}" | awk '{print $1}') <(printf '%s\n' "${msg_cur}" | awk '{print $1}') | wc -l)"
        max_old="$(printf '%s\n' "${msg_last}" | awk '{print $1}' | tail -1)"
        full=false
        (( removed > 0 )) && full=true
        if [[ "${full}" == false ]]; then
          # a NEW file sorting before the current tail is a mid-insert;
          # morph positioning cannot be trusted for that — send everything
          while IFS= read -r f; do
            [[ -z "${f}" ]] && continue
            if [[ "${f}" < "${max_old}" ]] \
               && ! printf '%s\n' "${msg_last}" | awk '{print $1}' | grep -qxF "${f}"; then
              full=true; break
            fi
          done <<< "${changed}"
        fi
        if [[ "${full}" == true ]]; then
          sse_patch "$(_transcript "$1")" || exit 0
        else
          local -a modified=() added=()
          while IFS= read -r f; do
            [[ -z "${f}" ]] && continue
            if printf '%s\n' "${msg_last}" | awk '{print $1}' | grep -qxF "${f}"; then
              modified+=("${f}")
            else
              added+=("${f}")
            fi
          done <<< "${changed}"
          if (( ${#modified[@]} > 0 )); then
            sse_patch "$(_msgrender "${modified[@]}")" || exit 0
          fi
          if (( ${#added[@]} > 0 )); then
            sse_patch "$(_msgrender "${added[@]}")" append '#transcript' || exit 0
          fi
        fi
      fi
      # A saved assistant message supersedes its live thinking. A mid-turn
      # user message or tool result does not end the assistant's stream.
      while IFS= read -r f; do
        [[ "${f}" == *-assistant.md ]] && { live_buf=""; break; }
      done <<< "${changed}"
      # Message changes move the conversation — re-assert status in the same
      # moment instead of waiting for the next beat.
      st_last="$(_status_fragment "$1")"
      sse_patch "${st_last}" || exit 0
      msg_last="${msg_cur}"
    fi

    # --- .stream tail: turn boundaries force a full re-sync. The delta
    # path trusts stat comparison and morph merging; a periodic full
    # transcript re-asserts the DOM against any drift.
    ssz="$(stat -c %s "${dir}/.stream" 2>/dev/null || echo 0)"
    stream_replaced=false
    # A new turn can truncate and regrow beyond the old offset between polls.
    # Compare bytes already consumed, which an ordinary append cannot change.
    if (( stream_prefix_len > 0 && ssz >= stream_prefix_len )); then
      [[ "$(head -c "${stream_prefix_len}" "${dir}/.stream" 2>/dev/null | cksum)" == "${stream_prefix_sig}" ]] || stream_replaced=true
    fi
    if (( ssz < stream_off )) || [[ "${stream_replaced}" == true ]]; then
      stream_off=0
      stream_partial=""
      stream_prefix_len=0 stream_prefix_sig=""
      live_buf="" live_last=""
      error_text=""
    fi
    if (( ssz > stream_off )); then
      ev=""
      while IFS= read -r ev; do
        case "$(printf '%s' "${ev}" | jq -r '.type // empty' 2>/dev/null)" in
          thinking)
            IFS= read -r -d '' delta < <(printf '%s' "${ev}" | jq -j '.text // empty'; printf '\0')
            live_buf+="${delta}"
            ;;
          tool_start) live_buf="" ;;
          stop|done) force_full=true; live_buf="" ;;
          error)
            IFS= read -r -d '' error_text < <(printf '%s' "${ev}" | jq -j 'if (.message | type) == "string" and (.message | length) > 0 then .message else "Agent run failed" end'; printf '\0')
            ;;
        esac
      done < <(printf '%s' "${stream_partial}"; tail -c +$(( stream_off + 1 )) "${dir}/.stream" 2>/dev/null)
      stream_partial="${ev}"
      stream_off="${ssz}"
      stream_prefix_len=$(( stream_off < 256 ? stream_off : 256 ))
      stream_prefix_sig="$(head -c "${stream_prefix_len}" "${dir}/.stream" 2>/dev/null | cksum)"
    fi
    if [[ "${error_text}" != "${error_last}" ]]; then
      sse_patch "<div id=\"run-error\" role=\"alert\">$(html_escape "${error_text}")</div>" || exit 0
      error_last="${error_text}"
    fi
    # live thinking stream: show deltas as an open block while the turn is
    # running; the saved message's collapsed render supersedes it
    if [[ "${live_buf}" != "${live_last}" ]]; then
      if [[ -n "${live_buf}" ]]; then
        IFS= read -r -d '' escaped < <(html_escape "${live_buf}"; printf '\0')
        sse_patch "$(printf '<div id="live"><details class="seg think" open><summary>thinking…</summary><pre>%s</pre></details></div>' "${escaped}")" || exit 0
      else
        sse_patch '<div id="live"></div>' || exit 0
      fi
      live_last="${live_buf}"
    fi
    if [[ "${force_full}" == true ]]; then
      sse_patch "$(_transcript "$1")" || exit 0
      force_full=false
    fi
    if (( beat % 4 == 0 )); then # every ~2s: spinners + sidebar titles
      local st ti
      ti="$(_titles_sig)"
      if [[ "${ti}" != "${ti_last}" ]]; then
        sse_patch "$(_sb_ul "$1")" || exit 0
        ti_last="${ti}"
      fi
      st="$(_status_fragment "$1")"
      if [[ "${st}" != "${st_last}" ]]; then
        sse_patch "${st}" || exit 0
        st_last="${st}"
      fi
    fi
    if (( ++beat % 30 == 0 )); then # every ~15s (30 x 0.5s)
      # Heartbeat re-asserts the status fragment: a stalled beat or morph
      # hiccup self-corrects instead of requiring a page refresh.
      st_last="$(_status_fragment "$1")"
      sse_patch "${st_last}" || exit 0
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
  if _driver_alive "$1"; then
    # Mid-turn: insert into the live conversation (picked up before the next
    # API call). Falling back to a queued second driver would delay guidance
    # by the remainder of a possibly hours-long turn.
    if ! _insert_live_message "${dir}" "${msg}"; then
      handle_500 "could not insert message (seq collision); try again"
      return
    fi
    # The current driver may finish without another assemble (for example,
    # while its final provider response is in flight). Queue a follower under
    # the run lock. It checks the assembled-user marker after the first driver
    # exits and skips the API call if the message was already included.
    _launch_agent "$1" "" pending
  else
    _launch_agent "$1" "${msg}"
  fi
  STATUS=303
  HEADERS+=("Location: /s/$1")
}

handle_stop() { # $1 = session id — web equivalent of Ctrl-C on the driver
  [[ -d "${HARNESS_SESSIONS}/$1" ]] || { handle_404; return; }
  _stop_agent "$1"
  STATUS=303
  HEADERS+=("Location: /s/$1")
}

handle_404() { STATUS=404; HEADERS+=("Content-Type: text/plain"); BODY="not found"; }
handle_500() { STATUS=500; HEADERS+=("Content-Type: text/plain"); BODY="${1:-internal error}"; }
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
_web_queued_count() { # $1 = session dir
  local dir="$1" file name seq count=0
  local -A assembled=()
  if [[ -f "${dir}/.assembled_user_seqs" ]]; then
    while IFS= read -r seq; do
      [[ "${seq}" =~ ^[0-9]+$ ]] && assembled["${seq}"]=1
    done < "${dir}/.assembled_user_seqs"
  fi
  for file in "${dir}/messages/"*-user.md; do
    [[ -f "${file}" ]] || continue
    name="${file##*/}"; seq="${name%%-*}"
    [[ "${seq}" =~ ^[0-9]+$ ]] || continue
    [[ -n "${assembled[${seq}]+x}" ]] || count=$(( count + 1 ))
  done
  printf '%s\n' "${count}"
}

_web_unassembled_user() { # $1 = session dir
  (( $(_web_queued_count "$1") > 0 ))
}

_launch_agent() { # $1 = session id, $2 = message (empty = resume), $3 = pending-only
  local id=$1 dir="${HARNESS_SESSIONS}/$1"
  (
    # Blocking acquire: a message sent mid-turn queues behind the in-flight
    # run. flock -n would fail silently here and run a second concurrent
    # driver on the same session (duplicate subagents, racing writes).
    flock 9
    if [[ "${3:-}" == pending ]] && ! _web_unassembled_user "${dir}"; then
      exit 0
    fi
    if [[ -n "$2" ]]; then
      "${_HS}" agent "${id}" "$2" >>"${dir}/serve.log" 2>&1
    else
      "${_HS}" agent "${id}" >>"${dir}/serve.log" 2>&1
    fi
  ) 9>"${dir}/.lock" &>/dev/null &
}

_agent_status_html() { # $1 = id — static #agent-status element (morph target)
  local line; line="$(_agent_status_line "$1")"
  if [[ -n "${line}" ]]; then
    printf '<div id="agent-status" class="meta">%s</div>' "${line}"
  else
    printf '<div id="agent-status" hidden></div>'
  fi
}

_session_page() { # $1 = id, $2 = meta line
  local id=$1 title
  title="$(sed -n 's/^title=//p' "${HARNESS_SESSIONS}/${id}/session.conf" 2>/dev/null | head -1)"
  [[ -n "${title}" ]] || title="${id}"
  _head "${title}" "${id}" <<EOF
<h1>$(html_escape "${title}")</h1>
<p class="meta">$(html_escape "${id}") $(html_escape "$2") <a href="/">← all sessions</a></p>
$(_agent_status_html "${id}")
<div id="hb" hidden></div>
<div id="run-error" role="alert"></div>
<div id="view" data-init="@get('/s/$(html_escape "${id}")/events', {retry: 'always', retryMaxCount: 99999, openWhenHidden: true})">
<div id="scroll">
$(_transcript "$1")
<div id="live"></div>
</div>
</div>
<button id="scrollbtn" hidden title="scroll to bottom">↓</button>
$(_stop_btn "$(html_escape "${id}")")
<form method="post" action="/s/$(html_escape "${id}")">
  <textarea name="message" placeholder="reply…" rows="3" required autofocus></textarea>
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
// <details> open state survives morphs. Record user toggles by element id and
// re-apply them when a patch syncs the server's default open attribute.
(() => {
  const t = document.getElementById('transcript');
  if (!t) return;
  const toggled = new Map();
  t.addEventListener('click', e => {
    const sum = e.target.closest('summary');
    const d = sum && sum.parentElement;
    if (!d || !d.id) return;
    // activation (attribute toggle) happens after dispatch; read after
    queueMicrotask(() => { toggled.set(d.id, d.open); });
  }, true);
  new MutationObserver(muts => {
    for (const m of muts) {
      const el = m.target;
      if (!el.id || !toggled.has(el.id)) continue;
      // The user's own toggle updates the map before this timer runs.
      setTimeout(() => {
        if (toggled.has(el.id) && el.open !== toggled.get(el.id))
          el.open = toggled.get(el.id);
      }, 0);
    }
  }).observe(t, {subtree: true, attributes: true, attributeFilter: ['open']});
})();
</script>
EOF
}

# One awk pass over all message files — no per-message subprocess forks.
_msgrender() { # $@ = message files -> rendered divs (no #transcript wrapper)
  # One pass: frontmatter (role/timestamp/intent/tool/error) then body.
  # Assistant bodies split into segments — thinking/tool_call fences
  # (growing fences; see receive/10-save) render as collapsed <details>;
  # tool_call input gets the same flat-JSON→YAML treatment as results.
  # flat-JSON->YAML helpers shared with core (lib/render-result).
  awk -f "${HARNESS_ROOT}/plugins/core/lib/yaml.awk" -e '
    function esc(s, t) {
      t = s
      gsub(/&/, "\\&amp;", t); gsub(/</, "\\&lt;", t)
      gsub(/>/, "\\&gt;", t);  gsub(/"/, "\\&quot;", t)
      return t
    }
    function tsfmt(iso, r) { r = substr(iso, 6, 14); gsub(/T/, " ", r); return r }

    # Fences grow past any backtick run inside a block (see receive/10-save):
    # close a segment only on the exact opening fence length.
    function mkfence(n, s, i) { s = ""; for (i = 0; i < n; i++) s = s "`"; return s }

    # --- assistant segment emission (buffered; wrapper printed at ENDFILE) ---
    function flushtext() {
      if (textbuf ~ /[^ \t\n]/)
        html = html "<div class=\"seg text\"><pre>" esc(textbuf) "</pre></div>\n"
      textbuf = ""
    }
    function segid() { return "m" seq "s" ++segk }

    function flushseg( lbl, y2, LL) {
      if (seg == "think") {
        html = html "<details class=\"seg think\" id=\"" segid() "\"><summary>thinking</summary><pre>" esc(buf) "</pre></details>\n"
      } else if (seg == "call") {
        y2 = json2yaml(cbuf); if (y2 == "") y2 = cbuf
        lbl = vm["intent"]
        if (lbl == "") lbl = vm["command"]
        if (lbl == "") lbl = vm["path"]
        if (lbl == "") lbl = vm["prompt"]
        if (lbl != "") {
          split(lbl, LL, "\n"); lbl = LL[1]
          if (length(lbl) > 60) lbl = substr(lbl, 1, 57) "..."
          lbl = " · " lbl
        }
        html = html "<details class=\"seg call\" id=\"" segid() "\"><summary>" esc(cname lbl) "</summary><pre>" esc(y2) "</pre></details>\n"
      }
      seg = ""; buf = ""; cbuf = ""
    }

    FNR == 1 {
      sep = 0; role = ""; open = 0; body = ""
      ts = ""; intent = ""; tool = ""; terr = ""
      seg = ""; buf = ""; cbuf = ""; cname = ""; textbuf = ""; html = ""; segk = 0; segf = 3
      split("", vm)
    }
    !open && $0 == "---" { sep++; if (sep == 2) open = 1; next }
    !open && /^role: /      { role = substr($0, 7); next }
    !open && /^seq: /       { seq = substr($0, 6); next }
    !open && /^timestamp: / { ts = substr($0, 12); next }
    !open && /^intent: /    { intent = substr($0, 9); next }
    !open && /^tool: /      { tool = substr($0, 7); next }
    !open && /^error: /     { terr = substr($0, 8); next }
    !open { next }
    role == "assistant" {
      if (seg == "think" || seg == "call") {
        if ($0 == mkfence(segf)) flushseg()
        else if (seg == "think") buf = buf $0 "\n"
        else cbuf = (cbuf == "" ? $0 : cbuf "\n" $0)
      } else if (match($0, /^(`+)thinking/)) {
        flushtext(); seg = "think"; segf = RLENGTH - 8; buf = ""
      } else if (match($0, /^(`+)tool_call /)) {
        segf = RLENGTH - 10
        flushtext(); seg = "call"; cbuf = ""; cname = ""; split("", vm)
        if (match($0, /name=[^ ]+/)) cname = substr($0, RSTART + 5, RLENGTH - 5)
      } else {
        textbuf = textbuf $0 "\n"
      }
      next
    }
    { body = body $0 "\n" }
    ENDFILE {
      if (open) {
      if (length(body) > 100000) body = substr(body, 1, 100000)
      if (role == "assistant") {
        flushtext(); flushseg()
        printf "<div class=\"msg assistant\" id=\"m%s\"><div class=\"meta\">assistant · %s</div>\n%s</div>", seq, esc(tsfmt(ts)), html
      } else if (role == "tool_result") {
        # intent labels the collapsed result; failures stay expanded
        sum = intent != "" ? intent : (tool != "" ? tool : "tool_result")
        dopen = terr == "true" ? " open" : ""
        printf "<details class=\"msg tool_result\" id=\"m%s\"%s><summary>%s · %s</summary><pre>%s</pre></details>", seq, dopen, esc(sum), esc(tsfmt(ts)), esc(body)
      } else {
        printf "<div class=\"msg %s\" id=\"m%s\"><div class=\"meta\">%s · %s</div><pre>%s</pre></div>", esc(role), seq, esc(role), esc(tsfmt(ts)), esc(body)
      }
      }
    }
  ' "$@"
}

_transcript() { # $1 = id
  local dir="${HARNESS_SESSIONS}/$1"
  local -a files
  ls "${dir}/messages"/*.md >/dev/null 2>&1 || {
    printf '<div id="transcript"><p class="meta">(no messages yet)</p></div>'
    return
  }
  printf '<div id="transcript">'
  mapfile -t files < <(printf '%s\n' "${dir}"/messages/*.md | sort -V)
  _msgrender "${files[@]}"
  printf '</div>\n'
}

_dir_sig() { # fingerprint of a session dir: any file change (size or mtime)
  find "$1" -type f -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum
}
