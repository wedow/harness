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
title=
title_locked=
cwd=${cwd}
parent=${HARNESS_PARENT_SESSION:-}
EOF
  echo "${dir}"
}

_next_seq() {
  local dir="$1"
  local file name seq latest=0
  for file in "${dir}/messages/"*-*.md "${dir}/.seq/"*; do
    [[ -e "${file}" ]] || continue
    name="${file##*/}"; seq="${name%%-*}"
    [[ "${seq}" =~ ^[0-9]+$ ]] || continue
    (( 10#${seq} > latest )) && latest=$(( 10#${seq} ))
  done
  printf '%04d\n' $(( latest + 1 ))
}

# Reserve a sequence across writers with different role suffixes. A persistent
# marker prevents another writer from reusing a number if its owner dies before
# finishing the message file. The file itself is checked for older sessions
# whose messages predate reservations.
_claim_message_seq() {
  local dir="$1" seq n tries=0
  mkdir -p "${dir}/.seq"
  seq="$(_next_seq "${dir}")"; n=$(( 10#${seq} ))
  while (( tries++ < 1000 )); do
    seq="$(printf '%04d' "${n}")"
    if mkdir "${dir}/.seq/${seq}" 2>/dev/null; then
      if compgen -G "${dir}/messages/${seq}-*.md" >/dev/null; then
        rmdir "${dir}/.seq/${seq}"
      else
        printf '%s\n' "${seq}"
        return 0
      fi
    fi
    n=$(( n + 1 ))
  done
  return 1
}

_save_message() {
  local dir="$1" content="$2"
  local seq; seq="$(_claim_message_seq "${dir}")" || return 1
  cat > "${dir}/messages/${seq}-user.md" <<EOF
---
role: user
seq: ${seq}
timestamp: $(date -Iseconds)
---
${content}
EOF
}
