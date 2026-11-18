# Upstream vLLM docs, digested for our profile

Short digests of the upstream pages that explain the flags we use. All Reported, read 2026-11-12.

Version warning: every docs.vllm.ai page read here is the "latest developer preview" (no version number; footers dated between 2026-06-23 and 2026-11-12). Upstream releases on that date: `v0.32.0` (2026-10-18) and `v0.33.0rc3` (2026-11-02) (GitHub API). Our fork is `8244d1c44`, 409 commits ahead of upstream and 2,439 behind `v0.33.0rc3` (`fork-vs-upstream.md`). When a page and the fork disagree, the fork source at our commit wins; `production-profile.md` cites it.

## Engine arguments

`https://docs.vllm.ai/en/latest/configuration/engine_args.html`

| Flag | Upstream text | Note for us |
|---|---|---|
| `--decode-context-parallel-size` | "Number of ranks that shard the decode KV cache." Default 1 | Our DCP1 or DCP4 |
| `--cp-kv-cache-interleave-size` | "Interleave size of kv_cache storage while using DCP." | We set 4 |
| `--dcp-kv-cache-interleave-size` | "dcp_kv_cache_interleave_size has been replaced by cp_kv_cache_interleave_size" | We set both |
| `--dcp-comm-backend` | "Communication backend for Decode Context Parallel (DCP)." Choices `a2a`, `ag_rs`; `None` selects the model default, "ag_rs" | Our log shows `dcp_comm_backend=ag_rs`. The fork source adds: `a2a` "Reduces NCCL calls from 3 to 2 per layer for MLA models" (fork `vllm/config/parallel.py`). Never tested by us |
| `--kv-cache-dtype` | "Data type for kv cache storage." Default `auto` | `fp8` |
| `--block-size` | "Size of a contiguous cache block in number of tokens." | 256; the fork's GLM split pages use 2,048 |
| `--gpu-memory-utilization` | "The fraction of GPU memory to be used for the model executor, which can range from 0 to 1." | 0.96 |
| `--kv-cache-memory-bytes` | "Size of KV Cache per GPU in bytes." | Used by the LMCache script (default 5 GiB) |
| `--max-num-batched-tokens` | "Maximum number of tokens that can be processed in a single iteration." | 4096 |
| `--enable-chunked-prefill` | "If True, prefill requests can be chunked based on the remaining max_num_batched_tokens." | on |
| `--enable-prefix-caching` | "Whether to enable prefix caching." | on |
| `--prefix-caching-hash-algo` | choices `sha256`, `sha256_cbor`, `xxhash`, `xxhash_cbor`; default `sha256` | We use the default. The llm-d router must hash the same way (`llm-d-routing` skill) |
| `--mamba-cache-mode` | "--mamba-cache-mode is deprecated and will be removed in v0.34.0." Choices `align`, `none` | Required by the fork's GLM split pages. Expect a rename when the fork rebases past v0.34.0 |
| `--load-format` | "`instanttensor` will load the Safetensors weights on CUDA devices using InstantTensor"; other values include `auto`, `safetensors`, `ipc_cache`, `runai_streamer`, `dummy` | `instanttensor` |
| `--attention-backend` | "Attention backend to use." | `B12X` |
| `--moe-backend`, `--linear-backend` | "Backend for MoE expert computation kernels.", "Backend for linear layer GEMM kernels." | `b12x` |
| `--enable-flashinfer-autotune` | "Benchmark FlashInfer kernel implementations during warmup and use the fastest." | We pass `--no-enable-flashinfer-autotune` |
| `--prefill-schedule-interval` | "Only admit prefill once every N engine steps", default 1 | Now upstream too |
| `--speculative-config`, `--compilation-config`, `--additional-config` | "Speculative decoding configuration.", "torch.compile and cudagraph capture configuration for the model.", "Additional config for specified platform." | `cudagraph_mode` is a field inside `--compilation-config` |
| `--override-generation-config` | "Overrides or sets generation config." Default `{}` | temperature 1.0, top_p 0.95 |
| `--reasoning-parser` | "Select the reasoning parser depending on the model that you're using." | `glm45` |
| `--quantization` | "Method used to quantize the weights." | `modelopt_mixed` is not listed on the page; it is in the fork and named by the QAD model card |

Not on the upstream page (fork only, see `production-profile.md`): `--prefill-compute-share`, `--max-parallel-prefills`, `--recurrent-checkpoint-policy`.

## Serve-only flags

`https://docs.vllm.ai/en/latest/cli/serve.html`

- `--enable-auto-tool-choice`: "Enable auto tool choice for supported models." Default False. Needed by the needle probe.
- `--tool-call-parser`: "Select the tool call parser depending on the model that you're using."
- `--enable-prompt-tokens-details`: "If set to True, enable prompt_tokens_details in usage." Default False. The harness reads cached-token counts from it.
- `--default-chat-template-kwargs`: "Default keyword arguments to pass to the chat template renderer."
- `--chat-template`: "The file path to the chat template, or the template in single-line form".
- `--port`: default 8000.

## Speculative decoding and MTP

`https://docs.vllm.ai/en/latest/features/speculative_decoding/` and `https://docs.vllm.ai/en/latest/features/speculative_decoding/mtp.html`

- `method` values include `draft_model`, `ngram`, `suffix`, `mtp`, `eagle3`, `dflash`.
- `num_speculative_tokens`: "Number of speculative tokens to propose per step." The MTP page: "A small value like `1` is a good default to start with." We use 3 (fork wiki limit, `glm53-flash-model`).
- `draft_sample_method`: "`probabilistic` retains the full draft distribution for probability-ratio acceptance." The default is `greedy`. We use `probabilistic`.
- `rejection_sample_method`: "`standard`, `synthetic`, `block`, or the lossy `fly` verifier." We use `standard`; "FLy deliberately relaxes verification and is not distribution preserving", so never use `fly` without the quality gate.
- "`tensor_parallel_size` is not a valid key in `speculative_config`"; use `draft_tensor_parallel_size`.
- Lossless claim: "Speculative decoding sampling is theoretically lossless up to the precision limits of hardware numerics." The docs also say vLLM "does not currently guarantee stable token log probabilities".
- MTP page: "MTP only works for model families that support MTP in vLLM." `draft_lm_head_quantization` (`fp8` or `nvfp4`) gives the drafter a quantized LM head copy; "outputs are unchanged". The fork's equivalent for GLM-5.3 is `VLLM_GLM53_MTP_DRAFT_HEAD=nvfp4`.

## Context parallel (DCP)

`https://docs.vllm.ai/en/latest/serving/context_parallel_deployment.html` (page dated 2026-09-16)

- DCP "does not increase the number of GPUs we need to launch, but just reduces the KV cache duplication."
- Plain TP shards KV by heads; MLA has one KV head, so "DeepSeek-R1 has 1 KV head when MLA is enabled, so `-tp 8` duplicates KV cache 8x", and `-dcp 8` removes it. GLM-5.3-Flash sparse MLA behaves the same way (Inferred, `glm53-flash-model`).
- DCP size "should lie in the range of `[1, tp_size/H]`" (H = KV heads), so TP4 allows DCP up to 4.
- "with larger dcp size, the KV cache duplication is reduced, but the communication overhead increases." Our DCP4 decoded 6% to 24% slower than DCP1 (Observed, one run, `ARQUITETURA.md §29.6`).
- "Some attention backends also support DCP combined with MTP." The fork's B12X backend does (Observed, our runs).

## Prefix caching

`https://docs.vllm.ai/en/latest/design/prefix_caching.html` (page dated 2026-06-23)

- "we hash each kv-cache block by the tokens in the block and the tokens in the prefix before the block"; "We only cache full blocks."
- "As of v0.11, the default hashing algorithm is `sha256`". `sha256_cbor` gives reproducible hashes across environments.
- A request `cache_salt` "is injected into the hash of the first block", isolating tenants.
- Eviction: LRU free queue; when a request finishes, its blocks go to the tail in reverse order, so the last block is evicted first.
- The page does not cover hybrid models or `mamba_cache_mode`. For the KDA recurrent state, the fork's `--recurrent-checkpoint-policy request_boundaries` decides which prefix states are kept (fork `vllm/config/cache.py`, `production-profile.md`).

## Metrics

`https://docs.vllm.ai/en/latest/usage/metrics.html` (footer 2026-11-12) and `https://docs.vllm.ai/en/latest/design/metrics.html` (2026-10-30)

Names the current docs list that matter for us: `vllm:kv_cache_usage_perc`, `vllm:prefix_cache_hits`, `vllm:prefix_cache_queries`, `vllm:prompt_tokens_cached`, `vllm:num_requests_running`, `vllm:num_requests_waiting`, `vllm:num_preemptions`, `vllm:time_to_first_token_seconds`, `vllm:inter_token_latency_seconds`, `vllm:request_time_per_output_token_seconds`, `vllm:e2e_request_latency_seconds`, `vllm:request_prefill_time_seconds`, `vllm:request_queue_time_seconds`, and for speculative decoding only `vllm:spec_decode_num_accepted_tokens_per_pos`. The design page calls `vllm:spec_decode_num_accepted_tokens`, `vllm:spec_decode_num_draft_tokens` and similar "legacy" metrics to revisit.

What our servers actually exposed:

- Upstream vLLM 0.32.0 on the B300 exposed `vllm:kv_cache_usage_perc`, `vllm:prefix_cache_hits_total` and `vllm:prefix_cache_queries_total` (Observed, `f3/resultados/b300-20261105/startup.txt`). Note the `_total` suffix on counters, which the docs list without it.
- The fork's metric names were never captured. Unknown. Before writing dashboards or llm-d scorers, run `curl -s localhost:8000/metrics | grep -o '^vllm:[a-z_]*' | sort -u` on a fork server and record the list.

## The GLM-5.3-Flash recipe

`https://recipes.vllm.ai/zai-org/GLM-5.3-Flash`

- Requires "vLLM 0.29.0+" and an image with native GLM5Next support (vLLM PR #62424) and the Rust frontend.
- Default command (8x H200, FP8): `vllm serve zai-org/GLM-5.3-Flash --tokenizer-mode glm5_next --tensor-parallel-size 8 --disable-flashinfer-autotune --tool-call-parser glm47 --enable-auto-tool-choice --reasoning-parser glm47`. Upstream vLLM 0.32.0 rejected `--disable-flashinfer-autotune` with `unrecognized arguments` (`ARQUITETURA.md §9.3`); our profile uses `--no-enable-flashinfer-autotune`. The recipe uses `--reasoning-parser glm47`; our image profile uses `glm45`, the only one we ran.
- MTP with 5 speculative tokens on GB200 and 3 on the GB300 low-latency recipe. We cap at 3.
- `--kv-cache-dtype fp8` on Blackwell; Hopper "must run BF16 KV" in disaggregation.
- Environment: `VLLM_ENGINE_READY_TIMEOUT_S=3600`, `VLLM_USE_RUST_FRONTEND=1`.
- Known issues: images and video unsupported on the Rust frontend; sparse MLA init errors need FlashInfer 0.6.17 or 0.6.18 or newer (the page states both).
- No mention of SM120, RTX PRO 6000 or DCP. The recipe is not a source for our profile; it is a source for what upstream supports.
