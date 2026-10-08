#!/usr/bin/env bash
# Shared configuration and executable plugin discovery.
set -euo pipefail
umask 077

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HARNESS_LIVE_ROOT="${HARNESS_LIVE_ROOT:-${HARNESS_ROOT}}"
HARNESS_HOME="${HARNESS_HOME:-${HOME}/.harness}"
HARNESS_DATA="${HARNESS_DATA:-${HARNESS_HOME}/chat}"
HARNESS_CWD="${HARNESS_CWD:-${PWD}}"
HARNESS_PROVIDER="${HARNESS_PROVIDER:-}"
HARNESS_MODEL="${HARNESS_MODEL:-}"
HARNESS_VERSION="0.5.0"
export HARNESS_ROOT HARNESS_LIVE_ROOT HARNESS_HOME HARNESS_DATA HARNESS_CWD HARNESS_PROVIDER HARNESS_MODEL HARNESS_VERSION

_die() { printf 'harness: %s\n' "$*" >&2; exit 1; }
valid_id() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]]; }
stable_id() { printf '%s' "$*" | sha256sum | cut -c1-24; }

atomic_write() {
  local target="$1" temp
  mkdir -p "$(dirname "${target}")"
  temp="$(mktemp "${target}.tmp.XXXXXX")"
  if ! cat > "${temp}"; then rm -f "${temp}"; return 1; fi
  if [[ "${target}" == *.json ]] && ! jq -e -s 'length==1' "${temp}" >/dev/null 2>&1; then
    rm -f "${temp}"; printf 'refusing incomplete JSON publication: %s\n' "${target}" >&2; return 1
  fi
  mv -f "${temp}" "${target}"
}

process_start() {
  local pid="$1"
  [[ -r "/proc/${pid}/stat" ]] || return 1
  sed 's/.*) //' "/proc/${pid}/stat" 2>/dev/null | awk '{print $20}'
}

process_alive() {
  local pid="$1" start="${2:-}" current
  [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null || return 1
  [[ -r "/proc/${pid}/stat" ]] || return 1
  [[ "$(sed 's/.*) //' "/proc/${pid}/stat" 2>/dev/null | cut -d' ' -f1)" != Z ]] || return 1
  current="$(process_start "${pid}")" || return 1
  [[ -z "${start}" || "${current}" == "${start}" ]]
}

terminate_group() {
  local pid="$1" count
  kill -TERM -- "-${pid}" 2>/dev/null || return 0
  for (( count=0; count<20; count++ )); do
    kill -0 -- "-${pid}" 2>/dev/null || return 0
    sleep .05
  done
  kill -KILL -- "-${pid}" 2>/dev/null || true
}

_refresh_sources() {
  local src cur part sources=()
  for src in "${HARNESS_ROOT}"/plugins/*; do [[ -d "${src}" ]] && sources+=("${src}"); done
  [[ -d "${HARNESS_HOME}" ]] && sources+=("${HARNESS_HOME}")
  local ancestors=()
  cur="${HARNESS_CWD}"
  while :; do ancestors+=("${cur}"); [[ "${cur}" == / ]] && break; cur="$(dirname "${cur}")"; done
  for (( part=${#ancestors[@]}-1; part>=0; part-- )); do
    src="${ancestors[part]}/.harness"
    [[ -d "${src}" && "${src}" != "${HARNESS_HOME}" ]] || continue
    for cur in "${src}"/plugins/*; do [[ -d "${cur}" ]] && sources+=("${cur}"); done
    sources+=("${src}")
  done
  local IFS=:
  HARNESS_SOURCES="${sources[*]}"
  export HARNESS_SOURCES
  source "${HARNESS_ROOT}/lib/provider.sh"
  harness_auth_refresh
}

harness_find() {
  local type="$1" name="$2" src result="" dirs=()
  valid_id "${name}" || return 1
  IFS=: read -r -a dirs <<< "${HARNESS_SOURCES}"
  for src in "${dirs[@]}"; do [[ -x "${src}/${type}/${name}" ]] && result="${src}/${type}/${name}"; done
  [[ -n "${result}" ]] || return 1
  printf '%s\n' "${result}"
}

call() {
  local stage="$1" src file base current dirs=()
  shift
  valid_id "${stage}" || return 1
  declare -A hooks=()
  IFS=: read -r -a dirs <<< "${HARNESS_SOURCES}"
  for src in "${dirs[@]}"; do
    for file in "${src}/hooks.d/${stage}"/*; do [[ -x "${file}" ]] && hooks["${file##*/}"]="${file}"; done
  done
  current="$(cat)"
  if (( ${#hooks[@]} )); then
    while IFS= read -r base; do current="$(printf '%s' "${current}" | "${hooks[$base]}" "$@")" || return; done < <(printf '%s\n' "${!hooks[@]}" | sort)
  fi
  printf '%s\n' "${current}"
}

harness_tools() {
  local src file name schema dirs=()
  declare -A tools=()
  IFS=: read -r -a dirs <<< "${HARNESS_SOURCES}"
  for src in "${dirs[@]}"; do
    for file in "${src}"/tools/*; do [[ -x "${file}" ]] && tools["${file##*/}"]="${file}"; done
  done
  local result='[]'
  if (( ${#tools[@]} )); then
    while IFS= read -r name; do
      schema="$("${tools[$name]}" --schema)" || return 1
      result="$(printf '%s\n%s' "${result}" "${schema}" | jq -cs '.[0] + [.[1]]')"
    done < <(printf '%s\n' "${!tools[@]}" | sort)
  fi
  printf '%s\n' "${result}"
}

harness_system() {
  local src file parent dirs=() ancestors=()
  declare -A seen=()
  IFS=: read -r -a dirs <<< "${HARNESS_SOURCES}"
  for src in "${dirs[@]}"; do
    for file in "${src}"/prompts/*.md; do [[ -f "${file}" ]] && { cat "${file}"; printf '\n\n'; }; done
    parent="$(dirname "${src}")"
    if [[ -f "${parent}/AGENTS.md" && -z "${seen[$parent]+x}" ]]; then
      seen["${parent}"]=1; cat "${parent}/AGENTS.md"; printf '\n\n'
    fi
  done
  parent="${HARNESS_CWD}"
  while :; do ancestors+=("${parent}"); [[ "${parent}" == / ]] && break; parent="$(dirname "${parent}")"; done
  for (( src=${#ancestors[@]}-1; src>=0; src-- )); do
    parent="${ancestors[src]}"
    if [[ -f "${parent}/AGENTS.md" && -z "${seen[$parent]+x}" ]]; then
      seen["${parent}"]=1; cat "${parent}/AGENTS.md"; printf '\n\n'
    fi
  done
  if [[ -x "${HARNESS_ROOT}/plugins/skills/hooks.d/assemble/35-skills" ]]; then
    printf '{"system":""}' | "${HARNESS_ROOT}/plugins/skills/hooks.d/assemble/35-skills" | jq -r '.system // ""'
  fi
}

harness_config() {
  local src dirs=() value
  IFS=: read -r -a dirs <<< "${HARNESS_SOURCES}"
  for (( src=${#dirs[@]}-1; src>=0; src-- )); do
    [[ -f "${dirs[src]}/settings.conf" ]] || continue
    value="$(sed -n 's/^provider=//p' "${dirs[src]}/settings.conf" | tail -1)"
    [[ -n "${HARNESS_PROVIDER}" || -z "${value}" ]] || HARNESS_PROVIDER="${value}"
    value="$(sed -n 's/^model=//p' "${dirs[src]}/settings.conf" | tail -1)"
    [[ -n "${HARNESS_MODEL}" || -z "${value}" ]] || HARNESS_MODEL="${value}"
    break
  done
  export HARNESS_PROVIDER HARNESS_MODEL
}

# Snapshot only program files. Credentials and chat data never enter a release.
code_snapshot() {
  local digest target temp before after attempt
  before="$(code_digest "${HARNESS_LIVE_ROOT}")"
  digest="${before}"
  target="${HARNESS_DATA}/code/${digest}"
  if [[ ! -d "${target}" ]]; then
    for (( attempt=0; attempt<5; attempt++ )); do
      temp="$(mktemp -d "${HARNESS_DATA}/code/.build.XXXXXX")"
      cp -a "${HARNESS_LIVE_ROOT}/bin" "${HARNESS_LIVE_ROOT}/lib" "${HARNESS_LIVE_ROOT}/plugins" "${temp}/"
      digest="$(code_digest "${temp}")"; after="$(code_digest "${HARNESS_LIVE_ROOT}")"
      if [[ "${digest}" == "${before}" && "${after}" == "${digest}" ]]; then
        target="${HARNESS_DATA}/code/${digest}"
        mv -T "${temp}" "${target}" 2>/dev/null || rm -rf "${temp}"
        printf '%s\n' "${target}"; return 0
      fi
      rm -rf "${temp}"; before="${after}"
    done
    printf 'program files changed during snapshot; retrying next tick\n' >&2; return 1
  fi
  printf '%s\n' "${target}"
}

code_digest() (
  cd "$1"
  # Relative paths make the digest independent of the staging directory.
  { find bin lib plugins -type f -print0 | sort -z | xargs -0 sha256sum
    find bin lib plugins -printf '%m %p %l\n' | sort
  } | sha256sum | cut -d' ' -f1
)
