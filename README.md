# infer

Serving the GLM-5.3-Flash model to about 10,000 developers who use coding agents, on NVIDIA RTX PRO 6000 Blackwell GPUs. The system is being built on AWS.

| Path | Contents |
|---|---|
| [`docs/`](docs/README.md) | Current state, decisions, measured results, open questions and the AWS build plan. Start with `docs/README.md` |
| `bench/` | Benchmark harness: quality gate, decode and prefill, agent sessions against the SLO, summary. See [`bench/README.md`](bench/README.md) |
| `router/` | llm-d router and prefill/decode experiments run on a small test model |
| `.claude/` | Claude Code configuration: project instructions, skills, specialist agents, commands and hooks |
| `scripts/fetch_evidence.sh` | Downloads the raw results and the working journal from the release [`evidence-2026-11-12`](https://github.com/paulohenriquevn/infer/releases/tag/evidence-2026-11-12) |

## First steps after cloning

```bash
scripts/fetch_evidence.sh        # raw results and journal, checksum-verified (needs the gh CLI)
bench/setup_bench.sh             # upstream llm-inference-bench at a pinned commit plus our patch
(cd bench && uvx pytest -q)      # harness tests
```

Then open Claude Code in the repository root. `.claude/CLAUDE.md` loads automatically and points to the skills and agents. The build follows the phases of [`docs/06-aws-implementation-plan.md`](docs/06-aws-implementation-plan.md); `/phase-check 1` shows what phase 1 still needs.

Anything that starts or resizes paid cloud resources asks for confirmation first (hook `guard-paid-actions`).
