# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Harness is a minimal agent loop in bash. The core script (~270 lines) is a plugin discovery walker, hook pipeline runner, state follower, and CLI dispatch. Everything else — session management, provider discovery, tool discovery, message assembly, API calls, response parsing, tool execution, prompt loading, cost tracking, approval gates, CLI commands — lives in hooks and plugins that can be written in any language.

Dependencies: bash 4+, jq, curl. No package manager, no language runtime.

## Commands

```bash
# Run the agent
bin/harness "do something"           # one-shot (args = message)
echo "do X" | bin/harness            # one-shot (stdin)
bin/harness                          # interactive REPL
bin/harness <session-id>             # resume session

# Inspect
bin/harness tools                    # list discovered tools
bin/harness hooks [stage]            # list discovered hooks
bin/harness session list             # list sessions
bin/harness session show <id>        # inspect session

# There is no test suite or linter.
# Verify changes by running the agent and inspecting session files.
```

The `bin/hs` symlink is an alias for `bin/harness`.

## Architecture

### The State Machine

The core loop is a pure state follower. It dispatches hooks for the current state, reads `next_state` from the hook output, and transitions. The core has no built-in transitions — state flow is entirely declared by hooks. An empty or absent `next_state` stops the loop. After the loop ends, `output` is read from the terminal state's result and printed.

```
start → assemble → send → receive → done
                    ↑                  │
                    │   tool_exec → tool_done
                    │                  │
                    └──────────────────┘
```

This diagram is emergent from hooks, not hardcoded. Hooks drive iteration: `tool_exec` pops one call, `tool_done` routes back to `tool_exec` or `assemble`.

Discovery is fully dynamic — plugins are rediscovered every loop iteration, so tools and hooks can be added/removed at runtime.

### Plugin Discovery & Provider Scoping

Harness walks from CWD upward to `/`, collecting `.harness/` directories. Local overrides global by basename. Bundled plugins in `plugins/*/` are loaded at lowest priority.

**Provider plugins** — any plugin directory containing a `providers/` subdirectory — are scoped: only the active provider's plugin is loaded. This means `plugins/anthropic/` hooks only participate when `HARNESS_PROVIDER=anthropic`. Non-provider plugins (like `plugins/core/`) always participate.

### Five Plugin Types

**Commands** (`commands/`): CLI subcommands discoverable via the same source walk as other plugin types. Protocol: `--describe` returns one-line help text; otherwise executed with remaining args. Local overrides global by basename. Built-in: `agent`, `session`, `tools`, `hooks`, `help`, `version`. The default command (no args or unrecognized first arg) is `agent`.

**Tools** (`tools/`): Executables responding to `--schema`, `--describe`, `--exec`. Input is JSON on stdin via `--exec`, output on stdout. Language-agnostic. Core tools: `bash`, `read_file`, `write_file`, `str_replace`, `list_dir`. Additional bundled tools: `agent` (spawn subagent sessions), `skill` (load skill instructions).

**Hooks** (`hooks.d/<stage>/`): Pipeline executables named `NN-name` (numeric prefix for sort order). Each hook's stdout feeds the next's stdin. Non-zero exit aborts the chain. Stages: `start`, `assemble`, `send`, `receive`, `tool_exec`, `tool_done`, `error`, `done`.

**Providers** (`providers/`): Receive assembled payload JSON on stdin, output raw API response. Support introspection flags: `--describe`, `--ready`, `--defaults`, `--env`. If `HARNESS_PROVIDER` is not set, harness auto-selects the first provider whose `--ready` exits 0. Built-in: `anthropic`, `openai`, `zai`.

**Prompts** (`AGENTS.md` + `prompts/*.md`): `AGENTS.md` files follow the [agents.md standard](https://agents.md) — placed at the project root (parent of `.harness/`), not inside it. The `30-prompts` assemble hook concatenates them (global first, local last). Additional prompt fragments go in `.harness/prompts/*.md`.

### Canonical Message Format

Session messages use a provider-agnostic format. Provider-specific hooks translate to/from this format, enabling mid-session provider switching. Key fields: `tool_call` (not tool_use), `call_id` (not tool_use_id), `stop: end|tool_calls|length|error` (normalized), `error` (not is_error).

### Session State is Filesystem

Sessions live in `<sessions-dir>/<id>/messages/` as numbered markdown files with YAML frontmatter. Tool calls are stored as fenced code blocks with `tool_call` info strings.

### Key Files

- `bin/harness` — core: source discovery, hook pipeline runner, state follower, CLI dispatch (~270 lines)
- `plugins/core/commands/` — built-in CLI commands (agent, session, tools, hooks, help, version)
- `plugins/core/hooks.d/` — provider-agnostic hooks (send, tool_exec, tool_done, assemble/tools, assemble/prompts)
- `plugins/anthropic/hooks.d/` — Anthropic-specific hooks (assemble/messages, receive/save)
- `plugins/anthropic/providers/anthropic` — Anthropic API call
- `plugins/openai/hooks.d/` — OpenAI-specific hooks (assemble/messages, receive/save)
- `plugins/openai/providers/openai` — OpenAI-compatible API call (works with ollama, llama.cpp, vLLM)
- `plugins/zai/` — z.ai provider (Anthropic-compatible, hooks symlinked to anthropic)
- `plugins/core/tools/` — five built-in tools
- `plugins/subagents/` — `agent` tool + prompt fragment for spawning child sessions
- `plugins/skills/` — `skill` tool + `25-skills` assemble hook for skill discovery

## Conventions

- All bash scripts use `set -euo pipefail` and `local` variables
- All JSON manipulation goes through `jq` — no bash JSON parsing
- Tools and hooks are executable files, not sourced scripts
- Hook naming: `NN-name` where NN is a two-digit sort key
- Command protocol: `--describe` (one-line help), otherwise executed with remaining args
- Tool protocol: `--schema` (JSON), `--describe` (one-line), `--exec` (JSON stdin → stdout)
- Provider protocol: `--describe`, `--ready`, `--defaults`, `--env`, plus stdin→stdout for execution
- Hooks receive `HARNESS_SOURCES` (colon-separated active source dirs) for plugin discovery
- Full protocol docs in `docs/PROTOCOLS.md`
- `HARNESS_CWD` tracks the session's original working directory; tools use it
