# GLM-5.3-Flash serving for coding agents

This folder is the consolidated state of the project: serving the GLM-5.3-Flash model to about 10,000 developers who use coding agents, on NVIDIA RTX PRO 6000 Blackwell GPUs. It is written for the people and the coding agents who will build the system on AWS. Everything here was distilled on 2026-11-12 from the working journal `ARQUITETURA.md` (Portuguese, chronological), the notes in `NOTAS.md`, the reports in `reports/` and the raw results in the results archive: `f3/resultados/`.

## Where things stand

| Topic | State | Document |
|---|---|---|
| Serving engine | Decided: the local-inference-lab fork of vLLM with the QAD NVFP4 checkpoint, 4 GPUs per replica, TP4 + MTP3. SGLang measured and rejected | `03-serving-engine-and-benchmarks.md` |
| Replica profile | Open: DCP1 (24 agents inside the SLO, one run) or DCP4 (16 agents, not reproduced) | `03-serving-engine-and-benchmarks.md` |
| Quality gate | Decided: needle-checksum, 500 runs, one-sided Fisher test against 3/500, implemented in `bench/summarize.py` | `03-serving-engine-and-benchmarks.md` |
| KV tiers | LMCache RAM tier restores sessions but does not raise concurrent capacity; corrected test not run | `04-kv-cache-routing-and-disaggregation.md` |
| Router | llm-d EPP with prefix affinity, validated only on a small test model | `04-kv-cache-routing-and-disaggregation.md` |
| P/D disaggregation | Not in the first design | `04-kv-cache-routing-and-disaggregation.md` |
| Fleet size and cost | The fleet table is out of date: it assumed 40 streams per replica, measured is 16 to 24 agent sessions | `01-product-demand-and-slo.md`, `05-capacity-cost-and-providers.md` |
| Provider | AWS chosen for development; `g7e.24xlarge` is one replica. Nothing has run on AWS | `05-capacity-cost-and-providers.md`, `06-aws-implementation-plan.md` |

## Documents

1. `01-product-demand-and-slo.md`: product decision, coding-agent workload, demand model, SLO and the primary metric.
2. `02-model-hardware-and-checkpoints.md`: model architecture, KV size, GPUs and hosts, checkpoints and their quality, what the vLLM fork adds.
3. `03-serving-engine-and-benchmarks.md`: engine decision, measured numbers, the serving profile in production, quality gate, host qualification, how to reproduce.
4. `04-kv-cache-routing-and-disaggregation.md`: KV tiers, LMCache, router experiments, P/D, cell design.
5. `05-capacity-cost-and-providers.md`: what a replica costs and holds, Nebius, Vast.ai and AWS findings.
6. `06-aws-implementation-plan.md`: phases with acceptance criteria for building on AWS. Start here to write code.

## Conventions

Every important claim carries an evidence label:

- Observed: we measured it; the result path is given.
- Reported: a named source says it; we did not reproduce it.
- Inferred: derived from other data; the reasoning is given.
- Hypothesis: to be validated.
- Unknown: nobody has the answer yet.

Section references such as "§29.6" point to `ARQUITETURA.md`, the Portuguese working journal, and paths such as `f3/resultados/...` point to raw results. Both are in the release `evidence-2026-11-12` (https://github.com/paulohenriquevn/infer/releases/tag/evidence-2026-11-12); `scripts/fetch_evidence.sh` downloads them, checks the checksums and places them at the repository root. Most numbers come from single runs; the documents say so where it matters. Prices carry the date they were read.

## Repository layout

| Path | Contents |
|---|---|
| `bench/` | The benchmark harness used for the engine comparison: `run_benchmark.sh` (gate, speed, agent levels), server launch scripts, `summarize.py` (SLO and quality verdicts, with tests), `setup_bench.sh`. See `bench/README.md` |
| `bench/vast/` | `vast.sh` and `prepare_host.sh`: rent, prepare, run, fetch and destroy Vast.ai instances |
| `bench/llm-inference-bench/` | `llm_decode_bench.py` from local-inference-lab with our exact-history patch, cloned by `bench/setup_bench.sh` (not versioned) |
| `router/` | llm-d routing experiments on the mini model: Helm values, A/B, session client, P/D manifests and load |
| results archive: `f3/resultados/` | Raw results, one directory per run, published separately from this repository |
| `f3/rtx/`, `f3/b300/`, `f3/terraform/` | Terraform used on Nebius (working tree, not in this repository) |
| `reports/`, `research_notes/` | Research reports and their source notes (Portuguese) |

## Contradictions found while consolidating

The journal grew over two weeks and some early numbers were superseded without being edited in place. The documents use the latest value. Known cases:

| Topic | Earlier text | Current value |
|---|---|---|
| KV per 256K session | 1.62 GB (§2, §3, §8.3) | about 2.3 GB (8.7 KB per token plus about 0.15 GB of KDA state; §2 correction, §9.3); §10.1 and §13.2 give 2.2 and 2.28 GB |
| Streams per replica in the fleet table | 40 (§18.1, §20.1) | 24 agent sessions inside the SLO with DCP1 (one run), 8 with DCP4 (one run; §29.6 calls it guaranteed, see below); §20 also says the 30 tok/s floor caps a replica at 32 streams |
| Replicas for the 10,000-user base case | 22 (§18.1) | 35 to 44 after the Weka corpus (§24.3), still before the measured capacity above |
| Cost per user (§19.1) | US$ 15.8 to 25.2 per month | Out of date: depends on the 40-stream assumption |
| Needle gate | 120/120 (§27.4) | Fisher test against 3/500 (§29.5) |
| vLLM DCP4 capacity | 16 agents (§29.1); 8 guaranteed under the two-run rule (§29.6) | 16 failed on repeat; level 8 passed only in run 1 (run 2 tested 16 and 24), so no DCP4 capacity is confirmed by two runs |
| gsm8k on host 48294 | 99% (§29.10) | 96/96 in the raw `gsm8k.json` |
| SGLang FP8 needle | 4/480 (§29.5) | 4/240 at C8 and 0/240 at C16; 4/480 is the pooled total |
| Host qualification threshold | 1,400 tok/s at C32 (§29.10) | Applies to the DCP1 profile; DCP4 gave 1,279 to 1,288 on the good host 157204 |
| LMCache version in the image | 0.5.5.dev0 (§15) | 0.5.3.dev453+lil, 2026-10-11 (§25.1, read from the image) |
| Sessions per US$/h baseline | 12.3 (§12.4, §26.4) | That figure counts HBM capacity without an SLO; inside the SLO it is 2.85 to 4.28 (§29) |
| Image driver | "tests driver 615.71.09" (§10.4) | expects 615.65.02 or newer (§25.1) |
| Fork lag behind upstream vLLM | 3,304 (§13.3), 3,222 (§22.1), 2,439 (§26.5) commits | Different reference branches and dates; recount before relying on it |
| b12x repository | active (§13.3) | archived, moved into FlashInfer (§22.1) |
| TTFT target scope | 5 s for turns with up to 8K new tokens (§20) | `summarize.py` applies 5 s to every cached turn |
| SGLang decision reason "llm-d reads vLLM KV events" (§29.7) | | Corrected on 2026-11-12: only the approximate router mode, which ignores events, was tested |

Further per-topic inconsistencies are listed at the end of `04-kv-cache-routing-and-disaggregation.md`.

## What is still open, in order

1. Second speed run of vLLM DCP1 at 16 and 24 agents on a host that passes qualification (phase 1 and 2 of the AWS plan cover it).
2. The corrected LMCache test (phase 4).
3. Recompute the fleet size and cost per user from measured capacity.
4. G7e: current price, discounts, quota, driver and GPU peer-to-peer.
5. Cause of the 5 times slower Vast host 48294 (Unknown; it ran driver 580.95.05).
