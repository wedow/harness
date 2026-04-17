---
name: extend-harness
description: Use whenever the user asks the running agent to gain a new capability — phrasings like "build a tool", "add a hook", "give yourself X", "let me <do thing> through you", or anything that extends the agent itself at runtime. Defines the plugin protocols, where to install them (.harness/ scopes), and the required test-through-tool-call iteration pattern. CRITICAL: "tool" here means a plugin the agent invokes via tool-calls — install it to a .harness/ directory; do NOT write a standalone CLI script in the working directory and do NOT modify the harness codebase under plugins/. Load this skill before acting on such a request rather than reverse-engineering the protocol from source.
---

# Extending harness

Harness is a state follower; everything else is plugins discovered at runtime from `.harness/` directories. To extend the running agent — yourself — drop an executable into the right place. The next loop iteration picks it up; no restart needed (`_refresh_sources` runs every turn).

## Where to put extensions

Discovery walks from CWD up to `/`, collecting every `.harness/` directory. For same-named files, **most-local wins**. Pick scope based on lifetime and audience:

| Scope | Location | Use when |
|---|---|---|
| User-global | `~/.harness/` | Available everywhere; personal preferences, secrets |
| Project | `<repo>/.harness/` | Committed with the repo, scoped to that project |
| Subdir | `<dir>/.harness/` | Narrower scope inside a monorepo |

Inside any `.harness/`:

```
commands/         # CLI subcommands (hs <name>)
tools/            # tools the model can call
hooks.d/<stage>/  # pipeline hooks; sorted by NN- prefix
providers/        # LLM API adapters (binary or .conf variant)
prompts/*.md      # appended to the system prompt
skills/<name>/    # on-demand instruction packs (SKILL.md)
plugins/<name>/   # plugin packs with the same layout
```

`AGENTS.md` follows the [agents.md standard](https://agents.md) — placed at the **parent** of the `.harness/` directory, not inside it.

## Tools (the most common extension)

A tool is an executable responding to three flags. Drop it at `.harness/tools/<name>` and `chmod +x`.

```bash
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --schema) cat <<'JSON'
{"name":"web_get","description":"GET a URL and return body",
 "input_schema":{"type":"object",
                 "properties":{"url":{"type":"string"}},
                 "required":["url"]}}
JSON
    ;;
  --describe) echo "GET a URL" ;;
  --exec)
    url="$(jq -r '.url' < /dev/stdin)"
    curl -fsS "$url"
    ;;
esac
```

- Stdout becomes the tool result. Stderr → `HARNESS_LOG`. Non-zero exit marks the result as `error: true`.
- Tools run in `HARNESS_CWD` (the session's original working directory).
- Any language: see [`../../../../examples/tools/web_fetch`](../../../../examples/tools/web_fetch) for a Python example.

Verify: `hs tools` lists what's discovered.

## Hooks (the agent loop is a pipeline)

Each stage dispatches its hooks as a chain — each hook reads the previous one's stdout and writes JSON. The numeric `NN-` prefix sets order. Local same-basename overrides global, which lets you replace a bundled hook by name.

```
start → assemble → send → receive → done
                    ↑                 │
                    │   tool_exec → tool_done
                    │                 │
                    └─────────────────┘
```

The transition is **not hardcoded** — each hook may emit `next_state` and the loop follows it. Empty `next_state` ends the loop. `output` (string) is what's printed when the loop exits.

| Stage | Stdin | Default next | Use for |
|---|---|---|---|
| `sources` | `{}` | (n/a) | Discover/filter plugin source dirs |
| `resolve` | `{provider,model}` | (n/a) | Pick provider/model before the loop |
| `start` | `{}` | `assemble` | Session init (e.g. set `HARNESS_CWD`) |
| `assemble` | `{}` | `send` | Build payload (messages, tools, system) |
| `send` | payload | `receive` | Call provider |
| `receive` | API response | `done` | Save assistant msg, extract tool calls |
| `tool_exec` | `{tool_calls:[…]}` | `tool_done` | Execute one tool call |
| `tool_done` | tool result | `tool_exec` / `assemble` | Save result, route |
| `error` | error context | (empty=stop) | Recover or report |
| `done` | final context | (empty=stop) | Cleanup, terminal |

Pipeline rules:
- All hooks for a stage run in basename-sorted order (use `NN-` prefix).
- Non-zero exit aborts the chain → routes to `error`.
- **Pass-through hooks** (gates, observers) just `cat` stdin to stdout after side effects, leaving the pipeline payload intact.
- The hook that wants to drive a transition emits `{"next_state": "..."}` (usually the last hook in the stage).

Example — confirm bash before execution (gate hook on `tool_exec`):

```bash
#!/usr/bin/env bash
# .harness/hooks.d/tool_exec/05-confirm
set -euo pipefail
tc="$(cat)"
[[ "$(echo "$tc" | jq -r '.name')" == "bash" ]] || { echo "$tc"; exit 0; }
cmd="$(echo "$tc" | jq -r '.input.command')"
read -p "run: $cmd ? [y/N] " r </dev/tty
[[ "$r" =~ ^[Yy] ]] || exit 1
echo "$tc"
```

Example — log token usage after each response (observer hook on `receive`):

```bash
#!/usr/bin/env bash
# .harness/hooks.d/receive/20-cost
set -euo pipefail
r="$(cat)"
in="$(echo "$r" | jq -r '.usage.input_tokens // 0')"
out="$(echo "$r" | jq -r '.usage.output_tokens // 0')"
echo "$(date -Iseconds) in=$in out=$out" >> "${HARNESS_SESSION}/cost.log"
echo "$r"   # pass through
```

Verify: `hs hooks <stage>` lists what's discovered.

## Skills (on-demand instruction packs)

A skill is a directory under `.harness/skills/<name>/` containing `SKILL.md` with YAML frontmatter (`name`, `description`). The `35-skills` assemble hook injects only the catalog (name + description) into the system prompt — the model loads the full body via the `skill` tool when relevant. Optional sibling dirs (`references/`, `scripts/`, `assets/`) are listed so the model knows what auxiliary files exist.

```
.harness/skills/my-workflow/
  SKILL.md                # frontmatter + body
  references/details.md   # listed in <skill-resources>
  scripts/setup.sh        # listed in <skill-resources>
```

Use a skill when instructions would bloat the system prompt but only matter for specific tasks. The `description` field is what triggers the model — make it concrete about *when* to load it.

## Providers

A provider is an executable in `providers/<name>` reading payload JSON on stdin and writing the raw API response. Optional flags: `--describe`, `--ready` (exit 0 if creds set; used for auto-select), `--defaults` (`model=…` lines), `--env`, `--stream`.

A directory whose basename matches a binary in its `providers/` (e.g. `plugins/openai/providers/openai`) is treated as a **provider plugin** — its hooks/tools/prompts only participate when that provider is active.

For OpenAI-compatible or Anthropic-compatible services, write a `<name>.conf` instead of a full binary:

```
protocol=openai
description=My Endpoint
model=foo-1
url=https://api.example.com/v1/chat/completions
auth_env=MY_API_KEY
```

Drop in any `providers/` dir; `hs auth set <name>` stores credentials under that name.

## Prompts

`AGENTS.md` files (at each `.harness/` parent) are concatenated into the system prompt, global → local. For composable fragments inside `.harness/`, use `prompts/*.md` (sorted by filename, all loaded). Local fragments come last so they can refine global ones.

## Workflow for self-extension

1. Decide scope (`~/.harness/` for personal, `<repo>/.harness/` for shared).
2. Write the executable with the right protocol — use `write_file`, not heredoc-via-bash, so the file is clean and easy to edit later.
3. **`chmod +x`** — non-executable files are silently ignored. This is the most common omission.
4. **Verify by invoking the new extension as a real tool call on your next turn.** Harness rediscovers tools every loop iteration, so the new tool is already registered — make a tool call to it the same way you call `read_file` or `bash`. Listing it with `hs tools` only proves discovery, not that the protocol implementation is correct; you must actually invoke it. For hooks, trigger the relevant stage (e.g. emit a tool call to exercise `tool_exec`). For commands, run `hs <name>` from `bash`. **Never test a tool by shelling out** (`./tool --exec <<< '{...}'`) or by exiting back to the user with "ready to use" — both bypass the JSON dispatcher and silently skip protocol bugs (bad schema, wrong stdout shape, schema/exec mismatch, forgotten `chmod +x`).
5. **Iterate on failure.** If the result is an error or unexpected output, read it, edit the file with `str_replace`/`write_file`, and call again. Keep iterating until a real tool call returns the expected result. **The task is not done until you have personally invoked the new extension through the loop and seen the right result** — do not return control to the user with the extension untested.

## Going deeper

- Full plugin protocol spec: [`../../../../docs/PROTOCOLS.md`](../../../../docs/PROTOCOLS.md)
- Working examples: [`../../../../examples/`](../../../../examples/) — tools, gate hooks, observer hooks
- Architecture overview: [`../../../../AGENTS.md`](../../../../AGENTS.md) and [`../../../../README.md`](../../../../README.md)
- Reference patterns: read existing bundled plugins under [`../../../../plugins/`](../../../../plugins/) — `plugins/core/hooks.d/` for provider-agnostic hooks, `plugins/anthropic/` and `plugins/openai/` for full provider plugins, `plugins/skills/` for the skill discovery hook itself
- Streaming protocol (`.stream` JSONL events) and canonical message format: see `docs/PROTOCOLS.md`
