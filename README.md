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
export OPENAI_API_KEY="sk-..."        # or use a variant
export GROQ_API_KEY="gsk_..."

# Or use your ChatGPT subscription (Plus/Pro/Team/Enterprise)
hs auth set chatgpt                    # opens browser for OAuth login

# Or use your Claude subscription (Pro/Team/Enterprise)
hs auth set claude                     # opens browser for OAuth login

# One-shot: run an agent to completion
hs "find all TODO comments in this repo and create a summary"

# Interactive REPL
hs

# Resume a session
hs session list
hs 20260324-143022-12345

# See what's discovered from your current directory
hs help
```

## How it works

The core is a state follower (~100 SLOC). It does three things:

1. **Bootstraps** with bundled plugins + `~/.harness`, then runs `call sources` — a hookable pipeline that discovers all source directories. The default `30-walk-dirs` hook walks CWD upward collecting `.harness/` directories; `40-scope-providers` filters by active provider. Discovery reruns every loop iteration, so plugins can be added/removed at runtime.

2. **Dispatches hooks** via `call <name>`. Hooks are executables sorted by numeric prefix, chained as a pipeline. Hook output is JSON; the `next_state` field drives state transitions.

3. **Follows states** until `next_state` is empty. The core has no built-in transitions — the topology `start → assemble → send → receive → (tool_exec → tool_done → assemble) → done` is emergent from which hooks exist and what `next_state` they emit.

The loop has zero provider-specific knowledge. Message formats, API calls, response parsing — all of it lives in provider-specific hooks (`plugins/anthropic/`, `plugins/openai/`). Provider-agnostic behavior (tool execution, prompt loading, tool discovery) lives in `plugins/core/`. Additional bundled plugins provide subagent spawning (`plugins/subagents/`) and skill discovery (`plugins/skills/`).

## Plugin types

### Commands

Executables in `commands/` directories. CLI subcommands are discovered via the same source walk as other plugin types. Each supports one flag:

```bash
my-command --describe  # one-line human description
my-command [args...]   # execute the command
```

Built-in commands: `agent`, `session`, `tools`, `hooks`, `help`, `version`. The default command (bare `hs` or unrecognized first arg) is `agent`. Override any built-in by placing a same-named executable in a higher-priority `commands/` directory.

### Tools

Executables in `tools/` directories. Each supports three flags:

```bash
my-tool --schema    # emit JSON tool schema (Anthropic format)
my-tool --describe  # one-line human description
my-tool --exec      # execute: read JSON input from stdin, write result to stdout
```

Write tools in any language. See `examples/tools/web_fetch` for a Python example.

Built-in tools: `bash`, `read_file`, `write_file`, `str_replace`, `list_dir`, `agent`, `skill`.

### Hooks

Executables in `hooks.d/<stage>/` directories. Stages:

| Stage | stdin | Emits next_state | Purpose |
|---|---|---|---|
| `sources` | `{}` | _(n/a — called by core)_ | Discover source directories |
| `start` | `{}` | `assemble` | Session initialization |
| `assemble` | `{}` | `send` | Build the API request payload |
| `send` | payload JSON | `receive` | Call the provider |
| `receive` | API response | `tool_exec` or `done` | Parse response, save message, extract tool calls |
| `tool_exec` | context w/ `tool_calls` | `tool_done` | Pop and execute first tool call |
| `tool_done` | tool result + remaining | `tool_exec` or `assemble` | Save result, loop or continue |
| `error` | context JSON | _(empty = stop)_ | Handle errors |
| `done` | context JSON | _(empty = stop)_ | Cleanup (terminal) |

All hooks chain as a pipeline: each receives the previous hook's stdout on stdin. The last hook in each pipeline must emit `next_state` to declare the transition. Empty or absent `next_state` stops the loop.

Naming convention: `NN-name` where NN controls execution order. Examples:
- `10-messages` — runs first in the assemble stage
- `20-tools` — runs second
- `50-G-cost-guard` — a gate hook (convention, not enforced)

### Providers

Executables in `providers/` directories. Receive the assembled payload JSON on stdin, output the raw API response. Providers also support introspection flags for auto-discovery:

```bash
my-provider --describe  # one-line description
my-provider --ready     # exit 0 if credentials are configured
my-provider --defaults  # key=value pairs (e.g. model=claude-sonnet-4-6)
my-provider --env       # list supported env vars with descriptions
```

If `HARNESS_PROVIDER` is not set, harness auto-selects the first discovered provider whose `--ready` exits 0, and loads its `--defaults` for unset vars like `HARNESS_MODEL`.

Built-in: `anthropic`, `openai`, `chatgpt`, `claude`. Each lives in its own provider plugin directory with provider-specific hooks for message assembly and response parsing. The `openai` provider works with any OpenAI-compatible API (ollama, llama.cpp, vLLM) — set `OPENAI_API_URL` to point at a local server. The `chatgpt` provider authenticates via OAuth2 PKCE and uses ChatGPT subscription quotas (Plus/Pro/Team/Enterprise) — no API key needed. The `claude` provider authenticates via OAuth2 PKCE with Claude.ai subscriptions (Pro/Team/Enterprise) — no API key needed.

#### Provider variants

Many services share the same API format — they just need a different URL and API key. Instead of writing a full provider plugin, create a `.conf` file:

```
protocol=openai
description=Groq (OpenAI-compatible)
model=openai/gpt-oss-120b
url=https://api.groq.com/openai/v1/chat/completions
auth_env=GROQ_API_KEY
```

Place it in any `providers/` directory (`~/.harness/providers/`, `.harness/providers/`, or a plugin's `providers/`). Harness resolves the conf to the protocol's provider binary, sets the right env vars, and runs the protocol's hooks — no symlinks or plugin directories needed.

Bundled variants: `groq`, `deepseek` (OpenAI-compatible), `zai` (Anthropic-compatible).

```bash
# Use a variant
export GROQ_API_KEY="gsk_..."
HARNESS_PROVIDER=groq hs "hello"

# Or store credentials persistently
hs auth set groq
HARNESS_PROVIDER=groq hs "hello"

# Use ChatGPT subscription (no API key needed)
hs auth set chatgpt              # opens browser for OAuth login
HARNESS_PROVIDER=chatgpt hs "hello"

# Use Claude subscription (no API key needed)
hs auth set claude               # opens browser for OAuth login
HARNESS_PROVIDER=claude hs "hello"
```

See [docs/PROTOCOLS.md](docs/PROTOCOLS.md) for full protocol details on all plugin types.

## Directory structure

```
~/AGENTS.md                  # global agent instructions (agents.md standard)
~/.harness/                  # global (always loaded)
  prompts/                   # additional prompt files (sorted, all loaded)
    00-persona.md
    10-coding-style.md
  commands/                  # global custom commands
  tools/                     # global custom tools
  hooks.d/                   # global hooks
  providers/                 # global providers and variant confs
  sessions/                  # session storage (default)

~/project/AGENTS.md          # project-specific instructions (agents.md standard)
~/project/.harness/          # project-local (loaded when CWD is under ~/project)
  commands/
    deploy                   # project-specific deploy command
  tools/
    lint-check               # project-specific tool
  hooks.d/
    tool_exec/
      05-approve             # require approval for this project
  skills/
    my-skill/
      SKILL.md               # frontmatter (name, description) + instructions
```

System prompts follow the [agents.md](https://agents.md) standard: place an `AGENTS.md` file at the root of any directory with a `.harness/` config. For composable prompt fragments, use `prompts/*.md` inside `.harness/`.

Skills are directories containing a `SKILL.md` with YAML frontmatter (`name`, `description`). Place them in `.harness/skills/` or `.agents/skills/` at any level. The `25-skills` assemble hook discovers them and injects a catalog into the system prompt; the `skill` tool loads full instructions on demand.

When multiple `.harness/` directories exist in the path from CWD to `$HOME`, they all contribute. For hooks and tools with the same basename, the most-local one wins. For prompt content, everything is concatenated (global first, local last, so local instructions can refine global ones).

## Message storage

Each session is a directory of markdown files:

```
sessions/20260324-143022-12345/
  session.conf                       # metadata (model, provider, cwd, timestamps)
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
