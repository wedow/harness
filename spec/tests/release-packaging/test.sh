#!/usr/bin/env bash
# Install the AUR package into a staging root and exercise its actual CLI/libs.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." >/dev/null && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
source "${repo}/pkg/aur/harness/PKGBUILD"
source_dir="${tmp}/harness-${pkgver}"
mkdir -p "${source_dir}/scripts"
cp "${repo}/scripts/release-manifest.sh" "${source_dir}/scripts/"
cp -a "${repo}/bin" "${repo}/lib" "${repo}/plugins" "${repo}/docs" "${source_dir}/"
cp "${repo}/AGENTS.md" "${repo}/README.md" "${repo}/LICENSE" "${source_dir}/"
pkgdir="${tmp}/pkg"
(cd "${tmp}"; package)
installed="${pkgdir}/usr/lib/harness"
[[ -f "${installed}/lib/bootstrap.sh" && -x "${installed}/lib/reactor" && -x "${installed}/lib/worker" ]]
[[ -f "${installed}/bin/harness" && ! -L "${installed}/bin/harness" ]]
[[ -f "${installed}/plugins/web/public/app.js" ]]
[[ -L "${pkgdir}/usr/bin/hs" ]]
[[ " ${depends[*]} " == *' socat '* && " ${depends[*]} " == *' util-linux '* && " ${depends[*]} " == *' coreutils '* ]]
export HARNESS_ROOT="${installed}" HARNESS_LIVE_ROOT="${installed}" HARNESS_HOME="${tmp}/home" HARNESS_DATA="${tmp}/chat"
[[ "$("${pkgdir}/usr/bin/harness" version)" == "harness ${pkgver}" ]]
"${pkgdir}/usr/bin/harness" submit 'packaged input' > "${tmp}/ack"
"${pkgdir}/usr/bin/harness" history | jq -e '.events[0].data.text=="packaged input"' >/dev/null
"${pkgdir}/usr/bin/harness" tools | jq -e 'any(.[];.name=="zoom")' >/dev/null

# A queued snapshot root must survive the installed launcher's path patch.
snapshot="${tmp}/snapshot"
cp -a "${installed}" "${snapshot}"
sed -i 's/^HARNESS_VERSION=.*/HARNESS_VERSION="snapshot-check"/' "${snapshot}/lib/bootstrap.sh"
HARNESS_ROOT="${snapshot}" "${pkgdir}/usr/bin/harness" version > "${tmp}/snapshot-version"
[[ "$(cat "${tmp}/snapshot-version")" == 'harness snapshot-check' ]]

printf 'PASS: staged package includes executable runtime and preserves snapshot roots\n'
