#!/usr/bin/env bash
# Regression for issue #10: skill catalog uses frontmatter `name:`, but the
# `skill` tool used to resolve by directory name. If the two diverged, the
# model would see one identifier in <available-skills> and the tool would
# look up another, so explicit skill loading silently failed. Both must use
# the frontmatter name.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

skill_tool="${HARNESS_ROOT}/plugins/skills/tools/skill"

# Build a source dir with a skill whose dir name DIFFERS from frontmatter name
src="${_tmpdir}/src"
mkdir -p "${src}/skills/some-folder-name"
cat > "${src}/skills/some-folder-name/SKILL.md" <<'MD'
---
name: published-name
description: a test skill
---
hello from the skill body
MD

export HARNESS_SOURCES="${src}"
export HARNESS_CWD="${_tmpdir}"

# Resolving by the frontmatter name should work
out="$(echo '{"name":"published-name"}' | "${skill_tool}" --exec)"
[[ "${out}" == *'hello from the skill body'* ]] || {
  echo "FAIL: skill tool did not resolve by frontmatter name"
  echo "got: ${out}"
  exit 1
}

# Resolving by the directory name should NOT work (frontmatter is the
# source of truth — the catalog publishes the frontmatter name)
if echo '{"name":"some-folder-name"}' | "${skill_tool}" --exec >/dev/null 2>&1; then
  echo "FAIL: skill tool resolved by directory name; should only match frontmatter name"
  exit 1
fi
