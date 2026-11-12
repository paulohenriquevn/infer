# Prefix scorers, load scorers, saturation and how to size them

The parameters that decide whether a request sticks to the replica holding its prefix or moves to a less loaded one, with defaults from llm-d `v1.0.0`, our measured inputs and how to calibrate. Upstream defaults are Reported from the llm-d-router `v1.0.0` plugin READMEs (URLs below, read 2026-11-12, through a summarizer) and the local llm-d `v1.0.0` clone.

## Sources

| Plugin or doc | URL |
|---|---|
| `approx-prefix-cache-producer` | https://github.com/llm-d/llm-d-router/tree/v1.0.0/pkg/epp/framework/plugins/requestcontrol/dataproducer/approximateprefix |
| `precise-prefix-cache-producer` | https://github.com/llm-d/llm-d-router/tree/v1.0.0/pkg/epp/framework/plugins/requestcontrol/dataproducer/preciseprefixcache |
| `prefix-cache-scorer` | https://github.com/llm-d/llm-d-router/tree/v1.0.0/pkg/epp/framework/plugins/scheduling/scorer/prefix |
| `prefix-cache-affinity-filter` | https://github.com/llm-d/llm-d-router/tree/v1.0.0/pkg/epp/framework/plugins/scheduling/filter/prefixcacheaffinity |
| `token-load-scorer` | https://github.com/llm-d/llm-d-router/tree/v1.0.0/pkg/epp/framework/plugins/scheduling/scorer/tokenload |
| `inflight-load-producer` | https://github.com/llm-d/llm-d-router/tree/v1.0.0/pkg/epp/framework/plugins/requestcontrol/dataproducer/inflightload |
| `utilization-detector` | https://github.com/llm-d/llm-d-router/tree/v1.0.0/pkg/epp/framework/plugins/flowcontrol/saturationdetector/utilization |
| `concurrency-detector` | https://github.com/llm-d/llm-d-router/tree/v1.0.0/pkg/epp/framework/plugins/flowcontrol/saturationdetector/concurrency |
| Calibration recipe | https://github.com/llm-d/llm-d/tree/v1.0.0/guides/recipes/router/calibration |
| Blog "Sticky Until Saturated" (2026-08-17, before v1.0) | https://llm-d.ai/blog/sticky-until-saturated-token-aware-routing |
| Precise routing guide | https://github.com/llm-d/llm-d/blob/v1.0.0/guides/precise-prefix-cache-routing/README.md |

## Approximate against precise prefix tracking

| | Approximate (what we run) | Precise (not tested) |
|---|---|---|
| Producer | `approx-prefix-cache-producer` | `precise-prefix-cache-producer` plus a `token-producer` |
| Tokens | approximated from characters; no tokenizer | real token IDs |
| Index | EPP-local LRU of hashes it routed, per endpoint | built from engine KV events over ZMQ (one subscriber per pod), with snapshot and replay on gaps |
| Sees evictions | no | yes, for what the engine publishes |
| Engine requirement | none | `--kv-events-config` with publisher `zmq`; events must carry `token_ids` and `extra_keys`; `--block-size` equal to `tokenProcessorConfig.blockSizeTokens` |
| Cost on restart | index lost | index rebuilt from replay |

Reported, prefix-cache-aware-routing doc and the producer READMEs. For our model the precise path is blocked by the LMCache in the fork image (no `BlockRemoved`), by per-user salted hashes, and by KDA groups the indexer does not model (`../SKILL.md`, decision 5).

## Parameters and defaults

| Plugin | Parameter | Default | Ours | Comment |
|---|---|---|---|---|
| `approx-prefix-cache-producer` | `autoTune` | `true` | `true` (not set) | infers block size and LRU capacity from endpoint metrics; ignores the offload tier (`../SKILL.md` decision 3); set `false` before production |
| | `blockSizeTokens` | 64 (values below 64 are raised to 64) | 8704 | engine block on the mini; 2,048 on the fork image (see below) |
| | `maxPrefixTokensToMatch` | 131072 (the configuration page shows 16384 as an example) | 262144 | takes precedence over `maxPrefixBlocksToMatch` (2048) when above 0; setting both to 0 matches the whole prompt |
| | `lruCapacityPerServer` | 31250 blocks | default | about 272M tokens at 8,704 per block, 64M at 2,048; above any pool we measured |
| `prefix-cache-affinity-filter` | `affinityThreshold` | 0.80 | default | share of the prefix that must match for an endpoint to count as sticky |
| | `peakPrefillThroughput` | 15928 tok/s | default | measured for Qwen3-32B on H100 TP2 (calibration matrix lists vLLM v0.23.0; the filter README says vLLM 0.19) |
| | `maxTTFTPenaltyMs` | 18000 ms | default | 0 means always stick |
| | `explorationProbability` | 0 | default | |
| | `ttftSource` | `prefillThroughput` | default | alternative `latencyPredictor` |
| `token-load-scorer` | `queueThresholdTokens` | 4194304 | default | score `1 - min(1, tokens / threshold)` |
| `inflight-load-producer` | `addEstimatedOutputTokens` | `false` | default | needs an output-length bucket plugin |
| `prefix-cache-scorer` | `matchLengthWeight`, `matchLengthScaleTokens` | 0.0, 8192 | not used | only in scorer-based profiles such as the no-Kubernetes guide |

How the filter decides (Reported, filter README): estimated TTFT per endpoint = in-flight uncached tokens / `peakPrefillThroughput`. Stickiness breaks when the best sticky endpoint's estimate exceeds the best non-sticky one's by more than `maxTTFTPenaltyMs`. If a signal is missing the gate is skipped and counted as outcome `missing_signal` in `llm_d_epp_prefix_cache_affinity_filter_decisions_total`.

## Tau

The blog defines tau = `peakPrefillThroughput` x `maxTTFTPenaltyMs`, in uncached tokens in flight (Reported). Shipped defaults give 15,928 tok/s x 18 s = 286,704 tokens (Inferred arithmetic). The blog's experiments set `maxTokensInFlightPenalty=286720` (20,480 tok/s x 14 s) directly; that parameter is not in the v1.0.0 filter README (Reported by absence). The two products agree within 16 tokens; only the v1.0.0 parameters exist now.

For our model (Inferred):

- `peakPrefillThroughput` should be the replica's prefill rate at the scheduler's chunk size. R1 (TP4 + DCP4) measured 10,381 tok/s cold and about 4,100 tok/s while decoding (Observed (real), §12.2). The calibration recipe measures the cold figure.
- `maxTTFTPenaltyMs` is how much extra TTFT a sticky request may pay before it moves. Moving costs a full recompute of the uncached prefix on the new replica; staying costs queue time. For a 120K-token session at 10,381 tok/s a move costs about 11.6 s of prefill (Inferred), so a penalty below that favours moving even when the move is more expensive. Our TTFT target is 5 s for cached turns. A starting point is a penalty near the cold prefill time of a median session, then checked under saturating load (Hypothesis).

## The fork's block size

Every fork server log we have prints the cache page size at start (Observed, `servidor-direto.log` and `servidor.log` of `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1`, `vast-vllm-r1`, `vast-vllm-r1-rep2`, `vast-vllm-lmcache-controle` and `f3/resultados/vast-20261112/vllm/vast-vllm-dcp1-rep`; old Portuguese file names):

```text
(Worker_TP0 pid=63573) WARNING 11-12 00:23:51 [interface.py:900] Using split GLM-5.3 cache pages: target block size 2048 tokens, recurrent-state block size 2048 tokens.
...
(EngineCore pid=63550) INFO 11-12 00:26:15 [kv_cache_utils.py:753] kv lcm block sizes 2048
```

The command line asks for `--block-size 256` (Observed, `bench/server-vllm-dcp1-direct.sh`), and the fork raises it to 2,048 for GLM-5.3 split pages. The run with LMCache (`vast-vllm-lmcache`) printed 1,024 instead (Observed). So `blockSizeTokens` for the real model is 2,048 without LMCache and 1,024 with it, for this image (Observed in logs). That 2,048 is also the prefix-cache hit granularity is Inferred from "lcm block sizes"; confirm with a cache-hit test whose prefix is not a multiple of 2,048. Read the line again on every new image.

## `lruCapacityPerServer` sizing

`lruCapacityPerServer = KV pool tokens per replica / blockSizeTokens`, with `autoTune: false` (Inferred from the parameter's definition).

| Profile | Pool tokens | Blocks at 2,048 | Label |
|---|---|---|---|
| DCP1 | 6,789,052 | about 3,315 | pool Observed (real), harness `kv_tokens_source` in `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/agentes-24.json`; block Observed in the log |
| TP4 + DCP4 | 23,249,576 | about 11,352 | pool Observed (real), §12.2 (R1 on Nebius); block 2,048 Observed on the DCP4 Vast runs |
| Default | 64M tokens implied at 2,048 | 31,250 | Reported default |

Older notes divided by 8,704 (the mini block) and got 780 and about 2,665 blocks; those numbers do not apply to the real model. Whether to add LMCache L1 blocks is a Hypothesis: those blocks are reachable without recompute, but the EPP cannot see their eviction either.

## Saturation detectors

Used only with flow control (`cells-and-bursts.md`).

| Detector | Parameters (defaults) | Rule |
|---|---|---|
| `utilization-detector` (default) | `queueDepthThreshold` 5, `kvCacheUtilThreshold` 0.8, `metricsStalenessThreshold` 200ms, `stalenessPolicy` `saturated`, `headroom` 0.0 | per endpoint `max(queue / 5, KV / 0.8)`; pool saturation is the mean. Stale metrics count as saturated by default |
| `concurrency-detector` | `concurrencyMode` `requests`, `maxConcurrency` 100, `maxTokenConcurrency` 1,000,000, `headroom` 0.0, `failOpen` true | counts in-flight work from `inflight-load-producer`; no scrape lag |
| `max-saturation-detector` (Beta) | `detectors`, `stages` | composite of several |

The flow-control guide recommends `concurrency-detector` in production because scraped metrics lag (Reported). Our own runs agree that queue and KV are late signals: in steady state the engine queue averaged under 0.2 at the SLO limit and KV stayed at 16 to 73% (Observed, `autoscaling-and-observability` skill, `references/signals-and-thresholds.md`). For the real model `maxConcurrency` should be the measured `C` per replica (24 for DCP1 in one run, 16 or less for DCP4), not 100 (Inferred). The turn-priority guide uses 32, the `max-num-seqs` of its engine (Reported).

## Calibrating `peakPrefillThroughput`

`guides/recipes/router/calibration/calibrate.sh` runs a Kubernetes Job that sends `NUM_WARMUP` (5) then `NUM_MEASUREMENTS` (20) requests of exactly `CHUNK_SIZE` random token IDs and prints `CHUNK_SIZE / median(TTFT)`. `CHUNK_SIZE` must equal vLLM `--max-num-batched-tokens`; `T_MAX_SECONDS` (18) only feeds an informational `TAU` line. It does not change any config (Observed in the local clone's README).

For us (Inferred):

- `CHUNK_SIZE=4096`, the `--max-num-batched-tokens` of the fork profile (`vllm-fork-serving` skill). Confirm on the server command line of the run.
- The Job needs Kubernetes. On plain EC2 reproduce the same measurement with any client that sends 4,096 random token IDs to `/v1/completions` and records TTFT; the cache must miss every time.
- Measure per profile (DCP1, DCP4) because the value depends on model, accelerator, TP and chunk size (Reported, configuration matrix).
- A related tool, `calibrate-min-cached-token-delta.sh`, sizes `minCachedTokenDelta` for P2P KV pulls. It only matters with the `p2p-kv-cache-sharing` path, which needs precise routing.
