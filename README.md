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
export ANTHROPIC_API_KEY="sk-ant-..."

# One-shot: run an agent to completion
hs run "find all TODO comments in this repo and create a summary"

# Interactive chat
hs chat

# Resume a session
hs session list
hs chat 20260324-143022-12345
```

## How it works

The harness script is about 400 lines. It does three things:

1. **Walks up from CWD** collecting every `.harness/` directory it finds, from the current project up to `$HOME`. Each can contain `tools/`, `hooks.d/`, `providers/`, `prompts/`, and a `HARNESS.md` file. Local directories override global ones by basename.

2. **Runs hooks** at each stage of the loop. Hooks are executables sorted by numeric prefix. They chain as a pipeline — each hook's stdout feeds the next hook's stdin. Non-zero exit aborts the chain.

3. **Loops**: assemble → send → receive → (extract tool calls → execute → save result → repeat) → done.

That's it. The loop is the only thing the core does. Message assembly, tool discovery, prompt loading, response saving, cost tracking — all of it is implemented as hooks that ship in `plugins/core/` but can be overridden or extended per-project.

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

| Stage | Type | stdin | Purpose |
|---|---|---|---|
| `on-start` | event | (empty) | Session initialization |
| `assemble` | pipeline | `{}` → full payload | Build the API request |
| `pre-tool` | pipeline | tool call JSON | Gate or modify tool calls |
| `receive` | pipeline | API response JSON | Process/save response |
| `tool-done` | pipeline | tool result JSON | Process/save tool results |
| `on-error` | event | error info | Handle errors |
| `on-end` | event | (empty) | Cleanup |

Pipeline hooks chain: each receives the previous hook's stdout on stdin, transforms it, and writes to stdout. Event hooks are called for side effects; their stdout is discarded.

Naming convention: `NN-name` where NN controls execution order. Examples:
- `10-messages` — runs first in the assemble stage
- `20-tools` — runs second
- `50-G-cost-guard` — a gate hook (convention, not enforced)

### Providers

Executables in `providers/` directories. Receive the assembled payload JSON on stdin, output the raw API response. Select with `HARNESS_PROVIDER=name` or `--provider name`.

Built-in: `anthropic`. Writing an OpenAI-compatible provider means mapping the payload format and calling a different endpoint — about 60 lines of bash.

## Directory structure

```
~/.harness/                  # global (always loaded)
  HARNESS.md                 # global system prompt additions
  prompts/                   # additional prompt files (sorted, all loaded)
    00-persona.md
    10-coding-style.md
  tools/                     # global custom tools
  hooks.d/                   # global hooks
  providers/                 # global providers
  sessions/                  # session storage (default)

~/project/.harness/          # project-local (loaded when CWD is under ~/project)
  HARNESS.md                 # project-specific instructions
  tools/
    deploy                   # project-specific deploy tool
  hooks.d/
    pre-tool/
      10-approve             # require approval for this project
```

When multiple `.harness/` directories exist in the path from CWD to `$HOME`, they all contribute. For hooks and tools with the same basename, the most-local one wins. For prompt content, everything is concatenated (global first, local last, so local instructions can refine global ones).

## Message storage

Each session is a directory of markdown files:

```
sessions/20260324-143022-12345/
  session.md                         # metadata (model, provider, cwd, timestamps)
  messages/
    0001-user.md                     # user message
    0002-assistant.md                # assistant response (with tool_use blocks)
    0003-tool_result.md              # tool execution result
    0004-tool_result.md              # (consecutive results grouped by assembler)
    0005-assistant.md                # continuation
```

Each message file has YAML frontmatter with metadata (`role`, `seq`, `timestamp`, `model`, `stop_reason`, token counts) and a markdown body. Tool use blocks within assistant messages are stored as fenced code blocks:

````
```tool_use id=toolu_abc123 name=bash
{"command": "ls -la"}
```
````

The message assembler hook (`10-messages`) reconstitutes the API messages array from these files. Because the filesystem *is* the state, any tool — `grep`, `sed`, a text editor — can inspect or modify conversation history.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `HARNESS_HOME` | `~/.harness` | Base config directory |
| `HARNESS_SESSIONS` | `$HARNESS_HOME/sessions` | Session storage |
| `HARNESS_MODEL` | `claude-sonnet-4-20250514` | Model identifier |
| `HARNESS_PROVIDER` | `anthropic` | Provider plugin name |
| `HARNESS_MAX_TURNS` | `100` | Max loop iterations |
| `ANTHROPIC_API_KEY` | (required) | Anthropic API key |
| `ANTHROPIC_MAX_TOKENS` | `8192` | Max response tokens |

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

# Add project context
cat > .harness/HARNESS.md << 'EOF'
This is a Rust project using tokio for async. Run tests with `cargo test`.
EOF
```

The agent itself can extend the harness by writing new tools or hooks to `.harness/` directories during a session. This is intentional.

## License

MIT — see [LICENSE](LICENSE) for details.
