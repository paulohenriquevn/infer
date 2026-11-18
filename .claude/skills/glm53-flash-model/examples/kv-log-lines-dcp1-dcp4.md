# KV cache size in the server log: DCP1 against DCP4

Real startup lines from the fork, same Vast host 157204, same image (`v0.1.dev21830+g8244d1c44`), same checkpoint and flags except `--decode-context-parallel-size`. The process prefixes such as `(EngineCore pid=...)` are removed. The files are named `servidor-direto.log` (old Portuguese name for "direct server log").

## DCP1

Source: `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/servidor-direto.log`, 2026-11-12.

```text
INFO 11-12 00:23:03 [mla_attention.py:688] Using fp8_ds_mla KV cache format for B12X backend.
INFO 11-12 00:23:51 [model_runner.py:456] Model loading took 42.2 GiB memory and 49.097309 seconds
WARNING 11-12 00:23:51 [interface.py:900] Using split GLM-5.3 cache pages: target block size 2048 tokens, recurrent-state block size 2048 tokens.
WARNING 11-12 00:24:51 [kv_cache_utils.py:1863] Rebalanced split KV cache groups from layer counts [12, 11, 11, 12] to [9, 9, 8, 8, 12]; shared-pool max-request cost decreased from 7743301632 to 7582924800 bytes (2.07%).
WARNING 11-12 00:24:51 [kv_cache_utils.py:2744] Keeping split GLM-5.3 cache groups with physical page sizes [1148928, 1187840].
INFO 11-12 00:25:36 [gpu_worker.py:782] Available KV cache memory: 45.76 GiB
INFO 11-12 00:25:36 [kv_cache_utils.py:2850] GPU KV cache size: 6,789,052 tokens, Maximum concurrency for 1,048,576 tokens per request: 6.47x
```

The same profile on host 48294 logged `GPU KV cache size: 6,779,520 tokens` (Observed, `f3/resultados/vast-20261112/vllm/vast-vllm-dcp1-rep/servidor-direto.log`).

## DCP4

Source: `f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/servidor-direto.log`, 2026-11-11.

```text
INFO 11-11 23:33:14 [mla_attention.py:688] Using fp8_ds_mla KV cache format for B12X backend.
INFO 11-11 23:34:18 [model_runner.py:456] Model loading took 42.2 GiB memory and 65.049147 seconds
WARNING 11-11 23:34:18 [interface.py:900] Using split GLM-5.3 cache pages: target block size 2048 tokens, recurrent-state block size 2048 tokens.
WARNING 11-11 23:38:17 [kv_cache_utils.py:1863] Rebalanced split KV cache groups from layer counts [12, 11, 11, 12] to [6, 6, 6, 6, 5, 5, 6, 6]; shared-pool max-request cost decreased from 2267375616 to 2231725056 bytes (1.57%).
WARNING 11-11 23:38:17 [kv_cache_utils.py:2744] Keeping split GLM-5.3 cache groups with physical page sizes [1148928, 1187840].
INFO 11-11 23:38:17 [gpu_worker.py:782] Available KV cache memory: 45.53 GiB
INFO 11-11 23:38:17 [kv_cache_utils.py:2850] GPU KV cache size: 22,954,769 tokens, Maximum concurrency for 1,048,576 tokens per request: 21.89x
```

Other DCP4 starts of the same profile: `23,249,576 tokens` with 46.1 GiB available (Nebius R1, `f3/resultados/rtx-20261105/r1-servidor.log`) and `23,149,073 tokens` (Vast `vast-vllm-r1`).

## For comparison: upstream vLLM on one B300

Source: `f3/resultados/b300-20261105/vllm-startup-grep.txt` (upstream vLLM 0.32.0, `nvidia/GLM-5.3-Flash-NVFP4`, `--max-model-len 262144`).

```text
INFO 11-05 16:37:59 [mla_attention.py:540] Using standard fp8 KV cache format. To use DeepSeek's fp8_ds_mla KV cache format, please set `--attention-backend FLASHMLA_SPARSE`
INFO 11-05 16:52:56 [interface.py:776] Setting kv cache block size to 128 for DEEPSEEK_V32_INDEXER/KPOOL_TAIL/FLASHINFER_MLA_SPARSE backend(s).
INFO 11-05 16:54:36 [kv_cache_utils.py:853] kv cache group sizes (8576, 8576, 8576, 8576, 8576, 4)
INFO 11-05 16:54:36 [gpu_worker.py:759] Available KV cache memory: 39.05 GiB
INFO 11-05 16:54:36 [kv_cache_utils.py:2327] GPU KV cache size: 4,807,959 tokens, Maximum concurrency for 262,144 tokens per request: 18.34x
```

## What to read in these lines

| Line | What it tells you |
|---|---|
| `Using fp8_ds_mla KV cache format for B12X backend` | The fork uses DeepSeek's fp8 MLA layout. Upstream on B300 used the "standard fp8" layout, so bytes per token differ between the two stacks |
| `Using split GLM-5.3 cache pages: target block size 2048 tokens` | The fork pages GLM-5.3 KV and recurrent state in 2,048-token pages, although the command says `--block-size 256` (`VLLM_GLM53_SPLIT_TARGET_BLOCK_SIZE=2048` in the env). The LMCache arm (`vast-vllm-lmcache`) logged 1,024 for both pages |
| `layer counts [12, 11, 11, 12]` | 46 layers: 45 decoder layers plus the MTP layer |
| `shared-pool max-request cost ... 7582924800 bytes` | Bytes one request of `--max-model-len` (1,048,576) needs per GPU. Divide by 1,048,576 for bytes per token per GPU: 7,232 (DCP1) and 2,128 (DCP4) |
| `Available KV cache memory` | What is left per GPU after weights (42.2 GiB), activations and CUDA graphs at `--gpu-memory-utilization 0.96` |
| `GPU KV cache size: N tokens` | The token budget of the whole replica. With DCP1 every GPU holds every token; with DCP4 each GPU holds a quarter |
| `Maximum concurrency for 1,048,576 tokens per request` | N / max-model-len: how many full-length requests fit. 6.47 x 4 = 25.9 sessions of 256K for DCP1 |

Ratio DCP4 / DCP1: 22,954,769 / 6,789,052 = 3.38 in tokens, 3.40 in max-request cost. Why not 4: `../references/architecture.md`, "Why DCP4 gives 3.4 times the tokens".
