# Prefill and decode cost model for GLM-5.3-Flash

Every measured number we have on how one replica spends time between prefill and decode, the two-ceiling capacity formula of `ARQUITETURA.md` §17.3 worked out, and what the per-turn recompute really is.

Read this when you need a number to plan with, when you want to know whether a figure is a single run or which DCP setting it used, or when a capacity estimate does not match a benchmark.

Labels: Observed (we measured it, path given), Reported (a named source says it), Inferred (derived, arithmetic shown), Hypothesis, Unknown. Raw results are in the results archive (`f3/resultados/...`, fetched by `scripts/fetch_evidence.sh`). Files written before 2026-11-12 keep Portuguese names (`agentes-16.json`, `servidor.log`, `r1-suite.jsonl` fields such as `concorrencia`). Every cell below is one run unless the row says otherwise.

## Where each number was measured

| Name | Hardware | Profile | Date | Source |
|---|---|---|---|---|
| R1 | Nebius `gpu-rtx6000-a`, 4 of 8 RTX PRO 6000 Server Edition, driver 580.173 | fork image, TP4 + DCP4 + MTP3, `--max-num-batched-tokens 4096`, `--max-num-seqs 32` | 2026-11-05 | `f3/resultados/rtx-20261105/`, §12.2 |
| Vast 157204 DCP4 | Vast.ai host 157204, 4 RTX PRO 6000 Server Edition, driver 615.71.09 | same profile as R1 (`server-vllm-direct.sh`) | 2026-11-11 | `f3/resultados/vast-20261111/vllm/vast-vllm-r1/`, §29.1 |
| Vast 157204 DCP4 repeat | same host | same | 2026-11-11 | `.../vast-vllm-r1-rep2/`, §29.6 |
| Vast 157204 DCP1 | same host | `server-vllm-dcp1-direct.sh` (DCP1) | 2026-11-11 | `.../vast-vllm-dcp1/`, §29.6 |
| Vast 48294 DCP1 | Vast.ai host 48294, driver 580.95.05 | DCP1 | 2026-11-12 | `f3/resultados/vast-20261112/vllm/`, §29.10; speed numbers have no validity (failing host) |
| R2 | Nebius 1 B300, upstream vLLM 0.32.0, NVIDIA NVFP4 checkpoint | MTP3, batch 4096 | 2026-11-05 | §12.3; different engine and GPU, used only as a reference for interference |

## Cold prefill by prompt length

| Prompt | R1 DCP4 TTFT (tok/s) | Vast 157204 DCP4 | Vast 157204 DCP1 | Vast 48294 DCP1 (failing host) |
|---|---|---|---|---|
| 8K | 0.83 s (`pd_bench`, about 8.2k tok/s) | 1.071 s (7,655 tok/s, 7 samples) | 0.966 s (8,490 tok/s, 10 samples) | 9.437 s (869 tok/s) |
| 32K | 3.17 s (10,180 tok/s, harness); 3.173 s (`pd_bench`) | 3.897 s (8,293 tok/s, 3 samples) | 3.543 s (9,121 tok/s, 3 samples) | 37.423 s (864 tok/s) |
| 128K | 12.5 s (10,289 tok/s, harness); 12.603 s (`pd_bench`) | 15.993 s (8,057 tok/s, 1 sample) | 14.389 s (8,957 tok/s, 1 sample) | 148.843 s (866 tok/s) |
| 256K | 25.165 s (10,381 tok/s, `pd_bench`, prompt 260,000) | not run | not run | not run |

Sources: R1 `pd_bench` rows `frio-8k`, `frio-32k`, `frio-128k`, `frio-256k` in `f3/resultados/rtx-20261105/r1-suite.jsonl`; R1 harness numbers in §12.2; Vast numbers in `prefill.json` of each run directory (the `prefill` block, `method: client`). All Observed.

Readings:

- Cold prefill is linear in prompt length within about 10% from 8K to 256K on R1 (Observed). Use about 10.3k tok/s for R1 and about 8 to 9k tok/s for the Vast host (Observed). The Vast host prefills 10% to 20% slower than R1 while it decodes faster at C1 (§29.2); the cause is Unknown.
- DCP1 prefills 7% to 11% faster than DCP4 on the same host (Observed, one run each).
- The failing host 48294 prefills 10 times slower at every length. Its numbers are kept only as the failing case for host qualification (§29.10).
- The community wiki reports 13,117 tok/s at 32K on Workstation cards with TP4 + DCP4, and 13,816 tok/s on Max-Q with DCP1 (Reported, rtx6kpro, §10.2). Our Server Edition hosts reach 62% to 78% of that; the cause is Unknown.

## Cached prefill

| Case | Value | Source |
|---|---|---|
| Repeat of a 128K prompt from the HBM prefix cache, R1 | TTFT p50 0.14 s, p95 0.163 s (3 requests) | Observed, `r1-suite.jsonl` row `quente-128k` |
| Agent turn with 96% to 97% of the prompt cached, Vast DCP4, 8 agents | TTFT p95 3.37 s | Observed, `vast-vllm-r1/agentes-8.json` via `summarize.py` |

The 0.14 s case is a pure hit: the whole prompt is cached and only one token is computed. Agent turns are never pure hits, because each turn adds new tokens (next section).

## The per-turn recompute is the new tool input, not a cache tail

`summarize.py` reports "recomputed tokens per turn" as `prompt_tokens - cached_tokens` on steady-state turns. On every vLLM run it was 3,200 to 3,800 at p50 and 5,300 to 5,900 at p90 (Observed, §29.1, §29.6). The journal (§29.2, §26) and `docs/01` and `docs/03` read this as the hybrid cache tail: the part of the previous turn that the KDA state cannot reuse because vLLM saves recurrent state only at block boundaries.

The turn logs say otherwise. The bench (`llm_decode_bench.py`, scenario `agents`, commit `52216d70`) builds each new prompt as previous prompt + the exact output token IDs + a block of `randint(1024, 6144)` random tool tokens (Observed in the code: `prompt = prompt + list(out) + ctx.prompts.make(tool)`; `parse_token_value` reads `1k` as 1,024). So the new input per turn is known exactly: `tool = prompt_tokens(turn n+1) - prompt_tokens(turn n) - completion_tokens(turn n)`. Comparing that with the recomputed count, turn by turn (script and full output in `../examples/recompute-split.md`):

| Run (vLLM fork, Vast 157204) | Turn pairs | Recomputed p50 / p90 | Tool block p50 / p90 | Recomputed minus tool, p10 / p50 / p90 |
|---|---|---|---|---|
| DCP4, 8 agents | 77 | 3,420 / 5,282 | 3,419 / 5,281 | 1 / 1 / 1 |
| DCP4, 16 agents | 183 | 3,518 / 5,863 | 3,517 / 5,862 | 1 / 1 / 1 |
| DCP4, 32 agents | 375 | 3,637 / 5,725 | 3,636 / 5,724 | 1 / 1 / 1 |
| DCP1, 16 agents | 243 | 3,475 / 5,821 | 3,474 / 5,820 | 1 / 1 / 1 |
| DCP1, 24 agents | 361 | 3,419 / 5,491 | 3,418 / 5,490 | 1 / 1 / 1 |
| SGLang FP8 (ormandj v0.6.1), 8 agents, for contrast | 116 | 3,492 / 5,425 | 3,410 / 5,283 | 21 / 116 / 230 |

Observed: on the vLLM fork every turn recomputes exactly the new tool tokens plus one token. The whole previous turn, including its output, comes from cache. SGLang recomputes 116 extra tokens at the median, which is its hybrid cache tail.

Why (Observed in the server logs of every run): the profile starts vLLM with `--recurrent-checkpoint-policy request_boundaries`, and the log prints "Request-boundary recurrent checkpoint caching is enabled. Supported chat requests retain leading instructions, the complete prompt, and the response endpoint." The fork saves KDA state at the end of the response, which is what FlashState's "frontier checkpoints" do. The `--mamba-cache-mode align` and block size do not create a tail in this traffic.

Consequences:

- The recomputed count is the input the agent added (Inferred from the table). The only way to reduce it is to send less new input. No engine change removes it.
- Porting FlashState for the per-turn tail buys nothing measurable in this harness (Inferred). §26.5 point 3 asked for exactly this measurement before any port. What FlashState could still help with is sessions whose state was evicted, which is the LMCache and ThunderAgent problem.
- Caveat: the bench sends token IDs and appends the exact output tokens. A real agent sends chat messages through the chat template, which can re-render earlier turns (for example strip or keep reasoning text; our profile sets `clear_thinking: false`). If the re-rendered prefix differs from what was generated, the cache stops earlier and a real tail appears. Whether that happens with GLM-5.3-Flash's template and a real agent is Unknown; measure it with test E9 (a real agent) by comparing `prompt_tokens - cached_tokens` with the size of the new messages.

## Decode by concurrency

Aggregate output tok/s, context 0, 30 s per cell, `max_tokens` 8192, `ignore_eos` (from `decode.json` `summary_table` and `results[]`).

| Concurrency | R1 DCP4 (§12.2) | Vast 157204 DCP4 | Vast 157204 DCP4 repeat | Vast 157204 DCP1 | Vast 48294 DCP1 (failing) |
|---|---|---|---|---|---|
| 1 | 119.8 | 145.6 | 139 | 154.5 | 108.2 |
| 8 | 585.0 | 598.8 | 586 | 696.3 | 298.6 |
| 16 | not run | 910.3 | 923 | 1,072.6 | 350.8 |
| 32 | 1,425.5 | 1,279.1 | 1,288 | 1,580.3 | 297.6 |

Per stream and per token, from `results[]` of the same files (Observed):

| | DCP4 C1 | DCP4 C8 | DCP4 C16 | DCP4 C32 | DCP1 C1 | DCP1 C8 | DCP1 C16 | DCP1 C32 |
|---|---|---|---|---|---|---|---|---|
| Output tok/s per user, p50 | 147.0 | 76.1 | 58.1 | 40.1 | 156.1 | 88.4 | 68.0 | 50.1 |
| Inter-token latency p50 | 6.80 ms | 13.14 ms | 17.22 ms | 24.97 ms | 6.41 ms | 11.31 ms | 14.71 ms | 19.98 ms |
| Chunk inter-arrival p50 | 18.49 ms | 35.73 ms | 47.39 ms | 69.69 ms | 17.01 ms | 33.12 ms | 41.45 ms | 55.91 ms |

The chunk interval is about 2.7 times the inter-token latency because MTP3 delivers about 2.7 tokens per step (Inferred from the ratio; the R1 log showed 2.5 to 2.7 accepted per step, §12.2).

Decode is flat in context from 0 to 128K on R1 (Observed, §12.2): 119.8 / 123.6 / 120.8 tok/s at 1 stream for contexts 0 / 32K / 128K, and 1,425.5 / 1,440.7 / 1,423.3 at 32 streams. Above 128K it is Unknown. The journal attributes the flatness to sparse MLA (`index_topk=2048`) on the 11 full-attention layers and the fixed-size KDA state on the other 34 (§12.2 reading, not a separate measurement).

The 44.5 tok/s per stream used in the capacity formula is R1's 1,425.5 / 32 (Inferred). On the Vast host DCP4 gives 40.1 and DCP1 50.1 tok/s per user at C32 (Observed above).

## Prefill under decode

| Measure | Value | Source |
|---|---|---|
| Prompt throughput while 16 and 32 streams decode 256-token outputs from 8K prompts | 4,123 and 4,179 tok/s | Observed, `r1-suite.jsonl` rows `decode-c16` and `decode-c32` (field `tok_prompt_s`) |
| Same, 4 streams | 3,875 tok/s | row `decode-c4` |
| Cold rate without decode | 10.3k tok/s | §12.2 |
| Ratio | about 0.40 | Inferred; equals `--prefill-compute-share 0.4` (§12.2) |
| TTFT of 8K prompts at concurrency 16 / 32 | p50 25.9 s / 56.1 s | Observed, rows `decode-c16`, `decode-c32`; one prefill lane serializes them |
| 8 prompts of 128K together, output 64 | TTFT p50 63.2 s, p95 101.4 s; TPOT p50 39.6 ms per step (about 15 ms per token) | Observed, row `longo-c8-128k` |
| R2 (B300, upstream vLLM, MTP3, batch 4096), 8 x 128K | TTFT p50 24.5 s, p95 41 s; about 55 ms per token | Observed, §12.3 |
| B300, upstream, no MTP, default batch, 8 x 128K | 247 ms per token | Observed, §9.3 |

`pd_bench` counts streaming chunks, not tokens. With MTP each chunk carries about 2.6 tokens, so divide its `tpot_*_ms` by 2.6 for a per-token figure (§12.2). That is where "39.6 ms per step, about 15 ms per token" comes from.

## Two-ceiling capacity formula (§17.3), worked out

Definitions (Inferred, §17.3):

```
T     = P / R_pf + O / r_dec       seconds of engine time per turn
N_dec = S * (T + think) / T        decode ceiling: S slots (--max-num-seqs), each busy T out of every T + think seconds
N_pf  = R_pf * (T + think) / P     prefill ceiling: the single prefill lane delivers R_pf tok/s, each session needs P per cycle
N     = min(N_dec, N_pf), and the joint limit is lower still
```

Constants measured on R1 DCP4 (§17.3): `R_pf = 4,100` tok/s (prefill under decode), `r_dec = 44.5` tok/s per stream at 32 streams, `S = 32`.

### Example 1: Weka-shaped demand (Inferred)

P = 3,700 (Weka mean new tokens per request), O = 1,077 (Weka mean output, which is Claude's output; GLM's is Unknown), think = 5 s (loop pause fixed in §24.3).

```
T     = 3,700 / 4,100 + 1,077 / 44.5 = 0.90 + 24.20 = 25.1 s
N_dec = 32 * (25.1 + 5) / 25.1       = 32 * 1.199 = 38.4
N_pf  = 4,100 * (25.1 + 5) / 3,700   = 33.4
N     = 33 sessions in the loop per replica, before any joint effect
```

§24.3 states "about 36" for the decode ceiling and "about 40" for the prefill ceiling because it uses T from 25 to 35 s. With T = 35 s, N_pf = 4,100 x 40 / 3,700 = 44.

### Example 2: the §17.3 scenarios

| Scenario | P | O | Think | T | N_dec | N_pf | §17.3 result |
|---|---|---|---|---|---|---|---|
| Low | 8,500 | 4,000 | 5 s | 2.07 + 89.9 = 92.0 s | 33.7 | 46.8 | about 25 (joint) |
| Base | 4,000 | 1,500 | 17 s | 0.98 + 33.7 = 34.7 s | 47.7 | 53.0 | about 40 (joint) |
| High | 1,100 | 690 | 24 s | 0.27 + 15.5 = 15.8 s | 80.7 | 148.3 | about 80 (ceiling) |

The T, N_dec and N_pf columns are our arithmetic from the formula (Inferred); the last column is what §17.3 states after applying a joint-limit discount it does not spell out.

### Example 3: the formula against the harness (Inferred from Observed numbers)

The bench scenario has P = uniform 1,024 to 6,144 (mean 3,584), O = `max_tokens` uniform 300 to 4,000 (observed previous-turn output mean 2,039 to 2,183 in the turn logs), think = uniform 0 to 3 s (mean 1.5).

```
T     = 3,584 / 4,100 + 2,100 / 44.5 = 0.87 + 47.2 = 48.1 s
N_dec = 32 * 49.6 / 48.1             = 33
N_pf  = 4,100 * 49.6 / 3,584         = 57
```

The formula predicts about 33 sessions on DCP4. The harness failed DCP4 at 32 agents, and at 16 on the repeat, on the TTFT p95 criterion while per-stream decode stayed above 30 tok/s (37.7 at 32 agents). Steady-state load measured from the turn logs (script in `../examples/agent-levels.md`):

| Run | Agents | Turns per second | New tokens to prefill per second | TTFT p95 |
|---|---|---|---|---|
| DCP4 | 8 | 0.257 | 857 | 3.37 s |
| DCP4 | 16 | 0.329 | 1,226 | 4.77 s |
| DCP4 | 32 | 0.418 | 1,549 | 6.08 s |
| DCP1 | 16 | 0.407 | 1,497 | 4.71 s |
| DCP1 | 24 | 0.445 | 1,557 | 4.93 s |

The prefill demand never exceeded 1.6k tok/s, 38% of the 4.1k ceiling (Inferred). So the level failed on latency, before either throughput ceiling was reached. Our reading (Inferred): one turn's new input (p90 about 5.5K tokens) passes through one prefill lane that gets 40% of the compute of each step, and steps get slower as the decode batch grows (inter-token latency 6.8 ms at C1, 25 ms at C32 on DCP4). The prefill time of one turn grows with the number of decoding streams even when the lane is mostly idle. The formula gives an upper bound on sessions; the TTFT SLO binds first. Which of lane queueing or slower steps dominates is Unknown; measure TTFT of a fixed 5K-token turn at decode concurrency 8, 16 and 32 with no other prefill to separate them.

## Cold first-turn queue

All agents of a level start with a fresh 40K to 100K context (`AGENT_START=40k-100k`), sent 2 s apart (the bench sleeps 2 s between spawns). Each first turn is a cold prefill and they share one lane, so TTFT grows by about 25 s per agent. At 16 agents on Vast DCP4 the last agent got its first token after 339.8 s and the steady state began at 416 s (Observed, table in `../examples/cold-first-turn-queue.md`). The 16 first turns carried 1.27 million tokens over about 340 s, about 3.7k tok/s, consistent with the 4.1k prefill-under-decode rate (Inferred).

Production equivalents (Inferred, §17.4): 51 cold 256K prefills cost about 22 min of one replica; a cell failover of 64 sessions of 256K costs about 27 min on one replica (13.5 min on two). With R1's cold rate, 256K takes 25.2 s alone and about 63.9 s under decode (Inferred, 262,144 / 4,100).

## What is still Unknown

- O for GLM-5.3-Flash in a real agent loop (test E9). It dominates T.
- Decode above 128K context.
- Whether the chat template creates a recompute tail with a real agent.
- Cold prefill on G7e and on any host other than R1, 157204 and 48294.
- How TTFT of a fixed turn grows with decode concurrency (the measurement proposed in example 3).
