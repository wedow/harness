# Plugin Protocols

Harness has four plugin types that follow executable protocols: commands, tools, providers, and hooks. Each is a standalone executable (any language) discovered from `.harness/` directories and `plugins/*/`.

## Commands

Commands are executables in `commands/` directories. They implement CLI subcommands for `harness`.

| Flag | Output | Purpose |
|------|--------|---------|
| `--describe` | one line on stdout | Short description for `hs help` |
| *(none)* | varies | Execute the command with remaining args |

When invoked, commands receive remaining CLI arguments. The following `HARNESS_*` env vars are exported before dispatch: `HARNESS_ROOT`, `HARNESS_HOME`, `HARNESS_SESSIONS`, `HARNESS_PROVIDER`, `HARNESS_MODEL`, `HARNESS_MAX_TURNS`, `HARNESS_LOG`, `HARNESS_VERSION`.

Commands that need access to harness internals (session management, agent loop, discovery functions) source `bin/harness`:

```bash
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --describe) echo "short description"; exit 0 ;;
esac
source "${HARNESS_ROOT}/bin/harness"
# ... use harness functions ...
```

The `BASH_SOURCE` guard at the end of `bin/harness` prevents `main()` from running when sourced.

Discovery follows the same source walk and override rules as other plugin types — local overrides global by basename.

## Tools

Tools are executables in `tools/` directories. They respond to three flags:

| Flag | Input | Output | Purpose |
|------|-------|--------|---------|
| `--schema` | — | JSON | Tool definition (name, description, input_schema) |
| `--describe` | — | one line on stdout | Short description for `hs tools` and `hs help` |
| `--exec` | JSON on stdin | text on stdout | Execute the tool with the given input |

### `--schema`

Returns a JSON object with the tool definition:

```json
{
  "name": "tool_name",
  "description": "What this tool does",
  "input_schema": {
    "type": "object",
    "properties": {
      "param": { "type": "string", "description": "..." }
    },
    "required": ["param"]
  }
}
```

### `--exec`

Receives `input_schema`-shaped JSON on stdin. Stdout becomes the tool result sent back to the model. Stderr goes to `HARNESS_LOG`. A non-zero exit marks the result as `error: true`.

### Environment

Tools receive the standard hook environment (see below) plus:
- `HARNESS_CWD` — the session's original working directory (tools should `cd` here)
- `HARNESS_TOOL_TIMEOUT` — optional timeout in seconds

### Example

```bash
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --schema)   cat <<'JSON'
{ "name": "greet", "description": "Say hello",
  "input_schema": {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]} }
JSON
    ;;
  --describe) echo "Say hello to someone" ;;
  --exec)
    name="$(jq -r '.name' < /dev/stdin)"
    echo "Hello, ${name}!"
    ;;
esac
```

## Providers

Providers are executables in `providers/` directories. They handle API communication with an LLM backend.

### Provider plugins

A plugin directory that contains a `providers/` subdirectory is a **provider plugin**. During discovery, provider plugins are skipped unless their directory basename matches the active `HARNESS_PROVIDER`. This means only the active provider's hooks, tools, and prompts participate in the session.

Non-provider plugins (directories without `providers/`) always participate regardless of the active provider.

### Execution mode

Stdin: assembled payload JSON (with `model`, `system`, `messages`, `tools` fields).
Stdout: raw API response.
Stderr: errors only.

Non-zero exit signals a fatal error.

### Introspection flags

All flags are optional — a provider that only handles stdin/stdout still works. But supporting these flags enables auto-discovery and dynamic help.

| Flag | Output | Purpose |
|------|--------|---------|
| `--describe` | one line on stdout | Short description for `hs help` |
| `--ready` | exit code only | Exit 0 if credentials are configured, 1 if not |
| `--defaults` | `key=value` lines | Default values for HARNESS_ vars (e.g. `model=...`) |
| `--env` | text lines | Env vars this provider supports, with descriptions |

### `--ready`

Used for auto-selection. Harness iterates discovered providers (sorted by name) and picks the first where `--ready` exits 0. This check should be fast — just test whether the required env var is set, don't make network calls.

```bash
[[ "${1:-}" == "--ready" ]] && { [[ -n "${MY_API_KEY:-}" ]]; exit $?; }
```

### `--defaults`

Key-value pairs, one per line. Harness uses these to populate unset `HARNESS_` vars after auto-selecting a provider. Currently recognized keys:

| Key | Maps to |
|-----|---------|
| `model` | `HARNESS_MODEL` |

```bash
[[ "${1:-}" == "--defaults" ]] && { echo "model=claude-sonnet-4-6"; exit 0; }
```

### `--env`

Freeform text listing supported env vars. Displayed in `hs help` under each provider. Convention: `VAR_NAME` followed by spaces and a description, with defaults in parentheses.

```
MY_API_KEY     API key (required)
MY_API_URL     API endpoint (https://api.example.com/v1)
MY_MAX_TOKENS  max response tokens (8192)
```

### Example

```bash
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "--describe" ]] && { echo "Example LLM API"; exit 0; }
[[ "${1:-}" == "--ready" ]]    && { [[ -n "${EXAMPLE_KEY:-}" ]]; exit $?; }
[[ "${1:-}" == "--defaults" ]] && { echo "model=example-v1"; exit 0; }
[[ "${1:-}" == "--env" ]]      && { cat <<'EOF'
EXAMPLE_KEY       API key (required)
EXAMPLE_URL       API endpoint (https://api.example.com/v1)
EOF
exit 0; }

EXAMPLE_KEY="${EXAMPLE_KEY:?EXAMPLE_KEY not set}"
payload="$(cat)"
# ... build request, call API, output response ...
```

### Provider variants

A **variant** is a config file that reuses an existing provider's protocol with different endpoint settings. This avoids duplicating provider scripts for services that share the same API format (e.g. Groq, DeepSeek, and other OpenAI-compatible endpoints).

Variants are `.conf` files in any `providers/` directory, named `<variant>.conf`:

```
protocol=openai
description=Groq (OpenAI-compatible)
model=llama-3.3-70b-versatile
url=https://api.groq.com/openai/v1/chat/completions
auth_env=GROQ_API_KEY
```

| Field | Required | Purpose |
|-------|----------|---------|
| `protocol` | yes | Base provider to invoke (`openai` or `anthropic`) |
| `description` | no | Human-readable description |
| `model` | no | Default model (populates `HARNESS_MODEL` if unset) |
| `url` | no | API endpoint (sets `${PROTOCOL}_API_URL`) |
| `auth_env` | no | Env var name for API key (falls back to auth cache under variant name) |

**Resolution**: when `HARNESS_PROVIDER=groq`, harness looks for a `groq` executable first. Finding none, it looks for `groq.conf`, reads `protocol=openai`, sets the protocol's env vars from the conf, and invokes the `openai` provider binary.

**Scoping**: the protocol provider's hooks (assemble, receive) run automatically — no symlinks needed.

**Auth**: `hs auth set groq` stores credentials under the name `groq`. The variant resolution reads from the auth cache using the variant name.

**Placement**: bundled variants live alongside their protocol (`plugins/openai/providers/groq.conf`). User-defined variants go in `~/.harness/providers/` or a project's `.harness/providers/`.

## Hooks

Hooks are executables in `hooks.d/<stage>/` directories. They form a pipeline: each hook's stdout feeds the next hook's stdin. Named `NN-name` where `NN` is a two-digit sort key controlling execution order.

### Pipeline behavior

1. Hooks are collected from all active plugin sources (lowest to highest priority)
2. Deduplicated by basename — a local `10-save` overrides a bundled `10-save`
3. Sorted by basename (numeric prefix determines order)
4. Executed as a chain: stdin of hook N = stdout of hook N-1
5. Non-zero exit aborts the chain and returns the error to the caller

### State machine

The agent loop is a state machine. Each state dispatches hooks for that stage, then reads control fields from the pipeline output to determine the next state.

**Default transitions:**

```
start → assemble → send → receive → done
                     ↑                 │
                     │    tool_exec → tool_done
                     │                 │
                     └─────────────────┘
```

Hook output is JSON. Any hook can set these optional control fields:

| Field | Type | Purpose |
|-------|------|---------|
| `next_state` | string | Override the default state transition |
| `items` | array | Iterate each item through the next state (e.g., tool calls) |
| `output` | string | Text to display to the user when reaching `done` |

### Stages

| Stage | Stdin | Default next | Purpose |
|-------|-------|--------------|---------|
| `start` | `{}` | `assemble` | Initialize session env |
| `assemble` | `{}` | `send` | Build the request payload (messages, tools, prompts) |
| `send` | payload JSON | `receive` | Call the provider |
| `receive` | API response | `done` | Save assistant message, extract tool calls |
| `tool_exec` | tool call JSON | `tool_done` | Execute a single tool call |
| `tool_done` | tool result JSON | `assemble` | Save tool result |
| `error` | context JSON | `done` | Handle errors |
| `done` | context JSON | — | Cleanup (terminal) |

### Environment

Every hook receives:

| Variable | Contents |
|----------|----------|
| `HARNESS_SESSION` | path to current session directory |
| `HARNESS_STAGE` | current hook stage name |
| `HARNESS_MODEL` | selected model |
| `HARNESS_PROVIDER` | selected provider name |
| `HARNESS_ROOT` | harness installation directory |
| `HARNESS_SOURCES` | colon-separated list of active plugin source directories |
| `HARNESS_LOG` | log file path |

### `receive` specifics

The receive hook is provider-specific. It parses the raw API response and returns control JSON. For responses with tool calls:

```json
{
  "next_state": "tool_exec",
  "items": [
    {"id": "call_abc", "name": "bash", "input": {"command": "ls"}}
  ]
}
```

For final responses:

```json
{
  "next_state": "done",
  "output": "The model's text response"
}
```

### `tool_exec` specifics

Receives a single tool call as JSON:

```json
{"id": "call_abc", "name": "bash", "input": {"command": "ls"}}
```

Returns a tool result:

```json
{
  "call_id": "call_abc",
  "name": "bash",
  "input": {"command": "ls"},
  "result": "file1\nfile2\n",
  "error": false
}
```

Early hooks in the `tool_exec` pipeline (e.g., `05-approve`) can abort execution by exiting non-zero, replacing the old `pre-tool` stage.

### `tool_done` specifics

Receives the tool result JSON (same shape as `tool_exec` output). Saves it as a canonical message file.

### Example: approval hook

```bash
#!/usr/bin/env bash
# hooks.d/tool_exec/05-confirm — ask before running bash commands
set -euo pipefail

tc="$(cat)"
name="$(echo "${tc}" | jq -r '.name')"

if [[ "${name}" == "bash" ]]; then
  cmd="$(echo "${tc}" | jq -r '.input.command')"
  read -p "run: ${cmd}? [y/N] " -r reply </dev/tty
  [[ "${reply}" =~ ^[Yy] ]] || exit 1
fi

echo "${tc}"
```

## Canonical message format

Session messages are stored as markdown files with YAML frontmatter. The format is provider-agnostic — provider-specific hooks translate to/from this format.

### Assistant messages

```markdown
---
role: assistant
seq: 0002
timestamp: 2026-03-24T16:05:32-04:00
model: claude-sonnet-4-6
provider: anthropic
stop: tool_calls
tokens_in: 1200
tokens_out: 350
---
Here's some text

​```tool_call id=call_abc name=bash
{"command": "ls"}
​```
```

The `stop` field uses normalized values: `end`, `tool_calls`, `length`, `error`.

### Tool result messages

```markdown
---
role: tool_result
seq: 0003
timestamp: 2026-03-24T16:05:33-04:00
call_id: call_abc
tool: bash
error: false
---
file1
file2
```

### User messages

```markdown
---
role: user
seq: 0001
timestamp: 2026-03-24T16:05:30-04:00
---
List the files
```

## Streaming protocol (`.stream`)

The agent writes real-time JSONL events to `${HARNESS_SESSION}/.stream` during each turn. All events are single-line JSON (`jq -c` output), one per line. The file is the sole streaming interface -- clients (REPL, ACP adapter) tail it for live output.

### Lifecycle

The send hook truncates `.stream` at the start of each turn. Providers append `text`, `thinking`, and `tool_start` events during streaming. Receive hooks append a `stop` event after saving the assistant message. The `tool_done` hook appends after each tool execution. The agent loop appends `{"type":"done"}` when the loop exits. Consumers break on `done`.

### Event types

| Type | Fields | Source |
|------|--------|--------|
| `text` | `text` | Providers (token delta) |
| `thinking` | `text` | Providers (reasoning delta) |
| `tool_start` | `id`, `name`, `input` | Providers (tool call dispatched) |
| `tool_output` | `text` | `tool_exec` hook (formatted result) |
| `tool_done` | `id`, `name`, `seq`, `error` | `tool_done` hook |
| `stop` | `reason`, `seq` | Receive hooks |
| `error` | `message` | Error hook |
| `done` | *(none)* | `agent_loop` |

### Example `.stream` file

```jsonl
{"type":"text","text":"Hello "}
{"type":"text","text":"world."}
{"type":"thinking","text":"Let me consider..."}
{"type":"tool_start","id":"toolu_abc","name":"bash","input":{"command":"ls"}}
{"type":"tool_output","text":"  file1.txt\n  file2.txt"}
{"type":"tool_done","id":"toolu_abc","name":"bash","seq":"0003","error":"false"}
{"type":"stop","reason":"tool_calls","seq":"0002"}
{"type":"text","text":"Here are the files."}
{"type":"stop","reason":"end","seq":"0004"}
{"type":"done"}
```

### `stop` reasons

Normalized across providers: `end` (normal completion), `tool_calls` (tools pending), `length` (max tokens), `error`.

### Writing events

All writes are guarded by `[[ -n "${HARNESS_SESSION:-}" ]]` and append with `>>`. Providers write `text`/`thinking`/`tool_start`. Hooks write `tool_output`/`stop`/`tool_done`/`error`. The core loop writes `done`.

## Discovery order

Plugin sources are searched lowest to highest priority:

1. Bundled plugins (`<harness-root>/plugins/*/`, sorted) — **provider plugins filtered by active provider**
2. For each `.harness/` dir from global (`~/.harness`) to local (CWD):
   - Plugin packs within that dir (`plugins/*/`, sorted) — **provider plugins filtered**
   - The dir itself

Within each type (commands, tools, providers, hooks), later entries override earlier ones sharing the same basename. This means a local plugin always overrides a bundled one with the same name.

Discovery is fully dynamic — the agent loop rediscovers tools, hooks, and prompts on every iteration, so they can be added or removed at runtime. Commands are discovered once at CLI dispatch time.
