# Model, hardware and checkpoints

Scope: what we know about GLM-5.3-Flash, the NVIDIA RTX PRO 6000 Blackwell (SM120) GPU, and the checkpoints we can serve on it, as measured or read up to 2026-11-12. The source material is `ARQUITETURA.md` and `NOTAS.md` at the repository root (Portuguese). Section numbers such as "§12.2" refer to `ARQUITETURA.md`.

Evidence labels used throughout:

- Observed: we measured or read it ourselves; the host and date are given.
- Reported: a third party says it; the source is named.
- Inferred: our own calculation or reasoning from other data; the link is explained.
- Hypothesis: to be tested.
- Unknown: nobody has measured it, or the sources do not say.

Almost every performance number here comes from a single run per cell, without confidence intervals. Treat them as orders of magnitude, not as specifications.

## Summary

- **Model.** 320B total parameters, 18B active, 45 layers (34 KDA linear attention, 11 sparse MLA/DSA), 288 routed experts with 8 per token, 1 MTP layer, context of 1,048,576 tokens (Reported, model card and vLLM recipe; layer split Observed in `config.json`).
- **KV cost.** About 8.7 KB per token of MLA KV plus a fixed KDA state of about 0.15 GB per sequence, so about 2.3 GB for a 256K session (Observed on B300, §9.3; corroborated by a Reported 8.3 KB per token in §10.1). The earlier estimate of 1.62 GB per 256K session is superseded. Without DCP, MLA KV is replicated on every TP rank.
- **Replica.** 4 RTX PRO 6000 in TP4 with the `local-inference-lab` vLLM fork (`ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016`) and the checkpoint `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` (177.7 GB). With DCP4 this replica held 23.2 million KV tokens, about 88.7 sessions of 262,144 tokens in HBM (Observed, R1, §12.2).
- **Quality.** The QAD checkpoint on the fork passes the `needle-checksum` probe (3 errors in 500 at concurrency 8 for DCP4; 3 in 620 for DCP1). The NVIDIA NVFP4 PTQ checkpoint failed the same probe on upstream vLLM 0.32.0 on a B300 (108/120) and on SGLang (22 to 60 errors in 500 depending on kernels) (Observed, §12.3, §29.5).
- **Main risks.** The speed comes from fork-only code (B12X kernels, prefill compute share, a forked LMCache with its own DCP). The fork was 409 commits ahead and 3,304 behind vLLM `main` when checked on 2026-11-05 (§13.3), and PCIe P2P configuration on the host changes all-reduce latency by several times (§23, §25.2, §28.2).

## 1. Model architecture

### 1.1 Shape

| Property | Value | Evidence |
|---|---|---|
| Architecture class | `Glm5NextForConditionalGeneration` | Observed, `config.json` (NOTAS.md, "Arquitetura dos modelos") |
| Parameters | 320B total, 18B active | Reported, model card and vLLM recipe (§8.2) |
| Layers | 45: 34 KDA (linear attention) and 11 full-attention layers using sparse MLA with NoPE | Observed in `config.json` (§8.2, NOTAS.md) |
| Position of the 11 full-attention layers | 3, 7, 11, ..., 43 (one every 4) | Observed, `config.json` (NOTAS.md) |
| Experts | 288 routed, 8 per token, 1 shared | Observed, `config.json` (NOTAS.md) |
| Dense leading layers | `first_k_dense_replace=3` | Observed, `config.json` (NOTAS.md) |
| Hidden size | 4096 | Observed, `config.json` (NOTAS.md) |
| Sparse attention top-k | `index_topk=2048` | Observed, `config.json` (NOTAS.md) |
| MTP | 1 layer (layer 45; 1,760 tensors in the real checkpoint) | Observed, `config.json` and checkpoint index (NOTAS.md) |
| Other | Vision tower (24 blocks), `hc_mult=4`, multimodal | Observed, `config.json` (NOTAS.md); Reported, recipe (§8.2) |
| Context length | `max_position_embeddings` = 1,048,576 | Observed, `config.json`; R1 ran with `max-model-len` 1,048,576 (§12.2) |
| Native weights | FP8 (`zai-org/GLM-5.3-Flash`) | Reported, recipe (§8.2) |
| Licence of the base model | MIT | Observed, `LICENSE` at revision `46a050bec13002ad29ee795c16e61cf4fa3c4a9c` (NOTAS.md) |

Attention head size for MLA is `kv_lora_rank + qk_rope_head_dim` = 512 + 0 = 512 (Inferred from the vLLM 0.32.0 backend code and the config, NOTAS.md). On SM120 the upstream vLLM 0.32.0 path is `FLASHINFER_MLA_SPARSE_SM120`, which only accepts `--kv-cache-dtype fp8_ds_mla` (Observed in code and on a Colab RTX PRO 6000, NOTAS.md). Hopper does not support FP8 KV for this model and runs KV in BF16 (Reported, vLLM recipe, §8.2).

### 1.2 KV and state per token

**Current numbers (use these):**

| Item | Value | Evidence |
|---|---|---|
| MLA KV per token, whole model | about 8.7 KB | Observed on 1 B300, vLLM 0.32.0, `nvidia/GLM-5.3-Flash-NVFP4`, 2026-11-05: 39.05 GiB of KV for 4,807,959 tokens (§9.3, correction note in §2) |
| Cross-check | about 8.3 KB per token | Reported by `local-inference-lab/rtx6kpro`: TP2 + DCP2, 7,650,410,496 bytes of KV per GPU for 1,844,162 tokens (§10.1). Agrees with 8.7 KB within 5% (Inferred, §10.1) |
| KDA state per KDA layer | 64 x 128 x 128 x 4 = 4,194,304 bytes (fp32) plus 147,456 bytes of convolution state | Inferred from config geometry; the formula reproduces the "mamba page padding 2.64%" line of the vLLM log (§2) |
| KDA state per sequence (34 layers) | about 148 MB (0.15 GB), constant with context length | Inferred, same calculation (§2) |
| Per 256K session | about 2.3 GB of MLA KV plus 0.15 GB of KDA state | Inferred from the measured 8.7 KB per token (§2 correction) |

The extra KV over the original estimate probably includes the sparse indexer cache (Hypothesis, §2).

**Superseded estimate (do not use):** §2 originally computed 512 bytes per token per full-attention layer and 1.62 GB per 256K session. That table under-counts by about 1.5x and is kept in the source only as history. §3 and §8.3 still quote 1.62 GB in passing; read those mentions as superseded.

### 1.3 What DCP does to KV

- Without DCP, MLA KV is not partitioned by tensor parallelism: each TP rank holds the full KV (Reported by the llm-d GLM-5.2 blog, which measured 598 thousand tokens per node at TP=8 against 1.77 million at DEP8; §2 item 3).
- `--decode-context-parallel-size` (DCP) splits MLA KV across ranks. It exists in upstream vLLM 0.32.0 (Observed, §10.3).
- Measured effect on our replica, same image and checkpoint, 4 RTX PRO 6000 Server Edition on Vast.ai machine 157204, 2026-11-11: DCP4 gave 23.1 million KV tokens, DCP1 gave 6.79 million, a 3.4x difference (Observed, §29.6).
- The trade is speed: DCP1 decoded 6% to 24% faster than DCP4 on the same host (Observed, one run, §29.6). Which DCP setting goes to production is still open (§29.7).

## 2. Hardware

### 2.1 RTX PRO 6000 variants

| Variant | Where we saw it | Notes |
|---|---|---|
| Server Edition | Nebius `gpu-rtx6000-a` (R0, R1, P0 sessions), Vast.ai machines 157204 and 48294, Google Colab G4 | 97,887 MiB, compute capability 12.0 (Observed, Colab, NOTAS.md). On Nebius: 600 W per GPU, memory clock up to 12,481 MHz, no power throttling (Observed, 2026-11-06, NOTAS.md) |
| Workstation | `rtx6kpro` wiki | 300 to 600 W, some runs with memory overclock "+6000" (Reported, §10.4 item 5) |
| Max-Q Workstation | `rtx6kpro` wiki and the reference table we compare against | 325 W, memory at 13,365 MHz, driver 615.71.09 (Reported, §22.2) |

All community performance numbers come from Max-Q or Workstation cards in the authors' own servers. Ours come from the Server Edition. How much of the gap between the two is the card is Unknown (§12.2, §22.2).

AWS `g7e` instances use the same Server Edition GPU (96 GB). List prices in us-east-1 on 2026-11-04: `g7e.24xlarge` (4 GPUs, 96 vCPUs) US$ 16.57/h, `g7e.48xlarge` (8 GPUs, 192 vCPUs) US$ 33.14/h (Observed, AWS Price List API, NOTAS.md). G/VT vCPU quotas were 0 at the time and increase requests were pending (Observed, NOTAS.md). PCIe topology, P2P behaviour and driver version on `g7e` are Unknown: none of the measurements below were taken on AWS.

### 2.2 PCIe topology, P2P and NUMA

| Host | Topology | P2P and all-reduce | Evidence |
|---|---|---|---|
| Nebius 8-GPU VM (`uk-south2`), R1, 2026-11-05 | 2 NUMA nodes with 4 GPUs each (0 to 3, 4 to 7); `NODE` links within a node, `SYS` across nodes; 1,716 GiB RAM. A TP4 on GPUs 0 to 3 stays inside one NUMA node | P2P write about 41 to 42 GB/s, read latency about 2 µs (measured during server start, so a floor; §13.4 later calls this measurement invalid for all-reduce) | Observed (§12.2) |
| Same VM type, P0 session, 2026-11-06, TP4 group (GPUs 0 to 3), idle GPUs | as above | Without the driver P2P override, the B12X custom all-reduce lost to NCCL from 4 KiB: 55.1 vs 21.2 µs at 8 KiB, 131.9 vs 25.7 µs at 32 KiB. With the override it roughly tied NCCL at 8 to 56 KiB (19.8 vs 21.5 µs at 8 KiB) and was 5.7x faster than without it at 32 KiB | Observed, `p2pmark` (§25.2, NOTAS.md 2026-11-06) |
| Vast.ai machine 157204 (Nevada), 2026-11-11 | Asymmetric: GPU0 on NUMA 0, GPUs 1 to 3 on NUMA 1; all traffic with GPU0 crosses sockets (`SYS`) | P2P enabled between all 4 GPUs without any driver override (`nvidia-smi topo -p2p r`); B12X PCIe all-reduce 9.1 to 9.5 µs at 256 B to 2 KiB, against 32.1 to 57.4 µs on the Nebius R1 host | Observed (§28.2) |
| Vast.ai machine 48294 (Texas), 2026-11-12 | Same topology as 157204, links at Gen5 x16 | Same all-reduce backend, but decode was about 5x slower and GPUs drew about 116 W under load. Cause Unknown; Hypothesis: something outside the GPUs, such as another tenant on the 8-GPU host | Observed (§29.10) |

The driver override that fixed the Nebius host is the module parameter line `PeerMappingOverride=1;ForceP2P=0x11;RMForceP2PType=1;RMPcieP2PType=2;GrdmaPciTopoCheckOverride=1;EnableResizableBar=1` (Observed, NOTAS.md 2026-11-06). The `rtx6kpro` wiki explains why: in a `NODE` topology without a PCIe switch, the driver stages GPU-to-GPU accesses inside kernels through system memory by default, and the one-shot all-reduce becomes about 15x slower than NCCL (Reported, `optimization/pcie-oneshot-allreduce.md`, §23.1). The wiki also asks for ACS disabled and IOMMU out of the way, and documents NCCL hangs caused by P2P (Reported, §10.4 item 4).

Operational details that cost us time (Observed, §25.3): the Nebius image already sets `NVreg_RegistryDwords="PeerMappingOverride=1;"`, so the new override must keep that value and live in a file read last (`zz-*.conf`); `nv-hostengine` and `nvidia-persistenced` must be stopped before reloading the driver; modules unload in the order `nvidia_drm`, `nvidia_modeset`, `nvidia_peermem`, `gdrdrv`, `nvidia_uvm`, `nvidia`.

Effect of the override on server decode: Unknown. The P0 server never started in that session (§25.2). The faster decode on Vast machine 157204 (145.6 against 119.8 tok/s at C1) is attributed to the faster all-reduce, Inferred and not isolated (§29.2).

A test before trusting any host: decode at C32 for about 5 minutes after the server is up, and discard the host below 1,400 tok/s with the DCP1 profile; DCP4 gives about 1,280 on a good host (decision in §29.10).

### 2.3 All-reduce backend

The fork used the `B12X_PCIE` all-reduce in `oneshot` mode (maximum 86,016 bytes) on the `tp` group (Observed in the R1 server log, §23.1). Our earlier hypothesis that the custom all-reduce was not being selected was refuted (§12.2).

There is a disagreement in the source about decode all-reduce message sizes: §23.1 says decode sizes with MTP3 fall in 8 to 64 KiB, §25.2 and NOTAS.md say 8 to 56 KiB, and §28.2 calls 256 B to 2 KiB "the decode size". See "Open questions".

Our fork (`paulohenriquevn/vllm`, branch `lab/dev`, commit `66d49ef`) adds a check: it reads `/proc/driver/nvidia/params`, warns with the fix line when `ForceP2P` is missing, and with `VLLM_PCIE_REQUIRE_P2P_OVERRIDE=1` disables the B12X all-reduce and uses NCCL. 12 CPU unit tests pass; it has not run on a real server (Observed, §23.4).

### 2.4 Driver and CUDA compatibility

| Item | Value | Evidence |
|---|---|---|
| Fork image | CUDA 13.4.1, torch 2.14 (`2.14.0a0` from NVIDIA), NCCL 2.30.7, FlashInfer `0.7.1+lil...g6023d031be8e`; expects driver 615.65.02 | Observed, extracted from the image (§25.1) |
| Driver on Nebius GPU VMs | 580.173.02 (Kubernetes node: CUDA 13.0.3) | Observed (§9.3, NOTAS.md) |
| Fork image on driver 580.173 | Works: `torch.cuda.is_available()` true, capability (12, 0), correct BF16 matmul, a Qwen3-0.6B server started and answered, and the full model ran in R1 | Observed, R0 and R1 (§12.1, §12.2) |
| Driver on Vast machine 157204 | 615.71.09 | Observed (§28.2) |
| Driver used by the wiki reference | 615.71.09 | Reported (§22.2) |

Whether driver 580 against 615 contributes to the decode gap is Unknown (§22.5 item 3, §23.1).

### 2.5 Weight loading and cold start

| Run | Storage | Loader | Weights | Time | Evidence |
|---|---|---|---|---|---|
| B300, 2026-11-05 (§9.3) | 500 GiB network disk, about 205 MB/s | vLLM default | 178.48 GiB (NVIDIA NVFP4) | 888 s | Observed |
| R2, B300, 2026-11-05 | disk at 1.9 GB/s | vLLM default | 191.2 GiB model incl. MTP | 829.7 s (about 270 MB/s) plus 57.9 s for the MTP head | Observed (§12.1, §12.3) |
| R1, 8 RTX, 2026-11-05 | NRD disk of 1,767 GiB, about 1.9 GB/s | `--load-format instanttensor` (fork) | 165 GiB (QAD) | 134.5 s (about 1.4 GB/s) | Observed (§12.1, §12.2) |
| `rtx6kpro` wiki | populated Hugging Face cache | `instanttensor` | 177 GB | 39 s | Reported (§10.1) |

Two causes were behind the slow loads: small disks and the default loader. On Nebius, network disk bandwidth grows with provisioned size: a 200 GiB `NETWORK_SSD` boot disk read at 104 MiB/s, a 1,767 GiB NRD at 1,923 MiB/s, a 1,860 GiB IO M3 at 2,075 to 2,115 MiB/s (Observed, `fio`, §12.1). The measured fix is a large disk plus `--load-format instanttensor` (§12.1). `instanttensor` and `ipc_cache` also exist in upstream vLLM 0.32.0 (Observed in `vllm/config/load.py`, §10.3).

Cold start times (Observed unless stated):

| Case | Time | Source |
|---|---|---|
| R1 server, first start, 8 RTX on Nebius | 15 min total: 134 s weights, about 9 min B12X JIT compilation | §12.2 |
| New Nebius VM to ready | 21 to 23 min | §22.2 |
| B300 upstream, no MTP | about 23 min (load plus about 2 min kernel warm-up) | §9.3 |
| B300 upstream, MTP3 | about 25 min (incl. about 4 min FlashInfer autotune) | §12.3 |
| Vast 157204, cold kernel cache | 511 s | §29.1 |
| Vast 157204, warm kernel cache | 201 s | §29.1 |
| Vast 48294 (degraded host) | 1,084 s against 260 s on 157204 | §29.10 |
| Fork image pull | 7 min 30 s; 12.9 GB compressed, 30.6 GB uncompressed (44.5 GB in containerd) | §12.1, NOTAS.md |

The image pull took the same time with Docker's `data-root` on the 1.9 GB/s disk, about 29 MB/s over 12.9 GB, so the bottleneck is the registry, decompression or layer concurrency, not the disk (Observed, §17.2). The JIT cache under `/cache` should make later starts faster if persisted; we destroyed the disk before measuring a second start (§13.4, P3). Checkpoint download ran at about 1 GB/s on Nebius and about 10.5 Gbit/s on Vast machine 157204 (Observed, §25.4, §28.2).

Target N5 (Hypothesis): new VM to first token in 12 min or less (§22.4).

## 3. Checkpoints

### 3.1 Candidates

Sizes are the sum of `.safetensors` files from the Hugging Face API (Observed, §8.3, §10.5, NOTAS.md). Fit is weights only, before activations, CUDA graphs and KV (Inferred by subtraction, §8.3).

| Checkpoint | Size | Fits 2 RTX (192 GB) | Fits 4 RTX (384 GB) | Fits 1 B300 (288 GB) | Licence | Quality evidence |
|---|---|---|---|---|---|---|
| `zai-org/GLM-5.3-Flash` (FP8) | 328.3 GB | no | yes, 56 GB left | no | MIT | SGLang FP8 needle 4/240 at C8 and 0/240 at C16, same as the vLLM fork reference (p = 0.72) (Observed, §29.5) |
| `nvidia/GLM-5.3-Flash-NVFP4` (PTQ, ModelOpt) | 204.4 GB | no | yes | yes, 84 GB left | MIT | **Failed** the needle probe on upstream vLLM (B300) and SGLang (§3.3) |
| `RedHatAI/GLM-5.3-Flash-NVFP4` | 197.8 GB | no | yes | yes, 90 GB left | Unknown | None |
| `ormandj/...W4A16-NVFP4-K32-Experts-FP8-WO` (Helix) | 178.0 GB | yes, about 7 GB per GPU left | yes | yes | Unknown | None of ours |
| `local-inference-lab/GLM-5.3-Flash-NVFP4` | 199.4 GB | no (Inferred) | yes; TP4 profile | not stated | MIT | AA-LCR 74.00% (Reported, §10.1) |
| `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` | 187.7 GB | yes: 93.8 GB per GPU, about 4 to 7 GiB of KV left | yes | not stated | not stated in the source | None of ours |
| `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` | 177.7 GB | yes (`glm53-tp2` preset) | yes | not stated | "other" on the Hugging Face API | Passes (§3.2) |
| `nvidia/GLM-5.3-Flash-FP4-Local` | 177.5 GB | not stated | not stated | not stated | "other" | None; card not read (NOTAS.md) |

With the official NVIDIA or RedHat checkpoints, the minimum RTX unit is TP4 (Inferred, §8.3). A related artefact, the DFlash2 drafter, is CC BY-NC-ND 4.0, non-commercial (Reported, §10.4 item 6). One `rtx6kpro` page says the checkpoint download is "about 60 GB", which contradicts the API totals; we trust the API (Observed, §10.4 item 7).

What the NVIDIA NVFP4 quantizes: routed experts and the dense MLPs of the first layers, in groups of 16, weights and activations in FP4, KV in static FP8. Excluded from quantization (134 entries): `lm_head`, `embed_tokens`, all `self_attn*` including KDA, the `mlp.gate` routers, `shared_experts*`, the vision tower and the MTP layer (Observed, `quantization_config`, NOTAS.md).

### 3.2 Quality evidence for the QAD checkpoint on the fork

| Test | Result | Host and date | Evidence |
|---|---|---|---|
| `needle-checksum`, 8K prompt, temperature 0 | 120/120 EXACT at concurrency 8 | Nebius 8 RTX, R1, 2026-11-05 | Observed (§12.2) |
| `gsm8k`, 96 problems | 94/96 | same | Observed (§12.2) |
| needle, DCP4, 500 runs at C8 | 3 errors in 500; 0 in 120 at C16 | Vast 157204, 2026-11-11 | Observed (§29.5, §29.6) |
| needle, DCP1 | 3/120 at C8 (157204), then 500/500 at C8 and 120/120 at C16 (48294); total 3 in 620 at C8 | Vast, 2026-11-11 and 2026-11-12 | Observed (§29.6, §29.10) |
| `gsm8k` | 94/96 to 96/96 on 157204; 96/96 on 48294 (§29.10 says 99%; the raw `gsm8k.json` says 96/96) | Vast | Observed (§29.4, §29.10) |
| AA-LCR (100 questions, 3 answers each, GPT-5.6 judge) | QAD 73.00%, published NVFP4 74.00%, BF16 71.67%; no statistical difference (McNemar p above 0.40) | `rtx6kpro` | Reported (§10.1) |
| Behavioural fidelity, 7,168 tasks | equivalent within 1 point | `rtx6kpro` | Reported (§10.1) |
| aider polyglot, 5 runs | pass@2 88.0 ± 1.1% | `rtx6kpro`, for their checkpoints | Reported (§10.1) |
| Needle reference table, vLLM b12x, 500 requests per cell | 0% errors with W4A16, 6% to 9% with W4A4, 18% to 23% with a pre-QAD checkpoint | `llm-inference-bench` README | Reported (§29.4) |

Our fork configuration runs the MoE as W4A16 with `B12X_W4A16_FP32_TOPK_WEIGHTS=1`, the 0% row of that table (Observed, §29.4). The "3330 instead of 3332" answer is the model's known last-digit slip on a near tie, and the probe is an alarm for numerical changes such as MoE activation precision (Reported, `llm-inference-bench` README, §29.4). A kernel bug in the B12X NVFP4 prefill (R33, missing SwiGLU clamp, fixed in R35) passed through several releases, and W4A4 showed 5.9% wrong answers against 0 of 500 with 16-bit activations (Reported, §10.4 item 1).

Acceptance rule in force (decided 2026-11-12, §29.5): `needle-checksum` with 500 runs at concurrency 8, compared with the vLLM DCP4 reference (3 errors in 500) by a one-sided Fisher exact test; a configuration fails if it errs more than the reference with p < 0.05. This replaces the earlier 120/120 rule (§22.3, §27.4), which cannot separate two good configurations.

### 3.3 Why not the NVIDIA NVFP4 checkpoint

| Stack | Needle result | Evidence |
|---|---|---|
| Upstream vLLM 0.32.0, 1 B300, MTP3, `--max-num-batched-tokens 4096`, snapshot `1d00738646...`, 2026-11-05 | 108 EXACT and 12 NEAR_MISS (checksum 3330) in 120, 90.0%; Wilson 95% interval about 5.8% to 16.7% error | Observed (§12.3, §9.3) |
| SGLang, ormandj v0.5.0 profile, revision `09b04e5e` (no QAD), C8 / C16 | 94/120 and 99/120; without speculative decoding 109/120 and 104/120 | Observed, Vast 157204, 2026-11-11 (§29.4) |
| SGLang, revision `1d00738` (NVIDIA calibration fix of 28 Oct), MoE W4A4 | 60 errors in 500 at C8, 19 in 120 at C16; p = 2·10⁻¹⁵ against vLLM | Observed (§29.5) |
| Same, MoE on Marlin (W4A16) | 32 in 500, 5 in 120; p = 3·10⁻⁷ | Observed (§29.5) |
| Same, Marlin, no speculative decoding, SSM state in FP32 | 22 in 500, 10 in 120; p = 1·10⁻⁴ | Observed (§29.5) |

Reading:

- On the B300 the cause could not be attributed: checkpoint, kernel path and MTP all changed at once (§12.3).
- In SGLang, MoE activation quantization explains about half of the remaining error (Marlin vs W4A4, p = 0.003); speculative decoding and SSM state dtype had no measurable effect (p = 0.21) (Observed, §29.5).
- The residual comes from the NVFP4 weights without QAD (Inferred, §29.5): with the original FP8 weights SGLang matched vLLM.
- Open bugs #48919, #48931 and #48907 do not apply to this checkpoint (Observed by reading the checkpoint), and #49309 does not explain the residual, which persists without speculation (§29.5).
- We decided not to open an issue against the NVIDIA checkpoint: this is expected PTQ behaviour, and we only tested it in SGLang and upstream vLLM on B300, not in the engine NVIDIA validated it for (§29.9).

### 3.4 Why the QAD checkpoint

- It passes the quality rule on the fork (§3.2).
- It fits a TP4 replica with room for KV: on Vast 157204, weights took 42.2 GiB per GPU and KV got 45.9 GiB per GPU (Observed in logs, §29.2).
- The engine decision (vLLM fork) depends on it: its scales use the CSF format, which SGLang cannot read. SGLang PRs #46153 and #41624 add CSF support but were written and tested for Qwen (Reported, §29.5). No 4-bit checkpoint that SGLang loads today reaches vLLM's quality (§29.5).
- Pinned revision used in R1: `dec48abd33efa73c3bb7c95b74eee10cad34f9be` (Observed, §12.2).
- Open risk: the licence is "other" on the Hugging Face API and must be read before production (§10.4 item 6, §13.3 condition 4).

## 4. Performance

All runs below use the `llm-inference-bench` harness (`llm_decode_bench.py` 0.8.0, commit `52216d70865a015b34689626d04a80b89c9dc45f`), `plain` mode, one run per cell, unless stated. With MTP, our `pd_bench` counts streaming chunks of about 2.6 tokens; its per-step numbers are divided by 2.6 to get per-token numbers (§12.2).

### 4.1 R1: 4 RTX PRO 6000 Server Edition, fork, QAD, TP4 + DCP4 + MTP3

Host: Nebius `gpu-rtx6000-a` 8-GPU VM, on demand at US$ 14.40/h, GPUs 0 to 3, NRD disk of 1,767 GiB, command printed by the image (`print-command-glm53-tp4-dcp4-mtp3.sh`) with `NCCL_NET_PLUGIN=none` and `HF_HUB_OFFLINE=1`. Date 2026-11-05. Driver P2P override **not** active. Results in the results archive: `f3/resultados/rtx-20261105/`. Observed (§12.2).

| Item | Value |
|---|---|
| KV budget | 23,249,576 tokens, 88.7 sessions of 262,144 tokens; 32 concurrent slots (default profile) |
| MTP acceptance | 2.5 to 2.7 tokens per step |

Decode, aggregate tok/s:

| Context | 1 stream | 8 streams | 32 streams |
|---|---|---|---|
| 0 | 119.8 | 585.0 | 1,425.5 |
| 32K | 123.6 | 631.0 | 1,440.7 |
| 128K | 120.8 | 624.9 | 1,423.3 |

Decode is flat from 0 to 128K context (sparse attention).

| Prefill and mixed load | Value |
|---|---|
| Cold prefill, harness | 10,180 tok/s at 32K (TTFT 3.17 s); 10,289 tok/s at 128K (TTFT 12.5 s); Prometheus: 10,297 tok/s |
| Cold 256K, `pd_bench` | TTFT 25.2 s (10,381 tok/s); repeated 128K from cache: 0.14 s |
| Prefill with active decode | falls to about 4.1 thousand tok/s, 40% of 10.3 thousand, matching the fork's `--prefill-compute-share 0.4` with `--max-parallel-prefills 1` |
| 8 x 128K requests together | TTFT p50 63 s (p95 101 s); decode protected at 39.6 ms per step, about 15 ms per token |
| 8K prompts at concurrency 16 / 32 | TTFT p50 26 s / 56 s (single prefill lane) |

Gap to the community: single-stream decode was about half of what `rtx6kpro` reports for the same configuration (119.8 vs 238 tok/s; 46 vs 97.5 steps per second), and prefill was 78% (10.2 vs 13.1 thousand tok/s). Cause Unknown (§12.2). Leading hypothesis: the P2P override on the Nebius host (§2.2, §23.1). Community TP2 prefill (Max-Q, 325 W) of 10,254 to 10,620 tok/s is in the same range as our TP4 prefill, which weakens the idea that we are losing prefill (Reported, §23.3).

### 4.2 Later runs on Vast.ai (same image, checkpoint and harness)

4 RTX PRO 6000 Server Edition, machine 157204, Nevada, driver 615.71.09, US$ 5.61/h, 2026-11-11. Results in `f3/resultados/vast-20261111/`. Observed (§29.1, §29.6).

| vLLM fork | DCP4, run 1 | DCP4, run 2 | DCP1 |
|---|---|---|---|
| KV tokens | 23.1 million | 23.1 million | 6.79 million |
| Decode C1 / C8 / C16 / C32 (tok/s) | 146 / 599 / 910 / 1,279 | 139 / 586 / 923 / 1,288 | 154 / 696 / 1,073 / 1,580 |
| 16 agents: TTFT p95, tok/s p50 per stream | 4.77 s, 57.2 (pass) | 5.20 s, 57.8 (fail) | 4.71 s, 70.8 (pass) |
| 24 agents | not measured | 5.97 s, 47.1 (fail) | 4.93 s, 55.3 (pass) |

Prefill TTFT (DCP4): 1.07 s at 8K, 3.90 s at 32K, 15.99 s at 128K (§29.1). The SLO used is TPOT p50 of 30 tok/s per stream and TTFT p95 of 5 s on cached turns (§26.4). The DCP1 speed result needs a second run on a healthy host; the run on machine 48294 is not valid for speed (§29.10).

### 4.3 R2: 1 B300, upstream vLLM 0.32.0, NVIDIA NVFP4, MTP3, batch 4096

Host: Nebius `gpu-b300-sxm`, 1 GPU, preemptible in `us-north1` (US$ 9.00/h at the time), 2026-11-05. Flags: `--max-model-len 262144 --kv-cache-dtype fp8 --gpu-memory-utilization 0.85 --max-num-seqs 64 --enable-prefix-caching --max-num-batched-tokens 4096 --speculative-config '{"method":"mtp","num_speculative_tokens":3}'`. Results in `f3/resultados/b300-20261105/`. Observed (§12.3).

| Item | Value |
|---|---|
| KV with MTP | 27.42 GiB, 2,717,737 tokens, 10.37 sessions at 262,144 (18.34 without MTP: MTP and graphs cost 43% of KV) |
| Decode C1 / C8 / C32 at context 0 | 226.3 / 913.6 / 2,304.6 tok/s; 32 streams at 128K did not fit |
| Cold prefill | 9,972 tok/s at 32K; 26,270 tok/s at 128K (TTFT 4.91 s); 256K TTFT 10.1 s |
| 8 x 128K together | TTFT p50 24.5 s (p95 41 s), about 55 ms per token |
| Needle | 108/120, failed |

The earlier B300 run without MTP (§9.3, 2026-11-05) gave 7.0 ms TPOT at one stream (about 143 tok/s), 33 to 36 thousand tok/s cold prefill from 8K to 260K, and 247 ms TPOT with 8 x 128K requests.

### 4.4 Side by side (§12.4)

Configurations differ in engine, kernels, checkpoint and MTP. This compares configurations, not GPUs.

| Measure | 4 RTX (fork, QAD, TP4 + DCP4 + MTP3) | 1 B300 (upstream, NVIDIA NVFP4, MTP3) |
|---|---|---|
| Price per hour | US$ 7.20 on demand (half of the 8-GPU VM); US$ 3.16 spot (no capacity) | US$ 9.00 spot; US$ 9.50 list |
| KV tokens | 23.2 million | 2.7 million (4.8 without MTP) |
| 262,144-token sessions in HBM | 88.7 | 10.4 (18.3 without MTP) |
| Sessions per US$/h | 12.3 | 1.15 (2.04 without MTP) |
| Decode, 1 / 8 / 32 streams | 119.8 / 585 to 631 / 1,423 to 1,441 | 226.3 / 914 to 958 / 2,305 to 2,319 |
| Cold prefill 128K | 10,289 tok/s, TTFT 12.5 s | 26,270 tok/s, TTFT 4.9 s |
| Cold prefill 256K | TTFT 25.2 s | TTFT 10.1 s |
| 8 x 128K interference | TTFT p50 63 s, about 15 ms per token | TTFT p50 24.5 s, about 55 ms per token |
| Weights | 134 s (`instanttensor`) | 830 s (default loader) |
| Server start | 15 min (first, with JIT) | 25 min |
| `needle-checksum` | 120/120 | 108/120 |

Inferred cost per million tokens at full utilisation, no SLO (§12.4): cold prefill US$ 0.194 (RTX list) against US$ 0.095 (B300 spot); decode at 32 streams US$ 1.40 (RTX list) against US$ 1.08 (B300 spot). The RTX spot column in the source does not exist in practice: the 8-GPU RTX VM had no preemptible capacity.

The platform decision is RTX PRO 6000, with the goal of efficiency on RTX, not parity with B200 or B300 (decision of 2026-11-11, §26.4). The B300 is a measurement reference.

## 5. What the fork has that upstream vLLM lacks

Fork: `local-inference-lab` vLLM, image `karmic-kraken-20261016`, vLLM commit `8244d1c44348ae8a5bbfc9f1b607021652283ed4` (branch `dev/karmic-kraken`). Our copy: `paulohenriquevn/vllm`, tag and branch `baseline-rtx-20261105`, working branch `lab/dev` (Observed, §22.1).

| Feature | In upstream vLLM 0.32.0? | Notes | Evidence |
|---|---|---|---|
| B12X kernels: attention, MoE, dense, KDA, PCIe all-reduce | No | The likely source of SM120 speed. Need the fork image. The `local-inference-lab/b12x` repository is archived and moved into FlashInfer (§22.1) | Observed absence in upstream (§10.3) |
| `--prefill-compute-share`, `--max-parallel-prefills`, `--prefill-schedule-interval` | No (0 hits in `vllm/config/scheduler.py` of v0.32.0) | Reserves a share of compute for prefill when decode is active, with one prefill lane. Measured effect in R1: prefill at 40% under decode, decode protected | Observed (§10.3, §12.2) |
| LMCache fork with its own DCP | Separate process | LMCache `0.5.3.dev453+lil...g8ef537d6481b` (2026-10-11). Implements DCP itself (`dcp_size`, per-rank fragments, `_get_dcp_rank`). History diverges from upstream LMCache: only PR #4679 is an ancestor; #4834, #4936, #5042, #5076 and #5307 are not. Has `BlockStored` but no `BlockRemoved` event | Observed, extracted from image (§25.1) |
| KDA path | Different file | On CUDA the fork loads `vllm/models/glm5next/nvidia/kda.py` (Kimi-K3 base, B12X, `B12XKDARecoverSSMCommitContext`), which does not exist in v0.33.0. FlashKDA built with an SM120 patch; R1 ran with `"kda_prefill_backend":"b12x"` | Observed (§26.5) |
| `--print-command` | Image only | Prints the full `docker run`. Worth copying for reproducibility | Reported (§10.3) |
| Change log | 129 items in `.lil/changes/` | 77 fixes, 25 features, 15 performance, 6 internal, 6 compatibility; includes #931 (fix for #726) | Observed at `8244d1c` (§23.3) |

Features we use that upstream also has: MTP, DCP, `--max-num-batched-tokens`, `--load-format instanttensor` and `ipc_cache` (Observed, §10.3). Use `num_speculative_tokens` 3: the wiki reports `illegal memory access` under high concurrency above 3 (Reported, §10.1). Upstream 0.32.0 names the autotune flag `--no-enable-flashinfer-autotune`; the vLLM recipe's `--disable-flashinfer-autotune` was rejected (Observed, §9.3 correction, §10.1).

Fork switches not yet explored (from `.lil/changes/`, §23.3): `VLLM_B12X_BF16_GEMV=1` (#873, decode), `VLLM_SCHEDULER_UNCAP_PREFILL_ONLY_STEPS=1` (#880, prefill), `VLLM_GLM53_KDA_MXFP8_ACTIVATION_MODE=a16` (KDA MXFP8 with BF16 activation; Reported long-context quality 79.6% against 76.5% at 516K), and a prefill work limit under decode (#862, parameter name Unknown).

## 6. Maintenance risk

| Risk | Data | Evidence |
|---|---|---|
| Distance from upstream | `8244d1c443` was 409 commits ahead and 3,304 behind vLLM `main` (2026-11-05); 3,222 behind upstream in a later count (§22.1); forked from upstream at `0f8fa53` (2026-09-16) and 2,439 behind the `v0.33.0` tag (§26.5). Over 300 files changed | Observed, GitHub API and `git` (§13.3, §22.1, §26.5) |
| Maintainers | Volunteer community; 316 open issues on the vLLM fork, 128 on B12X | Observed (§13.3) |
| Hardware lock-in | B12X kernels target SM120; moving to another GPU loses the gain. Fork binaries list arch 10.0 in `CUDA_ARCH_LIST`, but the fork was never tested on a B300 | Observed (§13.3, §13.2) |
| Rebuild | `blackwell-llm-docker` has dozens of long Dockerfiles (CUDA 13.3 and 13.4, FlashInfer wheels) and documents build OOMs; no licence declared | Observed (§13.3) |
| Licences | vLLM fork, LMCache, FlashInfer, InstantTensor, `lil`: Apache-2.0. `nccl-canonical`: "other". `rtx6kpro`, `llm-inference-bench`, `blackwell-llm-docker`: none declared. QAD checkpoint: "other" | Observed (§13.3, §22.1) |
| Speed below reports | Decode C1 about half of the wiki on Nebius (cause Unknown) | Observed (§12.2) |
| Porting upstream features | Porting FlashState would mean redoing about 5 thousand lines in the scheduler and cache manager, the files where the fork diverges most; estimate of weeks is a Hypothesis | Observed diff sizes, Hypothesis on effort (§26.5) |
| LMCache events | The image's LMCache predates upstream PR #5307 (`BlockRemoved` for the CPU tier); whether it works with GLM-5.3-Flash recurrent checkpoints and DCP is a Hypothesis | Inferred and Reported (§25.1) |

Conditions set for using the fork (§13.3): pin the image by digest, the vLLM commit (`8244d1c443`) and the checkpoint revision (`dec48abd…`) and mirror the image in our own registry, never the moving tag `karmic-kraken-beta`; rebuild the image once from its source lock on a CPU VM; run the harness matrix and `needle-checksum` on every change of image, checkpoint or flag; clarify the image repository and QAD checkpoint licences before production.

Every fork update is a rebase plus requalification through the quality gate (§22.1, §22.3).

## Open questions

1. **Cause of the decode gap on Nebius.** 119.8 tok/s at C1 against about 238 reported. The P2P override fixed the microbenchmark (§25.2) but its effect on server decode was never measured. Driver 580 against 615 and Server Edition clocks are untested.
2. **AWS `g7e` hosts.** PCIe topology, NUMA layout, P2P state without overrides, driver version and whether we can set NVIDIA module parameters on the node are all Unknown. The Vast.ai results show identical-looking 4-GPU hosts differing by 5x (§29.10).
3. **Decode all-reduce message size.** §23.1 says 8 to 64 KiB, §25.2 says 8 to 56 KiB, §28.2 says 256 B to 2 KiB. Which is right decides which `p2pmark` row predicts decode.
4. **DCP1 or DCP4.** DCP1 decoded faster and passed 24 agents in one run; DCP4 holds 3.4x more KV. The second DCP1 speed run and the LMCache test with 24 active agents are pending (§29.9).
5. **Second server start time.** With the B12X JIT cache persisted, is a restart below 5 minutes (§13.4 P3)? Not measured on Nebius; 201 s with warm cache on Vast.
6. **QAD checkpoint licence ("other")** and the licences of `blackwell-llm-docker`, `rtx6kpro` and `llm-inference-bench`.
7. **KV per token on the fork.** Measured on B300 upstream (8.7 KB) and reported by the wiki (8.3 KB). R1 logs give 23.2 million tokens; the per-token figure on our fork was not computed in the sources. Session size in the sources varies between 2.2, 2.28 and 2.3 GB for 256K.
8. **Image rebuild from source.** Not yet done; until then the image is a black box (§13.3 condition 2).
9. **Long-context quality.** No quality test beyond the 8K needle and `gsm8k` ran on our stack. AA-LCR and the 516K numbers are Reported only.
