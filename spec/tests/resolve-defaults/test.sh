#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/resolve/30-defaults"

# Create mock source with a variant .conf
src="${_tmpdir}/source"
make_sources "$src"
mkdir -p "${src}/providers"
echo "model=test-model-7b" > "${src}/providers/testprov.conf"

# Test: model filled from provider .conf when model is empty
out="$(echo '{"provider":"testprov","model":""}' | "$hook")"
assert_json '.model' "$out" "test-model-7b"

# Test: model preserved when already set
out="$(echo '{"provider":"testprov","model":"already-set"}' | "$hook")"
assert_json '.model' "$out" "already-set"

# Test: passthrough when provider is empty
out="$(echo '{"provider":"","model":""}' | "$hook")"
assert_json '.provider' "$out" ""
assert_json '.model' "$out" ""
