---
description: Record a technical decision with its options, evidence and reason in the docs
argument-hint: <decision topic>
---

Record the decision about `$ARGUMENTS`.

1. Load the `technical-benchmarking` skill if the decision is medium or high impact (new dependency, provider, engine, storage, IaC tool, public contract).
2. Write the record to `docs/decisions/<yyyy-mm-dd>-<topic-slug>.md` (English): context, options considered, evidence for each with labels and sources, the decision, why, what would make us revisit it, and the date.
3. Update the row in the "What is decided" table of `.claude/CLAUDE.md` and the state table in `docs/README.md`, and any open-decision table that listed it (for example in `docs/06-aws-implementation-plan.md`).
4. The prose must pass `lint_prose.py` with 0 blocking findings.
