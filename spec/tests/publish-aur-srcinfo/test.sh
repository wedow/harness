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
pwd > .pwd
cat <<'EOF'
pkgbase = harness
	pkgdesc = Minimal agent loop in bash
EOF
SH
chmod +x "$test_dir/makepkg"

PATH="$test_dir:$PATH"
export PATH
export AUR_SSH_KEY=dummy
export HOME="${_tmpdir}/home"
mkdir -p "$HOME"

script="$test_dir/scripts/publish-aur.sh"
python - "$script" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
text = path.read_text()
old = '''main() {
    echo "Publishing $PKGNAME to AUR (v$VERSION)"
    setup_ssh
    push_to_aur
}
'''
new = '''main() {
    generate_srcinfo "$REPO_ROOT/pkg/aur/$PKGNAME"
}
'''
if old not in text:
    raise SystemExit('expected main block not found')
path.write_text(text.replace(old, new))
PY

bash "$script" v0.1.1 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

[ -s "$test_dir/pkg/aur/harness/.SRCINFO" ] || {
  echo ".SRCINFO was not written"
  exit 1
}

grep -q '^pkgbase = harness$' "$test_dir/pkg/aur/harness/.SRCINFO" || {
  echo ".SRCINFO missing pkgbase"
  cat "$test_dir/pkg/aur/harness/.SRCINFO"
  exit 1
}

grep -qx "$test_dir/pkg/aur/harness" "$test_dir/pkg/aur/harness/.pwd" || {
  echo "makepkg did not run in package directory"
  cat "$test_dir/pkg/aur/harness/.pwd"
  exit 1
}