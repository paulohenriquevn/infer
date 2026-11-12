# A healthy startup log, with the lines to check

Source: `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/servidor-direto.log` ("servidor-direto" is the old Portuguese name for the direct-server log). Vast host 157204, 2026-11-12, `bench/server-vllm-dcp1-direct.sh`, image `karmic-kraken-20261016`, warm compile cache, ready in 260 s (`tempo-pronto.txt`: `pronto em 260 s`). Lines are quoted exactly except that the process prefix such as `(EngineCore pid=63550)` is removed, duplicates from the 4 workers are dropped, and long lines are cut with `...`.

## The excerpt

```text
WARNING 11-12 00:22:12 [envs.py:2630] Unknown vLLM environment variable detected: VLLM_CACHE_DIR
WARNING 11-12 00:22:12 [envs.py:2630] Unknown vLLM environment variable detected: VLLM_CAUSAL_CONV1D_UPDATE_HOIST
... (7 more VLLM_GLM53_* names)
INFO 11-12 00:22:12 [api_utils.py:286] non-default args: {'model_tag': 'local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD', ...
WARNING 11-12 00:22:15 [vllm.py:2385] max_num_scheduled_tokens is set to 4096 based on the speculative decoding settings. This may lead to suboptimal performance. Consider increasing max_num_batched_tokens to accommodate the additional draft token slots, or decrease num_speculative_tokens.
INFO 11-12 00:22:17 [vllm.py:3510] GLM speculative KDA uses B12X checkpoint recovery with FP32 recurrent state. Use --no-use-replayssm to retain full speculative states.
INFO 11-12 00:22:29 [core.py:124] Initializing a V1 LLM engine (v0.1.dev21830+g8244d1c44) with config: model='/root/.cache/huggingface/hub/models--local-inference-lab--GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD/snapshots/dec48abd33efa73c3bb7c95b74eee10cad34f9be', ...
WARNING 11-12 00:23:01 [symm_mem.py:67] SymmMemCommunicator: Device capability 12.0 not supported, communicator is not available.
INFO 11-12 00:23:01 [cuda_communicator.py:420] Using ['B12X_PCIE', 'PYNCCL'] all-reduce backends (in dispatch order) for group 'tp:0' out of potential backends: ['FLASHINFER_PCIE_IPC', 'B12X_PCIE', 'B12X_ROCENANTE', 'FLASHINFER', 'NCCL_SYMM_MEM', 'QUICK_REDUCE', 'AITER_CUSTOM', 'CUSTOM', 'SYMM_MEM', 'PYNCCL'].
INFO 11-12 00:23:01 [cuda_communicator.py:420] Using ['PYNCCL'] all-reduce backends (in dispatch order) for group 'ep:0' ...
INFO 11-12 00:23:01 [b12x_pcie_all_reduce.py:326] Using B12X PCIe all-reduce (algorithm=oneshot, one-shot max=86016, fused max=86016, two-shot bf16 max=off, DMA min=off).
INFO 11-12 00:23:03 [mla_attention.py:688] Using fp8_ds_mla KV cache format for B12X backend.
WARNING 11-12 00:23:03 [mla_attention.py:783] Sparse MLA layer has no dense-MHA prefill path; using the top-k MQA path only.
INFO 11-12 00:23:29 [default_loader.py:575] Loading weights took 24.68 seconds
INFO 11-12 00:23:46 [nvfp4.py:261] Using 'MARLIN' NvFp4 MoE backend out of potential backends: ['FLASHINFER_TRTLLM', 'FLASHINFER_CUTEDSL', 'FLASHINFER_CUTLASS', 'VLLM_CUTLASS', 'MARLIN', 'HUMMING', 'EMULATION'].
INFO 11-12 00:23:48 [default_loader.py:575] Loading weights took 1.33 seconds
INFO 11-12 00:23:51 [model_runner.py:456] Model loading took 42.2 GiB memory and 49.097309 seconds
WARNING 11-12 00:23:51 [interface.py:900] Using split GLM-5.3 cache pages: target block size 2048 tokens, recurrent-state block size 2048 tokens.
INFO 11-12 00:23:56 [b12x_prepare.py:573] b12x weights preparation uses 8 compiler workers
WARNING 11-12 00:24:51 [kv_cache_utils.py:1863] Rebalanced split KV cache groups from layer counts [12, 11, 11, 12] to [9, 9, 8, 8, 12]; shared-pool max-request cost decreased from 7743301632 to 7582924800 bytes (2.07%).
INFO 11-12 00:25:33 [model_runner.py:1263] Graph capturing finished in 12 secs, took 0.78 GiB
INFO 11-12 00:25:36 [gpu_worker.py:782] Available KV cache memory: 45.76 GiB
INFO 11-12 00:25:36 [kv_cache_utils.py:2850] GPU KV cache size: 6,789,052 tokens, Maximum concurrency for 1,048,576 tokens per request: 6.47x
INFO 11-12 00:26:13 [core.py:390] init engine (profile, create kv cache, warmup model) took 141.85 s
INFO 11-12 00:26:21 [entry.py:139] Starting vLLM server on http://0.0.0.0:8000
INFO:     Application startup complete.
```

The B12X autotune progress lines are carriage-return updates; their final state on this start was `b12x ready comm.pcie: 283/283 ready, candidates 0/1 prepared, 15207 measured, 0 cached, 8 compilations, 0:42`.

## Checklist

| Check | Expected | If not |
|---|---|---|
| Engine version | `v0.1.dev21830+g8244d1c44` | Wrong image; stop |
| Snapshot in the model path | `.../snapshots/dec48abd33efa73c3bb7c95b74eee10cad34f9be` | Wrong revision; the gate result does not apply |
| `Using ['B12X_PCIE', 'PYNCCL'] ... for group 'tp:0'` and `Using B12X PCIe all-reduce (algorithm=oneshot, ...)` | present | `tp` fell back to NCCL; decode numbers are not comparable. Check `VLLM_ENABLE_PCIE_ALLREDUCE=1` and P2P (`../references/troubleshooting.md` section 2) |
| `Using fp8_ds_mla KV cache format for B12X backend.` | present | Attention backend or KV dtype changed |
| `Using 'MARLIN' NvFp4 MoE backend` | present (the MTP draft) | Speculative config changed |
| `Loading weights took` (first occurrence) | about 25 s on local disk, 134 s on a 1.4 GB/s network disk | Much slower: storage problem; 462 s on the slow host 48294 |
| `Model loading took 42.2 GiB memory` | 42.2 GiB on each of 4 ranks | Different checkpoint or TP |
| `Using split GLM-5.3 cache pages: target block size 2048 tokens` | present | `VLLM_GLM53_SPLIT_TARGET_BLOCK_SIZE` or `--mamba-cache-mode align` missing |
| `GPU KV cache size` | DCP1 about 6.79 million tokens; DCP4 about 23 million | Profile, memory utilization or DCP is not what you think |
| `b12x ready comm.pcie: ... cached` | warm: `0 measured, 179 cached, 0 compilations`; cold: about 6,700 compilations, 2.5 to 3.5 min | Cold start; persist `/cache` |
| `init engine ... took` | 75 to 142 s warm, about 350 s cold on host 157204 | See `../references/startup-and-weights.md` |
| `Application startup complete.` | present | Read the last ERROR line |

## Lines that look alarming but are expected

- `Unknown vLLM environment variable detected` for 9 names: fork switches read by model code, not registered in `vllm/envs.py` (`../references/production-profile.md`).
- `SymmMemCommunicator: Device capability 12.0 not supported`: SM120 has no symmetric-memory all-reduce; B12X and PYNCCL cover it.
- `Sparse MLA layer has no dense-MHA prefill path`: expected for this model.
- `max_num_scheduled_tokens is set to 4096 ... This may lead to suboptimal performance`: vLLM suggests raising `--max-num-batched-tokens` to fit draft tokens. We keep 4096 from the fork's recipe (`ARQUITETURA.md §10.3`). Whether a larger budget helps is untested (Hypothesis); it would go through the change procedure in `change-one-flag-walkthrough.md`.

## Quick extraction

```bash
grep -E 'Initializing a V1 LLM engine|Using B12X PCIe all-reduce|fp8_ds_mla|Loading weights took|Model loading took|split GLM-5.3 cache pages|Available KV cache memory|GPU KV cache size|init engine|Application startup complete' \
  "$LOGFILE" | sed -E 's/^\(([A-Za-z_0-9]+) pid=[0-9]+\) //' | awk '!seen[$0]++'
```

Run on this log on 2026-11-12, it printed the corresponding lines of the excerpt above, one per worker where the ranks log the same line (Observed).
