# GLM-5.3-Flash architecture for serving

What each part of the model is, what it costs at serving time, and how to compute KV memory from first principles. The short rules are in `../SKILL.md`; this file holds the derivations.

Labels: Observed (path), Reported (named source, URL, read 2026-11-12), Inferred (reasoning shown), Hypothesis, Unknown. `ARQUITETURA.md §N` is the project journal; `f3/resultados/...` is the results archive (both resolve after `scripts/fetch_evidence.sh`).

## Sources for this file

- `config.json` of `zai-org/GLM-5.3-Flash` at revision `46a050bec13002ad29ee795c16e61cf4fa3c4a9c`. Observed: downloaded on 2026-11-04 into the project research notes (not published) and fetched again on 2026-11-12 from `https://huggingface.co/zai-org/GLM-5.3-Flash/raw/46a050bec13002ad29ee795c16e61cf4fa3c4a9c/config.json`; the two copies are byte-identical as JSON.
- `config.json` of the QAD checkpoint at revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be` (Reported, `https://huggingface.co/local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD/raw/dec48abd33efa73c3bb7c95b74eee10cad34f9be/config.json`, read 2026-11-12). Its `text_config` has the same geometry; it adds explicit linear-attention keys (`linear_num_heads` 64, `linear_head_dim` 128, `linear_conv_kernel_dim` 4, `linear_lower_bound` -5.0) that repeat `linear_attn_config`.
- Server logs of the fork (`f3/resultados/vast-20261111/vllm/*/servidor-direto.log`, old Portuguese file name) and of upstream vLLM 0.32.0 on a B300 (`f3/resultados/b300-20261105/vllm-startup-grep.txt`).
- `ARQUITETURA.md §2` (and its "Correção posterior" note), §8.2, §9.3, §10.1, §12.3, §29.6.

## Layer map

45 decoder layers plus 1 MTP layer (index 45). `layer_types` in the config labels each decoder layer `linear_attention` or `deepseek_sparse_attention` (Observed, config).

| Part | Where | Config fields (Observed) | What it means for serving |
|---|---|---|---|
| KDA (Kimi Delta Attention, linear attention) | 34 layers: every layer not in the list below | `linear_attn_config`: `num_heads` 64, `head_dim` 128, `short_conv_kernel_size` 4, `gate_lower_bound` -5.0, `kda_layers` (34 entries) | Fixed-size recurrent state per sequence, independent of context length. Needs a "mamba-style" state cache, which is why vLLM uses `--mamba-cache-mode` and recurrent checkpoints for prefix caching |
| Sparse MLA with DSA (DeepSeek Sparse Attention), NoPE | 11 layers: 3, 7, 11, 15, 19, 23, 27, 31, 35, 39, 43 (`full_attn_layers`) | `kv_lora_rank` 512, `q_lora_rank` 1536, `qk_nope_head_dim` 256, `qk_rope_head_dim` 0, `v_head_dim` 256, `mla_use_nope` true, `num_attention_heads` 64, `num_key_value_heads` 64 | The only layers whose KV grows with context. MLA stores one compressed latent per token per layer, shared by all heads, so tensor parallelism cannot split it by head (see "TP replication") |
| DSA indexer | the same 11 layers | `index_n_heads` 32, `index_head_dim` 128, `index_topk` 2048, `index_kpool` 4, `index_kpool_compress` true, `index_kpool_always_select_tail` true, `index_share_for_mtp_iteration` true | Each decode token attends to at most 2,048 selected positions, so attention cost per token stops growing with context. The indexer keeps its own per-token keys (Hypothesis: the part of KV above the latent estimate, `ARQUITETURA.md §2`) |
| Dense MLP | layers 0, 1, 2 | `first_k_dense_replace` 3, `intermediate_size` 12288 | Small, always active |
| MoE | layers 3 to 44 (42 layers) | `n_routed_experts` 288, `num_experts_per_tok` 8, `n_shared_experts` 1, `moe_intermediate_size` 2048, `scoring_func` sigmoid, `topk_method` noaux_tc, `routed_scaling_factor` 2.5, `moe_router_dtype` float32, `swiglu_limit` 10.0 | 320B total and 18B active parameters (Reported, model card). Routed experts hold most of the weight bytes, so they are what 4-bit quantization targets. `swiglu_limit` is the clamp that a fork kernel once omitted (`ARQUITETURA.md §10.4` item 1) |
| mHC (manifold-constrained hyper-connections) | residual stream | `mhc` true, `hc_mult` 4, `hc_sinkhorn_iters` 20 | Four residual streams mixed per layer. The fork has a dedicated switch for it (`B12X_MHC_PDL=1`, see `vllm-fork-serving`) |
| MTP | layer 45 (1,760 tensors in the QAD checkpoint index, `ARQUITETURA.md §8.2`) | `num_nextn_predict_layers` 1 | The draft head for speculative decoding (`--speculative-config` method `mtp`). It has its own KV and appears as a 46th layer in the fork's cache groups (log `layer counts [12, 11, 11, 12]`, 46 in total) |
| Vision tower | 24 blocks | `vision_config.depth` 24, `hidden_size` 1024 | Multimodal input. Our workload is text; the weights still load |
| Vocabulary | | `vocab_size` 154880, `hidden_size` 4096 | |
| Context | | `max_position_embeddings` 1048576 | Our server runs `--max-model-len 1048576` |
| Native weights | | `quantization_config`: `quant_method` fp8, `fmt` e4m3, `weight_block_size` [128, 128], `activation_scheme` dynamic, 1,509 entries in `modules_to_not_convert` | The base checkpoint is block FP8; `transformers_version` 5.16.0 |

`head_dim` is 0 in the config and `qk_head_dim` is 256 (Observed). Do not use `head_dim` in any formula.

## KV memory per token

### What the first estimate missed

`ARQUITETURA.md §2` first counted only the MLA latent:

```text
MLA latent per token per layer = (kv_lora_rank + qk_rope_head_dim) x 1 byte (fp8)
                               = (512 + 0) x 1 = 512 bytes
x 11 sparse MLA layers          = 5,632 bytes per token for the whole model
x 262,144 tokens (256K)         = 1.48 GB per 256K session
```

(Inferred from the config.) The journal wrote 1.62 GB for this estimate; how it got there is not recorded (Hypothesis: counting the MTP layer too gives 12 x 512 x 262,144 = 1.61 GB). Both figures are superseded by the measurements below.

### What was measured

| Stack | Log lines | Bytes per token | Source |
|---|---|---|---|
| Upstream vLLM 0.32.0, 1 B300, `nvidia/GLM-5.3-Flash-NVFP4`, standard fp8 KV format | `Available KV cache memory: 39.05 GiB`; `GPU KV cache size: 4,807,959 tokens, Maximum concurrency for 262,144 tokens per request: 18.34x` | 39.05 x 2^30 / 4,807,959 = 8,721 B, whole model on one GPU | Observed, `f3/resultados/b300-20261105/vllm-startup-grep.txt`; `ARQUITETURA.md §9.3` |
| `local-inference-lab/rtx6kpro` wiki, TP2 + DCP2 | 7,650,410,496 bytes of KV per GPU for 1,844,162 tokens | about 8.3 KB | Reported, `ARQUITETURA.md §10.1` |
| Fork, TP4, DCP1, `fp8_ds_mla` format, host 157204 | `Available KV cache memory: 45.76 GiB`; `GPU KV cache size: 6,789,052 tokens`; `shared-pool max-request cost decreased from 7743301632 to 7582924800 bytes` | 7,582,924,800 / 1,048,576 = 7,232 B per GPU. Every GPU holds the whole sequence | Observed, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/servidor-direto.log` |
| Fork, TP4, DCP4, same host | `Available KV cache memory: 45.53 GiB`; `GPU KV cache size: 22,954,769 tokens`; `max-request cost decreased from 2267375616 to 2231725056 bytes` | 2,231,725,056 / 1,048,576 = 2,128 B per GPU, about 8.5 KB per token across the 4 GPUs | Observed, `f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/servidor-direto.log` |

The fork's "max-request cost" is the bytes one request of `--max-model-len` (1,048,576 tokens) needs on one GPU. Dividing the available memory by it reproduces the logged concurrency: 45.76 GiB / 7,582,924,800 B = 6.48, logged `6.47x` (Inferred, arithmetic). So the fork's bytes per token already include the per-request recurrent state spread over 1M tokens.

The planning figure in force is 8.7 KB per token for the whole model (`docs/README.md`, contradictions table: 2.3 GB per 256K session). The fork numbers agree within 3% for DCP4 (8.5 KB), which makes 8.7 KB a slightly conservative rule (Inferred).

### Why DCP4 gives 3.4 times the tokens, not 4

Inferred decomposition. Let `s` be the bytes per token that DCP splits across ranks and `c` the bytes per token that every rank keeps:

```text
DCP1: c + s     = 7,231.6 B
DCP4: c + s / 4 = 2,128.3 B
=> 0.75 s = 5,103.3   => s = 6,804.4 B   and   c = 427.2 B
ratio = 7,582,924,800 / 2,231,725,056 = 3.398  (logged token ratio 22,954,769 / 6,789,052 = 3.381)
```

A hint from the fork source and log (Inferred, the numbers match but no source states the layout): the fork's `kv_cache_utils.py` at commit `8244d1c44` says "GLM-5.3 stores two 64-row by 132-byte FP8 C4 index pages in the target MLA page tail when the target block contains 512 tokens", which is 132 bytes per 4 tokens, 33 B per token per layer for the indexer (Reported, `https://github.com/local-inference-lab/vllm/blob/8244d1c44348ae8a5bbfc9f1b607021652283ed4/vllm/v1/core/kv_cache_utils.py`, read 2026-11-12). If `fp8_ds_mla` keeps the DeepSeek V3.2 layout (512 fp8 values, four fp32 scales, then the rope part, which is 0 here), the latent takes 512 + 16 = 528 B (Hypothesis: the layout comes from vLLM's DeepSeek V3.2 support, not from a GLM source). 512 + 16 + 33 = 561 B per token per layer, and the logged MLA page is 1,148,928 B = 2,048 x 561. With 12 MLA layers (11 plus MTP), 12 x 561 = 6,732 B per token, within 1% of the split part `s` above. The second page size, 1,187,840 B, would then be the recurrent-state page; its layout is Unknown.

About 448 MB per 1M-token request is not split by DCP. What that part is remains Unknown. Hypothesis: the per-request KDA state and MTP or indexer state that DCP does not shard. How to find out: read the fork's `kv_cache_utils.py` around the "Rebalanced split KV cache groups" message (line 1863 in the log) inside the image.

## KDA state per sequence

Inferred from the config geometry:

```text
recurrent state per KDA layer  = num_heads x head_dim x head_dim x 4 bytes (fp32)
                               = 64 x 128 x 128 x 4 = 4,194,304 B
conv state per KDA layer       = (short_conv_kernel_size - 1) x 3 (q, k, v) x (64 x 128) x 2 bytes (bf16)
                               = 3 x 3 x 8,192 x 2 = 147,456 B
per sequence (34 layers)       = 34 x (4,194,304 + 147,456) = 147,619,840 B, about 0.15 GB
```

The formula reproduces the "mamba page padding 2.64%" line of the upstream vLLM log (`ARQUITETURA.md §2`). The fork log confirms fp32 state: `GLM speculative KDA uses B12X checkpoint recovery with FP32 recurrent state` (Observed, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/servidor-direto.log`).

Under TP4 the 64 KDA heads are split across ranks (Hypothesis: standard head sharding for linear attention, about 37 MB per GPU per sequence). It does not change the planning rule, which counts 0.15 GB per live sequence per replica.

With `--mamba-cache-mode align` and `--recurrent-checkpoint-policy request_boundaries`, the fork keeps extra recurrent checkpoints so a later request can resume from a cached prefix. Their count and memory cost per session are Unknown in our sources. The fork's log line `Using split GLM-5.3 cache pages: target block size 2048 tokens, recurrent-state block size 2048 tokens` (Observed) suggests one checkpoint per 2,048-token page (Hypothesis).

## TP replication of MLA KV and what DCP does

- MLA stores one latent vector per token per layer, shared by all 64 heads. Tensor parallelism splits heads, so every TP rank needs the whole latent: under TP4 without DCP the MLA KV is stored 4 times (Reported, vLLM context parallel docs: "DeepSeek-R1 has 1 KV head when MLA is enabled, so `-tp 8` duplicates KV cache 8x", `https://docs.vllm.ai/en/latest/serving/context_parallel_deployment.html`, read 2026-11-12, developer preview docs, not our pinned version).
- DCP shards the KV along the token dimension instead, so each rank keeps 1/DCP of the tokens. The docs bound DCP to `[1, tp_size/H]`, with H the number of KV heads (1 for MLA), so DCP4 is the maximum for TP4 (Reported, same page).
- Cost: "with larger dcp size, the KV cache duplication is reduced, but the communication overhead increases" (Reported, same page). Our measurement: DCP1 decoded 6% to 24% faster than DCP4 on the same host, one run (Observed, `ARQUITETURA.md §29.6`).
- The fork uses `dcp_comm_backend=ag_rs` (Observed in the engine config line of the DCP1 log). Upstream documents the choices `a2a` and `ag_rs` for `--dcp-comm-backend`, with `ag_rs` as the model default (Reported, `https://docs.vllm.ai/en/latest/configuration/engine_args.html`, read 2026-11-12, developer preview).
- `--dcp-kv-cache-interleave-size` is replaced by `--cp-kv-cache-interleave-size` upstream (Reported, same engine args page). Our scripts set both to 4.

Rule that follows (Inferred): never add the HBM of 4 GPUs into one KV pool unless DCP4 is on. With DCP1 each GPU holds the whole session.

## Session sizing table

Inferred from the bytes per token above. Planning numbers use 8.7 KB; deployed numbers come from the server log.

| Context | Planning (8.7 KB, whole replica) | Fork DCP1 (7,232 B per GPU, replicated on 4 GPUs) | Fork DCP4 (2,128 B per GPU) | KDA state |
|---|---|---|---|---|
| 100K tokens | 0.87 GB | 0.72 GB on each GPU | 0.21 GB per GPU, 0.85 GB per replica | 0.15 GB |
| 256K (262,144) | 2.28 GB | 1.90 GB on each GPU | 0.56 GB per GPU, 2.23 GB per replica | 0.15 GB |
| 1M (1,048,576) | 9.1 GB | 7.58 GB on each GPU | 2.23 GB per GPU, 8.9 GB per replica | 0.15 GB |

Sessions of 256K that fit in the HBM pool (Inferred): DCP1 6,789,052 / 262,144 = 25.9; DCP4 22,954,769 / 262,144 = 87.6. Worked example: `../examples/kv-per-session-calculation.md`.

## What this means for the other skills

- Capacity and LMCache sizing use 8.7 KB per token plus 0.15 GB per sequence (`capacity-and-cost`, `kv-cache-tiers`).
- The router's `blockSizeTokens` must match the engine block. The fork log shows `--block-size 256` on the command line and 2,048-token split cache pages in the log; which one the prefix cache hashes with is Unknown (`llm-d-routing` keeps it Unknown too). How to find out: read `cache_config_info` from `/metrics` on a running fork server.
