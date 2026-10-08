# Executable and storage protocols

Harness uses one durable chat connected to separate web, reactor, inference
worker, and tool-job processes. `bin/harness` handles built-in CLI dispatch;
shared code lives in top-level `lib/`. The old session state machine,
Markdown/frontmatter transcript protocol, ACP/REPL commands, and `.stream`
interface have been removed.

See [RUNTIME.md](RUNTIME.md) for execution and recovery, and
[PROVIDER_PROTOCOL.md](PROVIDER_PROTOCOL.md) for the inference boundary.

## Source discovery

Sources are searched from lower to higher priority:

1. Bundled `plugins/*` directories.
2. `HARNESS_HOME` (default `~/.harness`).
3. Ancestor `.harness/` directories from `/` toward the actor's working
   directory, with each directory's `plugins/*` packs followed by the directory
   itself.

An executable with the same name in a later source overrides an earlier one.
Tools, providers, custom commands, and hooks use these sources. Provider plugin
directories are not filtered by an old assemble/receive stage; transport
translation is contained in the chosen provider executable.

`HARNESS_CWD` is the actor's working directory. The main actor records the
working directory when its store is created. `HARNESS_DATA`, defaulting to
`$HARNESS_HOME/chat`, selects the durable chat independently of configuration.
The application does not use the old `HARNESS_SESSIONS` directory.

## Commands

Custom commands are executables in `commands/`. `--describe` returns one-line
help; normal execution receives the remaining arguments. Built-in commands are
dispatched directly by `bin/harness`; unknown names are resolved as custom
commands rather than treated as chat input.

Built-ins: `start`, `stop`, `restart`, `serve`, `reactor`, `worker`, `submit`,
`cancel`, `history`, `status`, `tools`, `help`, and `version`. `auth` remains a
plugin command. No arguments select `start`. Component management accepts `all`,
`web`, `reactor`, and `worker-N`; foreground commands support independent process
supervision.

## Tools

Tools are executables in `tools/`:

| Invocation | Contract |
| --- | --- |
| `--schema` | JSON `{name,description,input_schema}` |
| `--describe` | One-line description |
| `--exec` | JSON input on stdin; result on stdout; diagnostics on stderr |

A nonzero exit marks the job's result as an error. Tool inputs are objects.
A standard optional `intent` describes the requested operation for observers;
tools that support it ignore it during execution.

```json
{
  "name": "example",
  "description": "Describe the operation",
  "input_schema": {
    "type": "object",
    "properties": {"path":{"type":"string"}},
    "required": ["path"]
  }
}
```

Tools inherit `HARNESS_ROOT`, `HARNESS_HOME`, `HARNESS_DATA`, `HARNESS_CWD`,
`HARNESS_ACTOR`, provider/model settings, and discovered `HARNESS_SOURCES`.
`HARNESS_ROOT` identifies the pinned code snapshot for scheduled work, so sourced
modules must not make it readonly or replace it with a live installation path.

Tool calls become durable jobs with launch receipts recorded in the request's
protocol artifacts. Launching jobs ends the turn without an acknowledgement-only
model call. The actual result arrives later as an `echo` inbox message.
stdout/stderr and execution metadata are retained in the job artifacts. The
runtime bounds tool execution and clips large observations for model input. A
job with a recorded lease but no completed result is not blindly rerun after
interruption.

The `agent` tool is a reactor-dispatched special case: its schema accepts
`name`, `prompt`, and optional `cwd`. It creates a child actor rather than
executing a second synchronous loop. Its final report becomes a parent `work`
message. Use `zoom` with its name/actor to inspect its independent chat.

Memory tools: `zoom` accepts a numeric memory `id` and power-of-two `n`; the ID
must be aligned to `n`. At `n=1`, zero-based `page` retrieves original text in
pages. A string ID selects an actor by ID or unambiguous name; `page` selects a
message and `part` selects its text page. `date` accepts a memory ID and optional
actor. Memory IDs are distinct from journal sequence numbers.

## Hooks and prompts

Hooks remain executables in `hooks.d/<name>/`. `call NAME` collects them by
basename, applies local overrides, sorts them, and pipes each output into the
next input. Names use a numeric prefix such as `10-name` for ordering. A nonzero
exit aborts the pipeline. No hooks means input passes through unchanged.

This is a named extension mechanism, not the previous `next_state` agent loop.
For example, the `auth` command calls `auth-set` with `{}` and exports
`HARNESS_AUTH_PROVIDER`; the selected hooks return a credential object.

Prompt fragments live in discovered `prompts/*.md`. Nearby `AGENTS.md` files
contribute instructions. Requests freeze the assembled prompt and tool schemas.
Avoid dates, view contents, status, or other changing per-turn data in the system
prompt when a stable cached prefix is desired.

## Durable events

Each committed record is a JSON object:

```json
{
  "seq": 1,
  "id": "stable-client-message-id",
  "actor": "main",
  "kind": "message",
  "data": {"kind":"user","text":"The complete input"},
  "date": "2026-10-08T12:00:00Z"
}
```

The store serializes publication, assigns a global sequence, and publishes
`events/NNNNNNNNNNNN.json` atomically. `HEAD` and an ID index identify committed
records and deduplicate repeat submissions. Records are immutable. Reusing an
ID with different kind, actor, or content is an error.
Startup recovers published records that were interrupted before their
`HEAD`/index update, so committed input is visible without another submission.

Chat-visible kinds are `message`, `assistant`, `tool`, and `error` for actor
`main`. Messages have a provenance kind: `user`, `echo`, `work`, or `note` and
complete `text`. Assistant data contains visible `text`, normalized `blocks`,
and `request_id`; tool data contains `name`, `input`, `call_id`, and `job_id`.
Internal request/job completion events drive projection and recovery, but do
not appear as duplicate chat messages. Child events are isolated by actor.

The reactor owns the state projection. Workers and jobs publish result events
instead of changing actor state. Model payloads and results are stored under
`requests/`; tool inputs, leases, and results under `jobs/`. A locked queue claim
and process lease distinguish active work from an interrupted operation.
Cancellation advances an actor generation, rejecting older queued turns/jobs
and preventing their observations from waking a newer task. Committed messages
remain in the journal and memory even when cancellation suppresses that wakeup.

## Web interface

The loopback HTTP process exposes JSON endpoints:

| Request | Result |
| --- | --- |
| `POST /api/messages` with `{text,id?}` | Durable acknowledgement `{id,seq}` |
| `GET /api/events?after=N&limit=N` | Next visible events after a cursor; zero loads the newest page |
| `GET /api/events?before=N&limit=N` | Earlier visible events in chronological order |
| `GET /api/status` | Actor/component/request/job status |
| `POST /api/cancel` | Durable cancellation request for `main` |

Feed responses are `{events,cursor,has_more,status}`. Older-history paging does
not replace the browser's forward cursor. Page sizes are 1–200. Responses have
byte-accurate lengths and no-store headers. Request bodies are limited to 1 MiB.
Text is rendered as text, not HTML. Exact Host/Origin allowlists protect proxy
access and state-changing requests; see
[the web README](../plugins/web/README.md).
