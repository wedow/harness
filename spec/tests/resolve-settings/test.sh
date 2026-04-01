#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/resolve/10-settings"

# Create a mock source with settings.conf
src="${_tmpdir}/source"
make_sources "$src"
printf 'provider=test-provider\nmodel=test-model\n' > "${src}/settings.conf"

# Test: empty provider/model are filled from settings.conf
out="$(echo '{"provider":"","model":""}' | "$hook")"
assert_json '.provider' "$out" "test-provider"
assert_json '.model' "$out" "test-model"

# Test: existing provider is NOT overwritten
out="$(echo '{"provider":"existing","model":""}' | "$hook")"
assert_json '.provider' "$out" "existing"

# Test: model is NOT filled when provider was already set (provider_was_empty=no)
out="$(echo '{"provider":"existing","model":""}' | "$hook")"
assert_json '.model' "$out" ""
