#!/usr/bin/env bash
# A failed run offers a retry action that resumes the same session without
# adding a user message. The action must work through the HTTP route.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
repo_root="$(realpath "${HARNESS_ROOT}")"

sid=retry-session
dir="${HARNESS_SESSIONS}/${sid}"
mkdir -p "${dir}/messages"
printf '%s\n' '{"type":"error","message":"provider unavailable"}' > "${dir}/.stream"

# Capture the error patch as a browser would see it after connecting.
patches="${_tmpdir}/patches"
export PATCHES="${patches}" SID="${sid}"
timeout 8 bash -c '
  source "$HARNESS_ROOT/plugins/web/lib/http.sh"
  source "$HARNESS_ROOT/plugins/web/lib/pages.sh"
  respond_sse() { :; }
  sse_patch() { printf "%s\n" "$1" >> "$PATCHES"; }
  handle_events "$SID"
' &
hpid=$!
trap 'kill "$hpid" 2>/dev/null || true; wait "$hpid" 2>/dev/null || true; teardown' EXIT
for _ in {1..30}; do
  if [[ -f "${patches}" ]] && grep -Fq 'provider unavailable' "${patches}"; then break; fi
  sleep 0.1
done
grep -Fq "action=\"/s/${sid}/retry\"" "${patches}" \
  || { echo 'FAIL: failed run has no retry action'; exit 1; }
grep -Eq '<button[^>]*>[^<]*[Rr]etry' "${patches}" \
  || { echo 'FAIL: retry action has no visible button'; exit 1; }

# Route the form through the real handler, with a harmless driver stub.
stub_root="${_tmpdir}/stub-root"
mkdir -p "${stub_root}/bin"
ln -s "${repo_root}/plugins" "${stub_root}/plugins"
cat > "${stub_root}/bin/harness" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RETRY_RUNS}"
STUB
chmod +x "${stub_root}/bin/harness"
export HARNESS_ROOT="${stub_root}" RETRY_RUNS="${_tmpdir}/runs"
response="$(printf '%s\r\n' "POST /s/${sid}/retry HTTP/1.1" 'Host: 127.0.0.1:8080' 'Content-Length: 0' '' | "${stub_root}/plugins/web/lib/handler")"
[[ "${response}" == *'303 See Other'* ]] \
  || { echo 'FAIL: retry route did not redirect to the session'; exit 1; }
for _ in {1..30}; do [[ -f "${RETRY_RUNS}" ]] && break; sleep 0.1; done
assert_file_contains "${RETRY_RUNS}" "agent ${sid}"
[[ "$(find "${dir}/messages" -name '*-user.md' | wc -l)" -eq 0 ]] \
  || { echo 'FAIL: retry inserted a duplicate user message'; exit 1; }

echo PASS
