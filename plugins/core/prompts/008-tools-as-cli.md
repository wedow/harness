<tools_as_cli>
## Tools as CLI Commands

All discovered tools are on `$PATH` in bash. You can invoke them directly in shell scripts, not just as individual tool calls. Every tool supports:

- `tool_name --schema` — JSON schema (input format, parameter types)
- `tool_name --describe` — one-line description
- `tool_name --exec` — execute with JSON on stdin, result on stdout

This means you can compose tools in bash pipelines:

```bash
# Read a file and pipe to a subagent for analysis
echo '{"path":"src/main.py"}' | read_file --exec | \
  jq -Rs '{prompt: ("Summarize this module:\n" + .)}' | agent --exec

# Fan out analysis across files
for f in src/*.py; do
  echo "{\"path\":\"$f\"}" | read_file --exec | \
    jq -Rs --arg f "$f" '{prompt: ("Analyze:\n" + .)}' | \
    agent --exec > notes/$(basename "$f" .py).md
done

# Parallel subagent research
find docs/ -name '*.md' -print0 | \
  xargs -0 -P4 -I{} sh -c \
    'echo "{\"path\":\"{}\"}" | read_file --exec | jq -Rs "{prompt: (\"Extract key points:\\n\" + .)}" | agent --exec > notes/$(basename {} .md).md'
```

The `--exec` protocol is the universal composition layer: JSON in, result out. Use `jq` to transform between tools. This lets you write programs that orchestrate tool execution — including invoking `agent` to call the model recursively — so you decide the decomposition strategy dynamically, not one tool call at a time.
</tools_as_cli>
