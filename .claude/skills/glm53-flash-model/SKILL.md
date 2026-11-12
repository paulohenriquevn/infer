---
name: glm53-flash-model
description: Use when you reason about GLM-5.3-Flash itself, for example KV or session memory math, what TP and DCP do to KV, choosing, pinning or swapping a checkpoint, any quantization change (NVFP4, MXFP8, W4A4, W4A16, QAD, PTQ), the MTP speculative token count, or reading a needle-checksum result (3330 instead of 3332). Triggers include docs/02-model-hardware-and-checkpoints.md, checkpoint names under local-inference-lab/, nvidia/ or zai-org/ for GLM-5.3-Flash, and the words KDA, MLA, DSA, QAD, needle, last-digit slip.
---

# GLM-5.3-Flash: the model, its memory and its checkpoints

Facts about the model that every serving, capacity or quality decision in this project depends on. The serving engine and its flags are in the `vllm-fork-serving` skill.

Evidence labels: **Observed** (we measured or read it; path given), **Reported** (a named source says it), **Inferred** (derived; the link is given), **Hypothesis** (to test), **Unknown** (no source has it). Section marks such as §29.5 point to `ARQUITETURA.md`, the Portuguese working journal. The journal and `NOTAS.md` live outside this repository. The harness is in `bench/` of this repository; raw results are cited as `results archive: f3/resultados/...`, a path inside the published results archive. When the journal contradicts itself, later sections and "Correção posterior" notes win, and `docs/README.md` lists the known contradictions with their current values.

Almost every number here comes from one run per cell, without confidence intervals. Read them as orders of magnitude.

## When to use

- You need KV or memory per session, per token or per replica (capacity, fleet size, LMCache sizing, router admission).
- You are about to change the checkpoint, its revision, the quantization of any part of the model, or the MoE activation precision.
- You are about to change `num_speculative_tokens` or anything about MTP.
- A needle-checksum or gsm8k result came back and you must decide whether it is a regression.
- Someone proposes a new checkpoint, a new engine or a new GPU and claims "same quality".

## Files in this skill

Read SKILL.md first. Open the others when the task needs the detail.

| File | Read it when |
|---|---|
| [`references/architecture.md`](references/architecture.md) | You need the layer map, the config fields, or the full KV and KDA derivation, including why DCP4 gives 3.4 times the tokens of DCP1 |
| [`references/checkpoints-and-quantization.md`](references/checkpoints-and-quantization.md) | You compare or swap a checkpoint, read a `quantization_config`, or need a model card digest or the QAD licence terms |
| [`references/quality-alarm.md`](references/quality-alarm.md) | You run or read the needle-checksum or gsm8k gate, or need every past result with its path |
| [`examples/needle-pass-and-fail.md`](examples/needle-pass-and-fail.md) | You want to see what a passing (497/500) and a failing (440/500) `needle.json` look like |
| [`examples/gsm8k-excerpt.md`](examples/gsm8k-excerpt.md) | You read a `gsm8k.json` and need to know which fields matter |
| [`examples/kv-per-session-calculation.md`](examples/kv-per-session-calculation.md) | You size sessions, replicas or LMCache and want the arithmetic step by step |
| [`examples/kv-log-lines-dcp1-dcp4.md`](examples/kv-log-lines-dcp1-dcp4.md) | You check a server's KV budget after startup or compare DCP1 with DCP4 |

## Model shape (reference)

| Property | Value | Evidence |
|---|---|---|
| Class | `Glm5NextForConditionalGeneration` | Observed, `config.json` (NOTAS.md) |
| Parameters | 320B total, 18B active | Reported, model card and vLLM recipe (§8.2) |
| Layers | 45: 34 KDA (linear attention) and 11 full-attention layers with sparse MLA (DSA) and NoPE | Observed, `config.json` (§8.2) |
| Full-attention positions | 3, 7, 11, ..., 43 (one in every 4) | Observed, `config.json` |
| MoE | 288 routed experts, 8 per token, 1 shared; `first_k_dense_replace=3` | Observed, `config.json` |
| Hidden size, sparse top-k | 4096; `index_topk=2048` | Observed, `config.json` |
| MTP | 1 layer (layer 45, 1,760 tensors in the checkpoint) | Observed, `config.json` and checkpoint index |
| Other | vision tower (24 blocks), `hc_mult=4`, multimodal | Observed, `config.json`; Reported, recipe |
| Context | `max_position_embeddings` 1,048,576; our server runs `--max-model-len 1048576` | Observed |
| Native weights | FP8 (`zai-org/GLM-5.3-Flash`) | Reported, recipe (§8.2) |
| Base licence | MIT, at revision `46a050bec13002ad29ee795c16e61cf4fa3c4a9c` | Observed, `LICENSE` |
| MLA head size | `kv_lora_rank + qk_rope_head_dim` = 512 + 0 = 512 | Inferred from vLLM 0.32.0 code and config |

## Decisions and why

### 1. Size KV at 8.7 KB per token plus 0.15 GB of KDA state per sequence

- **Rule.** MLA KV is about 8.7 KB per token for the whole model. KDA state is about 148 MB per sequence and does not grow with context. A 256K session is about 2.3 GB of MLA KV plus 0.15 GB of KDA state.
- **Why.** Observed on 1 B300, upstream vLLM 0.32.0, `nvidia/GLM-5.3-Flash-NVFP4`, 2026-11-05: 39.05 GiB of KV for 4,807,959 tokens (§9.3 and the correction note at the top of §2). Cross-check: `local-inference-lab/rtx6kpro` reports 7,650,410,496 bytes of KV per GPU for 1,844,162 tokens at TP2 + DCP2, about 8.3 KB per token, within 5% (Reported, §10.1).
- **KDA state.** Per KDA layer 64 x 128 x 128 x 4 = 4,194,304 bytes (fp32) plus 147,456 bytes of convolution state; times 34 layers gives about 148 MB (Inferred from config geometry; the formula reproduces the "mamba page padding 2.64%" line of the vLLM log, §2).
- **Superseded.** The first estimate in §2 (512 bytes per token per full-attention layer, 1.62 GB per 256K session) under-counts by about 1.5x. §3 and §8.3 still quote 1.62 GB; treat those as history. Other places give 2.2 GB (§10.1) and 2.28 GB (§13.2) for 256K; they come from the 8.3 KB figure and rounding.
- **Hypothesis.** The extra KV over the first estimate is the sparse indexer cache (§2).
- **On the fork stack** (Inferred from the log line `shared-pool max-request cost ... to 7582924800 bytes` divided by 1,048,576): 7,232 B per token on each GPU with DCP1, 2,128 B per GPU with DCP4, about 8.5 KB per token across the replica. That agrees with 8.7 KB within 3%, so the planning rule stands. Derivation: `references/architecture.md`; log lines: `examples/kv-log-lines-dcp1-dcp4.md`.

### 2. Under TP, MLA KV is replicated unless DCP splits it

- **Rule.** Without decode context parallelism, every TP rank holds the full MLA KV. Never compute capacity by adding the HBM of the 4 GPUs as if it were one pool.
- **Why.** Reported by the llm-d GLM-5.2 blog: TP=8 held 598 thousand tokens per node against 1.77 million at DEP8 (§2 item 3). An external proposal that summed the 4 GPUs as one memory was rejected for this reason (§29.7).
- **What DCP changes.** `--decode-context-parallel-size` splits MLA KV across ranks (exists in upstream vLLM 0.32.0, Observed in code, §10.3). On the same host, image and checkpoint (Vast.ai machine 157204, 2026-11-11), DCP4 gave 23.1 million KV tokens and DCP1 gave 6.79 million, 3.4 times less (Observed, §29.6; server log lines `GPU KV cache size: 22,954,769 tokens` and `GPU KV cache size: 6,789,052 tokens` in `f3/resultados/vast-20261111/vllm/`).
- **The price of DCP.** DCP1 decoded 6% to 24% faster than DCP4 on the same host (Observed, one run, §29.6). Which one goes to production is open; see the `vllm-fork-serving` skill.
- **Why 3.4 and not 4** (Inferred): solving the two max-request costs gives about 6.8 KB per token that DCP splits and about 430 B per token (448 MB per 1M-token request) that every rank keeps. What that unsplit part is remains Unknown (`references/architecture.md`).
- **Inferred capacity hint.** With DCP1, 6.8 million tokens hold about 60 active sessions of 100 thousand tokens, more than the 24 that the SLO allowed (§29.8). Speed, not KV, set the DCP1 limit in that run.

### 3. Use the QAD checkpoint `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be`

- **It passes the quality gate on the fork.** needle-checksum 3 errors in 500 at concurrency 8 with DCP4 (the reference), 3 in 620 with DCP1, 0 in 120 at concurrency 16; gsm8k 94/96 to 96/96 on host 157204 (DCP4 runs 94/96 and 96/96, DCP1 95/96) and 96/96 on host 48294 (Observed in `gsm8k.json`; §29.10 says 99%, the raw file says 96/96). First run on Nebius R1: 120/120 and 94/96 (Observed, §12.2).
- **It fits a TP4 replica with room for KV.** Weights 42.2 GiB per GPU, KV 45.9 GiB per GPU on host 157204 (Observed in logs, §29.2; log line `Model loading took 42.2 GiB memory`). Total size 177.7 GB (Observed, Hugging Face API).
- **Third-party quality data.** AA-LCR (100 questions, 3 answers each, GPT-5.6 judge): QAD 73.00%, their published NVFP4 74.00%, BF16 71.67%, no statistical difference (McNemar p above 0.40); behavioural fidelity on 7,168 tasks within 1 point; aider polyglot pass@2 88.0 ± 1.1% over 5 runs (Reported, `rtx6kpro`, §10.1). These cover their checkpoints only.
- **The engine choice depends on it.** Its scales use the CSF format, which SGLang cannot read. SGLang PRs #46153 and #41624 add CSF support but were written and tested for Qwen (Observed in the PRs, §29.5). No 4-bit checkpoint that SGLang loads reached the fork's quality (§29.5).
- **Pin the revision.** R1 and every Vast run used `dec48abd33efa73c3bb7c95b74eee10cad34f9be` (Observed, §12.2 and server logs). A new revision is a new checkpoint for the gate.
- **Licence** (Reported, `LICENSE` in the repository, read 2026-11-12): `lil-license-1.0` is Apache 2.0 plus added terms. It forbids any reupload of the weights or of a re-sharded or re-quantized copy (section 2.1), allows private copies and running an inference service as long as the files are not made available to users (sections 2.2(b) and 2.2(d)), and ends the licence at once on breach. Keep the weights in storage only we control; get the terms reviewed before production (§10.4 item 6, §13.3 condition 4). Digest: `references/checkpoints-and-quantization.md`.

### 4. Keep MoE activations in 16 bits (W4A16)

- **Rule.** Decode runs the MoE as W4A16. The launch scripts set `B12X_W4A16_FP32_TOPK_WEIGHTS=1` and `VLLM_B12X_MOE_FP4_FORCE_A16=1` (Observed in `bench/server-vllm-direct.sh`).
- **Why.** The `llm-inference-bench` README reference table (vLLM b12x, 500 requests per cell) gives 0% needle errors with W4A16, 6% to 9% with W4A4 and 18% to 23% with a pre-QAD checkpoint (Reported, §29.4). On our host, SGLang with the NVIDIA NVFP4 checkpoint erred 60 in 500 with W4A4 MoE and 32 in 500 with Marlin W4A16; the difference is significant (p = 0.003), so activation quantization explains about half of that error (Observed, §29.5).
- **Cost.** 16-bit activations cost 10% to 11% of prefill in the fork's R33 measurement (Reported, §10.4 item 1).
- **Unknown.** The scripts also set `B12X_W4A16_A4_PREFILL=1`. The fork's change log describes a hybrid mode with calibrated A4 prefill and A16 decode and verify (`vllm-hybrid-a4-semantic-prefill`, §23.3); which mode was actually active in our runs was never checked.

### 5. MTP with exactly 3 speculative tokens

- **Rule.** `"num_speculative_tokens":3` in `--speculative-config`.
- **Why not more.** The fork's wiki reports `illegal memory access` under high concurrency with MTP above 3 and says "use 2, at most 3" (Reported, §10.1). The vLLM recipe uses 5; we do not follow it there.
- **Why not fewer.** MTP is the largest decode lever: R1 accepted 2.5 to 2.7 tokens per step (Observed, §12.2).
- **What it costs.** On the B300, MTP and CUDA graphs took 43% of the KV: 18.34 sessions of 262,144 tokens without MTP, 10.37 with it (Observed, §12.3).
- **Measuring with MTP.** `pd_bench` counts streaming chunks of about 2.6 tokens; divide its per-step numbers by 2.6 to get per-token numbers (Observed, §12.2).

### 6. Reject the NVIDIA NVFP4 PTQ checkpoint and any PTQ checkpoint without QAD until it passes the gate

- **Upstream vLLM 0.32.0, 1 B300, MTP3,** snapshot `1d00738646...`: 108 EXACT and 12 NEAR_MISS (checksum 3330) in 120, Wilson 95% interval about 5.8% to 16.7% error (Observed, §12.3). The cause could not be attributed there, since checkpoint, kernels and MTP all changed at once.
- **SGLang, revision `09b04e5e` (no QAD):** 94/120 and 99/120 at C8 and C16; 109/120 and 104/120 without speculation (Observed, §29.4).
- **SGLang, revision `1d00738` (NVIDIA calibration fix of 28 Oct):** 60/500 with W4A4, 32/500 with Marlin W4A16, 22/500 with Marlin, no speculation and FP32 SSM state; p from 2·10⁻¹⁵ to 1·10⁻⁴ against the reference (Observed, §29.5). The fix reduced the error from about 20% to 12% at C8 (p = 0.007) and changed nothing at C16.
- **Speculation and SSM state dtype** had no measurable effect (p = 0.21, Observed, §29.5).
- **The residual comes from the NVFP4 weights without QAD** (Inferred: with the original FP8 weights SGLang tied with the fork, 4/480, p = 0.72, §29.5).
- **Ruled out by reading the weights** (Observed, §29.5): #48919 and #48931 (gate and up share `weight_scale_2` in all 12,096 experts), #48907 (no subnormal E4M3 block scale in 12.6 million sampled scales). #49309 does not explain the residual, which persists without speculation.
- **No issue opened against NVIDIA** (decided §29.9): it is expected PTQ behaviour, and we never tested the checkpoint in the engine NVIDIA validated it for.

## How to

### Estimate KV for a workload

```text
MLA KV bytes   = tokens_in_context x 8.7 KB                      (whole model)
KDA state      = 0.15 GB per live sequence, independent of context
Per-GPU KV     = MLA KV / DCP size   (DCP=1 means every TP rank holds all of it)
```

Check the result against the server log line `GPU KV cache size: N tokens` after startup (R1: `23,249,576 tokens`, DCP4; Vast DCP1: `6,789,052 tokens`). That log value is the truth for the deployed stack; the formula is for planning.

### Read a needle-checksum result

The probe (8,192-token prompt, temperature 0, one `submit_context_check` tool call) asks the model to retrieve ALPHA 478, BETA 788 and GAMMA 426 from 291 inert records and compute ALPHA + 2·BETA + 3·GAMMA. The correct checksum is 3332 (478 + 1576 + 1278); the known wrong answer is 3330. The tool call is part of the test: answered in prose, the model passes 500/500 everywhere (Reported, `llm-inference-bench` README). Full prompt, labels and every result: `references/quality-alarm.md`. GLM-5.3-Flash nearly ties on that last digit, and the `llm-inference-bench` README calls it "the model's known last-digit slip" and uses it as an alarm for numerical changes such as MoE activation precision (Reported, §29.4). Even a good configuration errs now and then: the near tie plus server non-determinism (Reported, §10.4 item 1), and the reference itself erred 3 times in 500.

Why it is the quality alarm (Inferred from the tables above): it is cheap, it yields a count, and the count moves with exactly the changes that hurt this model (W4A4 activations, PTQ weights, a missing SwiGLU clamp), while gsm8k at 96 problems barely moved in the same runs: 94/96 on the fork and 95/96 on both SGLang arms, including the NVFP4 arm that failed the needle (§29.4).

The gate in force (decided 2026-11-12, §29.5):

```bash
# 500 runs at C8 and 120 at C16 plus gsm8k (96), run by run_benchmark.sh before any speed number
python3 bench/summarize.py --price <USD_per_hour> --needle-ref 3/500 <result_dirs>
# each arm is marked ok or FAIL; one-sided Fisher exact test, fail when worse than 3/500 at p < 0.05
```

Tests for the verdict logic: `bench/test_summarize.py` (20 tests, `uvx pytest`).

### Evaluate a new checkpoint

1. Read its licence and its `quantization_config` (what is quantized, group size, activation precision). For reference, the NVIDIA NVFP4 quantizes routed experts and the dense MLPs of the first layers in groups of 16, weights and activations in FP4, KV in static FP8, and excludes 134 entries: `lm_head`, `embed_tokens`, all `self_attn*` including KDA, the `mlp.gate` routers, `shared_experts*`, the vision tower and the MTP layer (Observed, NOTAS.md).
2. Check fit: size from the Hugging Face API (sum of `.safetensors`), not from a wiki page (one `rtx6kpro` page says "about 60 GB" for checkpoints that the API sums at 177.7 and 187.7 GB, §10.4 item 7).
3. Pin the revision SHA. Run the full gate on the fork with the production flags. Only then measure speed.

## Checkpoints

Sizes are the sum of `.safetensors` from the Hugging Face API (Observed, §8.3, §10.5). Fit is weights only, before activations, CUDA graphs and KV (Inferred).

| Checkpoint | Size | Fits 2 RTX (192 GB) | Fits 4 RTX (384 GB) | Licence | Quality evidence |
|---|---|---|---|---|---|
| `zai-org/GLM-5.3-Flash` (FP8) | 328.3 GB | no | yes, 56 GB left | MIT | SGLang FP8 needle 4/480, same as the fork reference (p = 0.72) (Observed, §29.5) |
| `nvidia/GLM-5.3-Flash-NVFP4` (PTQ, ModelOpt) | 204.4 GB | no | yes | MIT | **Fails** the needle on upstream vLLM (B300) and SGLang (Observed, §12.3, §29.5) |
| `RedHatAI/GLM-5.3-Flash-NVFP4` (PTQ W4A4, LLM Compressor) | 197.8 GB | no | yes | MIT (Reported, API) | None of ours |
| `ormandj/...W4A16-NVFP4-K32-Experts-FP8-WO` (Helix) | 178.0 GB | yes, about 7 GB per GPU left | yes | Unknown | None of ours |
| `local-inference-lab/GLM-5.3-Flash-NVFP4` | 199.4 GB | no (Inferred) | yes, TP4 profile | MIT | AA-LCR 74.00% (Reported, §10.1) |
| `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` | 187.7 GB | yes, 93.8 GB per GPU, about 4 to 7 GiB of KV left | yes | MIT (Reported, API) | None of ours |
| **`local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD`** | 177.7 GB | yes (`glm53-tp2` preset) | yes | `lil-license-1.0`: Apache 2.0 plus a ban on reuploads | **Passes** the gate on the fork (Observed, §29.5, §29.6, §29.10) |
| `nvidia/GLM-5.3-Flash-FP4-Local` (QAD, CSF scales) | 177.5 GB | yes, "about 166 GiB of vRAM" on 2 RTX PRO 6000 (Reported, card) | yes | `nvidia-open-model-agreement` | None of ours |

With the official NVIDIA or RedHat checkpoints the smallest RTX unit is TP4 (Inferred, §8.3). The DFlash2 drafter is CC BY-NC-ND 4.0, non-commercial (Reported, §10.4 item 6); do not ship it.

## Invariants

1. **KV math uses 8.7 KB per token plus 0.15 GB per sequence.** The 1.62 GB per 256K figure under-counts by 1.5x and would oversize every replica's session count.
2. **No capacity figure adds GPU memory across TP ranks unless DCP splits the KV.** Without DCP each rank holds the whole MLA KV.
3. **Any change to checkpoint, revision, quantization, kernel path, MoE activation precision or speculative settings re-runs the full gate** (500 at C8, 120 at C16, gsm8k) before a speed number counts. A faster configuration has shipped wrong before: the fork's R33 prefill kernel omitted a SwiGLU clamp, passed through several releases, and W4A4 gave 5.9% wrong needle answers against 0 in 500 with 16-bit activations (Reported, §10.4 item 1).
4. **MoE activations stay 16-bit (W4A16).** W4A4 costs measurable correctness on this model (§29.4, §29.5).
5. **`num_speculative_tokens` never exceeds 3.** Above 3 the fork's wiki reports illegal memory access at high concurrency.
6. **The checkpoint is pinned by revision SHA.** Moving tags or "latest" make the gate result meaningless.
7. **Quality evidence does not transfer between checkpoints.** The AA-LCR and aider numbers are for the `local-inference-lab` checkpoints; they say nothing about `nvidia/GLM-5.3-Flash-NVFP4` (§10.1).
8. **Read the licence before production** for anything that is not the MIT base model.

## Pitfalls we hit

- **Session size under-counted.** The first KV table (§2) gave 1.62 GB per 256K session; the B300 measurement showed about 1.5x more. Fixed by the correction note; every later sizing uses 8.7 KB per token.
- **The 120/120 gate rejected good configurations.** The reference itself erred 3 in 500, so a 120/120 rule fails a good arm by chance and cannot rank two good arms; telling 0% from 0.8% takes about a thousand runs per arm (§29.4, §29.5). SGLang FP8 at 117/120 looked like a failure but was not different from the fork (4/480 against 0/240, Fisher p = 0.31, §29.4). Fixed with the one-sided Fisher rule against 3/500.
- **A confounded failure.** The B300 run (108/120) changed checkpoint, kernels and MTP at once, so it could not say which one broke quality (§12.3). Change one thing per gated run.
- **Wrong upstream flag name.** The vLLM recipe's `--disable-flashinfer-autotune` was rejected by vLLM 0.32.0 (`unrecognized arguments`); the valid name is `--no-enable-flashinfer-autotune` (§9.3 correction, §10.1).
- **Test model does not load in the fork image.** The mini glm5next model fails because the image's `transformers` lacks `Glm5NextConfig` (Observed, §12.1). Tests of the fork need the real checkpoint.
- **Illegal memory access with long prompts on the mini model.** Prompts of 34,816 tokens with a 1 GiB pool crashed two replicas twice; 17,408 tokens did not (Observed, §7.3). Cause Unknown; the fork's wiki lists the same error in the GDN backend under speculative decoding, tied to vLLM issue 34948 and PR 35219 (Reported, §10.4 item 2). Not reproduced on the real model.

## Open questions

1. What the roughly 430 B per token that DCP does not split is (indexer, MTP or recurrent state). Read the fork's `kv_cache_utils.py` in the image.
2. Which block size the prefix cache hashes with: `--block-size 256` on the command line, 2,048-token split pages in the log.
3. Which MoE prefill mode `B12X_W4A16_A4_PREFILL=1` actually activates in our runs.
4. Long-context quality on our stack. Only the 8K needle and gsm8k ran; AA-LCR and the 516K numbers are Reported (§10.1, §23.3).
5. Whether the `lil-license-1.0` terms fit our hosting (private S3 mirror, AMI snapshots). Needs a legal read.
6. Whether `VLLM_GLM53_KDA_MXFP8_ACTIVATION_MODE=a16` (KDA MXFP8 with BF16 activation; Reported long-context quality 79.6% against 76.5% at 516K) is worth gating (§23.3).
7. Whether `nvidia/GLM-5.3-Flash-FP4-Local` holds the same weights as the QAD checkpoint under another licence (compare tensor hashes).

## Sources

- `docs/02-model-hardware-and-checkpoints.md` (sections 1, 3, 5 and open questions)
- `docs/03-serving-engine-and-benchmarks.md` (section 2.2 quality, section 5 gate)
- `docs/README.md` (contradictions table)
- `ARQUITETURA.md` §2 and its correction note, §7.3, §8.2, §8.3, §9.3, §10.1, §10.4, §10.5, §12.2, §12.3, §23.3, §29.2, §29.4, §29.5, §29.6, §29.8, §29.9, §29.10
- `NOTAS.md`, "Arquitetura dos modelos" (config and `quantization_config` reads)
- Server logs: `f3/resultados/rtx-20261105/r1-servidor.log`, `f3/resultados/vast-20261111/vllm/*/servidor-direto.log`
- Gate code: `bench/summarize.py`, `bench/test_summarize.py`
- Probe source: `llm-inference-bench` commit `52216d70865a015b34689626d04a80b89c9dc45f`, `llm_decode_bench.py` and README (`https://github.com/local-inference-lab/llm-inference-bench`)
- Hugging Face model API and cards, read 2026-11-12: `https://huggingface.co/local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` (and its `LICENSE`), `https://huggingface.co/nvidia/GLM-5.3-Flash-NVFP4`, `https://huggingface.co/nvidia/GLM-5.3-Flash-FP4-Local`, `https://huggingface.co/RedHatAI/GLM-5.3-Flash-NVFP4`, `https://huggingface.co/local-inference-lab/GLM-5.3-Flash-NVFP4`, `https://huggingface.co/local-inference-lab/GLM-5.3-Flash-NVFP4-Spark`, `https://huggingface.co/zai-org/GLM-5.3-Flash`
- vLLM docs (developer preview, not our pinned fork): `https://docs.vllm.ai/en/latest/serving/context_parallel_deployment.html`, read 2026-11-12
