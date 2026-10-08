# Provider protocol

Providers are executable transports in a discovered `providers/` directory.
They accept one canonical JSON request on stdin and return one canonical JSON
response on stdout after the call completes. They do not write chat history,
execute tools, or publish browser updates. Transport-level SSE, where required,
is collected privately rather than exposed as a Harness streaming interface.

`lib/provider.sh` resolves the provider/model and validates both boundaries.
The request worker captures stderr, retries failed inference within its budget,
and publishes a durable completion or failure for the reactor.

## Request

```json
{
  "model": "model-name",
  "system": "Stable instructions",
  "tools": [
    {"name":"read_file","description":"Read a file","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}
  ],
  "messages": [
    {"role":"user","content":"<chat>\n0+2|Earlier messages summarized\n</chat>"},
    {"role":"user","content":"Read the README"},
    {"role":"assistant","blocks":[{"type":"tool_call","id":"call-1","name":"read_file","input":{"path":"README.md"}}]},
    {"role":"tool","call_id":"call-1","name":"read_file","content":"{\"job_id\":\"job-1\",\"status\":\"queued\"}","error":false}
  ]
}
```

The portable system prompt is a string. The validator also accepts an array for
provider-native system blocks, but a custom transport must decide how to handle
that form. `model`, `system`, and `tools` can be omitted where the transport
provides defaults. Tool schemas use `{name,description,input_schema}`.

Messages have three roles:

| Role | Fields |
| --- | --- |
| `user` | `content`: string |
| `assistant` | `blocks`: ordered text/tool-call blocks; optional `provider_state` object |
| `tool` | `call_id`, `name`, `content`: strings; optional `error`: boolean |

Text blocks are `{type:"text",text}`. Tool-call blocks are
`{type:"tool_call",id,name,input}` with a nonempty ID/name and an object input.
Tool-call IDs must be unique within a request. Tool messages retain the native
call identity even when the receipt represents a launched background job rather
than the final result. That later result reaches the actor as an observation.

Fresh turns receive the saved memory prefix followed by chronological original
actor messages since the first pending input, including interleaved replies and
tool launches. Historical replies and launches retain observation provenance;
they are not replayed as native tool calls. The native assistant/tool ledger is
retained only for output-length continuation. A summary request uses the same
tool/system definitions and a smaller context view; its task asks for a summary,
and tool calls in its response are rejected by the runtime.

## Response

```json
{
  "blocks": [
    {"type":"text","text":"I will check that file."},
    {"type":"tool_call","id":"call-2","name":"read_file","input":{"path":"README.md"}}
  ],
  "stop": "tool_calls",
  "usage": {
    "input_tokens": 1000,
    "output_tokens": 120,
    "total_tokens": 1120,
    "cache_read_input_tokens": 800,
    "cache_creation_input_tokens": 0
  }
}
```

`blocks` is an ordered array of the same text/tool-call shapes. A successful
response must contain non-whitespace text or a valid tool call. Arguments must
parse to an object; malformed arguments and duplicate IDs fail the request.

| Stop | Meaning |
| --- | --- |
| `end` | Reply complete; no tool calls |
| `tool_calls` | At least one complete tool call |
| `length` | Output limit reached; no tool calls |

`usage` is an object; its known token fields are optional/null or nonnegative
integers. `input_tokens` counts the whole reported prompt, including cache reads
and writes. Anthropic's native `input_tokens` counts uncached input, so its
adapter adds the reported cache counters. OpenAI's input count already includes
cached tokens. `total_tokens` is input plus output; a supplied native total must
agree when both counts are known. Cache counters cannot exceed input.
[Anthropic usage accounting](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#tracking-cache-performance),
[OpenAI usage fields](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/retrieve).

| Transport | Cache reads | Cache writes |
| --- | --- | --- |
| Anthropic Messages | `usage.cache_read_input_tokens` | `usage.cache_creation_input_tokens` |
| OpenAI Chat Completions | `usage.prompt_tokens_details.cached_tokens` | `usage.prompt_tokens_details.cache_write_tokens` |
| ChatGPT Responses | `usage.input_tokens_details.cached_tokens` | `usage.input_tokens_details.cache_write_tokens` |

Cache-detail fields are optional and model-dependent. Messages-compatible
services exposing OpenAI-named usage use that schema as a
fallback when the native input count is absent. Missing counts remain `null`;
zero means the provider reported zero. Missing cache categories cannot establish
that a request missed the cache or incurred no cache-write charge. No price
calculation or rate-limit percentage is part of this contract.

The optional `provider_state` object carries native continuation data. Bundled
adapters use a `protocol` discriminator with Anthropic `content`, OpenAI
`message`, or ChatGPT `output`. The adapter reuses this state only for its own
protocol and translates canonical blocks when switching protocols. This state
is separate from visible text and the memory tree; native reasoning is never
converted into a memory message.

## Failure and retries

On transport, authentication, API, or validation failure, write a useful message
to stderr and exit nonzero. Do not return a success-shaped empty response.
Workers retain diagnostics with the request and publish `request.failed` after
the configured attempts. The reactor converts a failed turn into a visible
`error` event; a failed summary can be retried after another message arrives.

Inference retries are at least once: a provider may have processed a request
whose response was lost. Durable completion IDs prevent duplicated committed
chat actions. This is separate from tool execution: an interrupted side-effecting
tool with an uncertain outcome is not automatically rerun.

## Discovery and introspection

| Flag | Contract |
| --- | --- |
| `--describe` | One-line description |
| `--ready` | Exit zero when credentials/configuration permit use; no inference |
| `--defaults` | `key=value` defaults, including `model` |
| `--env` | Supported environment settings |

The execution interface takes no flags. There is no `--stream` interface.
An explicit `HARNESS_PROVIDER` selects a provider; otherwise resolution checks
ready providers in name order. More-local sources override executable or variant
names. `HARNESS_MODEL` overrides the selected provider's default.

Variants are `.conf` files in `providers/`. They select a base transport with
`protocol` and can specify `description`, `model`, `url`, `auth_env`,
`max_tokens`, `temperature`, `top_p`, `top_k`, and `prompt_cache`. Resolution maps
supported values into the base transport's environment. Credentials come from the named
environment variable or credential cache under the variant's name. Values are
read as configuration, never sourced as shell code.

Bundled transports cover Anthropic Messages (`anthropic`, and OAuth `claude`),
OpenAI-compatible Chat Completions (`openai`), and ChatGPT Responses (`chatgpt`).
OAuth token refresh is serialized by the credential lock.

## Prompt cache controls and verification

`ANTHROPIC_PROMPT_CACHE` controls Messages request annotations; an Anthropic
variant can set the same value with `prompt_cache`:

| Value | Request behavior |
| --- | --- |
| `auto` (default) | Native `api.anthropic.com` only: system/view marks and top-level automatic caching |
| `explicit` | Block-level system/view marks on any endpoint; no top-level automatic field |
| `off` | No cache annotations; preserve the original text and tool arguments |

Enable `explicit` on a compatible service only after confirming support for
Anthropic block-level cache controls. Compatibility alone does not establish
that support. ZAI retains its default implicit caching, which requires no hints;
its documented Chat Completions metric is
`usage.prompt_tokens_details.cached_tokens`.
[ZAI context caching](https://docs.z.ai/guides/capabilities/cache).

The marked view groups four complete lines per text block, marking its last
whole group and leaving a partial group unmarked. Anthropic permits four
breakpoints total; automatic caching uses one slot. The adapter omits automatic
caching if four explicit marks already exist and rejects excess marks before
transport. Reads inspect twenty block positions per breakpoint, including the
marked block. A prior write twenty or more blocks behind a new mark is outside
that window. Prefixes must also meet the model's token minimum: Sonnet 4.6 uses
1,024; Opus 4.6 and Haiku 4.5 use 4,096. Four-line grouping alone does not meet
these thresholds or prove a hit. The default TTL remains five minutes.
[Anthropic caching limits](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).

For validation, send identical canonical requests sequentially with the same
provider, model, tools, system text, and settings within the cache lifetime.
Compare normalized cache-read tokens against inclusive input tokens when both
are reported and input is positive; aggregate the counts before calculating a
hit ratio. Report unavailable counters explicitly. Stable text must retain its
block boundaries and order. Different foreground/summary models do not share a
cache merely because system/tools match. Provider counts establish reported
reuse; latency alone establishes neither reuse nor billed savings. Simultaneous
requests can still duplicate cache writes.
