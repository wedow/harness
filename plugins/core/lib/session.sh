# session helpers — sourced by commands that manage sessions
# requires: HARNESS_SESSIONS, HARNESS_MODEL, HARNESS_PROVIDER

_new_session() {
  local cwd="${1:-${PWD}}"
  local id; id="$(date +%Y%m%d-%H%M%S)-$$"
  local dir="${HARNESS_SESSIONS}/${id}"
  mkdir -p "${dir}/messages"
  cat > "${dir}/session.conf" <<EOF
id=${id}
model=${HARNESS_MODEL}
provider=${HARNESS_PROVIDER}
created=$(date -Iseconds)
cwd=${cwd}
EOF
  echo "${dir}"
}

_next_seq() {
  local dir="$1"
  local last; last="$(ls -1 "${dir}/messages/" 2>/dev/null | sort -n | tail -1)"
  if [[ -z "${last}" ]]; then echo "0001"
  else printf '%04d' $(( 10#${last%%-*} + 1 )); fi
}

_save_message() {
  local dir="$1" content="$2"
  local seq; seq="$(_next_seq "${dir}")"
  cat > "${dir}/messages/${seq}-user.md" <<EOF
---
role: user
seq: ${seq}
timestamp: $(date -Iseconds)
---
${content}
EOF
}
