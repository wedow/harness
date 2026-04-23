#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

repo_root="$(cd "${HARNESS_ROOT}" && pwd)"
test_dir="${_tmpdir}/repo"
mkdir -p "$test_dir/scripts" "$test_dir/pkg/aur/harness"
cp "$repo_root/scripts/publish-aur.sh" "$test_dir/scripts/"
cp "$repo_root/pkg/aur/harness/PKGBUILD" "$test_dir/pkg/aur/harness/"

cat > "$test_dir/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GIT_LOG"
case "$1" in
  clone)
    mkdir -p "$3/.git"
    exit 0
    ;;
  config)
    if [ "$2" = --global ] && [ "$3" = --add ] && [ "$4" = safe.directory ]; then
      printf '%s\n' "$5" > "$SAFE_DIR_FILE"
      exit 0
    fi
    exit 0
    ;;
  -C)
    shift
    repo="$1"
    shift
    if [ "$1" = diff ] && [ "$2" = --cached ] && [ "$3" = --quiet ]; then
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$test_dir/git"

cat > "$test_dir/makepkg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
pkgbase = harness
EOF
SH
chmod +x "$test_dir/makepkg"

PATH="$test_dir:$PATH"
export PATH
export AUR_SSH_KEY=dummy
export HOME="${_tmpdir}/home"
mkdir -p "$HOME"
export GIT_LOG="$test_dir/git.log"
export SAFE_DIR_FILE="$test_dir/safe-directory.txt"

bash "$test_dir/scripts/publish-aur.sh" v0.1.1 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

[ -s "$SAFE_DIR_FILE" ] || {
  echo "safe.directory was not configured"
  cat "$GIT_LOG"
  exit 1
}

grep -q '^clone ssh://aur@aur.archlinux.org/harness.git ' "$GIT_LOG" || {
  echo "expected clone command"
  cat "$GIT_LOG"
  exit 1
}