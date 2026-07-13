# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog,
and this project adheres to Semantic Versioning.

## [Unreleased]

### Added

### Changed

### Fixed

- Fixed ChatGPT provider auto-detection rejecting expired access tokens that can be renewed with a configured refresh token.

### Removed

## [0.3.0] - 2026-07-13

### Added
- Added a `rlm` plugin for recursive-context management via subagent queries: the filesystem becomes unbounded agent context and subagents are the query/computation layer over it.
- Added archive-based context compaction to the `rlm` plugin: when total message content exceeds a threshold (default 2,000,000 chars via `RLM_COMPACT_TOTAL`), the `messages/` directory is archived and a continuation message is injected, then assembly re-runs with a fresh window.
- Added a mandatory, search-driven post-compaction recovery protocol (inventory → grep/head/tail → focused subagents, writing a cited `notes/post-compaction-recovery.md`) and a `notes/` scratch directory for working state that survives compaction.
- Added an `rlm` orchestration prompt documenting `agent --exec` as a shell primitive (fan-out/barrier, map-reduce, final-writer, `git worktree` isolation).
- Added a delegation-depth counter (`HARNESS_DEPTH`, threaded parent+1 into every spawned subagent) that the `rlm` plugin uses to drop itself from the source list past `RLM_MAX_DEPTH` (default 2), turning deep subagents into leaf workers and stopping unbounded recursion.
- Added a `schema` field to the `agent` tool for validated structured output: the subagent returns a JSON object matching the schema, the tool strips fences, validates required keys, and retries on mismatch. Accepts plain JSON Schemas or the `{type:"json_schema",schema:{...}}` envelope.
- Added tmux pane streaming for subagents: inside a tmux session, spawned subagents run in a sibling pane with live output, panes tile into an even grid, and spill into a new window when full.
- Added nested session storage: subagent sessions are created under `<parent>/.harness/sessions/<child>/` with `parent=` lineage recorded.
- Added a subagent-role prompt (injected when `HARNESS_PARENT_SESSION` is set) steering subagents toward direct execution over recursive delegation.
- Added bundled core prompt directives shipped to every session: a maximal-simplicity prime directive, an agent coordination/delegation model, automatic skill selection, git commit hygiene, and a pre-finish simplicity reminder.
- Added a "Tools as CLI Commands" prompt documenting that discovered tools are on `$PATH` inside the bash tool and compose via the `--exec` JSON protocol.
- Added a `stream` command that runs the agent with live inline terminal output (text deltas, thinking, tool invocations and results, errors) backed by a shared `stream-renderer.sh` library reused by the REPL.
- Added session token-usage stats (total, input, output, cache read/written) printed on REPL exit, plus a one-line `harness resume <session-id>` hint.
- Added `tokens_total`, `tokens_cache_read`, and `tokens_cache_write` frontmatter on saved assistant messages across the Anthropic, OpenAI, and ChatGPT providers.
- Added `temperature`, `top_p`, and `top_k` keys to Anthropic-protocol variant `.conf` files, injected into the request body only when present.
- Added inactivity-based abort for streaming curl transfers (`--speed-limit`/`--speed-time`, ~60s) so a dead connection aborts instead of burning the full `--max-time`; non-streaming curls keep `--max-time` only.
- Rendered prior session history when resuming, with messages labeled, large tool-call arguments summarized, and tool results truncated past 10 lines.

### Changed
- Reworked the agent delegation model from a rigid main-overseer/subagent-never-delegate split to a cost-based rule: delegate to protect context or parallelize, execute directly when the overhead isn't worth it.
- Changed the bash tool to rebuild a `.tool-bin/` symlink directory of all discovered tools on each call (later source wins on collisions; `bash` excluded), so tools compose on `$PATH` and track runtime plugin changes.
- Threaded the parent's `HARNESS_MODEL` and `HARNESS_PROVIDER` into tmux-spawned subagent panes by default, so children no longer silently switch providers.
- Folded resume history rendering into a single `awk` pass over all message files for faster startup on large sessions.
- Annotated every assembled system-prompt section with its source file path so the agent can direct subagents to the exact files behind its instructions.
- Bumped the Fireworks variant to `kimi-k2p7-code` and the z.ai variant to `glm-5.2`.

### Fixed
- Fixed the `agent` tool swallowing child failures: non-zero exits and empty output now surface a marked error and propagate non-zero so `tool_exec` flags `error:true`, instead of reporting "completed with no output".
- Bounded subagent runs with `HARNESS_AGENT_TIMEOUT` (default 600s); a hung tmux pane is killed on expiry instead of blocking its parent.
- Fixed headless subagent dispatch calling a non-existent `run` subcommand, which prefixed every prompt with a stray "run ".
- Fixed externally-killed tmux panes (user-closed, OOM, `kill -9`, tmux restart) being reported as successful: a `.started` marker now distinguishes a killed pane from one that never ran.
- Fixed tmux subagent prompts being dropped by provider assemble hooks that read messages line-by-line, by writing the prompt with a trailing newline.
- Bound every parallel-dispatched tool executed during streaming with the tool timeout (`HARNESS_TOOL_TIMEOUT`, default 120s), so a hung non-agent tool no longer blocks the dispatcher on a path the agent timeout can't reach.
- Fixed the Anthropic provider crashing on z.ai's `data: [DONE]` SSE terminator.
- Fixed the hook pipeline crashing with "Argument list too long" when a tool produced multi-MB output: large fields are now fed to jq via `--rawfile` instead of CLI args.
- Surfaced a failing hook's stderr inline (hook path, exit code, last stderr lines) through the error stage instead of a generic log-file pointer.
- Preserved a structured `{error: ...}` JSON that a failing hook emits on stdout, rather than replacing it with the generic hook-failure wrapper.
- Fixed `edit_file` clobbering file modes (e.g. the executable bit) on edit; the temp file now inherits the target's mode.
- Stopped treating literal `` ```tool_call `` fenced blocks inside assistant message bodies as real tool calls across the Anthropic, OpenAI, and ChatGPT assemble hooks, so documentation and escaped examples are preserved as text.
- Fixed bare `harness resume` to select the session whose working directory matches the current directory instead of always picking the newest, and to honor an explicit `harness resume <session-id>`.

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
