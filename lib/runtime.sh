#!/usr/bin/env bash
# Event projection and scheduling. Called by an isolated, versioned tick process.
set -euo pipefail

state_update() { jq -c "$@" "${HARNESS_DATA}/state.json" | atomic_write "${HARNESS_DATA}/state.json"; }
state_actor() { jq -c --arg a "$1" '.actors[$a] // empty' "${HARNESS_DATA}/state.json"; }

runtime_queue_request() {
  local record="$1" id priority
  id="$(printf '%s' "${record}" | jq -r '.id')"
  priority=0-turn
  [[ "$(printf '%s' "${record}" | jq -r '.kind')" != summary ]] || priority=1-summary
  mkdir -p "${HARNESS_DATA}/requests/${id}"
  if [[ ! -f "${HARNESS_DATA}/requests/${id}/request.json" ]]; then
    printf '%s\n' "${record}" | atomic_write "${HARNESS_DATA}/requests/${id}/request.json"
  fi
  if [[ ! -f "${HARNESS_DATA}/requests/${id}/result.json" ]]; then
    printf '%s\n' "${record}" | atomic_write "${HARNESS_DATA}/queue/requests/${priority}/${id}.json"
  fi
}

runtime_response() {
  local event="$1" actor id record response blocks assistant text job index=0 call receipt receipts='[]' ledger
  actor="$(printf '%s' "${event}" | jq -r '.actor')"
  id="$(printf '%s' "${event}" | jq -r '.data.id')"
  record="$(cat "${HARNESS_DATA}/requests/${id}/request.json")"
  response="$(printf '%s' "${event}" | jq -c '.data.response')"
  if [[ "$(printf '%s' "${record}" | jq -r '.kind')" == summary ]]; then
    runtime_summary_result "${record}" "${response}"
    state_update 'del(.requests[$id])' --arg id "${id}"
    return
  fi
  [[ "$(state_actor "${actor}" | jq -r '.request')" == "${id}" ]] || return 0
  blocks="$(printf '%s' "${response}" | jq -c '.blocks')"
  text="$(printf '%s' "${blocks}" | jq -jr '[.[] | select(.type=="text") | .text] | join("\n")'; printf x)"; text="${text%x}"
  if [[ -n "${text}" ]]; then
    assistant="$(printf '%s\n%s' "$(printf '%s' "${text}" | jq -Rs .)" "${blocks}" | jq -cs --arg request "${id}" '{text:.[0],blocks:.[1],request_id:$request}')"
    store_emit assistant "${actor}" "${assistant}" "assistant-${id}" >/dev/null
  fi
  while IFS= read -r call; do
    index=$((index+1))
    local jid name binary code
    jid="job-$(stable_id "${id}:${index}")"
    name="$(printf '%s' "${call}" | jq -r '.name')"
    code="$(printf '%s' "${record}" | jq -r '.code_root')"
    binary="$(printf '%s' "${record}" | jq -r --arg n "${name}" '.tool_bins[$n] // ""')"
    job="$(printf '%s' "${call}" | jq -c --slurpfile request "${HARNESS_DATA}/requests/${id}/request.json" --arg id "${jid}" --arg actor "${actor}" --arg binary "${binary}" --arg code "${code}" --arg cwd "$(state_actor "${actor}" | jq -r '.cwd')" '{id:$id,actor:$actor,name:.name,input:.input,call_id:.id,binary:$binary,code_root:$code,cwd:$cwd,epoch:($request[0].epoch // 0),kind:(if .name=="agent" then "child" else "tool" end),parent_context:(if .name=="agent" then [{role:"user",content:("<parent-context>\n"+($request[0].payload.messages|map(if .role=="assistant" then .blocks|map(if .type=="text" then .text else (.name+" "+(.input|tojson)) end)|join("\n") else .content end)|join("\n"))+"\n</parent-context>")}] else null end)}')"
    store_emit tool "${actor}" "$(printf '%s' "${job}" | jq -c '{name,input,call_id,job_id:.id}')" "tool-${jid}" >/dev/null
    store_emit job.queued "${actor}" "${job}" "queued-${jid}" >/dev/null
    receipt="$(printf '%s' "${job}" | jq -c '{role:"tool",call_id,name,content:({job_id:.id,status:"queued"}|tojson),error:false}')"
    receipts="$(printf '%s\n%s' "${receipts}" "${receipt}" | jq -cs '.[0]+[.[1]]')"
  done < <(printf '%s' "${blocks}" | jq -c '.[] | select(.type=="tool_call")')
  assistant="$(printf '%s' "${response}" | jq -c '{role:"assistant",blocks,provider_state:(.provider_state // null)}')"
  ledger="$(printf '%s\n%s\n%s' "$(state_actor "${actor}" | jq -c '.ledger')" "${assistant}" "${receipts}" | jq -cs '.[0]+[.[1]]+.[2]')"
  local stop length_count
  stop="$(printf '%s' "${response}" | jq -r '.stop')"
  length_count="$(state_actor "${actor}" | jq -r '.length_count // 0')"
  if [[ "${stop}" == length ]]; then
    length_count=$((length_count+1))
    if (( length_count > ${HARNESS_LENGTH_CONTINUATIONS:-2} )); then
      runtime_fail_actor "${actor}" "${id}" 'output limit reached repeatedly'; return
    fi
    ledger="$(printf '%s' "${ledger}" | jq -c '.+[{role:"user",content:"Continue the truncated response from where it ended. Do not repeat completed work."}]')"
  fi
  local followup=false sticky=false
  # Queuing a job is not new input. Resume when its result (or user input)
  # arrives, rather than asking the model to narrate a potentially stale receipt.
  # Tool rounds keep the turn anchored on its user message: the ledger keeps
  # the tool_use blocks and receipts so results continue the same turn.
  [[ "${stop}" == length ]] && followup=true
  [[ "${stop}" == tool_calls ]] && sticky=true
  printf '%s' "${ledger}" > "${HARNESS_DATA}/requests/${id}/ledger.json"
  printf '%s' "${text}" > "${HARNESS_DATA}/requests/${id}/text"
  state_update '.actors[$a].request=null | .actors[$a].ledger=$ledger[0] | .actors[$a].followup=$followup | .actors[$a].length_count=$length | .actors[$a].last_reply=$text | .actors[$a].status=(if $followup then "ready" else "idle" end) | if ($followup or $sticky) then . else .actors[$a].ledger=[] | .actors[$a].turn=null end | del(.requests[$id])' --arg a "${actor}" --arg id "${id}" --slurpfile ledger "${HARNESS_DATA}/requests/${id}/ledger.json" --argjson followup "${followup}" --argjson sticky "${sticky}" --argjson length "${length_count}" --rawfile text "${HARNESS_DATA}/requests/${id}/text"
}

runtime_fail_actor() {
  local actor="$1" id="$2" error="$3"
  store_emit error "${actor}" "$(printf '%s' "${error}" | jq -Rs '{text:.}')" "error-${id}" >/dev/null
  state_update '.actors[$a].request=null | .actors[$a].ledger=[] | .actors[$a].followup=false | .actors[$a].turn=null | .actors[$a].status="error" | .actors[$a].last_reply=$error | del(.requests[$id])' --arg a "${actor}" --arg id "${id}" --arg error "${error}"
}

runtime_apply_event() {
  local event="$1" kind actor seq data id record child message
  kind="$(printf '%s' "${event}" | jq -r '.kind')"
  actor="$(printf '%s' "${event}" | jq -r '.actor')"
  seq="$(printf '%s' "${event}" | jq -r '.seq')"
  data="$(printf '%s' "${event}" | jq -c '.data')"
  case "${kind}" in
    message|assistant|tool)
      memory_ingest "${event}" >/dev/null
      if [[ "${kind}" == message ]]; then
        if [[ "$(printf '%s' "${data}" | jq -r '.epoch // empty')" == '' || "$(printf '%s' "${data}" | jq -r '.epoch')" == "$(state_actor "${actor}" | jq -r '.epoch // 0')" ]]; then
          state_update '.actors[$a].inbox |= (. + [$seq] | unique) | .actors[$a].wake_seq=$seq | if .actors[$a].request==null then .actors[$a].status="ready" else . end' --arg a "${actor}" --argjson seq "${seq}"
        fi
      fi
      ;;
    actor.created)
      printf '%s' "${data}" > "${HARNESS_DATA}/actor-new.json"
      state_update '.actors[$a] = ($new[0]+{inbox:[],ledger:[],request:null,turn:null,pending_jobs:[],status:"idle",round:0})' --arg a "${actor}" --slurpfile new "${HARNESS_DATA}/actor-new.json"
      mkdir -p "${HARNESS_DATA}/actors/${actor}"
      ;;
    request.queued)
      if [[ "$(printf '%s' "${data}" | jq -r '.kind')" == turn && "$(printf '%s' "${data}" | jq -r '.epoch // 0')" != "$(state_actor "${actor}" | jq -r '.epoch // 0')" ]]; then
        state_update '.cursor=$seq' --argjson seq "${seq}"; return 0
      fi
      runtime_queue_request "${data}"
      id="$(printf '%s' "${data}" | jq -r '.id')"
      printf '%s' "${data}" > "${HARNESS_DATA}/request-new.json"
      state_update '.requests[$id]=($r[0]|{id,actor,kind,l,i,attempt}) | if $r[0].kind=="turn" then .actors[$a].request=$id | .actors[$a].status="running" | .actors[$a].ledger=$r[0].payload.messages | .actors[$a].inbox |= map(select(. > $r[0].wake_seq)) | .actors[$a].round=$r[0].round | if .actors[$a].turn != $r[0].turn then .actors[$a].length_count=0 else . end | .actors[$a].turn=$r[0].turn | .actors[$a].followup=false else . end' --arg a "${actor}" --arg id "${id}" --slurpfile r "${HARNESS_DATA}/request-new.json"
      ;;
    request.completed) runtime_response "${event}" ;;
    request.failed)
      id="$(printf '%s' "${data}" | jq -r '.id')"
      record="$(cat "${HARNESS_DATA}/requests/${id}/request.json")"
      if [[ "$(printf '%s' "${record}" | jq -r '.kind')" == summary ]]; then
        runtime_summary_failure "${record}" "$(printf '%s' "${data}" | jq -r '.error')"
        state_update 'del(.requests[$id])' --arg id "${id}"
      elif [[ "$(state_actor "${actor}" | jq -r '.request')" == "${id}" ]]; then
        runtime_fail_actor "${actor}" "${id}" "$(printf '%s' "${data}" | jq -r '.error')"
      fi
      ;;
    job.queued)
      if [[ "$(printf '%s' "${data}" | jq -r '.epoch // 0')" != "$(state_actor "${actor}" | jq -r '.epoch // 0')" ]]; then
        state_update '.cursor=$seq' --argjson seq "${seq}"; return 0
      fi
      id="$(printf '%s' "${data}" | jq -r '.id')"
      mkdir -p "${HARNESS_DATA}/jobs/${id}"
      printf '%s' "${data}" | atomic_write "${HARNESS_DATA}/jobs/${id}/job.json"
      printf '%s' "${data}" > "${HARNESS_DATA}/job-new.json"
      state_update '.jobs[$id]=$j[0] | .actors[$a].pending_jobs |= (. + [$id] | unique)' --arg a "${actor}" --arg id "${id}" --slurpfile j "${HARNESS_DATA}/job-new.json"
      if [[ "$(printf '%s' "${data}" | jq -r '.kind')" == child ]]; then
        child="child-${id}"
        if ! printf '%s' "${data}" | jq -e '(.input.prompt|type)=="string" and (.input.prompt|length)>0 and (.input.name|type)=="string" and (.input.cwd==null or (.input.cwd|type)=="string")' >/dev/null; then
          store_emit job.completed "${actor}" "$(jq -cn --arg id "${id}" '{id:$id,result:"agent requires a name and nonempty task prompt",error:true}')" "completed-${id}" >/dev/null
          state_update '.cursor=$seq' --argjson seq "${seq}"; return 0
        fi
        record="$(printf '%s' "${data}" | jq -c --arg child "${child}" '{id:$child,name:.input.name,cwd:(.input.cwd // .cwd),parent:.actor,parent_job:.id,seed:.parent_context}')"
        store_emit actor.created "${child}" "${record}" "actor-${child}" >/dev/null
        message="$(printf '%s' "${data}" | jq -c '{kind:"user",text:(.input.prompt // "")}' )"
        store_emit message "${child}" "${message}" "task-${child}" >/dev/null
      elif [[ ! -f "${HARNESS_DATA}/jobs/${id}/result.json" ]]; then
        printf '%s' "${data}" | atomic_write "${HARNESS_DATA}/queue/jobs/${id}.json"
      fi
      ;;
    job.completed)
      id="$(printf '%s' "${data}" | jq -r '.id')"
      record="$(jq -c --arg id "${id}" '.jobs[$id] // empty' "${HARNESS_DATA}/state.json")"
      if [[ -n "${record}" ]]; then
        message="$(printf '%s\n%s' "${record}" "${data}" | jq -cs '{kind:(if .[0].kind=="child" then "work" else "echo" end),text:(if .[0].kind=="child" then "["+(.[0].input.name // .[0].id)+"] " else "Tool "+.[0].name+" (job "+.[0].id+"): " end)+(if .[1].error then "FAILED: " else "" end)+.[1].result,job_id:.[0].id,error:.[1].error,epoch:(.[0].epoch // 0)}')"
        store_emit message "${actor}" "${message}" "observation-${id}" >/dev/null
        state_update 'del(.jobs[$id]) | .actors[$a].pending_jobs |= map(select(. != $id))' --arg a "${actor}" --arg id "${id}"
      fi
      rm -f "${HARNESS_DATA}/queue/jobs/${id}.json"
      ;;
    cancel) runtime_cancel "${actor}" "${seq}" ;;
  esac
  state_update '.cursor=$seq' --argjson seq "${seq}"
}

runtime_cancel() {
  local actor="$1" cancelled_seq="${2:-0}" id record pid start
  if (( cancelled_seq>0 && $(state_actor "${actor}" | jq -r '.cancel_seq // 0')>=cancelled_seq )); then return 0; fi
  id="$(state_actor "${actor}" | jq -r '.request // empty')"
  if [[ -n "${id}" ]]; then
    rm -f "${HARNESS_DATA}/queue/requests/0-turn/${id}.json"
    if [[ -f "${HARNESS_DATA}/requests/${id}/lease.json" ]]; then
      pid="$(jq -r '.pid' "${HARNESS_DATA}/requests/${id}/lease.json")"
      start="$(jq -r '.start' "${HARNESS_DATA}/requests/${id}/lease.json")"
      process_alive "${pid}" "${start}" && kill -TERM -- "-${pid}" 2>/dev/null || true
    fi
  fi
  while IFS= read -r record; do
    id="$(printf '%s' "${record}" | jq -r '.id')"
    if [[ "$(printf '%s' "${record}" | jq -r '.kind')" == child ]]; then
      store_emit cancel "child-${id}" '{}' "cancel-${id}" >/dev/null
    elif [[ -f "${HARNESS_DATA}/jobs/${id}/lease.json" ]]; then
      pid="$(jq -r '.pid' "${HARNESS_DATA}/jobs/${id}/lease.json")"
      start="$(jq -r '.start' "${HARNESS_DATA}/jobs/${id}/lease.json")"
      process_alive "${pid}" "${start}" && kill -TERM -- "-${pid}" 2>/dev/null || true
      pid="$(jq -r '.execution.pid // empty' "${HARNESS_DATA}/jobs/${id}/lease.json")"
      start="$(jq -r '.execution.start // empty' "${HARNESS_DATA}/jobs/${id}/lease.json")"
      if [[ -n "${pid}" ]] && process_alive "${pid}" "${start}"; then terminate_group "${pid}"; fi
    fi
    rm -f "${HARNESS_DATA}/queue/jobs/${id}.json"
  done < <(jq -c --arg a "${actor}" '.jobs[] | select(.actor==$a)' "${HARNESS_DATA}/state.json")
  state_update '.actors[$a].request=null | .actors[$a].ledger=[] | .actors[$a].inbox=[] | .actors[$a].followup=false | .actors[$a].turn=null | .actors[$a].pending_jobs=[] | .actors[$a].status="cancelled" | .actors[$a].cancel_seq=$seq | .actors[$a].epoch=((.actors[$a].epoch // 0)+1) | .jobs |= with_entries(select(.value.actor != $a)) | .requests |= with_entries(select(.value.actor != $a or .value.kind=="summary"))' --arg a "${actor}" --argjson seq "${cancelled_seq}"
}

runtime_recent_messages() {
  local actor="$1" after="$2" through="$3" inbox="$4" tail record seq kind
  tail="$(memory_tail "${actor}" "${after}" "${through}" | jq -cs 'group_by(.source_seq) | map({seq:.[0].source_seq,kind:.[0].kind,text:(sort_by(.part)|map(.text)|join(""))})')" || return 1
  while IFS= read -r record; do
    seq="$(printf '%s' "${record}" | jq -r '.seq')"
    kind="$(printf '%s' "${record}" | jq -r '.kind')"
    if [[ "${kind}" == tool ]]; then
      # Launch history must retain job/call IDs without recreating a native
      # tool-call block that would require a matching protocol result.
      jq -c '.data | {role:"user",content:("<observation kind=\"historical_tool_launch\">\n"+({name,input,call_id,job_id}|tojson)+"\n</observation>")}' "${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json"
    else
      printf '%s' "${record}" | jq -c --argjson inbox "${inbox}" '
        . as $message | {role:"user",content:(if .kind=="user" then .text else
          "<observation kind=\""+(if .kind=="unii" then "historical_assistant" elif ($inbox|index($message.seq))==null then "historical_"+.kind else .kind end)+"\">\n"+.text+"\n</observation>" end)}'
    fi
  done < <(printf '%s' "${tail}" | jq -c '.[]')
}

runtime_schedule_actor() {
  local actor="$1" state inbox seq first last ledger view recent system tools config round epoch id record payload bins='{}' name binary budget bytes
  state="$(state_actor "${actor}")"
  [[ "$(printf '%s' "${state}" | jq -r '.request')" == null ]] || return 0
  inbox="$(printf '%s' "${state}" | jq -c '.inbox')"
  [[ "${inbox}" != '[]' || "$(printf '%s' "${state}" | jq -r '.followup // false')" == true ]] || return 0
  HARNESS_CWD="$(printf '%s' "${state}" | jq -r '.cwd')"; export HARNESS_CWD HARNESS_ACTOR="${actor}"
  HARNESS_PROVIDER="${_runtime_provider-${HARNESS_PROVIDER}}"; HARNESS_MODEL="${_runtime_model-${HARNESS_MODEL}}"
  _refresh_sources; harness_config
  round="$(printf '%s' "${state}" | jq -r '(.round // 0)+1')"
  epoch="$(printf '%s' "${state}" | jq -r '.epoch // 0')"; id="request-${actor}-${epoch}-${round}"
  config="$(provider_resolve "${HARNESS_PROVIDER}" "${HARNESS_MODEL}" 2>"${HARNESS_DATA}/setup-error")" || { runtime_fail_actor "${actor}" "${id}" "$(cat "${HARNESS_DATA}/setup-error")"; state_update '.actors[$a].inbox=[] | .actors[$a].round=$round' --arg a "${actor}" --argjson round "${round}"; return 0; }
  tools="$(harness_tools)" || return 1
  system="$(harness_system)" || return 1
  if [[ "$(printf '%s' "${state}" | jq -r '(.followup // false) or (.turn != null)')" == true ]]; then
    ledger="$(printf '%s' "${state}" | jq -c '.ledger')"
    first="$(printf '%s' "${state}" | jq -r '.turn')"
  else
    first="$(printf '%s' "${inbox}" | jq -r '.[0]')"
    if ! memory_ready "${actor}" "$((first-1))"; then
      local waiting=waiting_memory failed
      for failed in "${HARNESS_DATA}/actors/${actor}/summary-0-"*.json; do
        [[ -f "${failed}" ]] || continue
        if [[ "$(jq -r '.failed' "${failed}")" == true ]]; then waiting=blocked_memory; break; fi
      done
      state_update '.actors[$a].status=$waiting' --arg a "${actor}" --arg waiting "${waiting}"; return 0
    fi
    view="$(memory_view "${actor}" "$((first-1))")" || return 0
    ledger="$(printf '%s' "${view}" | jq -Rs '[{role:"user",content:.}]')"
    if [[ "$(printf '%s' "${state}" | jq -r '.round // 0')" == 0 ]]; then
      ledger="$(printf '%s\n%s' "${state}" "${ledger}" | jq -cs '(.[0].seed // []) + .[1]')"
    fi
    # Input can precede the previous call's final reply/tool events. Include
    # that whole actor-local tail once, rather than dropping interleaved history.
    recent="$(runtime_recent_messages "${actor}" "$((first-1))" "$(jq -r '.cursor' "${HARNESS_DATA}/state.json")" "${inbox}" | jq -cs '.')" || return 1
    ledger="$(printf '%s\n%s' "${ledger}" "${recent}" | jq -cs '.[0]+.[1]')"
  fi
  last="$(printf '%s' "${inbox}" | jq -r '.[-1] // 0')"
  if [[ "$(printf '%s' "${state}" | jq -r '(.followup // false) or (.turn != null)')" == true ]]; then
    while IFS= read -r seq; do
      [[ -n "${seq}" ]] || continue
      local incoming
      incoming="$(jq -c '.data | {role:"user",content:(if .kind=="user" then .text else "<observation kind=\""+.kind+"\">\n"+.text+"\n</observation>" end)}' "${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json")"
      ledger="$(printf '%s\n%s' "${ledger}" "${incoming}" | jq -cs '.[0]+[.[1]]')"
    done < <(printf '%s' "${inbox}" | jq -r '.[]')
  fi
  while IFS= read -r name; do
    binary="$(harness_find tools "${name}")"
    bins="$(printf '%s' "${bins}" | jq -c --arg n "${name}" --arg b "${binary}" '.[$n]=$b')"
  done < <(printf '%s' "${tools}" | jq -r '.[].name')
  payload="$(printf '%s\n%s\n%s' "$(printf '%s' "${system}" | jq -Rs .)" "${ledger}" "${tools}" | jq -cs --arg model "$(printf '%s' "${config}" | jq -r '.model')" '{model:$model,system:.[0],messages:.[1],tools:.[2]}')"
  # HARNESS_TURN_MAX_BYTES optionally caps the assembled request payload in
  # bytes. An anchored ledger that outgrew the cap re-anchors on the oldest
  # unprocessed inbox message and rebuilds from saved memory; a fresh turn
  # that still exceeds the cap fails instead of sending an unusable request.
  budget="${HARNESS_TURN_MAX_BYTES:-0}"
  [[ "${budget}" =~ ^[0-9]+$ ]] || budget=0
  if (( budget > 0 )); then
    bytes="$(printf '%s' "${payload}" | wc -c)"
    if (( bytes > budget )); then
      if [[ "$(printf '%s' "${state}" | jq -r '(.followup // false) or (.turn != null)')" == true && "${inbox}" != '[]' ]]; then
        state_update '.actors[$a].followup=false | .actors[$a].turn=null | .actors[$a].ledger=[]' --arg a "${actor}"
        if runtime_schedule_actor "${actor}"; then return 0; else return $?; fi
      fi
      runtime_fail_actor "${actor}" "${id}" "turn exceeds HARNESS_TURN_MAX_BYTES: request payload is ${bytes} bytes, cap is ${budget}; the pending input cannot fit one request"
      state_update '.actors[$a].inbox=[] | .actors[$a].round=$round' --arg a "${actor}" --argjson round "${round}"
      return 0
    fi
  fi
  record="$(printf '%s\n%s\n%s' "${payload}" "${config}" "${bins}" | jq -cs --arg id "${id}" --arg actor "${actor}" --arg code "${HARNESS_ROOT}" --argjson epoch "${epoch}" --argjson round "${round}" --argjson turn "${first}" --argjson wake "${last}" '{id:$id,actor:$actor,kind:"turn",code_root:$code,epoch:$epoch,payload:.[0],provider:.[1].provider,model:.[1].model,tool_bins:.[2],round:$round,turn:$turn,wake_seq:$wake}')"
  store_emit request.queued "${actor}" "${record}" "queued-${id}" >/dev/null
}

runtime_summary_failure() {
  local record="$1" error="$2" key actor
  key="$(printf '%s' "${record}" | jq -r '.memory_key')"; actor="$(printf '%s' "${record}" | jq -r '.actor')"
  printf '%s' "${record}" | jq -c --arg error "${error}" --argjson wake "$(state_actor "${actor}" | jq -r '.wake_seq // 0')" '{attempt:(.attempt+1),wake:$wake,error:$error,failed:true}' | atomic_write "${HARNESS_DATA}/actors/${actor}/summary-${key}.json"
  store_emit error "${actor}" "$(printf '%s' "${error}" | jq -Rs '{text:("Memory compaction failed: "+.+"\nA new message retries the failed summary.")}')" "error-$(printf '%s' "${record}" | jq -r '.id')" >/dev/null
}

runtime_summary_result() {
  local record="$1" response="$2" actor l i text size attempt key retry shortest
  actor="$(printf '%s' "${record}" | jq -r '.actor')"; l="$(printf '%s' "${record}" | jq -r '.l')"; i="$(printf '%s' "${record}" | jq -r '.i')"
  key="$(printf '%s' "${record}" | jq -r '.memory_key')"; attempt="$(printf '%s' "${record}" | jq -r '.attempt')"
  if ! printf '%s' "${response}" | jq -e '.stop=="end" and ([.blocks[]|select(.type=="tool_call")]|length)==0 and ([.blocks[]|select(.type=="text")|.text]|join(" ")|length)>0' >/dev/null; then
    runtime_summary_failure "${record}" 'invalid summary response'; return
  fi
  text="$(printf '%s' "${response}" | jq -r '[.blocks[]|select(.type=="text")|.text]|join(" ")|gsub("[\r\n]+";" ")')"
  size="$(printf '%s' "${text}" | wc -c)"
  retry="${HARNESS_DATA}/actors/${actor}/summary-${key}.json"; shortest="${text}"
  if [[ -f "${retry}" ]]; then
    shortest="$(printf '%s\n%s' "$(cat "${retry}")" "$(printf '%s' "${text}" | jq -Rs .)" | jq -rs 'if ((.[0].shortest // .[1])|utf8bytelength) < (.[1]|utf8bytelength) then .[0].shortest else .[1] end')"
  fi
  if (( size<=512 || attempt>=4 )); then
    memory_apply "${actor}" "${l}" "${i}" "${shortest}" >/dev/null
    rm -f "${retry}"
  else
    printf '%s' "${record}" | jq -c --arg shortest "${shortest}" --arg text "${text}" --argjson size "${size}" '{attempt:(.attempt+1),shortest:$shortest,previous:$text,size:$size,failed:false}' | atomic_write "${retry}"
  fi
}

runtime_schedule_summaries() {
  local actor="$1" task key retry attempt=0 record id config payload system tools prompt context model exclude wake setup_error
  exclude="$(jq -c --arg actor "${actor}" '[.requests[] | select(.actor==$actor and .kind=="summary") | ((.l|tostring)+"-"+(.i|tostring))]' "${HARNESS_DATA}/state.json")"
  wake="$(state_actor "${actor}" | jq -r '.wake_seq // 0')"
  for retry in "${HARNESS_DATA}/actors/${actor}/summary-"*.json; do
    [[ -f "${retry}" ]] || continue
    if [[ "$(jq -r '.failed' "${retry}")" == true ]] && (( wake <= $(jq -r '.wake' "${retry}") )); then
      key="${retry##*/summary-}"; key="${key%.json}"
      exclude="$(printf '%s' "${exclude}" | jq -c --arg key "${key}" '.+[$key]')"
    fi
  done
  while IFS= read -r task; do
    key="$(printf '%s' "${task}" | jq -r '(.l|tostring)+"-"+(.i|tostring)')"
    retry="${HARNESS_DATA}/actors/${actor}/summary-${key}.json"; attempt=0
    if [[ -f "${retry}" ]]; then
      attempt="$(jq -r '.attempt' "${retry}")"
      if [[ "$(jq -r '.failed' "${retry}")" == true ]] && (( $(state_actor "${actor}" | jq -r '.wake_seq // 0') <= $(jq -r '.wake' "${retry}") )); then continue; fi
    fi
    id="summary-${actor}-${key}-${attempt}"
    [[ ! -f "${HARNESS_DATA}/index/queued-${id}" ]] || continue
    HARNESS_CWD="$(state_actor "${actor}" | jq -r '.cwd')"; export HARNESS_CWD HARNESS_ACTOR="${actor}"
    HARNESS_PROVIDER="${_runtime_provider-${HARNESS_PROVIDER}}"; HARNESS_MODEL="${_runtime_model-${HARNESS_MODEL}}"
    _refresh_sources; harness_config
    model="${HARNESS_SUMMARY_MODEL-${HARNESS_MODEL}}"
    if [[ -n "${HARNESS_SUMMARY_PROVIDER:-}" && "${HARNESS_SUMMARY_PROVIDER}" != "${HARNESS_PROVIDER}" ]]; then model="${HARNESS_SUMMARY_MODEL:-}"; fi
    setup_error="${HARNESS_DATA}/actors/${actor}/summary-setup-error"
    if ! config="$(provider_resolve "${HARNESS_SUMMARY_PROVIDER:-${HARNESS_PROVIDER}}" "${model}" 2>"${setup_error}")"; then
      record="$(jq -cn --arg id "${id}" --arg actor "${actor}" --arg key "${key}" --argjson attempt "${attempt}" '{id:$id,actor:$actor,memory_key:$key,attempt:$attempt}')"
      runtime_summary_failure "${record}" "$(cat "${setup_error}")"
      continue
    fi
    tools="$(harness_tools)"; system="$(harness_system)"
    context="$(printf '%s' "${task}" | jq -r '.context // "<chat></chat>"')"
    prompt="$(printf '%s' "${task}" | jq -r 'if .l==0 then "Compaction: compress this message into one line of at most 512 UTF-8 bytes. Preserve names, decisions and provenance.\n<input>\n"+(.message|tojson)+"\n</input>" else "Compaction: merge these adjacent summaries into one line of at most 512 UTF-8 bytes.\n<input>\n"+(.text_a // "")+"\n"+(.text_b // "")+"\n</input>" end')"
    prompt+=$'\n'; prompt+="$(printf '%512s' '' | tr ' ' '-')"
    if [[ -f "${retry}" && "$(jq -r '.failed' "${retry}")" == false ]]; then
      prompt+=$'\n'; prompt+="Too long: $(jq -r '.size' "${retry}") bytes. Rewrite the whole line shorter: $(jq -r '.previous' "${retry}")"
    fi
    payload="$(printf '%s\n%s\n%s\n%s' "$(printf '%s' "${system}" | jq -Rs .)" "$(printf '%s' "${context}" | jq -Rs .)" "$(printf '%s' "${prompt}" | jq -Rs .)" "${tools}" | jq -cs --arg model "$(printf '%s' "${config}" | jq -r '.model')" '{model:$model,system:.[0],messages:[{role:"user",content:.[1]},{role:"user",content:.[2]}],tools:.[3]}')"
    record="$(printf '%s\n%s\n%s' "${task}" "${payload}" "${config}" | jq -cs --arg id "${id}" --arg actor "${actor}" --arg key "${key}" --arg code "${HARNESS_ROOT}" --argjson attempt "${attempt}" '{id:$id,actor:$actor,kind:"summary",code_root:$code,memory_key:$key,l:.[0].l,i:.[0].i,attempt:$attempt,payload:.[1],provider:.[2].provider,model:.[2].model}')"
    store_emit request.queued "${actor}" "${record}" "queued-${id}" >/dev/null
  done < <(memory_pending "${actor}" "${exclude}" 8 | jq -c '.[]')
}

runtime_launch_jobs() {
  local file id lease pid start code
  for file in "${HARNESS_DATA}/queue/jobs/"*.json; do
    [[ -f "${file}" ]] || continue
    id="$(jq -r '.id' "${file}")"; lease="${HARNESS_DATA}/jobs/${id}/lease.json"
    if [[ -f "${HARNESS_DATA}/jobs/${id}/result.json" ]]; then
      store_emit job.completed "$(jq -r '.actor' "${file}")" "$(cat "${HARNESS_DATA}/jobs/${id}/result.json")" "completed-${id}" >/dev/null
      continue
    fi
    if [[ -f "${lease}" ]]; then
      pid="$(jq -r '.pid' "${lease}")"; start="$(jq -r '.start' "${lease}")"
      if process_alive "${pid}" "${start}" || ! (exec 8>"${HARNESS_DATA}/locks/job-${id}"; flock -n 8); then continue; fi
      # A tool may have made an external change before it died. Never replay it.
      store_emit job.completed "$(jq -r '.actor' "${file}")" "$(jq -cn --arg id "${id}" '{id:$id,result:"Tool process was interrupted; execution outcome is unknown. It was not rerun.",error:true}')" "completed-${id}" >/dev/null
      continue
    fi
    code="$(jq -r '.code_root' "${file}")"
    HARNESS_ROOT="${code}" setsid "${code}/lib/job" "${id}" </dev/null >>"${HARNESS_DATA}/logs/job-${id}.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
  done
}

runtime_tick() {
  local seq head file event actor state id result _runtime_provider="${HARNESS_PROVIDER}" _runtime_model="${HARNESS_MODEL}"
  exec 6>"${HARNESS_DATA}/locks/projection"; flock 6
  seq="$(jq -r '.cursor' "${HARNESS_DATA}/state.json")"
  head="$(cat "${HARNESS_DATA}/HEAD")"
  local count=0
  while (( seq<head && count<1000 )); do
    seq=$((seq+1)); file="${HARNESS_DATA}/events/$(printf '%012d' "${seq}").json"
    [[ -f "${file}" ]] || break
    event="$(cat "${file}")"
    runtime_apply_event "${event}"
    count=$((count+1)); head="$(cat "${HARNESS_DATA}/HEAD")"
  done
  # Finish projecting committed controls before launching or scheduling work.
  # Derived events also belong to this backlog when the tick budget is reached.
  (( seq >= $(cat "${HARNESS_DATA}/HEAD") )) || return 0
  runtime_launch_jobs
  while IFS= read -r actor; do
    state="$(state_actor "${actor}")"
    if [[ "$(printf '%s' "${state}" | jq -r '.parent // empty')" != '' && "$(printf '%s' "${state}" | jq -r '.status')" =~ ^(idle|error)$ && "$(printf '%s' "${state}" | jq -c '.pending_jobs')" == '[]' && "$(printf '%s' "${state}" | jq -c '.inbox')" == '[]' ]]; then
      id="$(printf '%s' "${state}" | jq -r '.parent_job')"
      result="$(printf '%s' "${state}" | jq -c --arg id "${id}" '{id:$id,result:(.last_reply // ""),error:(.status=="error")}')"
      store_emit job.completed "$(printf '%s' "${state}" | jq -r '.parent')" "${result}" "completed-${id}" >/dev/null
      state_update '.actors[$a].status="completed"' --arg a "${actor}"
    else
      runtime_schedule_actor "${actor}" || true
    fi
    runtime_schedule_summaries "${actor}" || true
  done < <(jq -r '.actors | keys[]' "${HARNESS_DATA}/state.json")
}
