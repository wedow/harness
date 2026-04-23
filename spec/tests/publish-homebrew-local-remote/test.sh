#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

repo_root="$(cd "${HARNESS_ROOT}" && pwd)"
test_dir="${_tmpdir}/repo"
mkdir -p "$test_dir/scripts"
cp "$repo_root/scripts/publish-homebrew.sh" "$test_dir/scripts/"
cp "$repo_root/scripts/release-manifest.sh" "$test_dir/scripts/"

tap_remote="${_tmpdir}/tap.git"
git init --bare "$tap_remote" >/dev/null

unset TAP_GITHUB_TOKEN || true

bash_env=(
  env
  "TAP_REPO_URL=$tap_remote"
  "HOME=${_tmpdir}/home"
  bash "$test_dir/scripts/publish-homebrew.sh"
  v0.1.2
  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
)
mkdir -p "${_tmpdir}/home"
"${bash_env[@]}"

tap_checkout="${_tmpdir}/tap-checkout"
git clone "$tap_remote" "$tap_checkout" >/dev/null 2>&1

formula="$tap_checkout/Formula/harness.rb"
[ -f "$formula" ] || {
  echo "formula was not written"
  exit 1
}

grep -q 'url "https://github.com/wedow/harness/archive/refs/tags/v0.1.2.tar.gz"' "$formula" || {
  echo "formula URL not updated"
  cat "$formula"
  exit 1
}

grep -q 'sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"' "$formula" || {
  echo "formula sha256 not updated"
  cat "$formula"
  exit 1
}
