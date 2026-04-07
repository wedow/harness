# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## What This Is

Harness is a minimal agent loop in bash. The core script (~100 SLOC) is a bootstrap, hook pipeline runner (`call`), state follower, and CLI dispatch. Even source discovery is hookable — the `sources` stage lets plugins control which directories participate. Everything else — session management, provider discovery, tool discovery, message assembly, API calls, response parsing, tool execution, prompt loading — lives in hooks and plugins that can be written in any language.

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

# Tests
spec/run                             # run all tests
SPEC_DIR=spec bash spec/tests/NAME/test.sh  # single test
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

Discovery is fully dynamic and hookable — `_refresh_sources` runs every loop iteration, calling the `sources` stage hooks to rebuild the source list. Plugins can be added/removed at runtime.

### Streaming & Parallel Tool Dispatch

Streaming output is written to `${HARNESS_SESSION}/.stream` as JSONL. Providers append single-line JSON events during each turn — `text` (token deltas), `thinking` (reasoning), `tool_start`/`tool_done` (tool execution), `stop` (turn end), `error`, `done` (session end). The send hook passes `--stream` to any provider that supports it. The filesystem is the streaming interface.

During streaming, the send hook dispatches tool calls for parallel execution via a fifo. A background dispatcher reads completed tool calls and executes them immediately. Results are written to `${session}/.tool_dispatch/`. The `tool_exec` hook checks for pre-computed results before executing — making pre-dispatched tools instant. Anthropic dispatches per-tool during streaming (at `content_block_stop`), while OpenAI dispatches all tools after the stream ends (no per-tool completion event in the protocol).

### Provider Resolution

Provider resolution is a hookable `resolve` stage, run once before the agent loop. Three hooks form a pipeline: `10-settings` (reads `settings.conf`), `20-detect` (auto-detects first ready provider), `30-defaults` (reads model defaults from variant conf or `--defaults`). Override any step by placing a same-named hook in a higher-priority source dir.

### Plugin Discovery & Provider Scoping

Source discovery is a hookable `sources` stage. The core bootstraps with bundled plugins + `~/.harness`, then runs `call sources` — a pipeline of hooks that build the full source list. The default hooks:

- `30-walk-dirs` — walks from CWD upward to `/`, collecting `.harness/` directories and plugin packs. Local overrides global by basename.
- `40-scope-providers` — filters provider plugins by `HARNESS_PROVIDER`. When `HARNESS_PROVIDER` is empty, all providers pass through (needed for auto-detection).

Override either by placing a same-named hook in a higher-priority source dir.

### Five Plugin Types

**Commands** (`commands/`): CLI subcommands discoverable via the same source walk as other plugin types. Protocol: `--describe` returns one-line help text; otherwise executed with remaining args. Local overrides global by basename. Built-in: `agent`, `repl`, `acp`, `acp-stream`, `session`, `tools`, `hooks`, `help`, `version`. On a TTY with no args, the default command is `repl`; otherwise `agent` (headless one-shot). Unrecognized first arg also falls back to `agent`.

**Tools** (`tools/`): Executables responding to `--schema`, `--describe`, `--exec`. Input is JSON on stdin via `--exec`, output on stdout. Language-agnostic. Core tools: `bash`, `read_file`, `write_file`, `str_replace`. Additional bundled tools: `agent` (spawn subagent sessions), `skill` (load skill instructions).

**Hooks** (`hooks.d/<stage>/`): Pipeline executables named `NN-name` (numeric prefix for sort order). Each hook's stdout feeds the next's stdin. Non-zero exit aborts the chain. Stages: `resolve`, `start`, `assemble`, `send`, `receive`, `tool_exec`, `tool_done`, `error`, `done`.

**Providers** (`providers/`): Receive assembled payload JSON on stdin, output raw API response. Support introspection flags: `--describe`, `--ready`, `--defaults`, `--env`, `--stream` (SSE streaming with real-time display). If `HARNESS_PROVIDER` is not set, harness auto-selects the first provider whose `--ready` exits 0 (via the hookable `resolve` stage). Built-in: `anthropic`, `openai`, `chatgpt`, `claude`. The `chatgpt` provider uses OAuth2 PKCE to authenticate with ChatGPT accounts (Plus/Pro/Team/Enterprise) and speaks the Responses API via SSE streaming to `chatgpt.com/backend-api/codex/responses`. The `claude` provider uses OAuth2 PKCE to authenticate with Claude.ai subscriptions (Pro/Team/Enterprise) and calls the standard Messages API with Bearer auth. **Variants** are `.conf` files that reuse a provider's protocol with different endpoint config (url, auth, model, max_tokens, stream). Bundled variants: `groq`, `deepseek`, `openrouter` (OpenAI-compatible), `fireworks`, `zai` (Anthropic-compatible).

**Prompts** (`AGENTS.md` + `prompts/*.md`): `AGENTS.md` files follow the [agents.md standard](https://agents.md) — placed at the project root (parent of `.harness/`), not inside it. The `30-prompts` assemble hook concatenates them (global first, local last). Additional prompt fragments go in `.harness/prompts/*.md`.

### Canonical Message Format

Session messages use a provider-agnostic format. Provider-specific hooks translate to/from this format, enabling mid-session provider switching. Key fields: `tool_call` (not tool_use), `call_id` (not tool_use_id), `stop: end|tool_calls|length|error` (normalized), `error` (not is_error).

### Session State is Filesystem

Sessions live in `<sessions-dir>/<id>/messages/` as numbered markdown files with YAML frontmatter. Tool calls are stored as fenced code blocks with `tool_call` info strings.

### Key Files

- `bin/harness` — core: bootstrap, `call` (hook pipeline runner), state follower, CLI dispatch (~100 SLOC)
- `plugins/core/commands/` — built-in CLI commands (agent, repl, acp, acp-stream, session, tools, hooks, help, version)
- `plugins/core/lib/session.sh` — shared session helpers (sourced by agent, repl, acp)
- `plugins/core/hooks.d/` — provider-agnostic hooks (resolve, send, tool_exec, tool_done, assemble/tools, assemble/prompts)
- `plugins/anthropic/hooks.d/` — Anthropic-specific hooks (assemble/messages, receive/save)
- `plugins/anthropic/providers/anthropic` — Anthropic API call (API key)
- `plugins/anthropic/providers/claude` — Claude.ai OAuth (Bearer auth, shares anthropic hooks)
- `plugins/openai/hooks.d/` — OpenAI-specific hooks (assemble/messages, receive/save)
- `plugins/openai/providers/openai` — OpenAI-compatible API call (works with ollama, llama.cpp, vLLM)
- `plugins/openai/providers/*.conf` — OpenAI-compatible variants (groq, deepseek, openrouter)
- `plugins/anthropic/providers/*.conf` — Anthropic-compatible variants (fireworks, zai)
- `plugins/chatgpt/providers/chatgpt` — ChatGPT Responses API (OAuth, streams SSE)
- `plugins/chatgpt/hooks.d/` — ChatGPT-specific hooks (assemble/messages, receive/save, auth-set/oauth)
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
- Provider protocol: `--describe`, `--ready`, `--defaults`, `--env`, `--stream` (SSE), plus stdin→stdout for execution
- Hooks receive `HARNESS_SOURCES` (colon-separated active source dirs) for plugin discovery
- Full protocol docs in `docs/PROTOCOLS.md`
- `HARNESS_CWD` tracks the session's original working directory; tools use it
