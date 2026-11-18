# The coding-agent workload and how the bench models it

What the traffic of a coding agent looks like (input size, new tokens per turn, output, pauses, sub-agent bursts), where each number comes from, and how the `agents` scenario of our bench reproduces it and where it does not.

Read this before choosing `AGENT_*` values for a run, before using a capacity formula, or when someone asks why we plan around prefill.

## Two sources of workload shape

| Source | What it is | Units and caveats |
|---|---|---|
| llm-d GLM-5.2 blog, "Serving GLM-5.2 for Agentic Workloads on llm-d" (2026-07-22), `https://llm-d.ai/blog/serving-glm-5-2-agentic-workloads-on-llm-d` | 219 Claude Code sessions, 78,099 requests, analysed by llm-d and replayed on H200 | Input counted with the `o200k` tokenizer, output from the Anthropic API (the blog warns the two mix units). Reported, read in full for §8.1 on 2026-11-05 and digested in the project research notes (not published) |
| Weka corpus, Hugging Face dataset `semianalysisai/cc-traces-weka-062126` | 393 sessions, 98,827 requests (56,798 main-agent, 42,029 sub-agent) | We processed the whole corpus (`f3/p0/analisar_weka.py`, output `f3/p0/weka-resultado.json`, not in this repository). Mean input 218,921.8 and mean output 1,077.4 match the dataset README exactly (Observed, §24). Claude Opus and Haiku traffic with Claude latencies |

The blog page was read again on 2026-11-12 and the growth (632 / 3,735 / 148K), reuse (96%, 99.6%), think time (2 s, 24 s, 11.4 min) and input share (98.6%) figures still match (Reported). Two related llm-d posts, read 2026-11-12: "From agent traces to replay" (`https://llm-d.ai/blog/from-agent-traces-to-replay`) says "Our production agent workloads reuse 92% of prompt tokens" and that fixing how traces are rendered raised replayed reuse from 59% to 96%, so a replay that renders prompts differently from the agent understates cache hits; it also asks benchmark reports to state GPU type, P/D split, parallelism and KV-cache placement. "llm-d v1.0" (2026-10-20, `https://llm-d.ai/blog/llm-d-v1.0-state-of-the-art-inference-ready-for-day-2`) adds session-aware routing ("sticky until saturated") and turn-priority scheduling (Reported).

The blog's 219 sessions are a sample of the same SemiAnalysis Weka traffic (Inferred in the project research notes, from identical metrics); treat the two as one workload seen twice.

## Numbers

### From the llm-d blog (Reported)

| Property | Value |
|---|---|
| Input per request, main agent | p50 195K, p90 521K, p99 849K tokens |
| Output per response | p50 317, p90 1,705, p99 7,551 tokens |
| Input growth against the previous main-agent turn | p50 632, p90 3,735, p99 148K tokens |
| Prefix reuse | 96% of turns reuse at least 90% of the input; median reuse 99.6% |
| Token mix | 98.6% of served tokens are input |
| Gap between main-agent requests | p50 2 s, p90 24 s, p99 11.4 min |
| Session | median lasts 1 hour; turns per session p50 107, p90 354, p99 992 |
| Sub-agents | 40,367 of 78,099 requests arrive in groups; 7 per group at the median, 51 at p90, "without advance notice" |
| Prefix resets | 2.8% of turns share less than 50% of input with any of the previous 8 main-agent turns |
| Compaction (above 500K falling below 30K) | 0.03% of turns |

The "7,800 new tokens per turn" figure that §16.4 attributed to this blog is not in it; the blog publishes the growth percentiles above (§17.2).

### From the Weka corpus (Observed, our analysis, §24.1)

| Parameter | Value |
|---|---|
| New tokens per request (P) | mean 3,702, p50 1,600, p90 5,888, p99 40,960 |
| Global prefix hit | 98.31% |
| Output per request (O) | mean 1,077, p50 444, p90 2,659, p99 9,311 (main agent: mean 1,374, p50 616). Claude tokens |
| Share of session time in the loop (φ) | mean 0.256, p50 0.205, p90 0.508, p99 0.939 |
| Streams per looping session (f) | mean 1.146, p50 1.02, p90 1.43, p99 2.93 |
| Share of requests from sub-agents | 42.5% |
| Requests per sub-agent group | median 16, mean 24.8, p90 47, p99 175 |
| Peak concurrency per session | mean 3.2, p90 6, p99 16 |
| Request starts in 10 s, per-session peak | mean 5.4, p90 11, p99 19 |
| Pause between main turns | p50 4.8 s, p90 120 s, mean 376 s (human time included) |
| Engaged hours per session (30 min max gap) | median 1.43, mean 3.43, p90 7.4 |

Corpus caveats (§24.1): sessions with at least 20 requests only, "top" sampling, at most 10 concurrent sub-agent groups. It favours heavy users and tends to overestimate load per user.

§24.3 fixes P = 3,700, 98% hit, f = 1.15 and a loop pause of 5 s for sizing. O for GLM-5.3-Flash with `max` reasoning is Unknown (test E9).

## What the shape means for prefill and decode

- Cost is almost all prefill of a long, reused prefix (98.6% input). Plan capacity around new tokens per turn and the prefix cache, not around decode (Inferred, §8.1, §17.3).
- Two kinds of pause (Inferred, project research notes): inside a turn (tool and harness) the gap is seconds (p50 2 to 5 s, p90 about 24 s); between human turns it is minutes. Only the first counts for sessions in the loop; the second is what the RAM KV tier is for.
- Bursts: a sub-agent group of 47 (p90) or 175 (p99) requests sharing a prefix arrives at once. One replica has 32 decode slots (`--max-num-seqs 32`), so a p90 burst already queues (Inferred, §17.3).
- Loop time depends on our speed (§24.2): with R1 constants a GLM request takes about 25 s against 12.3 s for Claude, so φ rises from 0.26 to about 0.41 and looping sessions at peak grow about 1.6 times (Inferred).

## How the bench `agents` scenario models it

The scenario lives in `llm-inference-bench` (`llm_decode_bench.py`, commit `52216d70`, functions `sched_run_agents` and `sched_agent_start_range`). Observed in the code:

- A agents each keep one conversation of token IDs. A turn sends the whole conversation, appends the exact output token IDs on vLLM (`return_tokens_as_token_ids`; random tokens of the same count elsewhere), then a block of random tool tokens, then thinks, and repeats.
- Ranges are drawn uniformly (`rng.randint`, `rng.uniform`) with a seed per agent: start context `AGENT_START` (default `40k-100k`, where `k` means 1,024), tool block `AGENT_TOOL` (`1k-6k`), `max_tokens` `AGENT_RESPONSE` (`300-4000`), think seconds `AGENT_THINK` (`0-3`).
- Agents start 2 s apart. A conversation that would exceed the model length or the KV pool restarts from a new start context (counted as `resets`).
- Each level runs for its duration (`AGENT_LEVELS="agents:seconds"`) with its own seed (`--sched-seed <N>`), so no level inherits another level's cache.

How it compares with the trace (Inferred):

| Property | Bench default | Trace |
|---|---|---|
| Context at start | 40K to 100K, cold | main agent p50 195K |
| New input per turn | uniform 1,024 to 6,144 (mean 3,584) | Weka P mean 3,702, p50 1,600, p90 5,888 |
| Output per turn | `max_tokens` uniform 300 to 4,000; observed mean 2,039 to 2,183 | Claude mean 1,077, p50 444 |
| Think time | uniform 0 to 3 s | inside a turn p50 2 to 5 s; human gaps minutes |
| Sub-agent bursts | none | median group 16, p90 47 |
| Prefix sharing between agents | none (each agent has its own random context) | sub-agents share the parent's prefix |

So the bench matches the mean new input per turn, has longer outputs than Claude, has no bursts and no shared prefixes, and starts every agent cold at the same time. The SLO verdict depends on steady-state turns only (`summarize.py` drops the cold first-turn queue).

For the LMCache test the arms change only `AGENT_THINK` (20 to 60 s in §29.8, 60 to 100 s in the corrected arms) and the KV pool; see the `kv-cache-tiers` skill.

## What the bench measures per turn

From `turn_log` in `agents-<N>.json` (Observed field names): `agent`, `turn`, `prompt_len`, `max_tokens`, `send_s`, `ttft_s`, `seconds`, `prompt_tokens`, `cached_tokens`, `completion_tokens`. `cached_tokens` needs `--enable-prompt-tokens-details` on vLLM (present in our profile). From these, `summarize.py` computes the SLO, and `../examples/recompute-split.md` shows how to separate new input from cache tail.

## Gaps to close

1. O and time per request of GLM-5.3-Flash in a real agent loop (E9). It changes T, φ and every capacity number.
2. A sub-agent burst test on the real model: 47 requests sharing one long prefix, with and without single-flight (E6).
3. A replay of the Weka trace (or the blog's AIPerf replay) against one replica. AIPerf uses the trace's `out` as `max_tokens`, so it also does not measure O (§17.3).
4. Whether a chat-template agent keeps the one-token recompute that the token-ID bench shows.
