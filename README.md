# harness

One continuous chat, with durable memory and separate Bash processes for the
web frontend, the reactor, and model workers. Messages survive process restarts.
The agent starts each new turn from a saved tree of summaries and can open an
older summary with `zoom` when it needs the original details.

This branch replaces the session-based loop. Its store defaults to
`~/.harness/chat`; existing session directories are left in place and are not
imported automatically.

## Run from source

Requires Linux, Bash 4+, `jq`, `curl`, `socat`, and the standard Linux utilities
`flock`, `setsid`, `timeout`, and `sync`. The runtime has no package manager,
language runtime, or build step.

```bash
git clone https://github.com/wedow/harness.git
cd harness
ln -s "$PWD/bin/harness" ~/.local/bin/harness
ln -s "$PWD/bin/harness" ~/.local/bin/hs
```

Configure a provider, then start the processes:

```bash
export ANTHROPIC_API_KEY="your-api-key"
export HARNESS_PROVIDER=anthropic
bin/harness start
```

Open `http://127.0.0.1:8080`. You can also submit a message from the terminal:

```bash
bin/harness submit "Find the TODO comments in this repository and summarize them"
bin/harness history
bin/harness status
```

Provider selection can use `HARNESS_PROVIDER`, `HARNESS_MODEL`, or
`settings.conf` in a discovered configuration directory. API providers include
Anthropic and OpenAI-compatible endpoints; ChatGPT and Claude subscription
providers use the existing OAuth credential flow:

```bash
bin/harness auth set chatgpt
bin/harness auth set claude
```

Use `bin/harness help` for commands and a provider executable’s `--env` flag
for its supported settings.

## Separate processes

`harness` with no arguments starts the managed components: one web server, one
reactor, and five model workers by default. Each component can be stopped or
restarted independently:

```bash
harness start
harness restart web
harness restart reactor
harness restart worker-1
harness stop all
```

The foreground commands are useful when developing or running processes under
another supervisor. Run each in its own terminal:

```bash
harness serve         # web only
harness reactor      # event processing and scheduling
harness worker 1     # one model worker; use different numbers for others
```

The web server saves input and displays completed messages. It does not make
model calls or own the active task. The browser polls with a cursor, reconnects
automatically, preserves drafts, and retries a submission using its original
ID when a response is lost. Older history loads in pages.

The reactor projects committed events into actor state, creates model requests,
and launches background tool jobs. Workers claim model requests from the
filesystem queue and publish their result. Workers check turn requests first,
then alternate priority after a turn so summaries also make progress.
Tool completion and subagent reports enter the inbox as observations; the agent
ends its turn after launching jobs and resumes when results or new input arrive.

Each request records its payload, provider, model, tools, and code version.
In-flight work keeps that version; newly scheduled work can use updated code.
The event journal and queued work remain on disk across component restarts.
An interrupted tool with an uncertain execution outcome is reported as an error
rather than automatically executed again.

## Memory

The memory layout follows the [UniiChat design](https://gist.githubusercontent.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449/raw/3c190e06f34aba0c69f49042c526093269604935/optchat.md).

Each actor has an append-only message log and binary tree. Leaves summarize one
message; a parent summarizes two adjacent siblings. Nodes target 512 UTF-8
bytes. Short inputs can become nodes without a model call. Completed nodes are
immutable, and summaries are built from queued ready work.

The saved view covers the chat in chronological order, with finer detail near
the present. It grows to 128,000 bytes, then merges available sibling pairs down
to 64,000 bytes, ranked by age relative to the pair's size. The smaller view used
for compactions grows from 16,000 to 32,000 bytes. Views are saved and reused
across restarts rather than rebuilt from the log.

A fresh turn waits until the earlier messages it needs have summaries, then
receives the view followed by the new input. Truncated responses continue with
their active-turn protocol messages. Visible replies and tool calls feed memory;
reasoning does not. Subagents have their own logs and return reports to the
parent. `zoom` opens summaries or original messages; `date` looks up a message's
timestamp.

## Files and extensions

```text
bin/harness                 CLI dispatch
lib/bootstrap.sh            configuration, discovery, shared helpers
lib/store.sh                immutable events, submissions, feed, status
lib/runtime.sh              event projection and scheduling
lib/memory.sh               tree, views, summary queue, zoom/date
lib/provider.sh             provider resolution and canonical protocol
lib/services.sh             managed process start/stop/restart
lib/{component,reactor,worker,request,job,tick}
                            foreground process executables
plugins/core/tools/         file and shell tools
plugins/memory/             zoom/date tools
plugins/subagents/          background delegation
plugins/skills/             skill loading
plugins/{anthropic,openai,chatgpt}/providers/
plugins/web/                HTTP frontend and standalone browser assets
```

The durable store is separate from code and configuration:

```text
$HARNESS_DATA/
  events/                   immutable ordered event records
  state.json                reactor's current projection
  queue/requests/            turn and summary requests
  queue/jobs/                background jobs
  requests/                 saved requests, leases, completed results
  jobs/                     job records, leases, completed results
  actors/<id>/memory/
    main/YYYY-MM-DD.jsonl    actor's message log
    tree/YYYY-MM-DD.jsonl    completed summary nodes
    view.json               saved turn view
    compact-view.json       saved compaction view
  components/               managed process identities
  code/                     code snapshots for scheduled work
  logs/                     component and job diagnostics
```

Discovery combines bundled `plugins/*`, `HARNESS_HOME`, and ancestor
`.harness/` directories from the working directory up to `/`. Local executables
with the same name override earlier ones. Tools implement `--schema`,
`--describe`, and `--exec`; providers use the canonical request/response protocol.
Prompts are assembled from discovered `prompts/*.md` files and nearby `AGENTS.md`
files. Hooks remain executable JSON pipelines for named extension points.

See [docs/PROTOCOLS.md](docs/PROTOCOLS.md) and
[docs/PROVIDER_PROTOCOL.md](docs/PROVIDER_PROTOCOL.md) for the executable contracts.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `HARNESS_HOME` | `~/.harness` | Configuration and credentials |
| `HARNESS_DATA` | `$HARNESS_HOME/chat` | Durable chat, queue, and process state |
| `HARNESS_CWD` | current directory | Working directory for the main actor |
| `HARNESS_WORKERS` | `5` | Number of managed model workers |
| `HARNESS_SERVE_PORT` | `8080` | Loopback web port |
| `HARNESS_PROVIDER` | first ready provider | Provider for turns |
| `HARNESS_MODEL` | provider default | Model for turns |
| `HARNESS_SUMMARY_PROVIDER` | turn provider | Provider for summaries |
| `HARNESS_SUMMARY_MODEL` | turn model, or the selected summary provider's default | Model for summaries |
| `MEMORY_VIEW_HIGH` / `MEMORY_VIEW_LOW` | `128000` / `64000` | Turn-view byte budgets |
| `MEMORY_COMPACT_HIGH` / `MEMORY_COMPACT_LOW` | `32000` / `16000` | Compaction-view byte budgets |

To serve through a trusted reverse proxy, configure the exact public origin:

```bash
export HARNESS_WEB_ALLOWED_ORIGINS='https://agent.example-tailnet.ts.net'
harness restart web
```

`HARNESS_WEB_ALLOWED_HOSTS` permits additional exact proxy Host values. The
listener stays on loopback. See [plugins/web/README.md](plugins/web/README.md)
for the HTTP endpoints and proxy rules.

## Verify

```bash
spec/run
SPEC_DIR=spec bash spec/tests/NAME/test.sh
```

Tests use temporary stores and mock providers. The web test also exercises the
browser client when Node is available; Node is not a runtime dependency.

MIT — see [LICENSE](LICENSE).
