<orchestration>
## Orchestration Patterns

Treat `agent --exec` as a shell primitive. The parent agent should write small programs that call many model instances, capture compact outputs, reduce them with ordinary Unix tools, and keep bulky intermediate reasoning out of the parent context.

Use three output styles deliberately:

1. **Prose to files** when humans will read the results later.
2. **Structured JSON** when a script must branch, score, rank, or feed another agent.
3. **Durable notes/reports** written by a final agent when the parent only needs status.

### Structured agent calls for scripts

When a script needs to make decisions, pass `schema` to `agent --exec`. The schema may be a raw JSON Schema or an OpenAI-style structured-output envelope (`{type:"json_schema", name, schema, strict:true}`). The agent tool returns compact JSON suitable for `jq`.

```bash
result="$(
  jq -n '{
    prompt: "Classify this task as continue or stop. Return reason too.",
    schema: {
      type: "json_schema",
      name: "decision",
      schema: {
        type: "object",
        properties: {
          decision: {type: "string"},
          reason: {type: "string"}
        },
        required: ["decision", "reason"],
        additionalProperties: false
      },
      strict: true
    }
  }' | agent --exec
)"

if jq -e '.decision == "continue"' <<<"$result" >/dev/null; then
  echo "continue: $(jq -r '.reason' <<<"$result")"
fi
```

Use JSON for control flow. Do not pipe free-form model prose straight to `jq`.

### Fan-out + barrier

Run independent subagents concurrently, then block until all finish before reducing results. Each subagent writes its own output file so there is no shared mutable state.

```bash
pids=()
for f in src/*.py; do
  out="notes/review-$(basename "$f").json"
  (
    jq -Rs --arg f "$f" '{
      prompt: "Review " + $f + " and return risk score plus summary:\n" + .,
      schema: {
        type: "object",
        properties: {score: {type:"number"}, summary: {type:"string"}},
        required: ["score", "summary"],
        additionalProperties: false
      }
    }' < "$f" | agent --exec > "$out"
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
```

When the list is large, cap concurrency with `wait -n`:

```bash
max=4; running=0; i=0
tasks=("scan docs" "scan src" "scan tests" "scan tickets")
for t in "${tasks[@]}"; do
  (
    jq -n --arg t "$t" '{prompt:$t, schema:{type:"object", required:["summary"]}}' \
      | agent --exec > "notes/task-$i.json"
  ) &
  (( ++running >= max )) && { wait -n; (( --running )); }
  ((i++))
done
wait
```

### Map-reduce / judge

Use `jq` for reductions that are mechanical. Use a judge agent only when the reduction needs reasoning.

```bash
jq -s 'max_by(.score)' notes/review-*.json > notes/highest-risk.json
```

For reasoning reductions, pass the compact mapped results to one final agent:

```bash
reviews="$(jq -s . notes/review-*.json)"
jq -n --argjson reviews "$reviews" '{
  prompt: "Choose the most important issue from these reviews and explain why: " + ($reviews|tostring),
  schema: {
    type: "object",
    properties: {winner: {type:"string"}, rationale: {type:"string"}},
    required: ["winner", "rationale"],
    additionalProperties: false
  }
}' | agent --exec > notes/judgment.json
```

### Final-writer workflow

For recovery, planning, research, and other broad workflows, keep the parent as a thin coordinator:

1. Build a cheap inventory yourself with shell tools.
2. Spawn focused agents that each return compact JSON: objective, implementation, verification, repo state, risks.
3. Pass those JSON summaries to a final writer agent.
4. Have the final writer write the durable note/report to `notes/` and return only `{status,path,bytes}`.
5. Read the note only if the status or user request requires it.

```bash
objective="$(jq -n --arg archive "$archive" '{
  prompt: "Recover objective from " + $archive + " by targeted search. Cite files.",
  schema: {type:"object", required:["summary","citations"]}
}' | agent --exec)"

implementation="$(jq -n --arg archive "$archive" '{
  prompt: "Recover implementation and verification from " + $archive + ". Cite files.",
  schema: {type:"object", required:["summary","files","verification","citations"]}
}' | agent --exec)"

status="$(jq -n \
  --arg note "notes/post-compaction-recovery.md" \
  --argjson objective "$objective" \
  --argjson implementation "$implementation" \
  '{
    prompt: "Write " + $note + " from these summaries, then return status JSON: "
            + ({objective:$objective, implementation:$implementation}|tostring),
    schema: {
      type:"object",
      properties:{status:{type:"string"}, path:{type:"string"}, bytes:{type:"number"}},
      required:["status","path","bytes"],
      additionalProperties:false
    }
  }' | agent --exec)"

echo "$status" | jq -r '.status + " " + .path'
```

This is the core RLM pattern: parent scripts route compact state between model calls; subagents consume the large context; durable artifacts land on disk.

### Worktree isolation for parallel writes

Read-only fan-out is safe in one checkout. Parallel subagents that edit files can corrupt each other. Give each writer its own `git worktree` and point the subagent at it via `HARNESS_CWD`.

```bash
pids=()
for t in fixA fixB; do
  (
    wt="$PWD/../wt-$t"
    git worktree add -q -b "$t" "$wt" HEAD
    export HARNESS_CWD="$wt"
    jq -n --arg t "$t" '{prompt:("Implement " + $t)}' | agent --exec >/dev/null
    git -C "$wt" add path/you/expect
    git -C "$wt" diff --cached --quiet || git -C "$wt" commit -qm "$t"
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
```

Review and merge branches deliberately, then remove worktrees.
</orchestration>
