#!/usr/bin/env bash
# Publish harness formula to Homebrew tap
# Usage: ./scripts/publish-homebrew.sh <version> <sha256>
# Requires: TAP_GITHUB_TOKEN environment variable for the default GitHub remote

set -euo pipefail

(( $# >= 2 )) || { echo "Usage: $0 <version> <sha256>"; exit 1; }

VERSION="${1#v}"
SHA256="$2"
TAP_REPO="${TAP_REPO:-wedow/homebrew-tools}"
TAP_REPO_URL="${TAP_REPO_URL:-https://github.com/${TAP_REPO}.git}"
FORMULA_NAME="harness"
CLASS_NAME="Harness"
REPO_SLUG="wedow/harness"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version: $VERSION"; exit 1; }
[[ "$SHA256" =~ ^[a-f0-9]{64}$ ]] || { echo "Invalid sha256: $SHA256"; exit 1; }

manifest_entries() {
    "$REPO_ROOT/scripts/release-manifest.sh"
}

formula_install_lines() {
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf '    prefix.install "%s"\n' "$path"
    done < <(manifest_entries)
}

TAP_DIR="$(mktemp -d)"
TOKEN_FILE="$(mktemp)"
ASKPASS="$(mktemp)"
trap 'rm -rf "$TAP_DIR" "$TOKEN_FILE" "$ASKPASS"' EXIT

tap_requires_auth() {
    [[ "$TAP_REPO_URL" =~ ^https://github.com/ ]]
}

main() {
    echo "Publishing ${FORMULA_NAME} to Homebrew tap (v$VERSION)"

    if tap_requires_auth; then
        [[ -n "${TAP_GITHUB_TOKEN:-}" ]] || { echo "TAP_GITHUB_TOKEN not set"; exit 1; }
        (umask 077; printf '%s\n' "${TAP_GITHUB_TOKEN}" > "$TOKEN_FILE")
        printf '#!/bin/sh\ncat "%s"\n' "$TOKEN_FILE" > "$ASKPASS"
        chmod 700 "$ASKPASS"
        export GIT_ASKPASS="$ASKPASS"
    fi

    git clone "$TAP_REPO_URL" "$TAP_DIR"

    mkdir -p "$TAP_DIR/Formula"
    cat > "$TAP_DIR/Formula/${FORMULA_NAME}.rb" <<EOF
class ${CLASS_NAME} < Formula
  desc "Minimal agent loop in bash"
  homepage "https://github.com/${REPO_SLUG}"
  url "https://github.com/${REPO_SLUG}/archive/refs/tags/v${VERSION}.tar.gz"
  sha256 "${SHA256}"
  license "MIT"

  depends_on "bash"
  uses_from_macos "curl"
  depends_on "jq"
  uses_from_macos "perl"

  def install
    bin.install "bin/harness"
    bin.install_symlink "harness" => "hs"
$(formula_install_lines)

    inreplace bin/"harness", /^readonly HARNESS_ROOT=.*$/, <<~EOS
      readonly HARNESS_ROOT="#{prefix}"
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/harness version")
    assert_match version.to_s, shell_output("#{bin}/hs version")
  end
end
EOF

    git -C "$TAP_DIR" config user.name "github-actions[bot]"
    git -C "$TAP_DIR" config user.email "github-actions[bot]@users.noreply.github.com"
    git -C "$TAP_DIR" add "Formula/${FORMULA_NAME}.rb"

    if git -C "$TAP_DIR" diff --cached --quiet; then
        echo "No changes to publish"
        return 0
    fi

    git -C "$TAP_DIR" commit -m "harness v$VERSION"
    git -C "$TAP_DIR" push

    echo "Homebrew formula published successfully!"
}

main "$@"
