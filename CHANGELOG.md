# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog,
and this project adheres to Semantic Versioning.

## [Unreleased]

### Added
- Added `edit_file` tool: anchor-based file editor using `LINE#HASH` references from `read_file` output. Edits are validated against the live file before mutation, preventing stale edits. Supports `replace_range`, `append_at`, `prepend_at`, `append_file`, and `prepend_file` operations.
- Added `plugins/core/lib/hashline.awk`: portable awk library (macOS + Linux) implementing djb2 line hashing with format, validate, and context modes.

### Changed
- Changed `read_file` output format from plain line numbers (`nl`) to `LINENUM#HASH:content`, where `#HASH` is a 2-character verification anchor. Structural-only lines (e.g. `}`, blank lines) get position-dependent hashes to avoid collisions.

### Fixed

### Removed
- Removed `str_replace` tool, superseded by `edit_file`.

## [0.1.3] - 2026-04-23

### Added
- Added a `Release Rehearsal` workflow that exercises the Homebrew and AUR publish scripts against local mirrors before tagging.

### Fixed
- Hardened AUR release publishing in root-run CI environments by switching `.SRCINFO` generation away from the broken `su -c` path and validating generated metadata before push.
- Fixed the release rehearsal workflow so its tarball SHA step does not write into the directory it is archiving.

## [0.1.2] - 2026-04-23

### Fixed
- Fixed OpenAI and ChatGPT assemble hooks so embedded `---` blocks inside tool results are preserved as message content instead of being reparsed as frontmatter.
- Fixed AUR release publishing in root-run CI environments so `.SRCINFO` is generated from the package directory before push.

## [0.1.1] - 2026-04-23

### Added
- Added Homebrew and AUR release automation for published tags.
- Added the bundled `extend-harness` skill for teaching the running agent new capabilities through plugins.
- Added provider protocol documentation and package installation instructions for Homebrew and AUR.

### Changed
- Updated core prompt formatting to use XML sections and clearer bullet structure.
- Optimized Homebrew dependencies and added `perl` where required by release tooling.

### Fixed
- Surfaced API errors from streaming ChatGPT and OpenAI-compatible providers.
- Fixed AUR packaging to install the `bin/harness` symlink into `HARNESS_ROOT`.
- Fixed skill resolution so the skill tool matches frontmatter names instead of directory names.
- Improved macOS compatibility, including portable `setsid` handling for the ACP adapter.
- Added missing CI support for the `str_replace` tool's `perl` dependency.

### Removed
