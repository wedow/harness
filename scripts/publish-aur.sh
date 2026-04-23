#!/usr/bin/env bash
# Publish harness package to AUR
# Usage: ./scripts/publish-aur.sh <version> <sha256>
# Requires: AUR_SSH_KEY environment variable

set -euo pipefail

(( $# >= 2 )) || { echo "Usage: $0 <version> <sha256>"; exit 1; }
[[ -n "${AUR_SSH_KEY:-}" ]] || { echo "AUR_SSH_KEY not set"; exit 1; }

VERSION="${1#v}"
SHA256="$2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKGNAME="harness"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version: $VERSION"; exit 1; }
[[ "$SHA256" =~ ^[a-f0-9]{64}$ ]] || { echo "Invalid sha256: $SHA256"; exit 1; }

setup_ssh() {
    mkdir -p ~/.ssh
    (umask 077; printf '%s\n' "$AUR_SSH_KEY" > ~/.ssh/aur)
    export GIT_SSH_COMMAND="ssh -i ~/.ssh/aur -o StrictHostKeyChecking=accept-new"
}

generate_srcinfo() {
    local pkg_dir="$1"
    local srcinfo
    if (( EUID == 0 )); then
        id _build &>/dev/null || useradd -m _build
        chown -R _build: "$pkg_dir"
        srcinfo="$(su _build -s /bin/sh -c 'cd "$1" && makepkg --printsrcinfo' -- "$pkg_dir")"
    else
        srcinfo="$(cd "$pkg_dir" && makepkg --printsrcinfo)"
    fi
    printf '%s\n' "$srcinfo" > "$pkg_dir/.SRCINFO"
}

update_pkgbuild() {
    local pkgbuild="$1"
    sed -i "s|^pkgver=.*|pkgver=$VERSION|" "$pkgbuild"
    sed -i "s|^sha256sums=.*|sha256sums=('$SHA256')|" "$pkgbuild"
    sed -i "s|^pkgrel=.*|pkgrel=1|" "$pkgbuild"
}

AUR_DIR="$(mktemp -d)"
trap 'rm -rf "$AUR_DIR"' EXIT

push_to_aur() {

    echo "Publishing $PKGNAME to AUR..."

    if ! git clone "ssh://aur@aur.archlinux.org/$PKGNAME.git" "$AUR_DIR"; then
        echo "Creating new AUR package: $PKGNAME"
        rm -rf "$AUR_DIR"
        AUR_DIR="$(mktemp -d)"
        git -C "$AUR_DIR" init
        git -C "$AUR_DIR" remote add origin "ssh://aur@aur.archlinux.org/$PKGNAME.git"
    fi

    cp "$REPO_ROOT/pkg/aur/$PKGNAME/PKGBUILD" "$AUR_DIR/"
    update_pkgbuild "$AUR_DIR/PKGBUILD"
    generate_srcinfo "$AUR_DIR"

    git -C "$AUR_DIR" config user.name "github-actions[bot]"
    git -C "$AUR_DIR" config user.email "github-actions[bot]@users.noreply.github.com"
    git -C "$AUR_DIR" add PKGBUILD .SRCINFO

    if git -C "$AUR_DIR" diff --cached --quiet; then
        echo "No changes for $PKGNAME"
        return 0
    fi

    git -C "$AUR_DIR" commit -m "Update to v$VERSION"
    git -C "$AUR_DIR" push -u origin master
    echo "Published $PKGNAME"
}

main() {
    echo "Publishing $PKGNAME to AUR (v$VERSION)"
    setup_ssh
    push_to_aur
}

main "$@"