<git_hygiene>
# Git Commit Hygiene

Multiple agents may work concurrently in the same repository. Every commit must be clean, focused, and contain only the changes for that specific task.

## Pre-Commit Checklist

Before every commit:

1. Run `git status` and `git diff --staged` — review exactly what you're about to commit
2. Stage only your files — use `git add <specific-files>` not `git add .`
3. Verify the diff matches your task — if you see changes you didn't make, DO NOT commit them
4. Check for uncommitted work from other agents — unstaged changes may belong to concurrent tasks

## Concurrent Agent Safety

When working in a shared repository:

- NEVER use `git add .` or `git add -A` — always stage specific files by path
- NEVER commit unstaged changes you didn't create — they belong to another agent's task
- If in doubt, ask — "I see changes to X file that I didn't make. Should I include these?"
- Keep commits atomic — one logical change per commit, not a mix of unrelated work

## No Attribution

Commits must NEVER include:
- "Generated with Claude", "Co-Authored-By: Claude", or similar
- Mentions of "AI", "Claude", or any tools/agents used
- Emojis in commit messages

## Clean Commit Messages

Format: terse, imperative mood, lowercase subject, no period

```
feat: add salesforce oauth client
fix: auth middleware for canvas requests
chore: split ingress for separate cache routes
```

Body (optional): explain WHY only — the diff shows WHAT changed.
</git_hygiene>
