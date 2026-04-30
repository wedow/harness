# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog,
and this project adheres to Semantic Versioning.

## [Unreleased]

### Added

### Changed

### Fixed

### Removed

## [0.2.0] - 2026-04-29

### Added
- Added an `edit_file` tool for anchor-based file edits using `LINE#HASH` references from `read_file`.
- Added a portable `hashline.awk` helper for stable line anchors across macOS and Linux.
- Added a `resume` command for continuing sessions from the CLI.

### Changed
- Changed `read_file` output from plain line numbers to `LINENUM#HASH:content` anchors for safer file editing.
- Simplified agent spawning and refreshed workflow actions and test dependencies.

### Fixed
- Fixed REPL SIGINT cleanup and added a hard-kill path on repeated interrupt.
- Fixed PTY helper script argument ordering.
- Fixed publish/test workflow coverage around AUR metadata generation and Node 24 workflow validation.

### Removed
- Removed the `str_replace` tool, superseded by `edit_file`.

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
