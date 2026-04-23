#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

repo_root="$(cd "${HARNESS_ROOT}" && pwd)"
test_dir="${_tmpdir}/repo"
mkdir -p "$test_dir/scripts" "$test_dir/pkg/aur/harness"
cp "$repo_root/scripts/publish-aur.sh" "$test_dir/scripts/"
cp "$repo_root/pkg/aur/harness/PKGBUILD" "$test_dir/pkg/aur/harness/"

cat > "$test_dir/makepkg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
pkgbase = harness
	pkgdesc = Minimal agent loop in bash
	pkgver = 0.1.2
EOF
SH
chmod +x "$test_dir/makepkg"

PATH="$test_dir:$PATH"
export PATH
export HOME="${_tmpdir}/home"
mkdir -p "$HOME"
unset AUR_SSH_KEY || true

aur_remote="${_tmpdir}/aur.git"
git init --bare "$aur_remote" >/dev/null

env \
  "AUR_REMOTE_URL=$aur_remote" \
  bash "$test_dir/scripts/publish-aur.sh" \
  v0.1.2 \
  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

aur_checkout="${_tmpdir}/aur-checkout"
git clone "$aur_remote" "$aur_checkout" >/dev/null 2>&1

[ -f "$aur_checkout/.SRCINFO" ] || {
  echo ".SRCINFO was not pushed"
  exit 1
}

grep -q '^pkgver=0.1.2$' "$aur_checkout/PKGBUILD" || {
  echo "PKGBUILD version not updated"
  cat "$aur_checkout/PKGBUILD"
  exit 1
}

grep -q '^pkgbase = harness$' "$aur_checkout/.SRCINFO" || {
  echo ".SRCINFO missing pkgbase"
  cat "$aur_checkout/.SRCINFO"
  exit 1
}
