# AGENTS.md

Guidance for agents working in this repository. Follow the user's current
request and applicable working agreements within the instruction hierarchy.

## What this is

Harness runs one durable chat with tree-based memory. It is a Bash application
with separate web, reactor, and model-worker processes. Filesystem queues and
immutable events connect the components. Tools and provider executables remain
extensible without a package manager or language runtime.

Requires Linux, Bash 4+, `jq`, `curl`, `socat`, `flock`, `setsid`, `timeout`, and
`sync`. There is no per-session CLI, REPL, ACP adapter, or token-stream frontend.

## Commands

```bash
bin/harness                          # start managed components
bin/harness start [component]        # all, web, reactor, worker-N
bin/harness stop [component]
bin/harness restart [component]
bin/harness serve [port]             # foreground web only
bin/harness reactor                  # foreground event processor
bin/harness worker N                 # foreground model worker
bin/harness submit "do something"    # append input, return an acknowledgement
bin/harness history                  # committed main-chat events
bin/harness status                   # component, actor, queue, and job status
bin/harness cancel                   # stop the current main task
bin/harness tools
bin/harness auth [subcommand]
bin/harness help
bin/harness version

spec/run
SPEC_DIR=spec bash spec/tests/NAME/test.sh
```

`bin/hs` is an alias for `bin/harness`. The managed start defaults to one web
server, one reactor, and five workers (`HARNESS_WORKERS`). The default web port
is 8080 (`HARNESS_SERVE_PORT`).

## Ownership and data flow

`HARNESS_HOME` defaults to `~/.harness` for configuration and credentials.
`HARNESS_DATA` defaults to `$HARNESS_HOME/chat` for durable data. Existing session
stores are separate and must not be modified or silently migrated.

The HTTP process validates requests, submits durable events, and reads feeds and
status. It never owns a model request or agent task. Browser clients receive whole
committed events and status changes through Datastar SSE, preserve drafts, and
retry submissions with stable IDs. Pause connections and retries while hidden;
resume from the durable event cursor. Keep model responses and chat messages
complete rather than streaming tokens or partial messages.

The journal serializes publication under `flock`. Event IDs deduplicate retries;
reusing an ID with different content is an error. Publish complete records
atomically. Global event sequence numbers and per-actor memory message IDs are
different identifiers.

The reactor owns `state.json` and actor transitions. It consumes ordered events,
updates projections, schedules requests, and launches background jobs. Workers
claim queued model requests, make provider calls, and publish results. Tool jobs
run independently and report through events. Parent observations and named
subagent reports go into the inbox instead of blocking the parent on a tool.
Cancellation advances the actor's generation. Older queued work and observations
must not restart it; already committed messages remain in the permanent history.

Each request/job pins its payload, provider/model selection, tool paths, and planning code
snapshot. Preserve that version for in-flight work. New scheduling can load
updated code. Do not leak ownership locks into unrelated long-lived processes.
HTTP retries preserve the canonical payload and select the current transport
generation; worker deployment can fix unfinished requests without recreating them.
An interrupted tool can already have caused an external effect: report an unknown
outcome rather than blindly replaying it.

A fresh turn uses the saved memory prefix plus the chronological original actor
messages since the first pending input, including interleaved replies and tool
launches. A turn stays anchored on the message that opened it across tool
rounds and output continuations. In-turn provider/tool messages remain
separate protocol state. Preserve tool-call/result identities and observation
provenance; synthetic control messages are not user orders.

## Memory invariants

Each actor has memory under `actors/<id>/memory/`:

- `main/YYYY-MM-DD.jsonl`: append-only message records.
- `tree/YYYY-MM-DD.jsonl`: immutable completed nodes.
- `view.json`: saved turn view; `compact-view.json`: saved compaction view.
- Indexed records, ready queues, and recovery state support incremental work.

A leaf covers one message. A node at level `l`, index `i` covers `2^l` messages
starting at `i * 2^l`; only aligned adjacent siblings can merge. Summaries target
512 UTF-8 bytes. Measure bytes with `jq` or `wc -c`, not Bash character counts.
Preserve original input, names, corrections, exact paths, and progress status.
Reasoning must not enter memory.

The turn view grows from 64,000 to 128,000 bytes and then shrinks in one batch;
the compaction view uses 16,000 to 32,000 bytes. Rank eligible pairs by age from
their last message, divided by their size, with older pairs breaking ties.
Only built parents may be substituted. Save live views across restarts; never
reconstruct them from the log as a routine startup operation.

Queue ready summaries as dependencies complete. Do not scan the entire tree for
work on every tick. A fresh turn must not see placeholders or partial messages.
The `zoom` and `date` tools provide memory access; child actors retain independent
logs and report to their parent.

## Code layout

- `bin/harness`: CLI dispatch.
- `lib/bootstrap.sh`: configuration, executable discovery, hooks, shared helpers.
- `lib/store.sh`: event publication, durable submit/cancel, feed, status.
- `lib/runtime.sh`: projection, actor transitions, request/job scheduling.
- `lib/memory.sh`: message/tree storage, views, summaries, zoom/date.
- `lib/provider.sh`: provider resolution and canonical protocol validation.
- `lib/services.sh`: component management.
- `lib/{component,reactor,worker,request,job,tick}`: foreground supervisors,
  reactor ticks, model workers/requests, and tool-job execution.
- `plugins/core/tools/`: shell and file tools.
- `plugins/memory/`: zoom/date tools.
- `plugins/subagents/`: asynchronous child actors.
- `plugins/skills/`: skill discovery/loading.
- `plugins/{anthropic,openai,chatgpt}/providers/`: provider transports/variants.
- `plugins/auth/`: credential commands and OAuth integration.
- `plugins/web/`: socat HTTP process, framing/security, static browser client.

Discovery combines bundled plugin directories, `HARNESS_HOME`, and ancestor
`.harness/` directories, including their plugin packs. More-local executables
with the same basename override earlier ones. Prompts combine discovered prompt
fragments and nearby `AGENTS.md` files. Hooks are sorted executable JSON
pipelines for extension points, rather than the old state-machine transition
protocol.

Tools support `--schema`, `--describe`, and `--exec` (JSON stdin, stdout result).
Providers accept the canonical request and return normalized blocks and stop
reasons. Introspection flags and variant `.conf` files support discovery and
configuration. Protocol details belong in `docs/PROTOCOLS.md` and
`docs/PROVIDER_PROTOCOL.md`.

## Working conventions and verification

Use `set -euo pipefail` in Bash scripts and local variables in functions. Use
`jq` for JSON. Keep I/O, scheduling, memory algorithms, provider translation, and
presentation separate. Prefer explicit state and focused executable contracts.

Inspect Git status before editing and preserve concurrent work. Stage specific
files or hunks, review the final diff, and keep commits focused. Do not add tool
attribution or co-author trailers unless requested.

Run relevant tests and Bash syntax checks for code changes. Use mock providers
and temporary `HARNESS_HOME`/`HARNESS_DATA` paths; tests must not touch the user's
live chat or credentials. Do not make live API calls without task authorization.
ShellCheck should specify Bash for sourced files. Browser-client tests may use
Node when installed; it is optional and not an application dependency.

Favor behavior checks for replay, duplicate IDs, interrupted publication,
ordering, locks, cancellation, summary boundaries, UTF-8 byte limits, and
provider/tool identity preservation. Report exactly what was checked and any
remaining gaps. Documentation/configuration changes need direct validation;
avoid broad unrelated test runs.
