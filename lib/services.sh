#!/usr/bin/env bash
set -euo pipefail

service_names() {
  local choice="${1:-all}" slot
  if [[ "${choice}" == all ]]; then
    printf 'web\nreactor\n'
    for (( slot=1; slot<=${HARNESS_WORKERS:-5}; slot++ )); do printf 'worker-%s\n' "${slot}"; done
  elif [[ "${choice}" == web || "${choice}" == reactor || "${choice}" =~ ^worker-[1-9][0-9]*$ ]]; then printf '%s\n' "${choice}"
  else _die "unknown component: ${choice}"; fi
}

service_start() {
  local name command=() record pid count
  service_names "${1:-all}" >/dev/null || return 1
  while IFS= read -r name; do
    if [[ "${name}" == worker-* ]] && (( ${name#worker-}>${HARNESS_WORKERS:-5} )); then
      printf 'worker slot exceeds HARNESS_WORKERS: %s\n' "${name}" >&2; return 1
    fi
    record="${HARNESS_DATA}/components/${name}.json"
    if [[ -f "${record}" ]] && process_alive "$(jq -r '.pid' "${record}")" "$(jq -r '.start' "${record}")"; then continue; fi
    case "${name}" in
      web) command=("${HARNESS_ROOT}/plugins/web/commands/serve") ;;
      reactor) command=("${HARNESS_ROOT}/lib/reactor") ;;
      worker-*) command=("${HARNESS_ROOT}/lib/worker" "${name#worker-}") ;;
    esac
    setsid "${HARNESS_ROOT}/lib/component" "${name}" "${command[@]}" </dev/null >>"${HARNESS_DATA}/logs/${name}.log" 2>&1 & pid=$!
    for (( count=0; count<50; count++ )); do
      [[ -f "${record}" ]] && process_alive "$(jq -r '.pid' "${record}")" "$(jq -r '.start' "${record}")" && break
      process_alive "${pid}" || { cat "${HARNESS_DATA}/logs/${name}.log" >&2; return 1; }
      sleep 0.02
    done
    sleep .05
    process_alive "${pid}" || { cat "${HARNESS_DATA}/logs/${name}.log" >&2; return 1; }
  done < <(service_names "${1:-all}")
}

service_stop() {
  local name record pid start count
  service_names "${1:-all}" >/dev/null || return 1
  while IFS= read -r name; do
    record="${HARNESS_DATA}/components/${name}.json"; [[ -f "${record}" ]] || continue
    pid="$(jq -r '.pid' "${record}")"; start="$(jq -r '.start' "${record}")"
    if process_alive "${pid}" "${start}"; then
      kill -TERM "${pid}" 2>/dev/null || true
      for (( count=0; count<250; count++ )); do process_alive "${pid}" "${start}" || break; sleep 0.02; done
      process_alive "${pid}" "${start}" && { printf 'component did not stop: %s\n' "${name}" >&2; return 1; }
    fi
  done < <(if [[ "${1:-all}" == all ]]; then
    service_names all
    for record in "${HARNESS_DATA}/components/"*.json; do [[ ! -f "${record}" ]] || basename "${record}" .json; done
  else service_names "$1"; fi | sort -u)
  return 0
}
