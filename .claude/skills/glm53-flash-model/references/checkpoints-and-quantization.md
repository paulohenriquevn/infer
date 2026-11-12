# Checkpoints and quantization

Every GLM-5.3-Flash checkpoint the project considered, what is quantized in each, its licence, and the quality evidence we have. The decision (use the QAD checkpoint at `dec48abd...`) and its reasons are in `../SKILL.md`.

Labels: Observed (path), Reported (named source, URL, read 2026-11-12), Inferred, Hypothesis, Unknown. Hugging Face facts below come from the model API (`https://huggingface.co/api/models/<repo>`) and the raw `README.md` of each repository, both read 2026-11-12 at the `main` revision unless a SHA is given. Model cards change; re-read them before relying on a number.

## Terms

| Term | Meaning here |
|---|---|
| NVFP4 | 4-bit E2M1 values with an FP8 E4M3 scale per block of 16 values and an FP32 global scale per tensor (Reported, `local-inference-lab/GLM-5.3-Flash-NVFP4` card) |
| MXFP8 | 8-bit E4M3 values with a power-of-two (UE8M0) scale per block of 32 (Reported, same card and the QAD card) |
| W4A4 | 4-bit weights and 4-bit activations in the MoE GEMMs. Faster, and on this model measurably less accurate (see `quality-alarm.md`) |
| W4A16 | 4-bit weights, 16-bit activations. What our fork profile forces with `VLLM_B12X_MOE_FP4_FORCE_A16=1` |
| PTQ | Post-training quantization: weights rounded after training, with calibration data for scales |
| QAD | Quantization-aware distillation: a student with NVFP4 expert weights in its forward pass is trained against the BF16 teacher, so the rest of the network learns to compensate (Reported, `local-inference-lab/GLM-5.3-Flash-NVFP4` and `nvidia/GLM-5.3-Flash-FP4-Local` cards) |
| CSF | A lossless compression of the routed-expert E4M3 block scales: `weight_scale_encoding: "csf"`, codec `byte-window4-fixed-stream-u24-exceptions/1`, 36,288 compressed matrices (Reported, QAD card). Engines must decode it at load time; SGLang cannot (`ARQUITETURA.md §29.5`) |

## Summary table

Sizes are the sum of `.safetensors` reported by the Hugging Face API (Observed, `ARQUITETURA.md §8.3`, §10.5). Licence and revision are Reported from the API on 2026-11-12.

| Checkpoint | `main` SHA on 2026-11-12 | Size | Licence (API) | Scheme | Our quality evidence |
|---|---|---|---|---|---|
| `zai-org/GLM-5.3-Flash` | `46a050bec13002ad29ee795c16e61cf4fa3c4a9c` | 328.3 GB | MIT | Block FP8 E4M3, 128 x 128 | SGLang FP8 needle 4/480, tied with the fork reference (p = 0.72) (Observed, `ARQUITETURA.md §29.5`) |
| `nvidia/GLM-5.3-Flash-NVFP4` | `1d00738646cbb0c6d0a9eb403dac5f366f1473a7` | 204.4 GB | MIT | PTQ NVFP4, ModelOpt 0.47.0, W4A4 on experts and dense MLP, KV fp8 cast | Fails the needle on upstream vLLM (B300) and SGLang (Observed, §12.3, §29.5) |
| `RedHatAI/GLM-5.3-Flash-NVFP4` | `4756632d3fdf88095feaa87974d41354b2afdca4` | 197.8 GB | MIT | PTQ NVFP4 (LLM Compressor, compressed-tensors), W4A4 on MoE experts, MTP kept FP8 | None of ours |
| `local-inference-lab/GLM-5.3-Flash-NVFP4` | `175ae8ce3b5af842b0d0140dbeb43e9cfc557c49` | 199.4 GB | MIT | QAD NVFP4 routed experts, MXFP8 MTP experts, rest BF16 | None of ours. AA-LCR 74.00% (Reported, §10.1) |
| `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` | `a608241037e4c2565356bff7ca293f2133888f88` | 187.7 GB | MIT | Not stated in its card (the README is a copy of the zai-org card) | None of ours |
| **`local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD`** | **`dec48abd33efa73c3bb7c95b74eee10cad34f9be`** | 177.7 GB | `other`, `lil-license-1.0` | QAD NVFP4 routed experts with CSF scales, MXFP8 attention and shared experts, W4A16 NVFP4 MTP experts, mixed vision | **Passes** the gate on the fork (Observed, §29.5, §29.6, §29.10) |
| `nvidia/GLM-5.3-Flash-FP4-Local` | `76348ddb2be2e35e39ecfc00e75dc07703f4f3d5` | 177.5 GB | `other`, `nvidia-open-model-agreement` | Same component table as the QAD card, CSF scales | None of ours |
| `ormandj/...W4A16-NVFP4-K32-Experts-FP8-WO` (Helix) | not read | 178.0 GB | Unknown | W4A16 NVFP4 experts, FP8 weight-only elsewhere (from its name) | SGLang arms `ormandj` and `ormandj-portao1`: needle 119/120 and 117/120 at C8, 120/120 at C16 (Observed, `f3/resultados/vast-20261111/sglang/vast-sglang-ormandj*/needle*.json`) |

Our pin `dec48abd...` is still the `main` revision of the QAD repository on 2026-11-12 (Reported, API `sha`; last modified 2026-10-07). For the NVIDIA NVFP4, `main` is the `1d00738` snapshot we tested in SGLang.

## Card digests

### `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` (production)

Reported, `https://huggingface.co/local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD`, read 2026-11-12:

- "Multimodal checkpoint with QAD decoder weights, losslessly compressed routed-expert block scales, MXFP8 attention, NVFP4 MTP routed experts, and mixed-precision vision weights."
- Component table: decoder routed experts "QAD NVFP4; E2M1 values, E4M3 block scales, FP32 global/input scales"; decoder attention "MXFP8 projection selection from the pinned source"; MTP routed experts "NVFP4, BF16 activations; block scales stored directly"; vision attention MXFP8 (48 matrices); vision MLP NVFP4 with BF16 activations (76 matrices); 223 other vision tensors and 277 normalization tensors in BF16.
- "The checkpoint contains 36 safetensors shards targeting 5 GB each, under `tensors/`."
- "`config.json` uses the standard `quant_method: "modelopt"` and `quant_algo: "MIXED_PRECISION"`." Load with `--quantization modelopt_mixed`; "No checkpoint-root setting or CSF-specific load format is needed."
- "GPU inference and multimodal quality evaluation have not been run for this checkpoint." Read this as: the card makes no quality claim; ours is the gate.
- Its pinned input is the same repository at revision `fd660d51d1fc3caae26a4bf31b7451475bbb9bdc`; the card says every tensor outside the converted vision linears keeps the input's values.

`quantization_config` of the pinned revision (Observed in the fetched `config.json`, URL in `architecture.md`):

| Config group | Format | Targets |
|---|---|---|
| `group_nvfp4_routed_experts` | NVFP4, group 16, static input activations at 4 bits, `weight_scale_encoding` csf | `model.language_model.layers.3..44.mlp.experts` (42 layers) |
| `group_mxfp8_attention` | MXFP8, group 32, dynamic 8-bit activations | attention projections, including KDA projections such as `b_proj`, `f_a_proj`, `f_b_proj` |
| `group_mxfp8_shared_experts` | MXFP8, group 32 | `shared_experts.{gate,up,down}_proj` |
| `group_w4a16_nvfp4_mtp_routed_experts` | NVFP4 weights, group 16, no activation quantization | `layers.45.mlp.experts` (the MTP layer) |
| `group_vision_mxfp8`, `group_vision_w4a16_nvfp4` | MXFP8 and W4A16 NVFP4 | vision attention and MLP |

`quantized_layers` counts: 579 MXFP8 entries, 77 W4A16_NVFP4, 42 NVFP4 with CSF. Producer: `modelopt` `0.39.0.dev290+gf9d9a71de.d20260407` (Observed, same file).

Note: the checkpoint stores activation scales for the routed experts (static 4-bit input activations in the config). Our profile ignores them at decode and runs A16 (`VLLM_B12X_MOE_FP4_FORCE_A16=1`). The config default is W4A4 (Inferred from the config group), which matches the `llm-inference-bench` note "QAD (HF main), b12x W4A4 (profile default)" with 6.0% needle errors (Reported, `quality-alarm.md`).

Licence: `lil-license-1.0`, "Local Inference Lab License, Version 1.0" (Reported, `https://huggingface.co/local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD/raw/main/LICENSE`, read 2026-11-12). It is Apache 2.0 plus added terms. What matters for us:

- Section 2.1 forbids any "Reupload" of the checkpoint or a "Substantially Similar Copy", which includes re-sharded, re-serialized or re-quantized copies (section 1.7).
- Section 2.2(b) allows copies "on devices and in storage that only You control", and 2.2(d) allows "running the Licensed Work ... to provide a service, such as an inference service, as long as the files ... are not made available to users of the service".
- Section 3 requires an attribution notice at the top of any "Covered Page"; section 5 terminates the licence immediately on breach.
- Inferred consequence: mirroring the weights in a private S3 bucket that only we control fits 2.2(b); publishing them, or a bucket readable by others, does not. Whether "a cloud storage link" in our own account counts as storage "only You control" is a legal question; get it reviewed before production (Unknown).

### `local-inference-lab/GLM-5.3-Flash-NVFP4` (QAD, MIT)

Reported, `https://huggingface.co/local-inference-lab/GLM-5.3-Flash-NVFP4`, read 2026-11-12:

- "a quantization-aware distilled version of zai-org/GLM-5.3-Flash-BF16"; "approximately 199 GB on disk".
- Routed experts NVFP4 (trained); dense MLPs in layers 0 to 2 and shared experts BF16; attention, residual mixing, embeddings and LM head original BF16 or FP32, frozen; MTP routed experts MXFP8, not distilled; vision BF16.
- Distillation corpus "approximately 200M prompt-and-response tokens"; activation input scales calibrated on the same corpus "covers all 12,096 layer/expert pairs without fallback scales".
- No licence restriction beyond MIT. It is a fallback if the `lil-license-1.0` terms are unacceptable, but it has no gate result of ours and does not fit 2 GPUs (Inferred, 199.4 GB).

### `nvidia/GLM-5.3-Flash-NVFP4` (PTQ)

Reported, `https://huggingface.co/nvidia/GLM-5.3-Flash-NVFP4`, read 2026-11-12:

- "quantized with nvidia-modelopt v0.47.0"; "Only the weights and activations of the linear operators within transformer blocks in sparse MoE shared experts and dense MLP are quantized." Recipe `nvfp4_experts_dense_mlp-kv_fp8_cast`.
- Calibration data: cnn_dailymail and Nemotron-Post-Training-Dataset-v2. Test hardware "NVIDIA Blackwell GB200".
- Card accuracy, BF16 against NVFP4: GPQA Diamond 0.9217 / 0.9189; SciCode 0.5344 / 0.5374; MMMU Pro 0.7688 / 0.7751; AA-LCR 0.7669 / 0.7831; IFBench 0.644 / 0.6547; Terminal Bench 2.1 0.8258 / 0.8202.
- Our reading (Observed, project research notes, not published): `quantization_config` uses group 16, FP4 weights and activations, static FP8 KV, and excludes 134 entries (`lm_head`, `embed_tokens`, every `self_attn*` including KDA, the `mlp.gate` routers, `shared_experts*`, the vision tower and the MTP layer).
- Why its card numbers do not contradict our failure (Inferred): the card's benchmarks use temperature 1.0 and score final answers; the needle measures greedy last-digit stability. gsm8k at 96 problems also did not separate the NVFP4 arm from the good ones (`quality-alarm.md`).

### `nvidia/GLM-5.3-Flash-FP4-Local` (QAD, NVIDIA agreement)

Reported, `https://huggingface.co/nvidia/GLM-5.3-Flash-FP4-Local`, read 2026-11-12:

- "the NVFP4 scale factors in this checkpoint are in a new lossless compression format, but upstream vLLM support for this format has not yet landed. You must use one of the containers provided below."
- "uses approximately 166 GiB of vRAM", validated on "2 x NVIDIA RTX PRO 6000 Blackwell with 1.8M tokens of FP8 KV Cache".
- Its component table is identical to the QAD card's; GPQA Diamond 92.1% (BF16) against 91.3%; ToolEvalBench 91.9% against 92.4%.
- Containers named on the card: `ghcr.io/local-inference-lab/vllm:release-10142026` and `release-10152026` (not our `karmic-kraken-20261016`), and `eugr/spark-vllm-b12x:latest` for DGX Spark.
- Licence `nvidia-open-model-agreement`. Hypothesis: it is the same weights as our QAD checkpoint under a different licence; nothing in the sources confirms it. Comparing tensor hashes of the two repositories would settle it.

### `RedHatAI/GLM-5.3-Flash-NVFP4` (PTQ, MIT)

Reported, `https://huggingface.co/RedHatAI/GLM-5.3-Flash-NVFP4`, read 2026-11-12:

- "Weight quantization: FP4; Activation quantization: FP4"; "Only the weights and activations of the MoE expert linear operators are quantized using LLM Compressor"; "The MTP layers are kept in FP8".
- Card accuracy (3 seeds, 8 for AIME): GSM8K Platinum 97.74%, MATH-500 94.87%, AIME 2025 86.67%, GPQA Diamond 90.57%.
- Its deployment example uses `vllm/vllm-openai:glm53-flash`, `--disable-custom-all-reduce` and MTP with 5 speculative tokens.
- It is W4A4 PTQ like the NVIDIA checkpoint (Inferred from the card), so expect the same needle risk until gated.

### `zai-org/GLM-5.3-Flash` (base)

Reported, `https://huggingface.co/zai-org/GLM-5.3-Flash`, read 2026-11-12: 320B total and 18B active parameters, "the first natively multimodal model in the GLM-5 series", hybrid sparse and linear attention. The card points to the vLLM recipe `https://recipes.vllm.ai/zai-org/GLM-5.3-Flash`, which lists `zai-org/GLM-5.3-Flash` (native FP8, about 306 GiB), `zai-org/GLM-5.3-Flash-BF16` and `RedHatAI/GLM-5.3-Flash-NVFP4` (Reported, recipe page, read 2026-11-12).

## Fit per GPU count

Inferred, weights only, before activations, CUDA graphs and KV:

| Checkpoint | Fits 2 RTX PRO 6000 (192 GB) | Fits 4 (384 GB) |
|---|---|---|
| FP8 base, 328.3 GB | no | yes, 56 GB left |
| NVIDIA or RedHat NVFP4, about 200 GB | no | yes |
| QAD CSF, 177.7 GB | yes (`glm53-tp2` launcher preset) | yes; our log shows 42.2 GiB of weights per GPU at TP4 (`Model loading took 42.2 GiB memory`, Observed) |
| Spark, 187.7 GB | yes, 93.8 GB per GPU, about 4 to 7 GiB of KV left | yes |

## How to evaluate a new checkpoint

1. Read the licence file in the repository, not only the API tag.
2. Read `quantization_config`: which modules are quantized, group size, whether activations are quantized (`input_activations`), whether scales are compressed (`weight_scale_encoding`).
3. Size from the API (sum of `.safetensors`), never from a wiki page (`ARQUITETURA.md §10.4` item 7).
4. Pin the SHA. Run the quality gate (`quality-alarm.md`) on the fork with the production flags; only then measure speed.
5. Change one thing per gated run. The B300 run changed checkpoint, kernels and MTP at once and could not attribute its failure (`ARQUITETURA.md §12.3`).
