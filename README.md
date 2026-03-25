# harness

A minimal agent loop in bash. Everything else is plugins.

The core script handles plugin discovery, hook dispatch, and the agentic loop. Tools, providers, prompt loading, message serialization, cost tracking, approval gates — all of it lives in plugins that can be written in any language and dropped into well-known directories.

## Install

```bash
git clone <repo-url> ~/src/harness
ln -s ~/src/harness/bin/harness ~/.local/bin/harness
ln -s ~/src/harness/bin/harness ~/.local/bin/hs  # alias

# Dependencies: bash 4+, jq, curl
```

## Quick start

```bash
# Set an API key for any discovered provider
export ANTHROPIC_API_KEY="sk-ant-..."  # or
export OPENAI_API_KEY="sk-..."        # or
export ZAI_AUTH_TOKEN="..."

# One-shot: run an agent to completion
hs run "find all TODO comments in this repo and create a summary"

# Interactive chat
hs chat

# Resume a session
hs session list
hs chat 20260324-143022-12345

# See what's discovered from your current directory
hs help
```

## How it works

The core is a pure state machine (~670 lines). It does three things:

1. **Discovers plugins** by walking from CWD up to `$HOME`, collecting `.harness/` directories and bundled plugin packs. Provider plugins are scoped — only the active provider's plugin participates. Discovery reruns every loop iteration, so plugins can be added/removed at runtime.

2. **Dispatches hooks** at each state. Hooks are executables sorted by numeric prefix, chained as a pipeline. Hook output is JSON that may include control fields (`next_state`, `items`, `output`) to drive state transitions.

3. **Transitions**: `start → assemble → send → receive → (tool_exec → tool_done → assemble) → done`.

The loop has zero provider-specific knowledge. Message formats, API calls, response parsing — all of it lives in provider-specific hooks (`plugins/anthropic/`, `plugins/openai/`, `plugins/zai/`). Provider-agnostic behavior (tool execution, prompt loading, tool discovery) lives in `plugins/core/`.

## Plugin types

### Tools

Executables in `tools/` directories. Each supports three flags:

```bash
my-tool --schema    # emit JSON tool schema (Anthropic format)
my-tool --describe  # one-line human description
my-tool --exec      # execute: read JSON input from stdin, write result to stdout
```

Write tools in any language. See `examples/tools/web_fetch` for a Python example.

Built-in tools: `bash`, `read_file`, `write_file`, `str_replace`, `list_dir`.

### Hooks

Executables in `hooks.d/<stage>/` directories. Stages:

| Stage | stdin | Default next | Purpose |
|---|---|---|---|
| `start` | `{}` | `assemble` | Session initialization |
| `assemble` | `{}` | `send` | Build the API request payload |
| `send` | payload JSON | `receive` | Call the provider |
| `receive` | API response | `done` | Parse response, save message, extract tool calls |
| `tool_exec` | tool call JSON | `tool_done` | Execute a single tool (approval hooks go here too) |
| `tool_done` | tool result JSON | `assemble` | Save tool result |
| `error` | context JSON | `done` | Handle errors |
| `done` | context JSON | — | Cleanup (terminal) |

All hooks chain as a pipeline: each receives the previous hook's stdout on stdin. Any hook can set `next_state` in its JSON output to override the default transition.

Naming convention: `NN-name` where NN controls execution order. Examples:
- `10-messages` — runs first in the assemble stage
- `20-tools` — runs second
- `50-G-cost-guard` — a gate hook (convention, not enforced)

### Providers

Executables in `providers/` directories. Receive the assembled payload JSON on stdin, output the raw API response. Providers also support introspection flags for auto-discovery:

```bash
my-provider --describe  # one-line description
my-provider --ready     # exit 0 if credentials are configured
my-provider --defaults  # key=value pairs (e.g. model=claude-sonnet-4-20250514)
my-provider --env       # list supported env vars with descriptions
```

If `HARNESS_PROVIDER` is not set, harness auto-selects the first discovered provider whose `--ready` exits 0, and loads its `--defaults` for unset vars like `HARNESS_MODEL`.

Built-in: `anthropic`, `openai`, `zai`. Each lives in its own provider plugin directory (`plugins/anthropic/`, `plugins/openai/`, `plugins/zai/`) with provider-specific hooks for message assembly and response parsing. The `openai` provider works with any OpenAI-compatible API (ollama, llama.cpp, vLLM) — set `OPENAI_API_URL` to point at a local server. Writing a new provider means creating a plugin directory with the provider binary and format-translation hooks.

See [docs/PROTOCOLS.md](docs/PROTOCOLS.md) for full protocol details on all plugin types.

## Directory structure

```
~/AGENTS.md                  # global agent instructions (agents.md standard)
~/.harness/                  # global (always loaded)
  prompts/                   # additional prompt files (sorted, all loaded)
    00-persona.md
    10-coding-style.md
  tools/                     # global custom tools
  hooks.d/                   # global hooks
  providers/                 # global providers
  sessions/                  # session storage (default)

~/project/AGENTS.md          # project-specific instructions (agents.md standard)
~/project/.harness/          # project-local (loaded when CWD is under ~/project)
  tools/
    deploy                   # project-specific deploy tool
  hooks.d/
    tool_exec/
      05-approve             # require approval for this project
```

System prompts follow the [agents.md](https://agents.md) standard: place an `AGENTS.md` file at the root of any directory with a `.harness/` config. For composable prompt fragments, use `prompts/*.md` inside `.harness/`.

When multiple `.harness/` directories exist in the path from CWD to `$HOME`, they all contribute. For hooks and tools with the same basename, the most-local one wins. For prompt content, everything is concatenated (global first, local last, so local instructions can refine global ones).

## Message storage

Each session is a directory of markdown files:

```
sessions/20260324-143022-12345/
  session.md                         # metadata (model, provider, cwd, timestamps)
  messages/
    0001-user.md                     # user message
    0002-assistant.md                # assistant response (with tool_call blocks)
    0003-tool_result.md              # tool execution result
    0004-tool_result.md              # (consecutive results grouped by assembler)
    0005-assistant.md                # continuation
```

Each message file has YAML frontmatter with metadata (`role`, `seq`, `timestamp`, `model`, `provider`, `stop`, token counts) and a markdown body. The format is provider-agnostic — tool calls use `tool_call` (not provider-specific names), stop reasons are normalized (`end`, `tool_calls`, `length`, `error`):

````
```tool_call id=call_abc123 name=bash
{"command": "ls -la"}
```
````

Provider-specific assemble hooks (e.g., `plugins/anthropic/hooks.d/assemble/10-messages`) translate this canonical format into the provider's API message format. Because the filesystem *is* the state, you can switch providers mid-session and the message history just works.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `HARNESS_HOME` | `~/.harness` | Base config directory |
| `HARNESS_SESSIONS` | nearest `.harness/sessions/` up from CWD, else `$HARNESS_HOME/sessions` | Session storage (auto-discovered) |
| `HARNESS_MODEL` | auto from provider `--defaults` | Model identifier |
| `HARNESS_PROVIDER` | auto: first provider with credentials | Provider plugin name |
| `HARNESS_MAX_TURNS` | `100` | Max loop iterations |

Provider-specific env vars (API keys, endpoints, etc.) are listed by `hs help` and documented via each provider's `--env` flag.

## Extending

Copy an example hook or tool, make it executable, drop it in a `.harness/` directory:

```bash
# Add a cost tracker to your home config
mkdir -p ~/.harness/hooks.d/receive
cp examples/hooks.d/receive/20-cost ~/.harness/hooks.d/receive/
chmod +x ~/.harness/hooks.d/receive/20-cost

# Add a project-specific tool
mkdir -p .harness/tools
cp examples/tools/web_fetch .harness/tools/
chmod +x .harness/tools/web_fetch

# Add project context (agents.md standard)
cat > AGENTS.md << 'EOF'
This is a Rust project using tokio for async. Run tests with `cargo test`.
EOF
```

The agent itself can extend the harness by writing new tools or hooks to `.harness/` directories during a session. This is intentional.

## License

MIT — see [LICENSE](LICENSE) for details.
