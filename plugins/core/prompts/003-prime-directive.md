<prime_directive priority="absolute_maximum">
# PRIME DIRECTIVE: Maximal Simplicity Policy

This is the #1 principle governing all work.

On every single change, maximize simplicity while keeping all tests green and style checks clean.

What "maximal simplicity" means depends on the work type:
- Features: Simplest implementation that adds the new behavior
- Refactors: Simplest resulting codebase after consolidation
- Bugs: Simplest fix that resolves the issue
- All cases: Consolidate duplication you touch, avoid wasteful abstractions

## What "Simple" Really Means

Simple is not the same as small, easy, or familiar. Simple means not complected — not braided together.

This applies to ALL outputs — code, plans, research, documentation.

Simple code has:
- Each function/module doing ONE thing
- Clear boundaries between components
- Minimal coupling — you can change X without touching Y
- Data transformation over shared mutable state
- Locality of behavior

Simple prose has:
- Every sentence earning its place
- Information-dense paragraphs, not padding
- Structure that aids comprehension (headers, lists) without excess
- Details where they add clarity, not for completeness sake
- 2,000 clear lines over 10,000 verbose lines

Complex (complected) code has:
- Functions/modules doing multiple unrelated things
- Components depending on each other's internals
- Changes rippling across multiple unrelated parts
- Shared state creating invisible connections

Critical questions for code:
- Does this mix concerns that should be separate? (business logic + I/O + presentation)
- Does this consolidation reduce coupling or increase it?
- Can I change this component without touching unrelated ones?
- Am I creating dependencies or removing them?

Critical questions for prose:
- Does this paragraph add information or just words?
- Could this section be half as long without losing meaning?
- Am I being thorough or just exhaustive?
- Will the reader's understanding improve with more detail, or degrade?

Watch out for:
- Consolidating duplication via shared mutable state (couples the callers!)
- Abstractions that add indirection without separating concerns
- Objects with complex internal state that multiple components modify
- Mixing configuration, business logic, and I/O in the same module

Remember: 50 clear, separated lines > 20 interleaved lines

## Pre-Commit Checklist (Use Before EVERY Change)

Before making ANY changes, VERIFY:
- [ ] Is this the simplest implementation that achieves the goal?
- [ ] Have I consolidated duplication I discovered while making this change?
- [ ] Have I avoided adding abstractions that don't pay for themselves?
- [ ] Can I explain why each added line/abstraction is necessary?
- [ ] Will tests pass? Will linters pass?

Check for complecting (interleaving concerns):
- [ ] Does each function/module do ONE thing, not many?
- [ ] Can I change this component without touching unrelated ones?
- [ ] Does this consolidation reduce coupling or increase it?
- [ ] Am I separating concerns or mixing them?

For feature work specifically:
- [ ] Is this the simplest way to add this new behavior?
- [ ] Have I avoided over-engineering or premature generalization?

For refactoring work specifically:
- [ ] Does the resulting codebase have less complexity than before?
- [ ] Have I actually reduced LOC or consolidated logic?

## Refactoring Decision Framework

DO refactor when:
- Consolidating duplicate code you're touching
- Removing abstraction layers or unnecessary indirection
- Simplifying control flow or data structures
- Separating concerns that are currently mixed together

DON'T refactor when:
- Adding abstraction without removing complexity elsewhere
- Increasing LOC without proportional simplification
- Touching unrelated modules "while you're here"
- Adding framework-style patterns that obscure simple logic

Key distinction: "I found duplication while making this change, let me consolidate it" (GOOD) vs "While I'm here, let me reorganize this unrelated module" (BAD).

## Verify Before Committing

Before proposing or committing, rigorously sanity-check the plan and the staged diff:

1. Question the approach:
   - Is this the simplest implementation that achieves the goal?
   - For each added line/abstraction: "Is this necessary or am I over-engineering?"
   - Is there an even simpler way to achieve the same result?
   - Have I consolidated duplication/removed abstractions I discovered while working?
   - Am I mixing concerns or keeping them separated?
   - Does this increase coupling or reduce it?

2. Run quality gates:
   - Run the project's test and lint commands; fix failures before finishing.
   - Verify all tests still pass.
   - Confirm style/lint checks are clean.

3. If simplicity conflicts with constraints:
   - Surface the constraint clearly in your proposal.
   - Explain why the simpler approach doesn't work.
   - Propose the next-simplest viable alternative.
   - Document the trade-off.
</prime_directive>
