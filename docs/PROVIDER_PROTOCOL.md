# Provider Protocol

Contract between the harness and provider binaries. `docs/PROTOCOLS.md` has the short version alongside the other plugin types; this file covers the full lifecycle, the streaming side-channels, the error convention, and a proposed usage/rate-limit extension.

A provider is an executable in `providers/` that translates the harness's canonical payload into an API call and returns the response. It exposes introspection flags for discovery (`--describe`, `--ready`, `--defaults`, `--env`) and a streaming mode (`--stream`). Execution is stdin JSON in, stdout JSON out.

## Invocation flags

Harness invokes the binary in two modes: **introspection** (one of the flags below, exits without reading stdin) and **execution** (no flag or `--stream`, reads payload from stdin, writes response to stdout).

| Flag | Output | Called by | Purpose |
|------|--------|-----------|---------|
| `--describe` | one line on stdout, exit 0 | `help`, `session` commands | Short human-readable name |
| `--ready` | exit 0 / non-zero, no output | `resolve/20-detect` during auto-selection | Credentials present and valid? Must be fast — no network calls |
| `--defaults` | `key=value` lines on stdout, exit 0 | `resolve/30-defaults` after selection | Populate unset `HARNESS_*` vars. Currently only `model` is consumed |
| `--env` | freeform text on stdout, exit 0 | `help` command | Documented env vars, one per line (`VAR desc (default)`) |
| `--stream` | *(modifier)* | `send/10-send` when grepping the binary for the literal `--stream` | Enable SSE streaming; shifts arg and proceeds to execution |

`--ready` is polled in sorted order across all discovered providers when `HARNESS_PROVIDER` is unset; first zero-exit wins. The check is typically `[[ -n "$MY_KEY" ]]` or an auth-cache lookup, not a liveness probe.

`10-send` enables `--stream` only if `grep -q -- '--stream' <provider_bin>` matches — so adding the literal flag to the binary is how you opt in.

## Input: the assembled payload

The provider reads one JSON object on stdin, emitted by the `assemble` pipeline (`10-messages` + `20-tools`):

```json
{
  "model": "claude-sonnet-4-6",
  "system": "…system prompt text…",
  "messages": [ {"role": "user", "content": "hello"}, … ],
  "tools":    [ {"name": "bash", "description": "…", "input_schema": {…}}, … ]
}
```

Field semantics:

- `model` — selected model id; provider falls back to `$HARNESS_MODEL` when empty.
- `system` — concatenated system prompt from all `AGENTS.md` / `prompts/*.md` sources. May be an empty string.
- `messages` — provider-shaped array. The `assemble/10-messages` hook is per-provider, so the array already matches the target API's format (Anthropic content blocks, OpenAI role/content+tool_calls, or Responses API input items). **Mid-session provider switching goes through the canonical markdown files, not this payload.**
- `tools` — canonical tool schemas `{name, description, input_schema}`. The provider translates to its API's format (OpenAI: `{type:"function", function:{name, description, parameters}}`; Responses API: `{type:"function", name, description, parameters}`; Anthropic: passes through).

Additional hooks may inject fields; providers MUST tolerate unknown top-level keys.

## Output: the success response

On exit 0, the provider writes one JSON object to stdout: **the raw native API response, unmodified**. There is no harness-defined success schema.

`send/10-send` appends `{next_state: "receive"}` and passes the merged object to the `receive` stage. The provider-scoped `receive/10-save` hook parses the native shape, writes a canonical markdown message to `$HARNESS_SESSION/messages/NNNN-assistant.md`, and returns the state-machine control JSON.

Token accounting is **not normalized in the wire format**. Each receive hook maps its API's fields into the frontmatter's `tokens_in` / `tokens_out`:

| Provider | Native field on stdout | Frontmatter |
|----------|------------------------|-------------|
| anthropic | `.usage.input_tokens`, `.usage.output_tokens` | `tokens_in`, `tokens_out` |
| openai | `.usage.prompt_tokens`, `.usage.completion_tokens` | `tokens_in`, `tokens_out` |
| chatgpt (Responses) | `.usage.input_tokens`, `.usage.output_tokens` | `tokens_in`, `tokens_out` |

Stop reasons are similarly normalized in the receive hook to canonical `end` / `tool_calls` / `length` / `error`.

Streaming providers reconstruct a response that matches their non-streaming shape closely enough for the same receive hook to parse. See the streaming sections below for the reconstruction contracts.

## Streaming: `.stream` and the tool fifo

When `10-send` invokes the provider with `--stream`, two side channels open:

1. `$HARNESS_SESSION/.stream` — JSONL event log consumed by the REPL and ACP adapter for live display.
2. `$HARNESS_TOOL_FIFO` — one JSON line per tool call, read by a background dispatcher in `10-send` that pre-executes tools in parallel.

`10-send` truncates `.stream` before calling the provider and creates the tool-dispatch fifo. The provider is responsible for writing events during the SSE read loop and reconstructing a non-streaming-shaped response on stdout at the end.

### `.stream` events

Each event is a single-line JSON object, appended with `>>`. Writes must be guarded by `[[ -n "${HARNESS_SESSION:-}" ]]`. Provider-emitted types:

| Type | Fields | When |
|------|--------|------|
| `text` | `text` (token delta) | Assistant text delta received |
| `thinking` | `text` | Reasoning delta (anthropic only; openai exposes no per-delta thinking) |
| `tool_start` | `id`, `name`, `input` | Tool call arguments finalized (see dispatch timing below) |

Downstream stages emit `tool_output`, `tool_done`, `stop`, `error`, and `done`. Providers do not emit those.

### Tool-fifo dispatch protocol

When `$HARNESS_TOOL_FIFO` is set, the provider writes one JSON line per tool call as soon as the call's arguments are complete:

```json
{"id": "toolu_abc", "name": "bash", "input": {"command": "ls"}}
```

The background dispatcher in `10-send` reads each line, finds the tool binary, and runs it in a subshell at the session's recorded cwd. Results land in `$HARNESS_SESSION/.tool_dispatch/<id>.json` as `{result, error}`. The `tool_exec` hook later checks this directory before invoking a tool — dispatched tools return instantly.

Dispatch timing differs per provider because the underlying SSE events differ:

| Provider | Event that completes a tool call | Dispatch point |
|----------|----------------------------------|----------------|
| anthropic | `content_block_stop` for a `tool_use` block | Per-tool, mid-stream |
| chatgpt (Responses) | `response.function_call_arguments.done` per call | Per-tool, mid-stream |
| openai | No per-call completion event — deltas accumulate by index, finalized at `[DONE]` | All tools at once, after stream ends |

The `tool_start` `.stream` event is written at the same point as the fifo line, so the REPL sees the tool name/args as soon as the dispatcher does.

### Reconstructed response (streaming path)

After `[DONE]` / `response.completed` / `message_stop`, the provider emits a JSON object to stdout that the receive hook can parse as if it had been a non-streaming response. Each provider's reconstruction:

- **anthropic** — builds `{model, stop_reason, usage:{input_tokens, output_tokens}, content:[…]}` from `message_start` + accumulated `content_block_*` events. `content` preserves the block order of the stream.
- **openai** — rebuilds the canonical chat-completion envelope: `{id, object:"chat.completion", model, choices:[{message:{role, content?, tool_calls?}, finish_reason}], usage:{prompt_tokens, completion_tokens, total_tokens}}`. Requires `stream_options.include_usage=true` to get usage in the final chunk.
- **chatgpt** — passes through the `response` object from the `response.completed` event, but splices in text and function_call items observed during streaming if the final response's `.output` omits them (guards against the Responses API's occasional gaps).

## Errors (current convention)

On any failure, the provider writes a message to stderr and exits non-zero. `send/10-send` captures stderr, logs to `$HARNESS_LOG`, and emits:

```json
{"error": "<stderr text>"}
```

on stdout — which the state machine routes to the `error` stage, whose `10-display` hook formats `error: <message>` for the user and appends an `{"type":"error","message":…}` event to `.stream`.

Providers surface context in stderr today (e.g. `anthropic API error: rate_limit_exceeded`, `chatgpt API error: <msg> (resets in 42s)`). That text is all the user sees. There is no structured access to error type, retry timing, or rate-limit state.

## NEW: proposed usage + structured error extension

Two optional additions to the provider contract, both backwards-compatible. Providers that support them return richer signals; providers that don't keep working unchanged.

### Optional `usage` fields in the success response

On top of the existing native usage fields, providers MAY include a `usage` object with rate-limit context harvested from response headers. Receive hooks write these into the assistant-message frontmatter alongside `tokens_in` / `tokens_out`.

```json
{
  "usage": {
    "plan":       "pro",        // optional: subscription tier (string)
    "limit_pct":  73,           // optional: 0–100, usage against the current window
    "resets_at":  1713648000    // optional: unix epoch when the window resets
  }
}
```

Per-provider header sources:

| Provider | Headers → mapping |
|----------|-------------------|
| anthropic | `anthropic-ratelimit-*-remaining` + `-limit` → `limit_pct`; `anthropic-ratelimit-*-reset` → `resets_at` |
| chatgpt (Responses) | `x-codex-primary-used-percent` → `limit_pct`; `x-codex-primary-reset-*` → `resets_at`; plan info from `x-codex-primary-*` if exposed → `plan` |
| openai | `x-ratelimit-remaining-requests` + `-limit-requests` → `limit_pct`; `x-ratelimit-reset-requests` → `resets_at` |

All three fields are optional — a provider omits any it cannot populate. The extension is purely additive; providers not implementing it emit no `usage` block and nothing downstream breaks.

### Optional structured error on stdout

Today a failing provider emits plain text to stderr and `10-send` wraps it as `{error: msg}`. **Proposed**: on non-zero exit, the provider MAY write a JSON object to stdout (instead of or in addition to stderr text) with shape:

```json
{
  "error":      "rate limit exceeded",
  "error_type": "rate_limit",              // auth | rate_limit | invalid_request | server | network
  "rate_limit": {                          // optional, only for rate_limit errors
    "resets_at":          1713648000,
    "retry_after_seconds": 42
  }
}
```

`10-send` must be changed to: when the provider exits non-zero, peek at stdout — if it parses as a JSON object with a string `.error` field, forward it verbatim instead of the stderr-wrapping path; otherwise fall back to today's `{error: <stderr>}` behavior. **This is a harness-side change that this proposal depends on; it is not yet implemented.**

With structured errors available, the `error/10-display` hook can format retry guidance: `error: rate limit exceeded (resets at 2026-04-20 18:00:00)` via `date -d @<resets_at>`. The REPL can also surface a countdown instead of a bare message.

### Display-layer consumption

The REPL (and any other display client) reads the saved assistant-message frontmatter after each turn. Proposed behavior:

- If `usage.limit_pct >= 80`, print a dim warning: `[usage: 83% of pro limit]`.
- If `usage.resets_at` is present, include the humanized window end.
- On error events, if `rate_limit.resets_at` is present, render via `date -d @<ts>`.

None of this requires changes to the existing `.stream` event schema — frontmatter is the interchange.

## Per-provider status

What each provider currently emits vs what it would need to fully implement the proposal.

| Provider | Streaming | tokens | Structured errors | `usage` extension |
|----------|-----------|--------|-------------------|-------------------|
| **anthropic** | Yes; per-block dispatch; proper EOF-guarded SSE with API-error surfacing via `_api_error` capture | Native `input_tokens`/`output_tokens` → frontmatter | Plain stderr `anthropic API error: <msg>`; not structured | None. Needs: `curl -D` header dump + parse `anthropic-ratelimit-*` |
| **claude** | Delegates to `anthropic` | Delegates | Delegates; adds OAuth `token refresh failed` | Would inherit any anthropic changes |
| **chatgpt** | Yes; per-tool dispatch at `response.function_call_arguments.done`; streaming and non-streaming paths; partial error extraction (reads `error.resets_in_seconds` and appends to stderr) | Native `input_tokens`/`output_tokens` → frontmatter | Plain stderr; `resets_in_seconds` already captured, just not structured | None. Headers `x-codex-primary-*` already returned by backend but not parsed |
| **openai** | Yes; all-tools-after-stream dispatch (API limitation); requires `stream_options.include_usage`; stderr error extraction from non-SSE body | Native `prompt_tokens`/`completion_tokens` → frontmatter | Plain stderr | None. Needs `x-ratelimit-*` parsing |

### Contradictions and gaps noticed

Items worth future cleanup tickets; not part of this doc's scope:

- **Error return paths diverge.** `plugins/openai/hooks.d/receive/10-save` returns `{next_state: "error", error: "…"}` on missing choices; `plugins/anthropic/hooks.d/receive/10-save` has no equivalent branch (relies on the provider exiting non-zero upstream). The error-state contract should be one or the other, not both.
- **Thinking deltas are asymmetric.** Anthropic emits `thinking` events to `.stream`; OpenAI's `reasoning_effort` yields no per-delta event and ChatGPT's reasoning summaries aren't plumbed in. Clients have no way to know the provider is mid-reasoning unless they guess from silence.
- **Token field naming mismatch is baked in.** OpenAI's `prompt_tokens`/`completion_tokens` vs Anthropic/Responses' `input_tokens`/`output_tokens` is normalized only at the receive-hook boundary. If a future hook wanted to read raw provider output before `10-save`, it would have to know the provider.
- **`chatgpt --ready` requires an unexpired token, but `anthropic --ready` accepts an API key with no expiry check.** Consistent — the APIs differ — but worth noting for anyone auto-selecting: a "ready" chatgpt may still need a refresh the moment it runs.
- **ChatGPT already extracts `error.resets_in_seconds` from API errors (provider line ~196)** but only appends it to a stderr string. This is half of the structured-error proposal, already implemented and thrown away.
