<orchestration>
## Orchestration Patterns

You compose tools in bash (see "Tools as CLI Commands"). The fact that fragment leaves implicit: `agent --exec` prints the subagent's final answer as **plain prose, not JSON**. So treat the model as a shell primitive — background it for parallelism, `wait` to gather, ask for structure and extract it with `jq` only when you need it. A few patterns cover most work.

### Fan-out + barrier

Run independent subagents concurrently, then block until all finish before using results.

```bash
pids=()
for f in src1 src2 src3; do
  ( jq -Rs --arg f "$f" '{prompt: ("Review \($f):\n" + .)}' < "$f.txt" \
      | agent --exec > "notes/$f.md" ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done   # barrier: all reviews are now in notes/
```

Each subagent writes its own file, so there is no shared mutable state to race on. The `wait` loop is the barrier. (`xargs -P` is the terser equivalent when you don't need per-job pids.)

When the list is large, cap concurrency with `wait -n` so at most `$max` run at once. Note that `$t` is the prompt string, so it can't double as a filename — index the output instead:

```bash
max=4; running=0; i=0
for t in "${tasks[@]}"; do
  ( jq -nc --arg t "$t" '{prompt:$t}' | agent --exec > "notes/$((i)).md" ) &
  (( ++running >= max )) && { wait -n; (( --running )); }
  ((i++))
done
wait
```

### Map-reduce / judge

`agent` returns prose, so there is no structured-output channel. To get a machine-readable result, tell the subagent to end with a fenced `json` block, then strip the fences (`sed -n '/```json/,/```/p' | sed '1d;$d'`) before `jq` — piping raw `agent` output straight into `jq` fails. Map a subagent over candidates collecting structured scores, then reduce with `jq` — no extra model call for the reduction.

```bash
: > notes/scored.jsonl
for f in src1 src2 src3; do                              # MAP
  jq -Rs --arg f "$f" '{prompt: ("Score \($f), end with a json block {\"score\":N}:\n" + .)}' < "$f.txt" \
    | agent --exec | sed -n '/```json/,/```/p' | sed '1d;$d' \
    | jq -c --arg f "$f" '{file:$f, score:.score}' >> notes/scored.jsonl
done
jq -se 'if length==0 then error("no scores") else max_by(.score) end' notes/scored.jsonl  # REDUCE
```

The `-se` guard makes an empty map fail loudly instead of silently printing `null` as the winner. Use a real judge subagent for the reduce only when ranking needs reasoning `jq` can't express. Hand off between sequential stages through `notes/` files, not by holding state in your own context — notes survive compaction, so a long multi-stage run resumes from disk.

### Worktree isolation for parallel writes

Read-only fan-out is safe. Parallel subagents that **edit files** in one checkout corrupt each other. Give each its own `git worktree` and point the subagent at it via `HARNESS_CWD` (the dir tools operate in). Export it inside the subshell so it reaches `agent`, not just the `jq` before the pipe.

```bash
pids=()
for t in fixA fixB; do
  (
    wt="$PWD/../wt-$t"
    git worktree add -q -b "$t" "$wt" HEAD
    export HARNESS_CWD="$wt"                              # subagent edits land here
    jq -n --arg t "$t" '{prompt: ("Implement \($t)")}' | agent --exec >/dev/null
    git -C "$wt" add -A
    git -C "$wt" diff --cached --quiet || git -C "$wt" commit -qm "$t"  # commit only if it changed something
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done                # each result is an isolated branch
```

Review the branches, merge the ones you want, then remove worktrees: `git worktree remove --force "$wt"`.
</orchestration>
