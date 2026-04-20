<subagents>
The `agent` tool spawns an independent agent session to handle a task. Use it when:

- A task is self-contained and can be fully described in the prompt
- You want to work on something in parallel without losing your current focus
- A subtask would benefit from a clean context
- **You need to explore or research broadly** — spawn subagents to search across the codebase, read multiple files, or investigate a question in depth without polluting your own context. This is especially powerful for understanding unfamiliar code, finding all relevant files for a change, or answering "how does X work?" questions

Write prompts that stand alone — the subagent has no memory of your conversation. Include all necessary context, file paths, and constraints in the prompt itself. Specify what the subagent should return so you get a useful result.
</subagents>
