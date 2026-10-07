#!/usr/bin/env bash
# web-transcript-deltas — message changes patch individual elements without
# replacing the transcript's other children;
# turn-end (.stream done/stop) forces a full re-sync; mid-inserted files
# fall back to a full render (morph positioning can't be trusted).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
sess="deltas"
dir="${HARNESS_SESSIONS}/${sess}"
mkdir -p "${dir}/messages"
msg() { # $1 seq, $2 role, $3 body
  printf -- '---\nrole: %s\nseq: %s\ntimestamp: 2026-09-21T07:00:00+00:00\n---\n%s\n' "$2" "$1" "$3" \
    > "${dir}/messages/$1-$2.md"
}
msg 0001 user "first"

timeout 10 bash -c "
  export HARNESS_SESSIONS='${HARNESS_SESSIONS}' HARNESS_ROOT='${HARNESS_ROOT}'
  source '${HARNESS_ROOT}/plugins/web/lib/http.sh'
  source '${HARNESS_ROOT}/plugins/web/lib/pages.sh'
  respond_sse() { :; }
  sse_patch() {
    case \"\$1\" in
      *'id=\"transcript\"'*|*'id=\"m'[0-9]*) printf '=== PUSH %s\n%s\n=== END\n' \"\${2:-outer}:\${3:-}\" \"\$1\" >> '${_tmpdir}/pushes' ;;
    esac
    return 0
  }
  handle_events '${sess}'
" &
hpid=$!
sleep 0.8   # initial full sync

n_pushes() { grep -c '=== PUSH' "${_tmpdir}/pushes" 2>/dev/null || echo 0; }
last_push() { awk 'NR>FNR{next}' /dev/null; sed -n "/=== PUSH/,\$p" "${_tmpdir}/pushes" | awk '/=== PUSH/{n++} n<'"$(n_pushes)"'{} /=== END/{if(n<'"$(n_pushes)"')next} {if(n=='"$(n_pushes)"')print}' | sed '1d;$d'; }

# 1. initial sync only
[[ "$(n_pushes)" == "1" ]] || { echo "FAIL: expected initial push only, got $(n_pushes)"; kill $hpid 2>/dev/null; exit 1; }

# 2. appended message -> delta push containing ONLY the new element
msg 0002 user "second"
sleep 1.5
[[ "$(n_pushes)" == "2" ]] || { echo "FAIL: no delta push after append (have $(n_pushes))"; kill $hpid 2>/dev/null; exit 1; }
last="$(sed -n "/=== END/!d;p" "${_tmpdir}/pushes" >/dev/null; awk '/=== PUSH/{buf="";p=1;next} /=== END/{p=0;last=buf;next} p{buf=buf $0 "\n"} END{printf "%s",last}' "${_tmpdir}/pushes")"
echo "${last}" | grep -q 'id="m0002"' || { echo "FAIL: delta missing new message"; kill $hpid 2>/dev/null; exit 1; }
[[ "$(grep '=== PUSH' "${_tmpdir}/pushes" | tail -1)" == '=== PUSH append:#transcript' ]] \
  || { echo "FAIL: new message must append inside transcript"; kill $hpid 2>/dev/null; exit 1; }
if echo "${last}" | grep -q 'id="transcript"'; then
  echo "FAIL: delta morphs transcript wrapper and removes older messages"; kill $hpid 2>/dev/null; exit 1
fi
if echo "${last}" | grep -q 'id="m0001"'; then
  echo "FAIL: delta re-sent unchanged message (not a delta)"; kill $hpid 2>/dev/null; exit 1
fi

# 3. modified message -> morph that message only; preserve its siblings
msg 0001 user "first, revised"
sleep 1.2
[[ "$(n_pushes)" == "3" ]] || { echo "FAIL: no patch after edit"; kill $hpid 2>/dev/null; exit 1; }
last="$(awk '/=== PUSH/{buf="";p=1;next} /=== END/{p=0;last=buf;next} p{buf=buf $0 "\n"} END{printf "%s",last}' "${_tmpdir}/pushes")"
[[ "$(grep '=== PUSH' "${_tmpdir}/pushes" | tail -1)" == '=== PUSH outer:' ]] \
  || { echo "FAIL: modified message must morph by id"; kill $hpid 2>/dev/null; exit 1; }
echo "${last}" | grep -q 'id="m0001"' || { echo "FAIL: modified message missing"; kill $hpid 2>/dev/null; exit 1; }
if echo "${last}" | grep -q 'id="transcript"'; then
  echo "FAIL: modified message morphs transcript wrapper"; kill $hpid 2>/dev/null; exit 1
fi

# 4. turn-end done event -> full push (both messages)
printf '{"type":"done"}\n' >> "${dir}/.stream"
sleep 1.5
[[ "$(n_pushes)" == "4" ]] || { echo "FAIL: no full push after done (have $(n_pushes))"; kill $hpid 2>/dev/null; exit 1; }
last="$(awk '/=== PUSH/{buf="";p=1;next} /=== END/{p=0;last=buf;next} p{buf=buf $0 "\n"} END{printf "%s",last}' "${_tmpdir}/pushes")"
echo "${last}" | grep -q 'id="m0001"' && echo "${last}" | grep -q 'id="m0002"' \
  || { echo "FAIL: full push missing messages"; kill $hpid 2>/dev/null; exit 1; }

# 5. mid-inserted file (sorts before the current tail) -> full fallback
msg 0003 user "tail"
sleep 1.2
msg 0002a user "middle"
sleep 1.5
last="$(awk '/=== PUSH/{buf="";p=1;next} /=== END/{p=0;last=buf;next} p{buf=buf $0 "\n"} END{printf "%s",last}' "${_tmpdir}/pushes")"
echo "${last}" | grep -q 'id="m0001"' \
  || { echo "FAIL: mid-insert did not fall back to full render"; kill $hpid 2>/dev/null; exit 1; }

kill $hpid 2>/dev/null
wait $hpid 2>/dev/null || true
