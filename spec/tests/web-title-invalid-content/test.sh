#!/usr/bin/env bash
# Title input must stay on one printable session.conf line.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

session="${_tmpdir}/session"
mkdir -p "${session}"
printf 'title=Original\nprovider=chatgpt\n' > "${session}/session.conf"
cp "${session}/session.conf" "${_tmpdir}/original.conf"
export HARNESS_SESSION="${session}"

for title in $'New title\nprovider=evil' $'New title\rprovider=evil' $'New title\tmore' $'New title\177more' $'New title\n'; do
  if jq -n --arg title "${title}" '{title: $title}' | "${HARNESS_ROOT}/plugins/web/tools/title" --exec > "${_tmpdir}/out"; then
    echo 'FAIL: title with a control character was accepted'
    exit 1
  fi
  cmp -s "${session}/session.conf" "${_tmpdir}/original.conf" || {
    echo 'FAIL: rejected title changed session.conf'
    exit 1
  }
done

cp "${_tmpdir}/original.conf" "${session}/session.conf"
if printf '%s\n%s\n' '{"title":"First"}' '{"title":"Second"}' | "${HARNESS_ROOT}/plugins/web/tools/title" --exec > "${_tmpdir}/out"; then
  echo 'FAIL: multiple JSON values were accepted as one title'
  exit 1
fi
cmp -s "${session}/session.conf" "${_tmpdir}/original.conf" || {
  echo 'FAIL: multiple JSON values changed session.conf'
  exit 1
}

for title in 'New title\nprovider=evil' 'New title\x0aprovider=evil' 'New title\012provider=evil'; do
  cp "${_tmpdir}/original.conf" "${session}/session.conf"
  jq -n --arg title "${title}" '{title: $title}' | "${HARNESS_ROOT}/plugins/web/tools/title" --exec > "${_tmpdir}/out"
  printf 'title=%s\nprovider=chatgpt\n' "${title}" > "${_tmpdir}/expected.conf"
  cmp -s "${session}/session.conf" "${_tmpdir}/expected.conf" || {
    echo 'FAIL: literal backslash escape changed session.conf structure'
    exit 1
  }
done

jq -n --arg title 'Valid title' '{title: $title}' | "${HARNESS_ROOT}/plugins/web/tools/title" --exec > "${_tmpdir}/out"
assert_eq 'valid title updated' "$(sed -n 's/^title=//p' "${session}/session.conf")" 'Valid title'
assert_eq 'other setting preserved' "$(sed -n 's/^provider=//p' "${session}/session.conf")" 'chatgpt'
