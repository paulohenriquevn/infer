# Scheduler, cache and speculation flags

What each flag that shapes prefill and decode does, where it is defined (upstream vLLM or the local-inference-lab fork), our value, and why. Read this before changing any of them, and when a new image or an upstream doc seems to contradict our profile.

Our values are Observed in `bench/server-vllm-dcp1-direct.sh` (DCP1) and `bench/server-vllm-direct.sh` (DCP4), and in the `non-default args` line of every archived `servidor.log`. Upstream docs and fork PRs were read on 2026-11-12 (Reported, URL given). The fork image is `karmic-kraken-20261016`, vLLM version string `0.1.dev21830+g8244d1c44`; it diverged from upstream at commit `0f8fa53` (2026-09-16, §26.5), so the upstream docs that match it best are v0.32.0. Docs for later versions are marked.

## Summary table

| Flag | Ours | Defined in | One-line effect |
|---|---|---|---|
| `--max-num-batched-tokens` | 4096 | upstream | token budget of one engine step (prefill chunks plus decode tokens) |
| `--enable-chunked-prefill` | on | upstream | long prompts are split into chunks that fit the step budget |
| `--max-num-seqs` | 32 | upstream | at most 32 requests running; the decode slot count |
| `--prefill-compute-share` | 0.4 | fork | while decode is active, prefill gets about 40% of step compute |
| `--max-parallel-prefills` | 1 | fork | one prefill lane: cold prompts are served one at a time |
| `--prefill-schedule-interval` | 1 | fork | Unknown semantics; fairness engines require it to be 1 |
| `--block-size` | 256 | upstream | physical KV block; the fork's split pages make the effective page 1,024 or 2,048 tokens |
| `--mamba-cache-mode` | `align` | upstream (deprecated later) | when recurrent (KDA) state is cached for prefix reuse |
| `--recurrent-checkpoint-policy` | `request_boundaries` | fork | KDA state saved at the end of each response; removes the per-turn tail |
| `--speculative-config` | MTP, 3 tokens | upstream (method), fork (extra keys) | multi-token prediction, about 2.6 tokens accepted per step |
| `--decode-context-parallel-size` | 1 or 4 (open decision) | upstream | shards MLA KV across ranks; 3.4 times more KV with 4 |
| `--kv-cache-memory-bytes` | unset in production; set in KV tests | upstream | fixed KV pool per GPU instead of a memory fraction |

## Upstream vLLM flags

### `--max-num-batched-tokens` (ours 4096)

- Upstream: "Maximum number of tokens that can be processed in a single iteration." The default is chosen in `EngineArgs.create_engine_config` (Reported, `https://docs.vllm.ai/en/stable/configuration/engine_args/`, read 2026-11-12).
- Tuning guide: "Smaller values (e.g., 2048) achieve better ITL because there are fewer prefills slowing down decodes"; higher values give better TTFT; for throughput they recommend above 8192 "especially for smaller models on large GPUs" (Reported, `https://docs.vllm.ai/en/latest/configuration/optimization/`, latest docs, read 2026-11-12).
- Our server log confirms it: `Chunked prefill is enabled with max_num_batched_tokens=4096.` and `'max_num_scheduled_tokens': 4096` (Observed, `vast-vllm-lmcache/servidor.log`).
- Why 4096: the community profile uses it (3072 on the 2-GPU preset) (Reported, rtx6kpro, §10.3). On a B300 with upstream vLLM, MTP3 plus a 4096 budget cut 8 x 128K interference about 4.5 times and cost about 22% of cold prefill rate; the two changes were made together, so the share of the budget is Unknown (Observed, §12.3).
- The fork's own GLM profile PR says the "8,192-token chunk" stayed unchanged when it added the compute share (Reported, `https://github.com/local-inference-lab/blackwell-llm-docker/pull/150`), which suggests the launcher's profile default may differ from our 4096. Our scripts pass 4096 explicitly; the log confirms what runs.
- First lever against an ITL tail before P/D: try 2048 or 3072 (Hypothesis, doc 04 §5.2). How it interacts with the compute share was never measured (Unknown).

### `--enable-chunked-prefill` (ours on)

"If True, prefill requests can be chunked based on the remaining max_num_batched_tokens" (Reported, engine args, latest). The tuning guide says chunked prefill is on by default whenever possible and that "the scheduling policy prioritizes decode requests ... It batches all pending decode requests before scheduling any prefill operations" (Reported, optimization page, latest). The fork's compute share changes that order under contention (next section).

### `--max-num-seqs` (ours 32)

"Maximum number of sequences to be processed in a single iteration" (Reported, engine args). With MTP and CUDA graphs captured up to 256 tokens per step (`--cudagraph-capture-sizes 1 2 4 8 16 32 40 48 64 96 128 192 256`), 32 sequences x (1 + 3 draft tokens) = 128 tokens per decode step fits a captured size (Inferred). It is the decode slot count in the capacity formula. A sub-agent burst above 32 queues (Inferred, §17.3). Raising it is untested. Per-stream decode at C32 with no context is 40 tok/s on DCP4 and 50 tok/s on DCP1 (Observed, `output_tps_per_user_p50` in `vast-vllm-r1/decode.json` and `vast-vllm-dcp1/decode.json`); how far above 32 the 30 tok/s floor holds is Unknown.

### `--long-prefill-token-threshold`, partial prefills

Upstream has `--long-prefill-token-threshold` (default 0, "0 disables the cap") (Reported, engine args stable and v0.32.0). `--max-num-partial-prefills` and `--max-long-partial-prefills` were not found in the v0.30.0, v0.32.0, stable or latest engine-args pages (Reported absence, read 2026-11-12). We do not set them; the fork's lane flags replace them.

### `--block-size` (ours 256) and the split cache pages

- Upstream: "Size of a contiguous cache block in number of tokens" (Reported).
- The fork splits GLM-5.3 cache pages. Our script exports `VLLM_GLM53_SPLIT_TARGET_BLOCK_SIZE=2048` and `VLLM_GLM53_SPLIT_MAMBA_BLOCK_SIZE=auto`, and the log prints `Using split GLM-5.3 cache pages: target block size 2048 tokens, recurrent-state block size 2048 tokens.` for DCP1 and DCP4 (Observed). With `CACHE_MODE=lmcache` the launcher printed 1,024 instead (Observed, §29.8 run). The meaning of the split is not documented in the sources; read it as the prefix-cache granularity (Inferred).

### `--mamba-cache-mode` (ours `align`)

- v0.30.0: choices `align`, `all`, `none`; `align` "caches Mamba state only at the last token of each scheduler step, at block-size multiples" and is the default with prefix caching; `all` caches at every block boundary (Reported, `https://docs.vllm.ai/en/v0.30.0/configuration/engine_args/`).
- v0.32.0: choices `align` and `none`, default `none` (Reported).
- stable (v0.33 era) and latest: deprecated, "has no effect", Mamba prefix caching follows `--enable-prefix-caching` (Reported). Our fork predates that change and accepts the flag.
- Why it matters less than the journal thought: the fork's `request_boundaries` policy saves state at the end of each response, and turn logs show exactly one recomputed token beyond the new input (Observed, `../examples/recompute-split.md`).

### `--recurrent-checkpoint-policy` (fork, ours `request_boundaries`)

Not in upstream docs. Observed effect: the log prints "Request-boundary recurrent checkpoint caching is enabled. Supported chat requests retain leading instructions, the complete prompt, and the response endpoint." and agent turns reuse the full previous turn. Keep it. Check for that line after any image change.

### `--speculative-config` (ours MTP, 3 tokens)

- Ours: `{"method":"mtp","draft_sample_method":"probabilistic","rejection_sample_method":"standard","moe_backend":"marlin","attention_backend":"B12X","num_speculative_tokens":3,"revision":"dec48abd..."}`. The extra keys are fork keys (Observed in the script).
- Upstream MTP page shows only `"method":"mtp"` and suggests 1 as a starting value (Reported, `https://docs.vllm.ai/en/latest/features/speculative_decoding/mtp/`, latest, page dated 2026-10-15). The vLLM GLM-5.3-Flash recipe uses 5 (Reported, §10.1). The fork crashes with `illegal memory access` above 3 at high concurrency (Reported, rtx6kpro, §10.1). Keep 3.
- Measured acceptance (`server_spec_accept_length` in `decode.json`): 2.59 to 2.66 on DCP4 and 2.49 to 2.64 on DCP1 (Observed). The log line at start says `GLM speculative KDA uses B12X checkpoint recovery with FP32 recurrent state.` (Observed).
- KV cost of MTP on the fork: Unknown. On B300 upstream, MTP plus CUDA graphs took 43% of the KV pool (Observed, §12.3).

### `--decode-context-parallel-size` (DCP; 1 or 4)

"Number of ranks that shard the decode KV cache. DCP does not expand the process world size." Default 1 (Reported, v0.32.0 engine args). DCP4 gives 23.1M KV tokens against 6.79M with DCP1, and DCP1 decodes 6% to 24% faster (Observed, §29.6). Production choice is open; DCP1 passed 24 agents once.

### `--kv-cache-memory-bytes`

"Size of KV Cache per GPU in bytes"; when set it overrides `gpu_memory_utilization` (Reported, v0.32.0 and stable). Used only in KV-tier tests to force eviction (`KV_CACHE_BYTES` in `server-vllm-lmcache-direct.sh`).

## Fork scheduler flags

None of these has a docs page. Their behaviour comes from the fork's pull requests (Reported, read 2026-11-12) and our measurements.

### `--prefill-compute-share` (ours 0.4)

- PR #664 "feat(scheduler): share compute and interleave bounded prefills", merged 2026-09-11: `--prefill-compute-share FLOAT|auto` "enables feedback-based sharing"; "The feature remains disabled unless prefill_compute_share is configured" (Reported, `https://github.com/local-inference-lab/vllm/pull/664`). PR #625 (merged 2026-09-04) added `--fairness-engine {compute_share,micro_slicing}` and says "One 4,096-token prefill quantum can still cause roughly 0.5-second decode" stall, and that it was not qualified for DCP4, MTP3 or DFlash2 at that time (Reported, `https://github.com/local-inference-lab/vllm/pull/625`).
- The GLM-5.3 profile turned it on at 0.4 in blackwell-llm-docker PR #150 (merged 2026-10-10). Their measurement on 8 RTX PRO 6000 (TP8), 16 decode streams plus one 32K prompt every 20 s: decode during prefill went from about 61 to about 405 to 413 tok/s; decode over the whole window from about 645 to about 620 tok/s; 32K TTFT median from about 4.4 s to about 8.9 s (Reported, PR #150).
- Ours: with decode active, prompt throughput was 4,123 to 4,179 tok/s against 10.3k cold, the 0.4 share (Observed, R1 `r1-suite.jsonl`), and decode held about 15 ms per token while eight 128K prompts were prefilled (Observed, §12.2).
- Why keep it: the SLO needs 30 tok/s per stream; 15 ms per token is about 66 tok/s (Inferred). The price is TTFT of cold prompts.
- Related bug: issue #733, compute share "can livelock at full KV"; fix #946 merged 2026-09-29 (Reported, title from the issue list; the issue page was not opened).

### `--max-parallel-prefills` (ours 1)

- PR #664: "One lane remains the default"; `auto` resolves to `min(4, max_num_seqs)` (Reported). PR #959 (merged 2026-10-01): lanes are active with 2 or more or `auto`; the GLM profile keeps 1 (Reported, `https://github.com/local-inference-lab/vllm/pull/959`).
- Measured by the fork with 4 lanes, 4 decodes and 8 long prefills: late 4K-prompt TTFT from 46.85 s to 8.73 s, median long-request TTFT from about 26.1 s to 47.3 s (Reported, #664).
- Open bugs that argue against more lanes today: #1037 "max-parallel-prefills > 1 locking up with OffloadingConnector", the scheduler livelocks near a full KV pool, `1` never hangs (Reported, open, `https://github.com/local-inference-lab/vllm/pull/1037`). #1048 (open) adds size-classed lanes, `--prefill-long-threshold N` and `--max-long-prefills L`, off by default; on DeepSeek V4.1-Flash with 23 sessions plus one 488K prompt it cut follow-up TTFT p50 from 76.4 s to 6.0 s while the long prompt's own TTFT grew to 528 s (Reported, table headers garbled per the reader).
- Ours: one lane is why cold first turns queue about 25 s per agent (`../examples/cold-first-turn-queue.md`) and why 8K prompts at concurrency 32 waited 56 s (Observed, R1). Size-classed lanes are the candidate fix for the cold queue; test them only after #1048 merges into an image we use.

### `--prefill-schedule-interval` (ours 1)

No definition or default found. It appears only as a constraint: fairness engines "require `prefill_schedule_interval=1`" and the launcher rejects an engine with an interval above 1 (Reported, #625). Keep 1.

### Switches not yet explored (§23.3)

| Switch | What the PR says | Status |
|---|---|---|
| `VLLM_SCHEDULER_UNCAP_PREFILL_ONLY_STEPS=1` (#880, included in merged #905) | a step with no eligible decode uses `max_num_batched_tokens` as its cap instead of `max_num_scheduled_tokens`; default 0; +8% to 12% prefill on MiMo-V2.6-Flash | Reported, `https://github.com/local-inference-lab/vllm/pull/880` and `/pull/905`. Ours has both caps at 4096, so the effect may be nil (Inferred) |
| Prefill token cap under contention (#862, merged 2026-09-23) | "opt-in maximum number of local prefill tokens per compute-share step"; a 3008-token cap gave max decode gap 454 ms during a warm 176K prefill; a cold first long prefill stalls much longer, so long-context warmup is required; validated on GLM-5.3 TP4/DCP4 | Reported, `https://github.com/local-inference-lab/vllm/pull/862`. Flag name Unknown |
| `VLLM_B12X_BF16_GEMV=1` (#873, included in #905) | decode-sized BF16 linears use b12x GEMV plans; default off; no numbers | Reported, `https://github.com/local-inference-lab/vllm/pull/873` |

## How to confirm what is running

```bash
# what the script asks for
grep -o -- '--\(prefill-compute-share\|max-parallel-prefills\|prefill-schedule-interval\|max-num-batched-tokens\|max-num-seqs\|mamba-cache-mode\|recurrent-checkpoint-policy\|block-size\|decode-context-parallel-size\) [^ ]*' bench/server-vllm-dcp1-direct.sh
# what the engine used (old directories: servidor.log)
sed 's/\x1b\[[0-9;]*m//g' <result_dir>/server.log | grep -o "'\(max_num_batched_tokens\|max_num_scheduled_tokens\|max_num_seqs\|prefill_compute_share\|mamba_cache_mode\|recurrent_checkpoint_policy\|block_size\|decode_context_parallel_size\)': [^,]*"
grep -c 'Request-boundary recurrent checkpoint caching is enabled' <result_dir>/server.log
grep -o 'split GLM-5.3 cache pages: [^.]*' <result_dir>/server.log | sort -u
```

Our DCP1 script passes `--max-parallel-prefills 1` and `--prefill-schedule-interval 1` explicitly. Whether vLLM echoes them in `non-default args` was not checked; if the grep finds nothing, they equal the defaults, which are the same values per #664.
