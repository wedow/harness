# Provider check

Run explicitly against a provider you have authorized for live inference:

```bash
scripts/check-provider.sh PROVIDER [MODEL]
```

This spends up to five sequential model calls. The first warms a fixed synthetic
128-line view, the second repeats it exactly, and the third appends one line.
The fourth requests a harmless `diagnostic_echo` call; the fifth supplies its
matching synthetic result and native continuation state. No returned tool runs.
Each call requests at most 4,096 output tokens and uses a 120-second curl limit,
with a 125-second process deadline. Failure stops the remaining calls and exits
nonzero. A provider that ignores the answer marker or requested tool also fails.

The check snapshots bundled code and uses temporary configuration, data, and
working directories. It copies the existing credential cache and provider
overrides; original source directories, hooks, prompts, and chat history are
excluded. OAuth refreshes update only temporary credential files. Existing
credential environment variables remain available. Nothing is persisted to your
chat or credential files; temporary requests and responses are removed on exit.
Local provider overrides are copied for the run and must honor the provider
contract and transport budget settings.

Stdout is one JSON report containing the provider/model, bundled `code_digest`,
and each call's phase, input-prefix SHA-256/byte count, elapsed seconds, stop
reason, normalized token usage, cache-read ratio, and success. The prefix covers
the stable system/tools/view before its closing tag and new instruction. It
excludes credentials. The digest identifies the bundled snapshot; copied local
provider overrides are outside that digest. No response text, reasoning,
headers, keys, or error bodies appear in the report.

`input_tokens` includes the whole prompt, including reported cached tokens.
Missing cache counters and undefined ratios are `null`; a reported zero means
zero. Compare the repeat and appended calls without assuming a cache hit or
price savings: support, thresholds, lifetimes, and billing vary by provider.
This is a small diagnostic, not a benchmark. The regular `spec/run` exercises
the check through an offline fixture and makes no live diagnostic calls.

## Observed ZAI run

On 2026-10-08, `scripts/check-provider.sh zai glm-5.3` passed all five calls
with the default implicit caching and a 16,002-byte initial input prefix.
The bundled code fingerprint was
`8f693e0b2f70b7b8417b00a5468483387ab2cba951c7550d23254dc1a5ca2db0`.

| Phase | Inclusive input tokens | Cache-read tokens | Reuse |
| --- | ---: | ---: | ---: |
| Warm | 5,586 | 5,568 | 99.7% |
| Exact repeat | 5,586 | 5,568 | 99.7% |
| Appended view | 5,602 | 5,568 | 99.4% |
| Tool call | 5,608 | 0 | 0% |
| Tool result | 5,729 | 5,568 | 97.2% |

An earlier interrupted diagnostic had already warmed this synthetic prefix, so
the first row is not a cold-cache baseline. ZAI returned native uncached input
separately from cache reads: the repeat reported 18 uncached plus 5,568 cached
tokens, confirming the inclusive normalization. Cache-write counts were absent
throughout. Calls took 3.6–4.9 seconds; these timings do not establish savings.
The tool-result call preserved native reasoning/tool identity and completed
without executing a tool. This validates the transport and reported reuse for
this run; it does not establish every runtime turn or summary will hit a cache.
