---
description: Check the acceptance criteria of a phase of the AWS implementation plan against the evidence
argument-hint: <phase number 1-5>
---

Check phase $ARGUMENTS of `docs/06-aws-implementation-plan.md`. Load the `aws-g7e-deployment` skill.

1. Read the phase's acceptance criteria.
2. For each criterion, find the evidence (result directory, log line, command output). Do not accept a statement without a file or command output behind it.
3. Print a table: criterion, value found, evidence path, pass/fail/missing.
4. The phase passes only if every criterion passes. If it passes, say which phase is next and what it needs first. If not, list what is missing, cheapest first.
5. Do not start instances or run paid work from this command.
