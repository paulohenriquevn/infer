---
name: capacity-and-cost
description: Use when sizing the fleet, estimating replicas or GPUs for a number of users, computing sessions per US$/h or cost per user, comparing self-hosting with the Z.ai API, reading or quoting a provider price or quota (Nebius, Vast.ai, AWS), or deciding whether a host can be reserved. Also use before quoting any number from the old fleet table, which is out of date.
---

# Capacity and cost

How much demand 10,000 coding-agent users create, how much one replica holds inside the SLO, what that costs per provider, and how to turn those three into a fleet size and a cost per user. The fleet table in the docs is stale; this skill says why and how to redo it.

Evidence labels: Observed (we measured it, path or section given), Reported (a named source says it), Inferred (derived, arithmetic shown), Hypothesis (to be validated), Unknown. "§N" points to `ARQUITETURA.md`, the Portuguese working journal kept outside this repository. "docs/0N" points to `docs/` in this repository. "10k report" is `reports/Arquitetura para 10 mil usuários.md`, also outside this repository. Raw results are cited as `results archive: f3/resultados/...`, a path inside the published results archive. Every price carries the date it was read; a GPU price older than a few days is stale (docs/05).

## When to use

- Someone asks "how many replicas, GPUs or instances for N users" or "what does it cost per user".
- You are about to quote 22 replicas, 15 VMs, 40 streams per replica, US$ 158k per month or US$ 15.8 per user. All of those come from the stale table.
- You compute or compare sessions per US$/h for a run, a host or a provider.
- You read or quote a price, discount or quota from Nebius, Vast.ai or AWS.
- You are about to reserve, prepay or add a host to the fleet.
- Someone proposes moving users to the Z.ai API, or asks whether self-hosting is cheaper.

## Decisions and why

| Decision | Why | Evidence |
|---|---|---|
| Product: unlimited tokens at a fixed cost per user | The product sells what the API does not: no token limit and a known monthly cost. This replaced cost per token as the decision criterion | Paulo's decision, §19; docs/01 |
| We do not try to beat the API on cost per token | At the modeled demand the API is cheaper: the fleet costs about 3 times the API at 10,000 users and 5 to 6 times at 1,000 | Inferred, §18.2, 10k report Table 1 |
| Primary metric: agent sessions inside the SLO per US$/h of one replica | It measures what the product pays for (users served within the SLO per dollar). HBM capacity alone ignores speed | Decision of 2026-11-11, §26.4, §27.4; docs/01 |
| SLO per replica: zero turn errors, TTFT p95 <= 5 s on cached steady-state turns, per-stream decode p50 >= 30 tok/s | These are the thresholds `bench/summarize.py` applies; 30 tok/s is the llm-d floor for agentic GLM | Hypothesis adopted for the MVP, §20; code in `summarize.py` (Observed) |
| Capacity per replica counts only under the two-run rule | DCP4 passed 16 agents once and failed the repeat (TTFT p95 5.20 s), so single runs decide nothing | Observed, §27.4, §29.6 |
| The fleet table (§18.1) is not a sizing answer | It assumed 40 streams per replica and demand factors that §24 later corrected | docs/01, docs/05, README contradictions table |
| Vast.ai only for measurements and on-demand bursts, never the reserved base | Same-listing hosts differed 1.4x to 5.3x in decode; instances are containers; prepaid credit is locked to one host | Observed §29.10, §28.1; Reported by Vast support 2026-11-12 |
| Spot is not part of the base or the burst | On Nebius the 8-GPU RTX VM had no preemptible capacity, preemption gives 60 s and no recovery, and a preempted replica loses its KV and pays a cold start | Observed §8.3, §11.1; Reported in Nebius docs §17.2 |
| Every host is qualified before it is measured, reserved or added | A host with the same "4x RTX PRO 6000" listing ran 5 times slower | Observed §29.10 |

## How to

### 1. Peak demand from the user count

```
L = U x d x h x s x φ      looping sessions at peak
S = L x f                  concurrent streams at peak
```

| Factor | Meaning | Low | Base | High | Label and source |
|---|---|---|---|---|---|
| U | registered users | | 10,000 | | product target (§19) |
| d | daily active over registered, workday | 0.25 | 0.40 | 0.60 | Reported (Jellyfish, Anthropic usage data) plus Hypothesis for the monthly active share |
| h | share of active users engaged in the peak hour | 0.35 | 0.50 | 0.60 | Hypothesis, no direct source |
| s | open sessions per engaged user | 1.1 | 1.3 | 1.6 | Reported (Jellyfish); high is Hypothesis |
| φ | share of session time spent in the agent loop | 0.15 | 0.25 | 0.40 | Reported (TraceLab, Copilot), Hypothesis anchored on them |
| f | streams per looping session (sub-agents) | 1.15 | 1.3 | 2.0 | Reported (Copilot median 1.15); base and high Hypothesis |

Base at 10,000 users (Inferred, 10k report §2): 10,000 x 0.40 x 0.50 x 1.3 x 0.25 = 650 looping sessions; 650 x 1.3 = 845 streams.

Apply the corrections that came after the formula (§24.3, Observed on the Weka corpus, 393 sessions, 98,827 requests):

- f = 1.15, not 1.3 (Weka mean 1.146).
- New tokens per request P = 3,700 (mean 3,702), prefix hit 98%, loop pause 5 s.
- φ = 0.256 holds only at Claude latency (mean API time 12.3 s). A GLM request on our engine takes about 25 s (P/4,100 + O/44.5 = 0.9 + 24.2, R1 constants), about 2 times Claude. Recompute φ with `φ' = bφ / (bφ + (1 − φ))`, where b is our request time over Claude's. b = 2 gives 0.512 / (0.512 + 0.744) = 0.41, so looping sessions at peak grow 1.6 times; b = 2.5 and 3 give 1.8 and 2.0 times (Inferred, §24.2).
- b is Unknown until EK9 (a real agent on GLM recording `completion_tokens`, `reasoning_tokens` and time per request). GLM output per call (O) is Unknown; Weka's O is Claude tokens (§24.1).

Weka caveat: it keeps sessions with at least 20 requests, uses "top" sampling and caps sub-agent groups at 10, so it favors heavy users and tends to overestimate load per user (§24.1).

Which factors move the fleet most (§18.5, 10k report §2): call weight (P and O) 3.2x, φ 2.7x, d 2.4x, h 1.7x, f 1.7x, s 1.45x. h has no source and φ has fragile support (the two sources differ by an order of magnitude on median human pause). No public source gives the ratio between registered users and looping sessions at peak.

### 2. Keep "streams" and "agent sessions inside the SLO" apart

They are different quantities. Mixing them is how the 40-per-replica figure entered the fleet table.

| | Demand-model stream (S) | Harness agent session |
|---|---|---|
| What it is | One agent call in its cycle at peak; sub-agent fan-out is already inside S through f; human pauses are removed through φ | One simulated coding agent driven by `llm_decode_bench.py` from `bench/run_benchmark.sh` |
| Shape | From public corpora of Claude users | Think time 0 to 3 s, start context 40K to 100K tokens, tool results 1K to 6K, responses 300 to 4,000 tokens, no sub-agent fan-out, no human pauses, `--max-num-seqs 32` (Observed in `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/agentes-24.json` and `servidor.sh`) |
| Per replica | 40 in §18.1: a computed ceiling from R1 decode and prefill constants, with no TTFT check (§17.3, §24.3) | 24 (DCP1, one run) or 8 (DCP4, one run at level 8; run 2 tested only 16 and 24 and failed 16), with the SLO checked (Observed, §29.6; raw `vast-vllm-r1/` and `vast-vllm-r1-rep2/`). Neither profile has a capacity confirmed by two runs |

How to bridge them (Inferred, the only mapping the docs use): a harness agent is close to one stream that never leaves the loop, so replicas needed = S / (agent sessions inside the SLO per replica). docs/01 uses it for its illustration (845 / 24 = 35.2 replicas against 845 / 40 = 21.1). The mapping itself has not been measured (docs/01 open questions). It misses two things the harness does not generate: correlated sub-agent bursts (Weka group median 16, p99 175, against 32 slots per replica) and GLM's real output length.

### 3. Measured capacity per replica

Host: Vast.ai machine 157204, 4x RTX PRO 6000 Server Edition, US$ 5.61/h (read 2026-11-11), fork image, QAD NVFP4 checkpoint, TP4, MTP3. Results in `f3/resultados/vast-20261111/vllm/` (Observed, §29.6).

| vLLM fork | DCP4 run 1 | DCP4 run 2 | DCP1 (one run) |
|---|---|---|---|
| KV capacity | 23.1M tokens | 23.1M tokens | 6.79M tokens |
| Decode C1 / C8 / C16 / C32 (tok/s) | 146 / 599 / 910 / 1,279 | 139 / 586 / 923 / 1,288 | 154 / 696 / 1,073 / 1,580 |
| 16 agents: TTFT p95, tok/s p50 | 4.77 s, 57.2 (pass) | 5.20 s, 57.8 (fail) | 4.71 s, 70.8 (pass) |
| 24 agents: TTFT p95, tok/s p50 | not measured | 5.97 s, 47.1 (fail) | 4.93 s, 55.3 (pass) |

What to quote:

- DCP1: 24 agents inside the SLO, one run, 0.07 s of TTFT margin. The second run on host 48294 is invalid (that host failed qualification, see step 7), so 24 is unconfirmed.
- DCP4: 16 agents passed in run 1 and failed in run 2. Level 8 passed in run 1 and was not repeated (`vast-vllm-r1-rep2/` has only `agentes-16` and `agentes-24`), so §29.6's "8 guaranteed" is not backed by two runs.
- Levels tested were 8, 16, 24 and 32, so every figure is a lower bound; the real ceiling between 24 and 32 is Unknown (§29.2).
- More KV does not mean more sessions inside the SLO: LMCache restored sessions correctly under HBM pressure but did not raise concurrent capacity, because restored KV must return to HBM (Observed, §29.8). With DCP1, 6.8M tokens hold about 60 active sessions of 100K tokens, more than the 24 the SLO allows (Inferred, §29.8).

### 4. Sessions per US$/h for a run or a provider

Formula (what `summarize.py` does): largest agent level N where that level and every smaller level pass the SLO, divided by the hourly price of one replica (4 GPUs). For an 8-GPU machine, the replica price is half the machine price.

```
python3 bench/summarize.py --price <US$ per replica-hour> <result dirs>
```

The quality gate runs in the same command (`--needle-ref`, default `3/500`); a run that fails it does not count.

| Provider, price (date read) | Replica price | DCP1, 24 agents | DCP4, 16 agents (one run) | DCP4, 8 agents (guaranteed) | Label |
|---|---|---|---|---|---|
| Vast 157204, US$ 5.61/h (2026-11-11) | 5.61 | 24 / 5.61 = 4.28 | 16 / 5.61 = 2.85 | 8 / 5.61 = 1.43 | 4.28 and 2.85 Observed (§29.6); 1.43 Inferred |
| Nebius list, US$ 14.40 per 8-GPU VM (2026-11-05) | 14.40 / 2 = 7.20 | 24 / 7.20 = 3.3 | 16 / 7.20 = 2.2 | 8 / 7.20 = 1.1 | Inferred; assumes Nebius hosts perform like 157204, untested |
| AWS `g7e.24xlarge` on-demand, `us-east-1`, US$ 16.57/h (2026-11-04) | 16.57 | 24 / 16.57 = 1.45 | 16 / 16.57 = 0.97 | 8 / 16.57 = 0.48 | Inferred; nothing has run on AWS |

The older "12.3 sessions per US$/h" (§12.4) is 88.7 sessions of 262,144 tokens that fit in HBM divided by US$ 7.20. It ignores speed and the SLO; never compare it with the table above.

### 5. Recompute the fleet

Inputs, all of which must be current and labeled:

1. U and the demand factors d, h, s with their labels (step 1).
2. f = 1.15 and φ recomputed at our measured request time (b from EK9; until then show b = 2, 2.5 and 3 as a range).
3. Agent sessions inside the SLO per replica from two runs on a qualified host (phase 2 of `docs/06-aws-implementation-plan.md`). Until then, show both 24 (DCP1, one run) and 8 (DCP4, guaranteed) and say which.
4. Replicas per machine: 1 for `g7e.24xlarge`, 2 for `g7e.48xlarge` or an 8-GPU Nebius VM.
5. The hourly price of the provider actually chosen, with the date read, and 730 hours per month.

Method used by §18.1 and the 10k report (§1, Inferred):

```
replicas_raw   = S / sessions_per_replica
poisson_margin = 1 + 3 / sqrt(L)
load_machines  = ceil( ceil(replicas_raw x poisson_margin) / replicas_per_machine )
spare_machines = ceil(load_machines / 5)        one N+1 machine per 5 loaded
total_machines = load_machines + spare_machines
monthly_cost   = total_machines x price_per_machine_hour x 730
```

Check that you reproduce the old base row before changing inputs: S = 845, L = 650, 40 per replica, 2 replicas per VM. replicas_raw = 21.1; margin = 1 + 3 / 25.5 = 1.118; 21.1 x 1.118 = 23.6, ceil 24; 24 / 2 = 12 load VMs; ceil(12 / 5) = 3 spare; 15 VMs; 15 x 14.4 x 730 = US$ 157.7k per month. That matches §18.1 and 10k report Table 1. The spare rule as `ceil(load / 5)` is read off the table rows (1 load gives 2 total, 2 give 3, 12 give 15, 20 give 24), Inferred.

Then swap in current inputs. The docs give only illustrations so far: 845 / 24 = 35.2 replicas before margin and N+1 (docs/01), and 35 to 44 replicas from the GLM-latency correction alone (§24.3). Neither is a fleet number. Label any result Inferred and list which inputs are still Hypothesis.

Limits of the method:

- The Poisson margin covers independent noise only. Correlated sub-agent fan-outs from several users at once are outside it (10k report §4).
- The growth unit in the design is a cell of 3 working machines plus 1 N+1, and a cell needs at least 2 machines (§17.3, §18.3). Round the result to cells.
- Reactive autoscaling cannot cover a 21 to 23 min cold start, so a scheduled floor 15 to 20 min before the peak is part of the cost (§18.3).

### 6. Cost per user and the API comparison

Cost per user per month = monthly_cost / U. §19.1 gives US$ 15.8 (base, 15 VMs: 157.7k / 10,000), US$ 25.2 (high, 24 VMs) and US$ 78.8 (stress, 75 VMs), all at Nebius list price and 40 streams per replica, so all out of date. The indicative selling price US$ 22.6 to 50.4 is cost / (1 − margin) at 30% and 50% gross margin (15.8 / 0.7 = 22.6; 25.2 / 0.5 = 50.4), Inferred.

Reference plans with limits (Reported, §19.1): Z.ai Lite US$ 18, Pro US$ 72, Max US$ 160; Claude Max US$ 200.

Self-host unit cost at 100% utilization, Nebius list, no SLO (Inferred, 10k report §1):

- Output: 7.2 / (1,425 x 3,600) x 10^6 = US$ 1.40 per 1M tokens.
- New input: 7.2 / (4,100 x 3,600) x 10^6 = US$ 0.49 per 1M tokens.
- Z.ai list: US$ 0.50 output, US$ 0.15 new input, US$ 0.03 cached input per 1M (Reported in the 10k report, dated 2026-11-05; the read date of the price page is not recorded). The two self-host figures do not add up, because prefill and decode share the replica.
- Cached input is 68% of the API bill in a typical step and almost free self-hosted.

Utilization break-even against the API (Inferred, §18.2, 10k report Table 2): 129% (low call weight, API always wins), 61% (base; 52% with 120K cached context), 29% (high). A fleet sized for one time zone's peak runs at 20 to 34% average utilization, 15 to 18% after margin and N+1. These used 25, 40 and 80 sessions per replica, so they move with measured capacity.

Per loop-hour: fleet US$ 0.18 at 100% utilization (7.2 / 40, inherits the 40 assumption) against API US$ 0.295 in the base case (§19.1). Under unlimited tokens the API is an uncapped bill: US$ 4.4, 26 and 88 per user per month at 15, 88 and 300 loop-hours (§19.1). The Z.ai coding plan forbids use as a product backend (§18.2).

Self-hosting wins on cost only with GPUs 33 to 43% cheaper, very good caching, users across time zones, or for reasons other than cost: data residency, API concurrency limit (not published, Unknown), control of quantization and parser (§18.2).

### 7. Qualify a host before measuring, reserving or adding it

1. Start the server with the production image, checkpoint and flags.
2. Record driver version, `nvidia-smi topo -m` and `nvidia-smi topo -p2p r`, and check the server log for `Using B12X PCIe all-reduce` (`bench/vast/prepare_host.sh` and `run_benchmark.sh` record the host; the log line is in `f3/resultados/vast-20261111/vllm/vast-vllm-r1/servidor.log`).
3. Run a C32 decode test with the harness about 5 minutes after the server is up.
4. Discard the host if aggregate C32 decode with the DCP1 profile is below 1,400 tok/s (DCP4 gives 1,279 to 1,288 on a good host, so do not apply the threshold to it).

Why 1,400: good hosts measured 1,423 to 1,580 tok/s with DCP1 (§12.2, §29.6); the bad host 48294 gave 296 (§29.10). The rule applies to Nebius and AWS too, since nothing guarantees uniform hosts there (Inferred, docs/05). Record every number with its machine ID.

## Invariants

- Never quote the §18.1 fleet table, the US$ 15.8 to 25.2 cost per user or the 80-stream pilot as current. They inherit 40 streams per replica; measured is 24 (DCP1, one run) or 8 (DCP4, guaranteed).
- Every capacity figure says DCP1 or DCP4, how many runs, the host ID and its price with the date. Why: the two profiles differ 3 times in guaranteed capacity, and one host was 5 times slower than another with the same listing.
- Every price carries its date and source. Why: prices move; the Nebius list rose 17 to 21% on H100 and B300 on 2026-10-01 (Reported, 10k report §3), and Nebius showed US$ 1.80 while an aggregator listed US$ 2.35 for the same VM (Unknown which applies).
- Sessions per US$/h uses the price of one replica (4 GPUs). Why: an 8-GPU machine holds two replicas; using its full price halves the metric.
- Show the arithmetic for every Inferred number. Why: the fleet numbers were revised three times (§18.1, §24.3, §29.6) and each revision needed the inputs to be traceable.
- A run that fails the quality gate has zero sessions per US$/h, whatever its speed. Why: SGLang NVFP4 tied vLLM on speed and failed quality with every checkpoint it loads (§29.5, §29.7).
- Do not reserve or prepay a host that has not passed qualification. Why: Vast prepaid credit cannot move to another host, and reservations elsewhere lock the same risk.
- "Unlimited" keeps capacity controls: a per-user cap on simultaneous streams (2 in the MVP, Hypothesis), fair share at peak, an acceptable-use policy, one key per user with anomaly detection (§19.3, §20). Why: uncapped concurrency drives demand to the stress case (4,608 streams, 75 VMs, about US$ 79 per user).

## Pitfalls we hit

- The 40-per-replica figure came from two computed ceilings with no TTFT check (§17.3). Measured with the SLO it is 24 or 8 (§29.6).
- §18.1 used f = 1.3 and Claude-latency φ. Weka gave f = 1.15, and GLM's slower requests push φ from 0.26 to about 0.41 (§24).
- 12.3 sessions per US$/h was read as an efficiency figure; it is HBM capacity without an SLO (§12.4, README contradictions).
- DCP4 at 16 agents passed once and failed the repeat by 0.20 s of TTFT (§29.6).
- Vast host 48294 (US$ 7.03/h, read 2026-11-12) gave C32 decode of 296 tok/s against 1,578 on 157204 with the same image, checkpoint and flags; GPUs sat near 116 W. Cause Unknown (§29.10). Its speed numbers are invalid; its quality numbers stand.
- The Nebius 8-GPU RTX spot price in `us-central1` once equaled list (US$ 1.789 per GPU-hour, §13.4), and B300 spot in `eu-west2` was above list (§8.3). Spot is not always cheaper.
- Nebius budgets only email and update every few hours; the spend estimate reached about US$ 44 against a balance assumed to be US$ 25 (§12.6, §25.5). A forgotten 8-GPU VM ran 6 h 8 min with no result, about US$ 88 (§25.3).

## Provider facts

### Nebius (no resources running: everything was destroyed on 2026-11-06 by Paulo's decision, `NOTAS.md`)

| Fact | Value | Date read | Label |
|---|---|---|---|
| RTX PRO 6000 list price | US$ 1.80 per GPU-hour; 8-GPU VM US$ 14.40/h | 2026-11-05 | Observed, §8.3, §25.4 |
| RTX spot | US$ 0.79 (`uk-south2`), 1.09 (`us-central1`), 1.38 (`eu-south1`) per GPU-hour | 2026-11-05 14:06 UTC | Observed, §8.3 |
| Presets | only `1gpu-24vcpu-218gb` and `8gpu-192vcpu-1744gb`; one GPU cannot hold the model, so the 8-GPU VM (2 replicas) is the smallest usable unit | 2026-11-05 | Observed in docs, §8.3 |
| Network | no InfiniBand for RTX; 400 Gbps Ethernet; plan for TCP between VMs | 2026-11-05 | Observed in docs, §8.3, §17.2 |
| Preemptible capacity for the 8-GPU RTX VM in `uk-south2` | 0 of 2, low | 2026-11-05 | Observed, §8.3 |
| Our quota | 8 RTX GPUs in each of `eu-south1`, `uk-south2`, `us-central1`; 2 instances and 4 disks per project in `uk-south2` | 2026-11-04 | Observed, `NOTAS.md` |
| Ceiling at the "full" quota tier | 32 GPUs per region x 3 regions = 12 VMs, about 85% of the 10,000-user base peak | 2026-11-05 | Reported in Nebius docs, Inferred coverage (10k report §3) |
| Commit discount for RTX, quota lead time | Unknown | | §18.2, V10 |
| Budgets | alert by email, do not block usage; the hard cap is a quota reduction | 2026-11-06 | Reported, §25.5 |

### Vast.ai

| Fact | Value | Date read | Label |
|---|---|---|---|
| Host 157204 (Nevada, 4x Server Edition) | US$ 5.61/h; source of all §29 numbers | 2026-11-11 | Observed |
| Host 48294 (Texas, datacenter, reliability 0.965) | US$ 7.03/h; failed qualification | 2026-11-12 | Observed |
| Reserved pricing | on-demand instance converts to reserved with prepaid period, discount "up to 50%", credit locked to that instance, withdrawable if the host is deverified | 2026-11-12 | Reported by Vast support |
| Discounts actually offered | `credit_discount_max` 0% to 15% on 4x and 8x RTX PRO 6000 hosts; datacenter hosts US$ 2.33 to 2.93 per GPU-hour; personal hosts US$ 1.44 to 1.52, no discount | 2026-11-12 | Observed via Vast API |
| Selection rule | Server Edition, at least 800 GB disk, at least 400 GB RAM, reliability at least 0.95, up to US$ 7/h | | §28.3, §29.9 |

Inferred: the 50% is a platform cap no RTX PRO 6000 host we saw offers, and a datacenter host at its best discount still costs more per GPU-hour than Nebius list (docs/05).

### AWS

| Fact | Value | Date read | Label |
|---|---|---|---|
| `g7e.24xlarge` (4 GPUs, one replica) | US$ 16.57/h on-demand, `us-east-1`, Price List API | 2026-11-04 | Observed, `NOTAS.md`, not rechecked |
| `g7e.48xlarge` (8 GPUs, two replicas) | US$ 33.14/h, same source; about US$ 4.14 per GPU-hour, the highest provider we priced | 2026-11-04 | Observed |
| G and VT on-demand vCPU quota | 0 in every region checked; request for 96 vCPU (one `g7e.24xlarge`) pending | 2026-11-04 | Observed |
| Savings Plans rate for G7e, Capacity Blocks | Savings Plan offered, G7e rate Unknown; Capacity Blocks did not list G7e | about 2026-11-05 | Observed and Reported, 10k report Table 5 |
| Performance on our model | Unknown; nothing has run on AWS | | docs/06 |

At the 2026-11-04 price one replica costs about 2.3 times Nebius list (16.57 / 7.20) and about 3 times Vast 157204 (16.57 / 5.61), Inferred.

## Open questions

- Does DCP1 hold 24 agents in a second run on a qualified host? Until then the two-run capacity is Unknown for DCP1 and 8 for DCP4.
- Capacity between 24 and 32 agents per replica (Unknown, levels not tested).
- GLM output per call and request time (b), from EK9. They move looping sessions by 1.6 to 2.0 times or more.
- How harness agent sessions map to demand-model streams; not measured.
- Our own d, h, s, φ, f: the first month of gateway telemetry is the planned source (§18.6, §19.4).
- Per-user stream cap (2 to 4), single price or tiers, whether background agents are inside "unlimited" (Paulo, §19.5).
- Definition of "user" (registered, MAU, DAU or seat) and of a looping session (§18.7).
- Current AWS G7e price, discounted price, quota status; Nebius commit discount and the US$ 1.80 against US$ 2.35 conflict.

## Sources

- `docs/README.md` (contradictions table), `docs/01-product-demand-and-slo.md`, `docs/05-capacity-cost-and-providers.md`, `docs/06-aws-implementation-plan.md`.
- `ARQUITETURA.md` §8.3, §12, §17.3, §18, §19, §20, §24, §25, §29.6, §29.10.
- `NOTAS.md`, outside this repository (AWS prices and quota of 2026-11-04, Nebius quotas, teardown of 2026-11-06).
- `reports/Arquitetura para 10 mil usuários.md` (Tables 1 to 5, §1 to §4).
- Code: `bench/summarize.py` (`--price`, `--needle-ref`), `bench/run_benchmark.sh`, `bench/vast/prepare_host.sh`.
