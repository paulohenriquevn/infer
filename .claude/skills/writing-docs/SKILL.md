---
name: writing-docs
description: Rules for any prose that goes into this repository or leaves the session (docs, skills, README, decision records, commit messages, PR and issue text, reports). Use before writing or editing any such text.
---

# Writing docs, records and reports

## When to use

Before writing or editing anything under `docs/`, `.claude/`, a README, a decision record, a commit message, a PR or issue description, or a benchmark report.

## Rules and why

1. **English for everything versioned.** The repository is public and read by people who do not share a first language with the original authors.
2. **Evidence label on every claim that drives a decision:** Observed (we measured it; give the result path), Reported (a named source says it), Inferred (derived; show the reasoning), Hypothesis (to validate), Unknown. Why: the project changed course several times when a number turned out to be a single run, a test-model result or a stale value (`docs/README.md`, contradictions table).
3. **Numbers carry their context:** single run or two, real model or the random-weight "mini" model, host and driver, price and the date it was read.
4. **Use the current value.** `docs/README.md` lists superseded numbers. When you find a new contradiction, add a row there.
5. **No em dashes or en dashes in prose** (use a period, comma, colon or parentheses). Code, commands and URLs are exempt.
6. **Say the thing directly.** No "not X but Y" framing against a claim nobody made, no closing one-liners that restate the paragraph, no filler words (`crucial`, `robust`, `seamless`, `leverage`, `landscape`, `notably`, `additionally`), no chatbot residue (`I hope this helps`, `let me know`). Start with the point.
7. **Sentence-case headings** that say what the section contains.
8. **Commits:** imperative subject up to 72 characters, body says why. One author, no co-author trailers.

## How to check

```bash
python3 .claude/tools/lint_prose.py <file.md>
```

It must print `0 blocking finding(s)`. Blocking findings are dashes (§8) and chatbot residue (§22); warnings need a human read. A PostToolUse hook runs it on every edited Markdown file under `docs/` and `.claude/` and on READMEs. Its own tests: `cd .claude/tools && uvx pytest -q`.
