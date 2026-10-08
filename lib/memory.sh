# shellcheck shell=bash
# Persistent chat memory. Source this file; public functions are memory_*.
# The log and nodes are immutable. Views and ready queues are recoverable state.
set -euo pipefail

_memory_dir() {
  local actor="$1"
  [[ "${actor}" =~ ^[A-Za-z0-9_.-]+$ && "${actor}" != . && "${actor}" != .. ]] || {
    echo 'memory: invalid actor' >&2; return 1;
  }
  [[ -n "${HARNESS_DATA:-}" ]] || { echo 'memory: HARNESS_DATA is required' >&2; return 1; }
  printf '%s/actors/%s/memory\n' "${HARNESS_DATA}" "${actor}"
}

_memory_write() {
  local file="$1" json="$2" tmp
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  printf '%s\n' "${json}" > "${tmp}" && mv "${tmp}" "${file}"
}

_memory_flush() {
  # sync -f flushes the filesystem containing the journal on GNU systems.
  # Plain sync provides the same ordering barrier on other platforms.
  sync -f "$1" 2>/dev/null || sync
}

_memory_init() {
  local dir="$1"
  mkdir -p "${dir}"/{main,tree,messages,nodes,ready,sources,raw,logged/main,logged/tree}
  [[ -f "${dir}/state.json" ]] || _memory_write "${dir}/state.json" '{"version":1,"total":0,"last_source_seq":-1,"view_shrinking":false,"compact_shrinking":false}'
  [[ -f "${dir}/view.json" ]] || _memory_write "${dir}/view.json" '[]'
  [[ -f "${dir}/compact-view.json" ]] || _memory_write "${dir}/compact-view.json" '[]'
}

_memory_log() {
  local file="$1" record="$2" identity="$3" marker="$4" pending offset actual expected last
  if [[ -f "${marker}" ]]; then rm -f "${marker}.pending"; return 0; fi
  pending="${marker}.pending"
  if [[ -f "${pending}" ]]; then
    offset="$(jq -r '.offset' "${pending}")"
  else
    offset=0; [[ ! -f "${file}" ]] || offset="$(wc -c < "${file}")"
    _memory_write "${pending}" "$(jq -cn --argjson offset "${offset}" '{offset:$offset}')" || return 1
    _memory_flush "$(dirname "${pending}")" || return 1
  fi
  actual=0; [[ ! -f "${file}" ]] || actual="$(wc -c < "${file}")"
  expected=$((offset + $(printf '%s\n' "${record}" | wc -c)))
  (( actual >= offset && actual <= expected )) || { echo 'memory: invalid append recovery boundary' >&2; return 1; }
  if (( actual > offset && actual < expected )); then
    # Only an uncommitted partial record is removed; committed lines remain
    # immutable. Its complete source is still in the operation journal.
    truncate -s "${offset}" "${file}" || return 1
    actual="${offset}"
  fi
  if (( actual == offset )); then
    printf '%s\n' "${record}" >> "${file}" || return 1
  else
    last="$(tail -n 1 "${file}" | jq -c "${identity}")" || return 1
    [[ "${last}" == "$(printf '%s' "${record}" | jq -c "${identity}")" ]] || return 1
    [[ -z "$(tail -c 1 "${file}")" ]] || return 1
  fi
  _memory_flush "${file}" || return 1
  : > "${marker}"
  rm -f "${pending}"
}

_memory_queue() {
  local dir="$1" actor="$2" level="$3" index="$4" message="${5:-null}" record
  [[ ! -f "${dir}/nodes/${level}-${index}.json" ]] || return 0
  [[ ! -f "${dir}/ready/${level}-${index}.json" ]] || return 0
  if (( level == 0 )); then
    record="$(printf '%s' "${message}" | jq -c --arg actor "${actor}" --arg id "summary-${actor}-${level}-${index}" \
      '{id:$id,actor:$actor,l:0,i:.id,source_seq:.source_seq,message:.}')"
  else
    record="$(jq -c -s --arg actor "${actor}" --arg id "summary-${actor}-${level}-${index}" \
      --argjson l "${level}" --argjson i "${index}" \
      '{id:$id,actor:$actor,l:$l,i:$i,text_a:.[0].text,text_b:.[1].text}' \
      "${dir}/nodes/$((level - 1))-$((index * 2)).json" \
      "${dir}/nodes/$((level - 1))-$((index * 2 + 1)).json")"
  fi
  _memory_write "${dir}/ready/${level}-${index}.json" "${record}"
}

# Publishing a node also makes its parent eligible. Short sibling lines need
# no model call, so they can be joined recursively without queueing work.
_memory_publish() {
  local dir="$1" actor="$2" node="$3" level index day sibling parent joined size
  read -r level index <<< "$(printf '%s' "${node}" | jq -r '[.l,.i] | @tsv')"
  day="$(printf '%s' "${node}" | jq -r '.date[0:10]')"
  [[ -f "${dir}/nodes/${level}-${index}.json" ]] || _memory_write "${dir}/nodes/${level}-${index}.json" "${node}" || return 1
  # If recovery encounters an already-published node, its original bytes win.
  node="$(cat "${dir}/nodes/${level}-${index}.json")"
  _memory_log "${dir}/tree/${day}.jsonl" "${node}" '[.l,.i]' "${dir}/logged/tree/${level}-${index}" || return 1
  rm -f "${dir}/ready/${level}-${index}.json"
  sibling=$(( index ^ 1 )); parent=$(( index / 2 ))
  [[ -f "${dir}/nodes/${level}-${sibling}.json" ]] || return 0
  if [[ -f "${dir}/nodes/$((level + 1))-${parent}.json" ]]; then
    _memory_publish "${dir}" "${actor}" "$(cat "${dir}/nodes/$((level + 1))-${parent}.json")"
    return
  fi
  joined="$(jq -c -s --argjson l "$((level + 1))" --argjson i "${parent}" \
    '([.[0].text,.[1].text] | join("\n")) as $text |
     {l:$l,i:$i,text:$text,size:($text|utf8bytelength),date:.[1].date}' \
    "${dir}/nodes/${level}-$((parent * 2)).json" "${dir}/nodes/${level}-$((parent * 2 + 1)).json")"
  size="$(printf '%s' "${joined}" | jq -r '.size')"
  if (( size <= 512 )); then
    _memory_publish "${dir}" "${actor}" "${joined}"
  else
    _memory_queue "${dir}" "${actor}" "$((level + 1))" "${parent}"
  fi
}

_memory_append_view() {
  local file="$1" id="$2" view end
  view="$(cat "${file}")"
  end="$(printf '%s' "${view}" | jq -r 'if length == 0 then 0 else .[-1] | (.[1]+1)*pow(2;.[0]) end')"
  (( end > id )) && return 0
  (( end == id )) || { echo 'memory: view coverage gap' >&2; return 1; }
  _memory_write "${file}" "$(printf '%s' "${view}" | jq -c --argjson id "${id}" '. + [[0,$id]]')"
}

# Read only the nodes referenced by a view, never enumerate the tree.
_memory_view_nodes() {
  local dir="$1" file="$2" level index path
  while IFS=$'\t' read -r level index; do
    path="${dir}/nodes/${level}-${index}.json"
    if [[ -f "${path}" ]]; then
      cat "${path}"
    else
      jq -c -n --argjson l "${level}" --argjson i "${index}" \
        '{l:$l,i:$i,text:"(not summarized yet: zoom it)",size:29,unbuilt:true}'
    fi
  done < <(jq -r '.[] | @tsv' "${file}")
}

_memory_view_bytes() {
  jq -r '14 + (map(.size + (((.i*pow(2;.l))|tostring)|length) + ((pow(2;.l)|tostring)|length) + 3) | add // 0)'
}

# The score uses the pair end, not its start: subtracting the common 2 from
# (T+1)/2^l-i gives (T-last)/2^l and does not alter ordering.
_memory_fit() {
  local dir="$1" file="$2" flag="$3" high="$4" low="$5" total="$6"
  local nodes bytes shrinking candidates pos level index parent found state
  if ! [[ "${high}" =~ ^[1-9][0-9]*$ && "${low}" =~ ^[1-9][0-9]*$ ]] || ! (( low < high )); then
    echo 'memory: view budgets must be positive and low < high' >&2; return 1;
  fi
  nodes="$(_memory_view_nodes "${dir}" "${file}" | jq -cs '.')"
  bytes="$(printf '%s' "${nodes}" | _memory_view_bytes)"
  shrinking="$(jq -r --arg flag "${flag}" '.[$flag]' "${dir}/state.json")"
  if (( bytes > high )); then shrinking=true; fi
  [[ "${shrinking}" == true ]] || return 0
  state="$(jq -c --arg flag "${flag}" '.[$flag]=true | if $flag=="view_shrinking" then .compact_shrinking=true else . end' "${dir}/state.json")"
  _memory_write "${dir}/state.json" "${state}"
  while (( bytes > low )); do
    candidates="$(printf '%s' "${nodes}" | jq -r --argjson total "${total}" '
      . as $nodes | [range(0;length-1) as $p | $nodes[$p] as $a | $nodes[$p+1] as $b |
        select($a.l == $b.l and ($a.i % 2 == 0) and $b.i == $a.i+1) |
        {p:$p,l:$a.l,i:$a.i,score:(($total+1)/pow(2;$a.l)-$a.i)}] |
      sort_by([(-.score),(.i*pow(2;.l))])[] | [.p,.l,.i] | @tsv')"
    found=false
    while IFS=$'\t' read -r pos level index; do
      [[ -n "${pos}" ]] || continue
      parent="${dir}/nodes/$((level + 1))-$((index / 2)).json"
      [[ -f "${parent}" ]] || continue
      nodes="$(printf '%s\n%s' "${nodes}" "$(cat "${parent}")" | jq -cs --argjson p "${pos}" '.[0][:$p] + [.[1]] + .[0][$p+2:]')"
      found=true
      break
    done <<< "${candidates}"
    [[ "${found}" == true ]] || break
    bytes="$(printf '%s' "${nodes}" | _memory_view_bytes)"
  done
  _memory_write "${file}" "$(printf '%s' "${nodes}" | jq -c 'map([.l,.i])')"
  if (( bytes <= low )); then shrinking=false; fi
  state="$(jq -c --arg flag "${flag}" --argjson shrinking "${shrinking}" '.[$flag]=$shrinking' "${dir}/state.json")"
  _memory_write "${dir}/state.json" "${state}"
}

_memory_fit_views() {
  local dir="$1" total before after
  total="$(jq -r '.total' "${dir}/state.json")"
  before="$(cat "${dir}/view.json")"
  _memory_fit "${dir}" "${dir}/view.json" view_shrinking "${MEMORY_VIEW_HIGH:-128000}" "${MEMORY_VIEW_LOW:-64000}" "${total}" || return 1
  after="$(cat "${dir}/view.json")"
  # A chat batch also starts a compaction-view batch, retaining its own view.
  if [[ "${before}" != "${after}" ]]; then
    _memory_write "${dir}/state.json" "$(jq -c '.compact_shrinking=true' "${dir}/state.json")"
  fi
  _memory_fit "${dir}" "${dir}/compact-view.json" compact_shrinking "${MEMORY_COMPACT_HIGH:-32000}" "${MEMORY_COMPACT_LOW:-16000}" "${total}"
}

_memory_recover() {
  local dir="$1" actor="$2" txn op record id day node size seq state
  [[ -f "${dir}/transaction.json" ]] || return 0
  txn="$(cat "${dir}/transaction.json")"
  op="$(printf '%s' "${txn}" | jq -r '.op')"
  if [[ "${op}" == ingest ]]; then
    while IFS= read -r record; do
      read -r id day <<< "$(printf '%s' "${record}" | jq -r '[.id,.date[0:10]] | @tsv')"
      [[ -f "${dir}/messages/${id}.json" ]] || _memory_write "${dir}/messages/${id}.json" "${record}" || return 1
      _memory_log "${dir}/main/${day}.jsonl" "${record}" '.id' "${dir}/logged/main/${id}" || return 1
      _memory_append_view "${dir}/view.json" "${id}" || return 1
      _memory_append_view "${dir}/compact-view.json" "${id}" || return 1
      node="$(printf '%s' "${record}" | jq -c '(.kind+": "+.text) as $text | {l:0,i:.id,text:$text,size:($text|utf8bytelength),date:.date}')"
      size="$(printf '%s' "${node}" | jq -r '.size')"
      if (( size <= 512 )); then _memory_publish "${dir}" "${actor}" "${node}" || return 1
      else _memory_queue "${dir}" "${actor}" 0 "${id}" "${record}" || return 1; fi
    done < <(printf '%s' "${txn}" | jq -c '.messages[]')
    seq="$(printf '%s' "${txn}" | jq -r '.source_seq')"
    _memory_write "${dir}/sources/${seq}.json" "$(printf '%s' "${txn}" | jq -c '{seq:.source_seq,ids:[.messages[].id]}')" || return 1
    state="$(printf '%s\n%s' "$(cat "${dir}/state.json")" "${txn}" | jq -cs '.[0]+{total:(.[1].start+(.[1].messages|length)),last_source_seq:.[1].source_seq}')"
    _memory_write "${dir}/state.json" "${state}" || return 1
  elif [[ "${op}" == apply ]]; then
    _memory_publish "${dir}" "${actor}" "$(printf '%s' "${txn}" | jq -c '.node')" || return 1
  else
    echo 'memory: invalid recovery journal' >&2; return 1
  fi
  _memory_fit_views "${dir}" || return 1
  _memory_flush "${dir}" || return 1
  rm -f "${dir}/transaction.json"
  _memory_flush "${dir}"
}

memory_ingest() (
  local event="${1:-}" actor dir seq kind prepared text_limit total txn last
  [[ -n "${event}" ]] || event="$(cat)"
  printf '%s' "${event}" | jq -e '(.seq|type=="number") and (.seq>=0) and (.seq==(.seq|floor)) and (.actor|type=="string")' >/dev/null || {
    echo 'memory: invalid event' >&2; return 1;
  }
  kind="$(printf '%s' "${event}" | jq -r '.kind')"
  case "${kind}" in message|assistant|tool) ;; *) return 0 ;; esac
  actor="$(printf '%s' "${event}" | jq -r '.actor')"
  dir="$(_memory_dir "${actor}")" || return 1
  mkdir -p "${dir}"
  exec {memory_fd}>"${dir}/.lock"; flock "${memory_fd}"
  _memory_init "${dir}"; _memory_recover "${dir}" "${actor}" || return 1
  seq="$(printf '%s' "${event}" | jq -r '.seq')"
  [[ ! -f "${dir}/sources/${seq}.json" ]] || return 0
  last="$(jq -r '.last_source_seq' "${dir}/state.json")"
  (( seq > last )) || { echo 'memory: events must be ingested in source order' >&2; return 1; }
  text_limit="${MEMORY_MESSAGE_BYTES:-65536}"
  if ! [[ "${text_limit}" =~ ^[1-9][0-9]*$ ]] || ! (( text_limit >= 4 )); then
    echo 'memory: invalid message byte limit' >&2; return 1;
  fi
  total="$(jq -r '.total' "${dir}/state.json")"
  prepared="$(printf '%s' "${event}" | jq -c --argjson limit "${text_limit}" --argjson start "${total}" '
    def chunks($limit):
      explode | reduce .[] as $cp ({parts:[],buf:[],bytes:0};
        (if $cp<128 then 1 elif $cp<2048 then 2 elif $cp<65536 then 3 else 4 end) as $n |
        if .bytes+$n>$limit then .parts += [(.buf|implode)] | .buf=[$cp] | .bytes=$n
        else .buf += [$cp] | .bytes += $n end) | .parts + [(.buf|implode)];
    . as $event |
    (if .kind=="assistant" then "unii" elif .kind=="tool" then "tool" else .data.kind end) as $kind |
    if (["user","unii","tool","echo","work","note"] | index($kind)) == null then [] else
    (if .kind=="tool" then (.data.name+" "+(.data.input|tojson)) else (.data.text // "") end) as $raw |
    ($kind=="echo" and ($raw|length)>30000) as $clipped |
    (if $clipped then "\n[... tool output clipped ...]\n" as $mark |
       ((30000-($mark|length))/2|floor) as $head | $raw[:$head]+$mark+$raw[-(30000-($mark|length)-$head):]
     else $raw end) as $text |
    (if $text=="" then [] else $text|chunks($limit) end) as $parts |
    [$parts | to_entries[] | {id:($start+.key),kind:$kind,text:.value,size:(.value|utf8bytelength),
      date:$event.date,source_seq:$event.seq,source_kind:$event.kind,part:.key,parts:($parts|length)} +
      (if $clipped then {clipped:true,original_size:($raw|utf8bytelength),raw_ref:("raw/"+($event.seq|tostring)+".json")} else {} end)] end')" || return 1
  printf '%s' "${event}" | jq -e '.date|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' >/dev/null || {
    echo 'memory: event requires an ISO date' >&2; return 1;
  }
  if printf '%s' "${prepared}" | jq -e 'any(.[];.clipped==true)' >/dev/null; then
    _memory_write "${dir}/raw/${seq}.json" "${event}"
  fi
  txn="$(printf '%s' "${prepared}" | jq -c --argjson seq "${seq}" --argjson start "${total}" '{op:"ingest",source_seq:$seq,start:$start,messages:.}')"
  _memory_write "${dir}/transaction.json" "${txn}" || return 1
  _memory_flush "${dir}" || return 1
  _memory_recover "${dir}" "${actor}"
)

# Map an event boundary to a message boundary in O(log(messages)) indexed reads.
_memory_limit() {
  local dir="$1" through="${2:-}" total low high mid seq
  total="$(jq -r '.total' "${dir}/state.json")"
  if [[ -z "${through}" ]]; then printf '%s\n' "${total}"; return 0; fi
  [[ "${through}" =~ ^[0-9]+$ ]] || { echo 'memory: invalid event boundary' >&2; return 1; }
  low=0; high="${total}"
  while (( low < high )); do
    mid=$(( (low + high) / 2 ))
    seq="$(jq -r '.source_seq' "${dir}/messages/${mid}.json")"
    if (( seq <= through )); then low=$((mid + 1)); else high="${mid}"; fi
  done
  printf '%s\n' "${low}"
}

_memory_ready() {
  local dir="$1" limit="$2" file id
  for file in "${dir}/ready/0-"*.json; do
    [[ -f "${file}" ]] || continue
    id="${file##*/}"; id="${id#0-}"; id="${id%.json}"
    (( id >= limit )) || return 1
  done
}

memory_ready() (
  local actor="$1" through="${2:-}" dir limit
  dir="$(_memory_dir "${actor}")" || return 1
  mkdir -p "${dir}"
  exec {memory_fd}>"${dir}/.lock"; flock "${memory_fd}"
  _memory_init "${dir}"; _memory_recover "${dir}" "${actor}" || return 1
  limit="$(_memory_limit "${dir}" "${through}")" || return 1
  _memory_ready "${dir}" "${limit}"
)

_memory_render_coords() {
  local dir="$1" level="$2" index="$3" limit="$4" start count
  count=$((1 << level)); start=$((index * count))
  (( start < limit )) || return 0
  if (( start + count <= limit )); then
    [[ -f "${dir}/nodes/${level}-${index}.json" ]] || return 1
    printf '%s %s\n' "${level}" "${index}"
  else
    (( level > 0 )) || return 1
    _memory_render_coords "${dir}" "$((level - 1))" "$((index * 2))" "${limit}" || return 1
    _memory_render_coords "${dir}" "$((level - 1))" "$((index * 2 + 1))" "${limit}" || return 1
  fi
}

_memory_render() {
  local dir="$1" file="$2" limit="$3" level index coords=''
  local paths=()
  while IFS=$'\t' read -r level index; do
    coords+="$(_memory_render_coords "${dir}" "${level}" "${index}" "${limit}")"$'\n' || return 1
  done < <(jq -r '.[] | @tsv' "${file}")
  while read -r level index; do
    [[ -n "${level}" ]] || continue
    paths+=("${dir}/nodes/${level}-${index}.json")
  done <<< "${coords}"
  if (( ${#paths[@]} == 0 )); then printf '<chat>\n</chat>'; return 0; fi
  jq -sjr '"<chat>\n" + (map(((.i*pow(2;.l))|tostring)+"+"+(pow(2;.l)|tostring)+"|"+(.text|gsub("\n";" "))+"\n")|join("")) + "</chat>"' "${paths[@]}"
}

memory_view() (
  local actor="$1" through="${2:-}" dir limit
  dir="$(_memory_dir "${actor}")" || return 1
  mkdir -p "${dir}"
  exec {memory_fd}>"${dir}/.lock"; flock "${memory_fd}"
  _memory_init "${dir}"; _memory_recover "${dir}" "${actor}" || return 1
  limit="$(_memory_limit "${dir}" "${through}")" || return 1
  _memory_ready "${dir}" "${limit}" || { echo 'memory: prefix summaries are not ready' >&2; return 1; }
  _memory_render "${dir}" "${dir}/view.json" "${limit}"
)

# Original records after an event boundary, including every part of a split
# message. Lookup is logarithmic in history plus the records in this actor tail.
memory_tail() (
  local actor="$1" after="$2" through="${3:-}" dir start end id
  [[ "${after}" =~ ^(-1|[0-9]+)$ ]] || { echo 'memory: invalid tail boundary' >&2; return 1; }
  dir="$(_memory_dir "${actor}")" || return 1
  mkdir -p "${dir}"
  exec {memory_fd}>"${dir}/.lock"; flock "${memory_fd}"
  _memory_init "${dir}"; _memory_recover "${dir}" "${actor}" || return 1
  if [[ "${after}" == -1 ]]; then start=0
  else start="$(_memory_limit "${dir}" "${after}")" || return 1; fi
  end="$(_memory_limit "${dir}" "${through}")" || return 1
  for (( id=start; id<end; id++ )); do
    cat "${dir}/messages/${id}.json" || return 1
  done
)

memory_pending() (
  local actor="$1" exclude="${2:-[]}" cap="${3:-${MEMORY_PENDING_LIMIT:-8}}"
  local dir file first='' limit level index context candidates='' name key selected=0 leaves=0
  declare -A excluded=()
  dir="$(_memory_dir "${actor}")" || return 1
  mkdir -p "${dir}"
  exec {memory_fd}>"${dir}/.lock"; flock "${memory_fd}"
  _memory_init "${dir}"; _memory_recover "${dir}" "${actor}" || return 1
  [[ "${cap}" =~ ^[1-9][0-9]*$ ]] || { echo 'memory: invalid pending limit' >&2; return 1; }
  printf '%s' "${exclude}" | jq -e 'type=="array" and all(.[];type=="string" and test("^[0-9]+-[0-9]+$"))' >/dev/null || {
    echo 'memory: excluded work must be an array of level-index keys' >&2; return 1;
  }
  while IFS= read -r key; do excluded["${key}"]=1; done < <(printf '%s' "${exclude}" | jq -r '.[]')
  # Enumeration is confined to unfinished work; completed tree nodes are never scanned.
  for file in "${dir}/ready/"*.json; do
    [[ -f "${file}" ]] || continue
    name="${file##*/}"; level="${name%%-*}"; index="${name#*-}"; index="${index%.json}"
    candidates+="$((index * (1 << level))) ${level} ${index}"$'\n'
    if (( level == 0 )) && { [[ -z "${first}" ]] || (( index < first )); }; then first="${index}"; fi
  done
  while read -r limit level index; do
    [[ -n "${level}" ]] || continue
    if (( level == 0 )); then
      leaves=$((leaves + 1))
      # In-flight or excluded leaves still count as unresolved predecessors.
      (( leaves <= 8 )) || continue
    fi
    key="${level}-${index}"
    [[ -z "${excluded[${key}]+x}" ]] || continue
    file="$(cat "${dir}/ready/${level}-${index}.json")"
    if (( level == 0 )); then limit="${index}"; else limit=$(((index + 1) * (1 << level))); fi
    if [[ -n "${first}" ]] && (( first < limit )); then limit="${first}"; fi
    context="$(_memory_render "${dir}" "${dir}/compact-view.json" "${limit}")" || return 1
    printf '%s' "${file}" | jq -c --arg context "${context}" '.+{context:$context}'
    selected=$((selected + 1))
    (( selected < cap )) || break
  done < <(printf '%s' "${candidates}" | sort -n -k1,1 -k2,2) | jq -cs '.'
)

memory_apply() (
  local actor="$1" level="$2" index="$3" summary="${4:-}" dir node date total
  if ! [[ "${level}" =~ ^[0-9]+$ && "${index}" =~ ^[0-9]+$ ]] || ! (( level < 52 )); then
    echo 'memory: invalid node coordinates' >&2; return 1;
  fi
  [[ -n "${summary}" ]] || summary="$(cat)"
  [[ -n "${summary}" ]] || { echo 'memory: empty summary' >&2; return 1; }
  dir="$(_memory_dir "${actor}")" || return 1
  mkdir -p "${dir}"
  exec {memory_fd}>"${dir}/.lock"; flock "${memory_fd}"
  _memory_init "${dir}"; _memory_recover "${dir}" "${actor}" || return 1
  [[ ! -f "${dir}/nodes/${level}-${index}.json" ]] || return 0
  [[ -f "${dir}/ready/${level}-${index}.json" ]] || { echo 'memory: node is not ready for compaction' >&2; return 1; }
  total="$(jq -r '.total' "${dir}/state.json")"
  (( (index + 1) * (1 << level) <= total )) || return 1
  date="$(jq -r '.date' "${dir}/messages/$(((index + 1) * (1 << level) - 1)).json")"
  node="$(printf '%s' "${summary}" | jq -c -Rs --argjson l "${level}" --argjson i "${index}" --arg date "${date}" '{l:$l,i:$i,text:.,size:utf8bytelength,date:$date}')"
  _memory_write "${dir}/transaction.json" "$(printf '%s' "${node}" | jq -c '{op:"apply",node:.}')" || return 1
  _memory_flush "${dir}" || return 1
  _memory_recover "${dir}" "${actor}" || return 1
)

memory_zoom() (
  local actor="$1" id="$2" count="$3" page="${4:-0}" dir level=0 index message
  [[ "${id}" =~ ^[0-9]+$ && "${count}" =~ ^[1-9][0-9]*$ && "${page}" =~ ^[0-9]+$ ]] || { echo 'memory: invalid zoom coordinates' >&2; return 1; }
  (( (count & (count - 1)) == 0 && id % count == 0 )) || { echo 'memory: zoom requires an aligned power-of-two range' >&2; return 1; }
  dir="$(_memory_dir "${actor}")" || return 1
  [[ -d "${dir}" ]] || { echo 'memory: actor has no memory' >&2; return 1; }
  exec {memory_fd}>"${dir}/.lock"; flock "${memory_fd}"
  _memory_recover "${dir}" "${actor}"
  if (( count == 1 )); then
    [[ -f "${dir}/messages/${id}.json" ]] || { echo 'memory: message not found' >&2; return 1; }
    # Pages are character boundaries; their UTF-8 bytes remain intact.
    jq -c --argjson page "${page}" --argjson size "${MEMORY_ZOOM_PAGE_CHARS:-16000}" '
      . as $message | (.text|length) as $n | (($n/$size)|ceil) as $pages |
      if $size<1 or $page >= ($pages|if .==0 then 1 else . end) then error("page out of range") else
      . + {text:(.text[$page*$size:($page+1)*$size]),page:$page,pages:($pages|if .==0 then 1 else . end),
        more:(($page+1)*$size<$n)} end' "${dir}/messages/${id}.json"
  else
    while (( (1 << level) < count )); do level=$((level + 1)); done
    index=$((id / count))
    [[ -f "${dir}/nodes/${level}-${index}.json" && -f "${dir}/nodes/$((level - 1))-$((index * 2)).json" && -f "${dir}/nodes/$((level - 1))-$((index * 2 + 1)).json" ]] || {
      echo 'memory: summary range not found' >&2; return 1;
    }
    jq -cs --argjson id "${id}" --argjson n "${count}" '{id:$id,n:$n,children:[.[]|{id:(.i*pow(2;.l)),n:pow(2;.l),text:.text}]}' \
      "${dir}/nodes/$((level - 1))-$((index * 2)).json" "${dir}/nodes/$((level - 1))-$((index * 2 + 1)).json"
  fi
)

memory_date() (
  local actor="$1" id="$2" dir
  [[ "${id}" =~ ^[0-9]+$ ]] || { echo 'memory: invalid message id' >&2; return 1; }
  dir="$(_memory_dir "${actor}")" || return 1
  [[ -d "${dir}" ]] || { echo 'memory: actor has no memory' >&2; return 1; }
  exec {memory_fd}>"${dir}/.lock"; flock "${memory_fd}"
  _memory_recover "${dir}" "${actor}" || return 1
  [[ -f "${dir}/messages/${id}.json" ]] || { echo 'memory: message not found' >&2; return 1; }
  jq -c '{id,date,source_seq}' "${dir}/messages/${id}.json"
)
