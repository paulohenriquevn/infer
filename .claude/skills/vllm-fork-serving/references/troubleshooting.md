# Troubleshooting the fork server

Every failure we hit with this stack, as symptom, log line, cause and fix. Ordered by how often it costs time. Labels: Observed (path), Reported, Inferred, Hypothesis, Unknown. "mini" marks the random-weight test model. Log files under `f3/resultados/` keep their old Portuguese names (`servidor-direto.log`, `avisos.txt` for warnings, `host-diagnostico.txt` for host diagnostics).

## Quick triage

| You see | Go to |
|---|---|
| C32 decode far below 1,400 tok/s with DCP1 | 1. Slow host |
| `Using B12X PCIe all-reduce` missing, or p2pmark custom loses to NCCL from 4 KiB | 2. P2P override |
| Driver below 615.65.02 | 3. Driver |
| `torch.OutOfMemoryError` during warmup or autotune | 4. OOM at warmup |
| `Checkpoint restore ... recomputing its prompt instead`, `aborted after 600.01 s` | 5. LMCache restores |
| `Unknown vLLM environment variable detected` | 6. Benign warnings |
| Server never answers `/health`, offline model not found | 7. Model resolution |
| `illegal memory access` | 8. Illegal memory access |
| Start fails right after the command line | 9. Command quoting |

## 1. Slow host (Vast 48294)

- **Symptom.** Decode at C1 / C8 / C16 / C32: 108.2 / 298.6 / 350.8 / 297.6 tok/s against 154.5 / 696.3 / 1,072.6 / 1,580.3 on host 157204 with the same image, checkpoint and script. C32 ITL p50 106.38 ms against 19.98 ms. Ready in 1,084 s against 260 s. Only 2 or 3 requests running at 16 agents with 5% of KV used (Observed, `decode.json` in `f3/resultados/vast-20261112/vllm/vast-vllm-dcp1-rep/` and `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/`; §29.10). Full table: `../examples/decode-48294-vs-157204.md`.
- **Log lines.** Nothing fails. The only outlier is the weight load:

```text
(Worker_TP0 pid=26242) INFO 11-12 10:00:38 [default_loader.py:575] Loading weights took 462.27 seconds
```

  against `Loading weights took 24.68 seconds` on 157204 (Observed, both `servidor-direto.log`). The B12X all-reduce line was present.
- **What differed** (Observed, `host.txt`, `host-diagnostico.txt`, `decode.json` hardware summaries, p2pmark):

| | 157204 (good) | 48294 (slow) |
|---|---|---|
| Driver | 615.71.09 | 580.95.05 |
| OS and kernel | Ubuntu 24.04, Linux 7.0.0-42 | Ubuntu 22.04, Linux 6.8.0-87 |
| CPU and NUMA | GPU0 on NUMA 0, GPUs 1 to 3 on NUMA 1 | Xeon 6767P, 2 sockets, 256 CPUs, 4 NUMA nodes; GPU0 on NUMA 0, GPUs 1 to 3 on NUMA 2 |
| Links | Gen5 x16 | Gen5 x16 |
| p2pmark custom all-reduce, 256 B / 2 KiB / 32 KiB | 9.1 / 9.1 / 76.2 µs | 13.8 / 21.7 / 125.0 µs |
| Average GPU power during decode | 986.56 W (4 GPUs) | 661.89 W; about 116 W per GPU in `host-diagnostico.txt` |
| Average PCIe rx | 10.8 GB/s | 4.6 GB/s |
| Weights load | 24.68 s | 462.27 s |

- **Cause.** Unknown. §29.10 called the topology and all-reduce "the same"; the table shows they were not identical (NUMA layout, all-reduce 1.5 to 2.4 times slower at small sizes, OS, driver). Hypotheses: a noisy neighbour on CPU or memory, a slower storage path (the 462 s load), NUMA placement, or the older driver. The driver alone does not explain it: Nebius R1 ran driver 580.173.02 and reached 1,425 tok/s at C32 (Inferred, §12.2, §29.10).
- **Fix.** The host gate: C32 decode about 5 minutes after start with the DCP1 profile; discard the host below 1,400 tok/s (`docs/06-aws-implementation-plan.md` phase 1). Record weight load time too: a load much slower than about 25 s on local disk is an early warning (Inferred from this one case).

## 2. P2P override not in effect (Nebius R1)

- **Symptom.** Decode C1 119.8 tok/s against 238 reported by the fork's wiki (Observed, §12.2). The server did choose the B12X all-reduce (that hypothesis was refuted, §23.1).
- **Evidence.** p2pmark on Nebius, 4 GPUs, custom PCIe all-reduce against NCCL (Observed, `f3/resultados/p0-20261106/resultados/host0/p2pmark-4gpu-sem-override.txt` and `...-com-override.txt`; "sem" means without, "com" means with):

| Size | Custom without override | Custom with override | NCCL |
|---|---|---|---|
| 256 B | 22.1 µs | 20.2 µs | 30.2 to 34.6 µs |
| 4 KiB | 31.4 µs (NCCL wins) | 11.7 µs | 30.2 to 30.7 µs |
| 32 KiB | 131.9 µs | 23.2 µs | 24.9 to 25.7 µs |
| 64 KiB | 657.6 µs | 43.9 µs | 23.9 to 24.7 µs |
| 1 MiB | 21,552.7 µs | 162.9 µs | 85.5 to 87.2 µs |

  The p2pmark header shows the state: `Runtime: ForceP2P=; RMForceP2PType=; RMPcieP2PType=;` without, `Runtime: ForceP2P=0x11; RMForceP2PType=1; RMPcieP2PType=2;` with.
- **Cause.** Reported by the fork's wiki: in a `NODE` topology without a PCIe switch the driver stages GPU-to-GPU traffic through system memory and the one-shot all-reduce becomes about 15 times slower than NCCL; the wiki also asks for ACS off and the IOMMU out of the way (§23.1, §10.4 item 4).
- **Fix.** The module parameter line (Observed, project research notes, not published, 2026-11-06; §25.2):

```text
PeerMappingOverride=1;ForceP2P=0x11;RMForceP2PType=1;RMPcieP2PType=2;GrdmaPciTopoCheckOverride=1;EnableResizableBar=1
```

  Keep any value the provider already sets, write it in a file read last (`zz-*.conf`), stop `nv-hostengine` and `nvidia-persistenced`, unload `nvidia_drm`, `nvidia_modeset`, `nvidia_peermem`, `gdrdrv`, `nvidia_uvm`, `nvidia` in that order, reload (§25.3). The server with the override never ran on Nebius; on Vast 157204 P2P worked without any override (RegistryDwords empty) and decode was 22% higher at C1 (Observed, §29.2).
- **Note on the numbers in §28.2.** The 9.1 to 9.5 µs quoted for 157204 are p2pmark's own custom all-reduce, not the B12X kernel inside vLLM (§23.1 says p2pmark measures its own implementation). The p2pmark rows on 157204 are 8.4 to 9.3 µs from 256 B to 2 KiB.

## 3. Driver

| Host | Driver | Result |
|---|---|---|
| Image | `CUDA_DRIVER_VERSION=615.65.02` | what the image was built for (§25.1) |
| Vast 157204 | 615.71.09 | good |
| Nebius R1 | 580.173.02 | worked; C32 1,425 tok/s |
| Vast 48294 | 580.95.05 | slow, cause not proven |

Record `nvidia-smi` on every host. A driver below 615.65.02 is the first difference to rule out, not a proven cause. Whether the image starts at all below some driver version is Unknown; both 580 hosts started.

## 4. OOM at warmup (mini, upstream vLLM 0.32.0)

- **Symptom.** `torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 390.00 MiB. GPU 0 has a total capacity of 94.97 GiB of which 121.88 MiB is free.` during `flashinfer_autotune` (`_run_flashinfer_autotune_dummy_runs`), inside a KDA linear (Observed (mini), project research notes, not published, Colab G4 run of 2026-11-04, `serve-nvfp4.log`).
- **Cause.** The autotune runs after the KV cache has filled memory up to `--gpu-memory-utilization 0.85` (Inferred in the same notes).
- **Fix used.** `--gpu-memory-utilization 0.5` for that test. Our production profile avoids FlashInfer autotune entirely (`--no-enable-flashinfer-autotune`) and runs at 0.96 without OOM in every fork start we have (Observed). If you turn autotune on, expect this failure.

## 5. LMCache restores stall (CACHE_MODE=lmcache)

Observed in `f3/resultados/vast-20261111/vllm/vast-vllm-lmcache/servidor-direto.log` (DCP4, `--kv-cache-memory-bytes` 5 GiB, L1 200 GB):

```text
LMCache INFO: Recurrent checkpoint restore of 45955 tokens for request cmpl-b07a10e23010bafb-0-9e431585 is waiting for GPU capacity (489 free blocks; the checkpoint needs 20 plus execution headroom) ...
LMCache INFO: Recurrent checkpoint restore of 77706 tokens failed for request cmpl-9886c21685dfd82a-0-83c4e5d3 on ranks [] after 2.0 s; recomputing its prompt ...
WARNING 11-12 02:05:12 [kv_cache_manager.py:1136] Checkpoint restore for request cmpl-b10694fe912ab28a-0-bdae742b waited 60.3 s for 67 GPU blocks; recomputing its prompt instead
WARNING 11-12 02:03:21 [stall_diagnostics.py:197] Request cmpl-a6bb4dea991d6ec8-0 aborted after 600.01 s (arrived 01:53:21.591), ...
```

- **Counts.** 90 "waiting for GPU capacity" lines, 1 failed restore, 9 recomputes after waits of 60.0, 60.3, 60.9, 85.1, 107.4, 133.5, 159.2, 165.6 and 185.3 s (Observed, `grep` of the log). `avisos.txt` says `agentes-48 terminou com código 2` ("agents-48 ended with exit code 2"). §29.8 reports "9 gave up after 133 to 185 s"; the log shows the range starts at 60.0 s.
- **Cause.** Restored KV must come back into HBM before the request runs; with the HBM pool cut to 5 GiB per GPU, active sessions left no room (Observed, §29.8). LMCache holds idle sessions; it does not add concurrent capacity.
- **Fix.** Size HBM for the active sessions and use LMCache only for idle ones. The corrected test (DCP1, KV sized so active sessions fit, about 48 agents thinking 60 to 100 s) is defined in `vast.sh` and has not run. Details: `kv-cache-tiers` skill.
- **Related.** `Triton kernel JIT compilation during inference: _restore_auxiliary_state_kernel` (and `_glm_device_token_metadata_kernel`) appeared in the same run: the restore path is not covered by warmup, so the first restores also pay a compile (Observed).

## 6. Benign warnings

| Line | Meaning |
|---|---|
| `Unknown vLLM environment variable detected: VLLM_GLM53_...` (9 names, list in `production-profile.md`) | The names are not registered in `vllm/envs.py`; model code reads several of them with `os.getenv`. Expected with this profile |
| `SymmMemCommunicator: Device capability 12.0 not supported` | Symmetric-memory all-reduce is not available on SM120; B12X and PYNCCL are used instead |
| `Sparse MLA layer has no dense-MHA prefill path` | Expected for this model |
| `Using ['B12X_PCIE', 'PYNCCL'] all-reduce backends (in dispatch order) for group 'tp:0'` | Normal; the `ep` group uses only PYNCCL; with DCP4 the `dcp` group uses PYNCCL |

## 7. Model not found offline

- **Symptom.** The server cannot resolve `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` with `HF_HUB_OFFLINE=1`.
- **Cause.** `hf download --revision <sha>` does not create `refs/main` (Observed, §25.3).
- **Fix.** Create `$HF_HOME/hub/models--local-inference-lab--GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD/refs/main` containing `dec48abd33efa73c3bb7c95b74eee10cad34f9be`.
- **Related (mini).** The mini glm5next test model does not load in the fork image because the image's `transformers` lacks `Glm5NextConfig` (Observed (mini), §12.1). Test the fork with the real checkpoint.

## 8. Illegal memory access (mini)

- **Symptom.** `CUDA error: an illegal memory access` on both replicas, twice, with 34,816-token prompts, a 1 GiB KV pool and `--max-num-seqs 64`; 17,408-token prompts did not crash (Observed (mini), upstream vLLM, §7.3).
- **Cause.** Unknown. The fork's wiki lists the same error in the GDN backend under speculative decoding (vLLM issue 34948, PR 35219) and reports it with MTP above 3 tokens at high concurrency (Reported, §10.1, §10.4 item 2).
- **Fix.** Keep `num_speculative_tokens` at 3 or less. Not reproduced on the real model.

## 9. Start fails on the command line

- **Symptom.** vLLM exits with an argument error.
- **Causes seen.** Hand-quoted `--speculative-config` JSON (§12.6); the recipe's `--disable-flashinfer-autotune`, which vLLM 0.32.0 rejected with `unrecognized arguments` (§9.3). The valid name is `--no-enable-flashinfer-autotune`.
- **Fix.** Start only from the generated scripts; never retype the command.

## 10. Operations traps

- Waiting with `pgrep -f name` inside an `ssh` command containing `name` matches itself; a GPU VM ran 6 h 8 min with no result (about US$ 88, §25.3). Wait on the log or `/health` and fail on an empty log.
- `a && b || c` runs `c` when `b` succeeds (§25.3).
- `llm_decode_bench.py` writes only finished scenarios; an interrupted agent level leaves no JSON (§29.8).
- SSH to rented hosts drops; run long commands under `setsid` with logs on disk (§28.1).
