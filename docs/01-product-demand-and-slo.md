# Product, demand and SLO

This document states what the system must serve, how much of it, and how we decide whether a
configuration is good enough. It covers self-hosting GLM-5.3-Flash for about 10,000 software
developers who run coding agents, on NVIDIA RTX PRO 6000 Blackwell GPUs, with the
`local-inference-lab` vLLM fork as the engine.

Sources are `ARQUITETURA.md` (cited by section, e.g. §18.1), `reports/Arquitetura para 10 mil
usuários.md` (cited as "the 10k report"), the notes in `research_notes/Arquitetura para 10 mil
usuários/`, `bench/summarize.py`, and result files in the results archive: `f3/resultados/`. All sources are in
Brazilian Portuguese; figures are copied from them, not recomputed, unless a line says Inferred and
shows the arithmetic.

Evidence labels: **Observed** (we measured it), **Reported** (a named source says it),
**Inferred** (derived, with the link stated), **Hypothesis** (to be validated), **Unknown**.

## Summary

- Product decision (§19): Unlimited tokens at a fixed cost per user. We do not try to beat
  the Z.ai API on cost per token; at the demand we modeled, the API is cheaper (§18.2, Inferred).
  The fleet only pays off if off-peak capacity gets used and per-user concurrency is capped.
- Workload: Coding-agent traffic is almost all prefill of a long, reused prefix: 98.6% of
  served tokens are input and 96% of turns reuse 90% or more of the prefix (Reported, llm-d
  GLM-5.2 blog, §8.1). Sub-agents arrive in correlated bursts (median group of 16 requests, p90
  47, p99 175 in the Weka corpus, Observed in our analysis, §24.1).
- SLO per replica (`bench/summarize.py`, §20, §26.4): zero turn errors, TTFT p95 <= 5 s on
  cached turns in steady state, per-stream decode p50 >= 30 tok/s. The targets are Hypothesis
  (§20); they are what we measure against.
- Primary metric (§26.4, §27.4): agent sessions inside the SLO per US$/h of a replica. An
  engine only replaces the current one with at least 20% more sessions per US$/h, in two runs,
  after passing the quality gate.
- Current measured capacity (§29.6, Observed): 24 coding-agent sessions per 4-GPU replica
  with DCP1 (one run only, TTFT p95 4.93 s); with DCP4, 16 passed once and failed the repeat, so
  the capacity that meets the two-run rule is 8.
- The fleet table is stale. It assumed 40 streams per replica (§18.1) and demand factors that
  §24 later corrected. It must be recomputed with measured capacity and measured demand before any
  sizing or budget decision.

## Product goal and decision

The target is 10,000 developers with **unlimited tokens** (Paulo's decision, §19). The product sells
what the API does not: no token limit, with a fixed and known cost per user. §19 replaces the
cost-per-token framing of §18.2 as the decision criterion.

Consequences recorded in §19:

- The fleet costs the same each month and the marginal token costs almost nothing until saturation
  (Inferred, §19.1). The metric becomes fixed cost per user and utilization.
- Fleet-only cost per user per month at 10,000 users: US$ 15.8 (base, 15 VMs), US$ 25.2 (high, 24
  VMs), US$ 78.8 (stress, 75 VMs) (Inferred, §19.1). These come from the §18.1 fleet table and
  inherit its 40-streams assumption (see "Measured capacity versus the fleet table").
- Indicative selling price US$ 22.6 (base) to US$ 50.4 (high) with 30 to 50% gross margin (Inferred,
  §19.1). Reference plans with limits: Z.ai Lite US$ 18, Pro US$ 72, Max US$ 160; Claude Max US$ 200
  (Reported, §19.1).
- The fleet is sized for the peak, so average utilization is 15 to 24% and about 76 to 85% of paid
  capacity sits idle (Inferred, §19.2). The engineering goal is to fill the valley: background agents
  (CI, refactoring, tests, PR review) go to a low-priority asynchronous queue that yields to the
  interactive queue, and users in several time zones flatten the peak-to-average ratio (§19.2).
- "Unlimited" still needs controls (§19.3): a cap on simultaneous streams per user (2 to 4 as
  Hypothesis; the MVP proposal is 2, §20), fair share at peak, an acceptable-use policy, one key per
  user with anomaly detection in the gateway, and quota or a second GPU source before launch.
- Token metering in the gateway stops being a billing mechanism and stays for abuse detection and
  consumption measurement (§19.4).

Open product decisions from §19.5 are listed under "Open questions".

## Workload model of coding agents

### Shape reported by the llm-d GLM-5.2 blog (§8.1)

Source: "Serving GLM-5.2 for Agentic Workloads on llm-d" (219 Claude Code sessions, 78,099
requests). The model differs from ours, so absolute performance numbers do not transfer; the
workload shape does. All Reported.

| Property | Value |
|---|---|
| Input per request | median 195K tokens |
| Output per request | median 317 tokens |
| Prefix reuse | 96% of turns reuse 90% or more of the prefix |
| Token mix | 98.6% of served tokens are input |
| Pause between turns | median 2 s, p90 24 s, p99 11.4 min |
| Session length | median session lasts 1 hour |
| Sub-agent fan-out | groups of 7 requests at the median, 51 at p90, arriving together |

Implications drawn in §8.1: cost is almost all prefill, so report US$ per 1M input and output tokens
separately; KV must survive pauses (with 100 to 400 conversations, live data is 1.4 to 5.6 times
HBM); burst tests need 51 requests sharing a prefix.

### Shape measured on the Weka corpus (§24)

Source: `semianalysisai/cc-traces-weka-062126` (393 sessions, 98,827 requests), processed by
`f3/p0/analisar_weka.py`, output in `f3/p0/weka-resultado.json` (both in the working tree, not in this repository). Mean input (218,921.8), mean output
(1,077.4) and request counts match the dataset README exactly (Observed, §24).

| Parameter | Earlier assumption | Weka value |
|---|---|---|
| New tokens per request (P) | 8,500 / 4,000 / 1,100 | mean 3,702, p50 1,600, p90 5,888, p99 40,960 |
| Global prefix hit | 96% | 98.31% |
| Output per request (O) | 690 / 1,500 / 4,000 | mean 1,077, p50 444, p90 2,659, p99 9,311 (these are Claude tokens) |
| Fraction of session time in the loop (φ) | 0.15 / 0.25 / 0.40 | mean 0.256, p50 0.205, p90 0.508, p99 0.939 |
| Streams per looping session (f) | 1.15 / 1.3 / 2.0 | mean 1.146, p50 1.02, p90 1.43, p99 2.93 |
| Share of requests from sub-agents | 51.7% | 42.5% |
| Requests per sub-agent group | median 7, p90 51 | median 16, mean 24.8, p90 47, p99 175 |
| Peak concurrency per session | n/a | mean 3.2, p90 6, p99 16 |
| Request starts in 10 s (per-session peak) | burst of 51 | mean 5.4, p90 11, p99 19 |
| Pause between main turns | 17 s (base) | p50 4.8 s, p90 120 s, mean 376 s (human time included) |
| Engaged hours per session (30 min max gap) | n/a | median 1.43, mean 3.43, p90 7.4 |

Caveats (§24.1): the corpus keeps sessions with at least 20 requests, uses "top" sampling and caps
concurrent sub-agent groups at 10, so it favors heavy users and tends to overestimate load per
user. The models are Claude Opus and Haiku, with Claude latencies.

§24.3 fixes these parameters for sizing: P = 3,700, 98% hit, f = 1.15, loop pause of 5 s. Output of
GLM-5.3-Flash with `max` thinking is Unknown.

### Loop time depends on our engine speed (§24.2)

φ = 0.256 holds at Claude latency (mean API time 12.3 s). With R1 constants (prefill under decode
4.1K tok/s, decode 44.5 tok/s per stream at 32 streams) and the corpus mean output, a GLM request
takes about 25 s (P/4,100 + O/44.5 = 0.9 + 24.2), 2.0 times Claude. If pauses stay the same, φ rises
from 0.26 to 0.41 and looping sessions at peak grow 1.6 times; at 2.5 and 3 times slower, 1.8 and 2.0
times (Inferred, `φ' = bφ/(bφ+(1−φ))`). Every gain in per-stream speed therefore reduces replicas
(§24.2, §26.4). The experiment that closes this is EK9: a real agent on GLM recording
`completion_tokens`, `reasoning_tokens` and time per request (§24.3).

### What the benchmark harness saw (§29.2)

On both engines tested, each cached turn re-prefilled 3,200 to 3,800 tokens at p50 and 5,300 to
5,900 at p90 even with about 97% of the prompt from cache (Observed). This is the tail the hybrid
cache does not reuse, and on vLLM it is what moves TTFT p95 from 3.4 s at 8 agents to 6.1 s at 32.

## Demand sizing from 1,000 to 10,000 users

### Peak-streams formula (10k report §2, §18.1)

```
L = U x d x h x s x φ        looping sessions at peak
S = L x f                    concurrent streams at peak
```

| Factor | Meaning | Low | Base | High | Source and label |
|---|---|---|---|---|---|
| d | DAU over registered users on a workday | 0.25 | 0.40 | 0.60 | Jellyfish and Anthropic usage data (Reported) plus monthly active share (Hypothesis) |
| h | share of active users engaged in the peak hour | 0.35 | 0.50 | 0.60 | Hypothesis with no direct source |
| s | open sessions per engaged user | 1.1 | 1.3 | 1.6 | Jellyfish (Reported); high is Hypothesis |
| φ | share of session time in the loop | 0.15 | 0.25 | 0.40 | TraceLab and Copilot (Reported); Hypothesis anchored on them |
| f | streams per looping session (sub-agents) | 1.15 | 1.3 | 2.0 | Copilot median 1.15 (Reported); base and high are Hypothesis |

Base at 10,000 users: 10,000 x 0.40 x 0.50 x 1.3 x 0.25 = 650 looping sessions, x 1.3 = 845 streams.
Per registered user this is 0.0166, 0.0845 and 0.461 streams in the low, base and all-high cases.

Which factors are weakest: h has no direct source and φ has fragile support (the two sources differ
by an order of magnitude on median human pause, 1.4 vs 25.2 min) (§18.5). Sensitivity of fleet size:
call weight (P and O) 3.2x, φ 2.7x, d 2.4x, h 1.7x, f 1.7x, s 1.45x (§18.5). No public source gives
the ratio between registered users and looping sessions at peak (§18.5).

Corrections after the formula was set: Weka gives f = 1.15 instead of 1.3 and sub-agent share 42.5%
instead of 51.7%; φ = 0.25 is confirmed only at Claude latency (§24, and the update note at the top
of the 10k report).

### Fleet table (§18.1, superseded inputs)

Assumptions: 8-RTX VM at US$ 10,512 per month (US$ 14.4 per hour, Nebius list), 2 replicas per VM,
**40 streams per replica** at base call weight, Poisson margin `1 + 3/sqrt(L)`, and 1 N+1 VM per 5
load VMs. All values Inferred at list price.

| Scale and scenario | Peak streams | Replicas | Load VMs / total VMs | Fleet, US$ k/month | Z.ai API, US$ k/month |
|---|---|---|---|---|---|
| 1,000 low | 17 | 1 | 1 / 2 | 21 | 1.4 |
| 1,000 base | 85 | 3 | 2 / 3 | 31.5 | 5.1 |
| 1,000 high | 146 | 4 | 3 / 4 | 42 | 8.7 |
| 10,000 low | 166 | 5 | 3 / 4 | 42 | 14.2 |
| 10,000 base | 845 | 22 | 12 / 15 | 158 | 51 |
| 10,000 high (Anthropic anchor) | 1,460 | 37 | 20 / 24 | 252 | 87 |

The 10k report adds a stress row (all factors high): 4,608 streams, 116 replicas, 62 / 75 VMs,
US$ 788.4k per month; it is not a planning scenario. The "high" row of 1,460 streams is an
independent anchor from Anthropic token data, not the formula with all-high factors (10k report §2).

Two later findings already invalidate the table as a sizing answer:

1. §24.3: with GLM taking about twice as long per request as Claude, the 22 base replicas become
   about 35 to 44 (Inferred, without Poisson margin or N+1).
2. §29.6: measured capacity per replica is below 40 (next section).

### Measured capacity versus the fleet table

Measured on 4 RTX PRO 6000 Server Edition at US$ 5.61/h (Vast.ai machine 157204), vLLM fork with
NVFP4 QAD checkpoint, TP4, MTP3. Results in `f3/resultados/vast-20261111/vllm/` (Observed, §29.6).

| vLLM | DCP4 run 1 | DCP4 run 2 | DCP1 |
|---|---|---|---|
| KV capacity | 23.1M tokens | 23.1M tokens | 6.79M tokens |
| 16 agents: TTFT p95, tok/s p50 | 4.77 s, 57.2 (pass) | 5.20 s, 57.8 (fail) | 4.71 s, 70.8 (pass) |
| 24 agents: TTFT p95, tok/s p50 | not measured | 5.97 s, 47.1 (fail) | 4.93 s, 55.3 (pass) |
| Sessions per US$/h | 2.85 (16 / 5.61) | | 4.28 (24 / 5.61) |

- DCP1 passed at 24 agents in **one run only**, with 0.07 s of TTFT margin. A second DCP1 run on
  another machine (48294, §29.10) produced invalid speed numbers (decode about 5 times lower, GPUs
  near idle, cause Unknown), so 24 is still unconfirmed.
- DCP4 at 16 agents did not reproduce. §29.6 calls 8 agents its guaranteed capacity, but
  level 8 passed in run 1 and was not repeated (run 2 tested only 16 and 24), so no DCP4 capacity is confirmed by two runs yet (Observed in `vast-vllm-r1/` and `vast-vllm-r1-rep2/`).
- Agent levels tested were 8, 16, 24 and 32, so "sessions in SLO" is a lower bound (§29.2).
- The harness agent is close to one continuous stream: think time 0 to 3 s, start context 40K to
  100K tokens, tool results 1K to 6K, responses 300 to 4,000 tokens, `--max-num-seqs 32` (Observed in
  `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/agentes-24.json` and `servidor.sh`). It has no
  sub-agent fan-out and no human pauses.

Illustration only (Inferred): replacing 40 by 24 in the base row gives 845 / 24 = 35.2 replicas
before Poisson margin and N+1, against 845 / 40 = 21.1 in §18.1. This still uses the superseded
demand factors (f = 1.3, Claude-latency φ), so it is not a new fleet number. At Nebius list price
per replica (US$ 14.4 per VM-hour / 2 = US$ 7.2), 24 sessions would be 24 / 7.2 = 3.3 sessions per
US$/h, against 4.28 at the Vast price (Inferred).

**The fleet table must be recomputed** with: measured sessions per replica (after a second DCP1
run), demand factors corrected by Weka (§24.3), φ at our measured request time (EK9), and the price
of the provider actually chosen. This document does not recompute it.

### Cost comparison with the Z.ai API (§18.2, 10k report §1)

Kept as context; §19 removed it as the decision criterion.

- Self-host at 100% utilization: about US$ 1.40 per 1M output tokens and US$ 0.49 per 1M new input
  tokens, 2.8 and 3.3 times Z.ai list price (US$ 0.50 and US$ 0.15). The two do not add up, because
  prefill and decode share the replica. Cached input (US$ 0.03 per 1M at Z.ai) is 68% of the API bill
  in a typical step and almost free when self-hosted (Inferred, §18.2).
- Utilization break-even against the API: 129% (low call weight, API always wins), 61% (base; 52%
  with 120K cached context) and 29% (high) (Inferred, §18.2). These use 25, 40 and 80 sessions per
  replica (10k report Table 2), so they also move with measured capacity.
- A fleet sized for one time zone's peak runs at 20 to 34% average utilization, 15 to 18% after
  margin and N+1. The fleet costs about 3 times the API at 10,000 users and 5 to 6 times at 1,000
  (Inferred, §18.2).
- Self-host wins only with GPUs 33 to 43% cheaper (published neocloud commit discounts are 25 to 30%;
  Nebius discount Unknown), very good cache behavior, users in several time zones, or reasons other
  than cost: data residency, API concurrency limit (not published, Unknown), control of quantization
  and parser. The Z.ai coding plan forbids use as a product backend (§18.2).
- Against cheap OpenRouter fp4 and fp8 endpoints (US$ 0.165 per loop-hour in the base case) the
  break-even is 89% to 171% (§18.2).
- Per loop-hour: fleet US$ 0.18 at 100% utilization against API US$ 0.295 in the base case (§19.1,
  computed as US$ 7.2 per replica-hour / 40 sessions, so it inherits the 40 assumption).
- Under unlimited tokens, the API becomes an uncapped bill risk (§19.4). The API at 15 loop-hours per
  user per month costs US$ 4.4, at 88 hours US$ 26, at 300 hours US$ 88; 15 VMs cover up to about 88
  hours per user per month at 100% utilization (§19.1, Inferred).

## SLO and primary metric

### SLO definition

Per agent level, a replica passes when all three hold (`bench/summarize.py` docstring and `Slo`
dataclass, Observed in code; targets from §20, labelled Hypothesis there):

| Criterion | Threshold | Notes |
|---|---|---|
| Turn errors | zero | from `summarize.py`; §20 itself defines availability failure as 5xx above 1% in 5 min |
| TTFT p95, cached turns | <= 5 s | turns >= 1 sent after the last agent finished turn 0; at least 20 such turns per level (§29.3) |
| Decode speed p50 per stream | >= 30 tok/s | output tokens after the first, per second; the llm-d floor for agentic GLM (§20) |

Other SLO rows proposed for the MVP (§20, all Hypothesis):

- TTFT p95 for a cold 256K context: 60 s (cold prefill measured at 25 s alone and 63 s p50 with 8 x
  128K concurrent, R1).
- Availability 99% per month (about 7 h down). Failure is 5xx above 1% in 5 min, TTFT p95 above
  target, or a stream cut after the first token. 99.5% or 99.9% only with a second region.

§20 says the 30 tok/s floor "fixes 32 streams per replica" (measured 44.5 tok/s at 32 streams on R1).
The SLO targets become requirements only after measurement (EK1 to EK9, §20).

### Quality gate

An arm only counts if it passes the quality gate. The original gate (§27.4) was 120/120 on
`needle-checksum` and no more than 2 points below R1 vLLM on gsm8k. §29.5 replaced the needle part
(decided 2026-11-12): 500 runs at 8 concurrent, compared with the vLLM DCP4 reference (3 errors in 500)
by a one-sided Fisher exact test; fail if worse than the reference with p < 0.05. `summarize.py`
implements this (`--needle-ref`, default `3/500`). DCP1 passes it: 3 errors in 620 at 8 concurrent
over two runs (§29.10, Observed).

### Primary metric

**Agent sessions inside the SLO per US$/h of a replica** (§26.4, §27.4). `summarize.py` computes it as
the largest agent count N where that level and all smaller levels pass, divided by the hourly price
of the replica on the machine where it ran.

The R1 baseline in §26.4 (12.3 sessions of 262,144 tokens per US$/h fitting in HBM) is a capacity
figure, not a count of sessions inside the SLO; it is not comparable with 2.85 or 4.28.

### Engine-switch rule (§27.4, applied in §29.7)

- A challenger engine must pass the quality gate and deliver at least **20% more sessions inside the
  SLO per US$/h** than the best vLLM arm, **in two runs**. Below that, the switch does not pay for the
  risk of depending on a community package.
- Outcome (accepted by Paulo on 2026-11-12, §29.7): the production engine is the `local-inference-lab`
  vLLM fork. SGLang FP8 had 8 sessions in SLO against 16 for vLLM DCP4 (KV of 1.05M tokens); SGLang
  NVFP4 tied at 16 but failed quality with every checkpoint it loads (§29.5).
- The configuration (DCP1 or DCP4, with or without LMCache) stays open until the second DCP1 run and
  the KV-tier test (§29.7, §29.9).

### Effect of the KV tier on capacity (§29.8)

Under HBM pressure (DCP4, KV capped at 5 GiB per GPU, 48 agents with 20 to 60 s think), LMCache
restored state correctly but did not raise simultaneous capacity: restored KV must return to HBM
(Observed; the test overloaded both arms, so it measures overload, not normal restore TTFT). The
inference drawn: capacity per replica is HBM divided by the context of active sessions, and LMCache
only serves sessions that are really idle. With DCP1, 6.8M tokens hold about 60 active sessions of
100K tokens, more than the 24 the SLO allows (Inferred, §29.8).

## MVP and phase plan (demand and SLO parts)

MVP proposals (§20), adopted as default until Paulo objects. Focus: availability and expansion, not
margin.

| Item | MVP answer | Label |
|---|---|---|
| Expansion target | 0 to 3 months: 100 to 300 users, 1 cell. 3 to 6 months: about 1,000, 3 VMs. 6 to 12 months: second region and quota request. 10,000 is a vision, not an MVP requirement | Hypothesis |
| Concurrency per user | 2 simultaneous streams; background agents in a low-priority async queue | Hypothesis |
| Usage pilot | 1 VM of 8 RTX (2 replicas, 80 streams at 40 per replica), started 30 min before business hours, about 10 h per workday: about US$ 3.2k per month (14.4 x 10 x 22) | Inferred |
| Availability MVP | 2 on-demand VMs in one region, US$ 21k per month 24x7; with 1 VM down, capacity halves and the gateway limits concurrency instead of failing | Inferred |

The 80-stream pilot figure uses the 40-per-replica assumption; with the measured 24 (DCP1, one run)
the same VM would hold 48 (Inferred: 2 x 24).

Phase plan (§18.6, amended by §19.4):

| Phase | Users | Demand and SLO content | Trigger to advance |
|---|---|---|---|
| 0 | about 100 | Gateway with telemetry of d, h, s, φ, f, P, O; after §19.4 the API serves a small pilot with a concurrency cap, because unlimited tokens on the API is an uncapped bill | 1 month of telemetry; under §19.4 the practical trigger is quota and capacity, not cost |
| 1 | about 1,000 | API or 1 cell of 2 to 4 VMs | peak above 70% of capacity (Hypothesis); 1,000-SSE soak and salt test passed |
| 2 | about 10,000 | 4 to 7 cells of 3+1 in 2 providers, admission control | review each quarter with measured utilization |

§19.4 also notes that the fixed fleet enters when the pilot's API bill passes the cost of the minimum
cell (2 VMs, US$ 21k per month): at US$ 0.295 per loop-hour that is about 71k loop-hours per month, or
713 per user at 100 users (Inferred).

Validation items that touch demand or SLO (§21.2, thresholds are Hypothesis):

| # | What | Pass if |
|---|---|---|
| V1 | Kill 1 of 2 replicas under 32 streams | 5xx below 1% in 5 min; only in-flight requests on the dead replica fail |
| V5 | Stop 1 of 2 VMs under load | gateway returns 429 with `retry-after` above remaining capacity; TTFT p95 of accepted requests within SLO |
| V6 | Burst of 51 sub-agents with a common prefix outside HBM | no `KEY_NOT_READABLE`; burst TTFT p95 lower with single-flight |
| V11 | Gateway soak of 1,000 SSE streams of 60 to 300 s | memory and CPU per stream measured; 0 connections dropped by the gateway |

What validation does not prove (§21.4): capacity at 10,000 users, because the design extrapolates
from 1 to 2 VMs.

## Open questions

- **Second DCP1 run.** Does 24 sessions per replica hold on a machine that passes the C32 decode
  check (at least 1,400 tok/s with DCP1, §29.10)? Until then, capacity per replica that meets the two-run rule
  is Unknown for DCP1 and 8 for DCP4.
- **Capacity between 24 and 32.** Levels tested were 8, 16, 24, 32; the real ceiling is Unknown.
- **GLM output per call (O) and request time.** Unknown until EK9; it drives φ and the replica count
  by 1.6 to 2.0 times or more (§24.3).
- **Harness versus real traffic.** The harness has 0 to 3 s think time and no sub-agent fan-out.
  How measured sessions map to the demand model's streams (which include fan-out f and pauses) has
  not been measured.
- **Demand factors for our product.** d, h, s, φ, f, P, O come from public corpora of Claude users;
  h has no direct source. The first month of gateway telemetry is the planned source (§18.6, §19.4).
- **Per-user stream cap.** 2 in the MVP (§20), range 2 to 4 (§19.3); Paulo's decision is pending
  (§19.5).
- **Pricing.** Single fixed price or tiers with more streams; whether background agents are inside
  "unlimited" (§19.5).
- **Definition of "user"** (registered, MAU, DAU or seat) and of a looping session (§18.7).
- **SLO by context range.** §18.7 asks for TTFT p95 per context range and TPOT p50 and p90; only the
  cached-turn and cold-256K TTFT rows exist (§20). §20 scopes the 5 s target to cached turns with up
  to 8K new tokens, while `summarize.py` applies it to all steady-state cached turns.
- **Provider price.** The metric depends on the replica price. Nebius list is US$ 1.80 per GPU-hour,
  an aggregator lists US$ 2.35 for the same VM, and which applies is Unknown (10k report §3).
- **KV tier under normal load.** The LMCache test with DCP1, normal KV, 24 active agents and idle
  sessions with minutes of think time has not run (§29.8).
