#!/usr/bin/env bash
# web-sse-cr-strip — sse_patch must strip CR from fragment lines: SSE treats
# a lone CR as a line terminator, so a CR inside a message body would split
# the event mid-HTML and corrupt the client-side morph (truncated transcripts).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

source "${HARNESS_ROOT}/plugins/web/lib/http.sh"

# Appended transcript messages must target the transcript, while the default
# append target used by agent-pushed UI fragments remains body.
out="$(sse_patch '<div id="m0002">second</div>' append '#transcript')"
printf '%s' "${out}" | grep -qFx 'data: selector #transcript' \
  && printf '%s' "${out}" | grep -qFx 'data: mode append' \
  || { echo "FAIL: transcript append patch target/mode wrong: ${out}"; exit 1; }
out="$(sse_patch '<div id="ui">hello</div>' append)"
printf '%s' "${out}" | grep -qFx 'data: selector body' \
  || { echo "FAIL: default append target changed: ${out}"; exit 1; }

# 1. mid-line CR (e.g. CRLF-bearing tool result content)
out="$(sse_patch "$(printf '<div id="x">before\rafters</div>')")"
if printf '%s' "${out}" | grep -q $'\r'; then
  echo "FAIL: CR survived into SSE data lines"; printf '%s' "${out}" | od -c; exit 1
fi
printf '%s' "${out}" | grep -qF 'data: elements <div id="x">beforeafters</div>' \
  || { echo "FAIL: content mangled: ${out}"; exit 1; }

# 2. CRLF line endings in fragment: CR stripped, LF line structure kept
out="$(sse_patch "$(printf '<div id="y">one\r\ntwo</div>')")"
if printf '%s' "${out}" | grep -q $'\r'; then
  echo "FAIL: CR survived"; exit 1
fi
printf '%s' "${out}" | grep -qF 'data: elements <div id="y">one' \
  && printf '%s' "${out}" | grep -qF 'data: elements two</div>' \
  || { echo "FAIL: CRLF fragment lines wrong: ${out}"; exit 1; }

# 3. full path: a transcript containing a CR-bearing tool result renders and
#    passes through sse_patch with no CR in any data line
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"
sess="${HARNESS_SESSIONS}/s1"
mkdir -p "${sess}/messages"
printf -- '---\nrole: tool_result\nseq: 0001\ntool: bash\nerror: false\n---\nstdout: |\n  col1\r\n  col2\r\n' \
  > "${sess}/messages/0001-tool_result.md"
out="$(sse_patch "$(_transcript s1)")"
if printf '%s' "${out}" | grep -q $'\r'; then
  echo "FAIL: CR from message body reached SSE data"; exit 1
fi
printf '%s' "${out}" | grep -qF 'col1' || { echo "FAIL: body content lost"; exit 1; }
