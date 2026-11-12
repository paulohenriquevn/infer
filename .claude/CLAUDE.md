# infer: GLM-5.3-Flash serving for coding agents

We serve GLM-5.3-Flash to about 10,000 developers who run coding agents. The system is being built on AWS. Everything we know is in `docs/`; read `docs/README.md` first in any new session that touches design, serving or infrastructure.

## What is decided (do not reopen without new evidence)

| Decision | Value | Why, in one line | Source |
|---|---|---|---|
| Engine | local-inference-lab fork of vLLM, image `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` | SGLang served half the sessions (FP8) or failed quality (NVFP4) on the same host | `docs/03`, §29.7 |
| Checkpoint | `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at `dec48abd33efa73c3bb7c95b74eee10cad34f9be` | Only 4-bit checkpoint that passes the needle gate; NVIDIA's PTQ NVFP4 fails it | `docs/02`, §29.5 |
| Replica | 4 RTX PRO 6000 Server Edition, TP4, MTP 3 tokens | Smallest unit that holds the official-size checkpoint; MTP above 3 is unstable | `docs/02` |
| Quality gate | needle-checksum 500 runs at C8 + 120 at C16, one-sided Fisher vs 3/500, plus gsm8k | 120/120 failed good configurations by chance | `docs/03` §5 |
| Primary metric | agent sessions inside the SLO per US$/h of a replica | What the product pays for | `docs/01` |
| SLO | zero turn errors, TTFT p95 <= 5 s on cached steady-state turns, per-stream p50 >= 30 tok/s | Targets are Hypothesis, but they are what we measure against | `docs/01` |
| P/D disaggregation | Not in the first design | Untested on the real model; on the test model it cut throughput 46% | `docs/04` |
| Infrastructure as code | Terraform, state in S3 with locking; plain EC2 for phases 1 to 3 | Existing Nebius Terraform; one tool for both providers we may use | `docs/decisions/2026-11-12-infrastructure-as-code-tool.md` |
| Engine switch rule | Only with >= 20% more sessions inside the SLO, in two runs | A switch costs the whole KV layer | §27.4 |

## What is open

DCP1 vs DCP4, whether the LMCache RAM tier pays off, fleet size, AWS price/quota/driver/P2P. The order of work is the phase plan in `docs/06-aws-implementation-plan.md`; a phase starts only when the previous one passed its acceptance criteria.

## Rules for this repository

1. **Evidence labels on every claim** in docs, PR descriptions, commit bodies and reports: Observed (path to the result), Reported (named source), Inferred (show the reasoning), Hypothesis, Unknown. A number without a label and a source does not go in.
2. **No serving change without the gate.** Any change to the image, checkpoint, launch flags, environment variables, kernels or driver re-runs the quality gate and the agent levels before its speed numbers count. Why: a kernel change once produced 5.9% wrong answers that passed several releases (§10.4), and W4A4 MoE doubled the error rate (§29.5).
3. **Single runs decide nothing.** A configuration change is accepted after two runs on a qualified host. DCP4 passed 16 agents once and failed the repeat (§29.6). Neither DCP1 nor DCP4 has a capacity confirmed by two runs yet.
4. **Qualify every new host** before measuring or reserving it: topology, P2P, driver, B12X all-reduce log line, C32 decode >= 1,400 tok/s with the DCP1 profile (DCP4 gives about 1,280 on a good host). Why: the same Vast listing was 5 times slower on one host (§29.10).
5. **Raw results are immutable.** Never edit files under `results/` or `f3/resultados/`; write a new run instead. A hook enforces this.
6. **Anything that costs money is confirmed first** (instances, reservations, `terraform apply`, scaling). A hook asks before such commands. Destroy test instances when the run ends and say so in the report.
7. **Docs are English** and pass `python3 ~/.claude/skills/humanize-writing/scripts/lint_prose.py` with 0 blocking findings (a hook runs it). No em dashes.
8. **Superseded numbers:** `docs/README.md` lists known contradictions in the journal. Use the current value; when you find a new contradiction, add it there.

## Where the knowledge is

| Topic | Skill | Specialist agent |
|---|---|---|
| Model architecture, KV size, checkpoints, quality alarm | `glm53-flash-model` | `serving-engineer` |
| vLLM fork profile, DCP, MTP, launcher, startup | `vllm-fork-serving` | `serving-engineer` |
| Prefill vs decode, interference, per-turn recompute, P/D | `prefill-decode-tuning` | `serving-engineer`, `kv-routing-architect` |
| KV tiers, LMCache, restores, KV events | `kv-cache-tiers` | `kv-routing-architect` |
| llm-d EPP, prefix affinity, cells | `llm-d-routing` | `kv-routing-architect` |
| SLO, quality gate, harness, host qualification | `inference-benchmarking` | `benchmark-analyst` |
| Demand model, fleet size, cost per session | `capacity-and-cost` | `benchmark-analyst` |
| AWS g7e, phases, IaC decisions | `aws-g7e-deployment` | `aws-platform-engineer` |
| Checking claims and sources | | `evidence-reviewer` |

Commands: `/qualify-host`, `/quality-gate`, `/summarize-run`, `/phase-check`, `/record-decision`.

## Code locations

The benchmark harness (`comparativo.sh`, `resumir.py` with tests, server launch scripts, `vast/roteiro.sh`) and raw results still live in the working tree `/home/paulo/Projetos/infer/f3/`, not in this repository. Skills cite them as `f3/...`. Moving the harness here is pending; when it moves, update the paths in the skills.

Tests: `uvx pytest -q` in the harness directory. Every bug fix starts with a failing regression test.
