#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091,SC2154
source "${SPEC_DIR}/helpers.sh"
setup
HARNESS_ROOT="$(cd "${HARNESS_ROOT}" && pwd)"
export HARNESS_ROOT
# setup in helpers.sh assigns _tmpdir.
# shellcheck disable=SC2154
export HARNESS_DATA="${_tmpdir}/data" HARNESS_ACTOR=main
source "${HARNESS_ROOT}/lib/memory.sh"

event() {
  local seq="$1" actor="$2" kind="$3" text="$4" date="${5:-2026-10-08T00:00:00Z}"
  jq -cn --argjson seq "${seq}" --arg actor "${actor}" --arg kind "${kind}" --arg text "${text}" --arg date "${date}" \
    '{seq:$seq,id:("e"+($seq|tostring)),actor:$actor,kind:"message",data:{kind:$kind,text:$text},date:$date}'
}
check() { [[ "$1" == "$2" ]] || { printf 'FAIL: %s\nexpected: %s\nactual: %s\n' "$3" "$2" "$1" >&2; exit 1; }; }
fail_if() { if "$@" >/dev/null 2>&1; then echo "FAIL: unexpectedly accepted $*" >&2; exit 1; fi; }

# Source attribution, short leaves, day files, duplicates, and lookup.
first="$(event 1 main user 'hello é😀')"
memory_ingest "${first}"
memory_ingest "${first}"
memory_ingest "$(event 2 main note 'a retained decision' 2026-10-09T01:02:03Z)"
memory_ingest '{"seq":3,"actor":"main","kind":"request.created","data":{},"date":"2026-10-09T01:02:03Z"}'
dir="${HARNESS_DATA}/actors/main/memory"
check "$(jq -r '.total' "${dir}/state.json")" 2 'duplicate and internal events must not create messages'
check "$(wc -l < "${dir}/main/2026-10-08.jsonl" | tr -d ' ')" 1 'one immutable source record'
check "$(memory_date main 1 | jq -r '.date')" '2026-10-09T01:02:03Z' 'date uses permanent id'
check "$(memory_zoom main 0 1 | jq -r '.text')" 'hello é😀' 'original UTF-8 text'
check "$(memory_zoom main 0 2 | jq '.children|length')" 2 'zoom expands built parent'
fail_if memory_zoom main 1 2
fail_if memory_zoom main 0 3
fail_if memory_date main 999
memory_ready main 1
check "$(memory_view main 1 | sed -n '2p')" '0+1|user: hello é😀' 'event boundary excludes later messages'
check "$(memory_view main | wc -c | tr -d ' ')" "$(_memory_view_nodes "${dir}" "${dir}/view.json" | jq -cs '.' | _memory_view_bytes)" 'view budgets count actual rendered UTF-8 bytes'
saved_main_view="$(cat "${dir}/view.json")"
printf '[[1,0]]\n' > "${dir}/view.json"
mv "${dir}/nodes/0-0.json" "${_tmpdir}/held-node"
fail_if memory_view main 1
mv "${_tmpdir}/held-node" "${dir}/nodes/0-0.json"
printf '%s\n' "${saved_main_view}" > "${dir}/view.json"
check "$(printf '{"id":0}\n' | "${HARNESS_ROOT}/plugins/memory/tools/zoom" --exec | jq -r '.text')" 'hello é😀' 'zoom tool protocol'
check "$(printf '{"id":1}\n' | "${HARNESS_ROOT}/plugins/memory/tools/date" --exec | jq -r '.source_seq')" 2 'date tool protocol'
jq -cn '{actors:{main:{id:"main",name:"Helper"},other:{id:"other",name:"main"}}}' > "${HARNESS_DATA}/state.json"
check "$(printf '{"id":"Helper","page":1}\n' | "${HARNESS_ROOT}/plugins/memory/tools/zoom" --exec | jq -r '.text')" 'a retained decision' 'named actor retrieves original chat pages'
check "$(printf '{"id":"main"}\n' | "${HARNESS_ROOT}/plugins/memory/tools/zoom" --exec | jq -r '.text')" 'hello é😀' 'actor identifiers take precedence over another actor name'

# Long non-tool messages split at UTF-8 character boundaries and retain all text.
utf8='é😀漢aé😀漢b'
MEMORY_MESSAGE_BYTES=8 memory_ingest "$(event 4 utf8 user "${utf8}")"
udir="${HARNESS_DATA}/actors/utf8/memory"
check "$(jq -sr '[.[].text]|join("")' "${udir}/main/2026-10-08.jsonl")" "${utf8}" 'split messages retain exact text'
check "$(jq -sr 'all(.[]; .size<=8 and .size==(.text|utf8bytelength))' "${udir}/main/2026-10-08.jsonl")" true 'split budget is UTF-8 bytes'
check "$(MEMORY_ZOOM_PAGE_CHARS=2 memory_zoom utf8 0 1 0 | jq -r '.text')" 'é😀' 'zoom pages preserve codepoints'
fail_if memory_zoom utf8 0 1 100

# Indexed actor tails use exclusive/inclusive event boundaries, retain all
# UTF-8 chunks, and return source records even before summaries are built.
check "$(memory_tail utf8 3 4 | jq -sr '[.[].text]|join("")')" "${utf8}" 'tail retains all parts at its inclusive boundary'
check "$(memory_tail utf8 4 | jq -s 'length')" 0 'tail excludes every chunk of its starting source event'
memory_ingest "$(event 6 utf8 note 'next exact text')"
check "$(memory_tail utf8 -1 5 | jq -sr 'all(.[];.source_seq==4 and .kind=="user")')" true 'tail filters actor and upper event boundary'
check "$(memory_tail utf8 4 6 | jq -cs '[.[].source_seq]')" '[6]' 'tail skips other actor events in the global sequence'
check "$(memory_tail utf8 6 4 | jq -s 'length')" 0 'reversed boundaries have no tail'
fail_if memory_tail utf8 -2
raw_tail="$(jq -nr '"r"*600+"\né😀\n"')"
memory_ingest "$(event 7 tail user "${raw_tail}")"
fail_if memory_ready tail
tail_view="$(cat "${HARNESS_DATA}/actors/tail/memory/view.json")"
check "$(memory_tail tail -1 7 | jq -sr '[.[].text]|join("")')" "${raw_tail}" 'tail reads originals without unresolved placeholders'
check "$(cat "${HARNESS_DATA}/actors/tail/memory/view.json")" "${tail_view}" 'tail preserves the saved view'

# Tool output clipping is explicit; the original source remains an artifact.
output="$(jq -nr '"a"*16000+"MIDDLE"+"z"*16000')"
memory_ingest "$(event 5 echoes echo "${output}")"
edir="${HARNESS_DATA}/actors/echoes/memory"
check "$(jq '.text|length' "${edir}/messages/0.json")" 30000 'echo character cap includes marker'
check "$(jq -r '.data.text' "${edir}/raw/5.json")" "${output}" 'raw echo retained'

# Unsummarized leaves block turns, but not each other; parents require both halves.
big="$(jq -nr '"x"*600')"
memory_ingest "$(event 10 long user "${big}")"
memory_ingest "$(event 11 long user "${big}")"
fail_if memory_ready long
fail_if memory_view long
pending="$(memory_pending long)"
check "$(printf '%s' "${pending}" | jq 'length')" 2 'both eligible leaf jobs returned'
check "$(printf '%s' "${pending}" | jq -r 'all(.[];.context=="<chat>\n</chat>")')" true 'contexts stop at first missing summary'
leaf_summary="$(jq -nr '"s"*300')"
memory_apply long 0 1 "${leaf_summary}"
check "$(memory_pending long | jq 'length')" 1 'parent not ready until both children are built'
memory_apply long 0 0 "${leaf_summary}"
memory_ready long
pending="$(memory_pending long)"
check "$(printf '%s' "${pending}" | jq -r '.[0].id')" summary-long-1-0 'deterministic ready parent id'
check "$(printf '%s' "${pending}" | jq -r '.[0].text_a|length')" 300 'parent carries exact first child'
memory_apply long 1 0 'both important messages'
before="$(memory_view long)"
memory_apply long 1 0 'a later completion must not rewrite a node'
check "$(memory_view long)" "${before}" 'nodes are immutable'
check "$(memory_pending long)" '[]' 'completed work leaves no queued job'
fail_if memory_apply long 1 1 unknown

# Batch merging only uses built parents and resumes shrink work after publication.
MEMORY_VIEW_HIGH=150 MEMORY_VIEW_LOW=80 memory_ingest "$(event 20 gate user "${big}")"
MEMORY_VIEW_HIGH=150 MEMORY_VIEW_LOW=80 memory_ingest "$(event 21 gate user "${big}")"
MEMORY_VIEW_HIGH=150 MEMORY_VIEW_LOW=80 memory_apply gate 0 0 "${leaf_summary}"
MEMORY_VIEW_HIGH=150 MEMORY_VIEW_LOW=80 memory_apply gate 0 1 "${leaf_summary}"
gdir="${HARNESS_DATA}/actors/gate/memory"
check "$(jq 'length' "${gdir}/view.json")" 2 'unbuilt parent cannot merge'
check "$(jq '.view_shrinking' "${gdir}/state.json")" true 'unfinished batch retained'
MEMORY_VIEW_HIGH=150 MEMORY_VIEW_LOW=80 memory_apply gate 1 0 'two durable facts'
check "$(cat "${gdir}/view.json")" '[[1,0]]' 'parent completion finishes batch'
check "$(jq '.view_shrinking' "${gdir}/state.json")" false 'completed batch resets flag'
saved="$(cat "${gdir}/view.json")"
source "${HARNESS_ROOT}/lib/memory.sh"
memory_view gate >/dev/null
check "$(cat "${gdir}/view.json")" "${saved}" 'restart loads stable saved view'

# At T=10, pair-end priority merges 8-9 ahead of 0-7 (the source counterexample).
small="$(jq -nr '"p"*100')"
for seq in {30..39}; do memory_ingest "$(event "${seq}" priority user "${small}")"; done
pdir="${HARNESS_DATA}/actors/priority/memory"
memory_apply priority 3 0 'old combined history'
printf '[[2,0],[2,1],[0,8],[0,9]]\n' > "${pdir}/view.json"
bytes="$(_memory_view_nodes "${pdir}" "${pdir}/view.json" | jq -cs '.' | _memory_view_bytes)"
_memory_fit "${pdir}" "${pdir}/view.json" view_shrinking "$((bytes-1))" "$((bytes-2))" 10
check "$(cat "${pdir}/view.json")" '[[2,0],[2,1],[1,4]]' 'end-normalized merge order'

# Equal pair scores prefer the older pair, even when its node size differs.
for seq in {300..306}; do memory_ingest "$(event "${seq}" ties user "${small}")"; done
tdir="${HARNESS_DATA}/actors/ties/memory"
printf '[[1,0],[1,1],[0,4],[0,5],[0,6]]\n' > "${tdir}/view.json"
bytes="$(_memory_view_nodes "${tdir}" "${tdir}/view.json" | jq -cs '.' | _memory_view_bytes)"
_memory_fit "${tdir}" "${tdir}/view.json" view_shrinking "$((bytes-1))" "$((bytes-2))" 7
check "$(cat "${tdir}/view.json")" '[[2,0],[0,4],[0,5],[0,6]]' 'oldest pair wins an equal score'

# Already queued or retry-gated merges do not consume the bounded result list.
for seq in {100..115}; do memory_ingest "$(event "${seq}" starvation user "${big}")"; done
for id in {0..15}; do memory_apply starvation 0 "${id}" "${leaf_summary}"; done
memory_ingest "$(event 116 starvation user "${big}")"
check "$(memory_pending starvation | jq 'all(.[];.l==1)')" true 'eight older merge tasks precede the new leaf'
excluded="$(jq -cn '[range(0;8)|"1-"+tostring]')"
pending="$(memory_pending starvation "${excluded}" 8)"
check "$(printf '%s' "${pending}" | jq -r '.[0].id')" summary-starvation-0-16 'excluded merge tasks cannot starve a leaf'
check "$(printf '%s' "${pending}" | jq 'length')" 1 'bounded list skips all excluded entries'

# Excluding in-flight leaves must not bypass the eight-unbuilt-predecessor gate.
for seq in {200..208}; do memory_ingest "$(event "${seq}" ahead user "${big}")"; done
excluded="$(jq -cn '[range(0;8)|"0-"+tostring]')"
check "$(memory_pending ahead "${excluded}" 8)" '[]' 'in-flight leaves still count toward ahead limit'

# Recover an interrupted transaction without duplicate log entries or lost work.
record="$(event 50 recovery user 'recover exactly once')"
actor=recovery
rdir="${HARNESS_DATA}/actors/${actor}/memory"
memory_ingest "${record}"
message="$(cat "${rdir}/messages/0.json")"
jq -cn --argjson message "${message}" '{op:"ingest",source_seq:50,start:0,messages:[$message]}' > "${rdir}/transaction.json"
memory_ready recovery
check "$(wc -l < "${rdir}/main/2026-10-08.jsonl" | tr -d ' ')" 1 'recovery does not duplicate main log'
check "$(wc -l < "${rdir}/tree/2026-10-08.jsonl" | tr -d ' ')" 1 'recovery does not duplicate tree log'
[[ ! -f "${rdir}/transaction.json" ]] || { echo 'FAIL: recovery journal retained' >&2; exit 1; }

# A process stopped during a long append leaves an uncommitted partial tail.
# The saved offset permits repair without changing any committed message line.
message="$(printf '%s' "${message}" | jq -c '.id=1 | .source_seq=51 | .date="2026-10-10T00:00:00Z"')"
jq -cn --argjson message "${message}" '{op:"ingest",source_seq:51,start:1,messages:[$message]}' > "${rdir}/transaction.json"
printf '{"offset":0}\n' > "${rdir}/logged/main/1.pending"
printf '{"id":1,"kind"' > "${rdir}/main/2026-10-10.jsonl"
memory_ready recovery
check "$(jq -r '.id' "${rdir}/main/2026-10-10.jsonl")" 1 'interrupted append repaired from transaction'
check "$(wc -l < "${rdir}/main/2026-10-08.jsonl" | tr -d ' ')" 1 'committed lines survive partial-tail repair'

echo PASS
