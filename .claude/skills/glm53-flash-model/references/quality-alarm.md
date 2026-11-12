# The quality alarm: needle-checksum and gsm8k

How the probe works, why it catches what hurts this model, how the gate decides, and every result we have. The gate rule itself is summarized in `../SKILL.md`; the harness that runs it is in the `inference-benchmarking` skill.

Labels: Observed (path), Reported (named source), Inferred, Hypothesis, Unknown. Result files keep their original names (`needle.json`, `needle-c16.json`, `gsm8k.json`); the directories are under `f3/resultados/`.

## The probe

Source: `llm-inference-bench` at commit `52216d70865a015b34689626d04a80b89c9dc45f`, `llm_decode_bench.py` lines 4318 to 4385 and README section "needle-checksum: greedy numerical stability" (Observed in the checkout; the repository is `https://github.com/local-inference-lab/llm-inference-bench`).

- It is "logprobz's GLM-5.3-Flash "3330/3332" context-check probe, rebuilt exactly (messages and tool schema hash to the original 7349ff46...)" (code comment).
- System prompt: `Follow the user's context-check instructions and use the supplied tool.`
- User prompt (built by `build_needle_checksum_prompt()`): a header `CONTEXT CHECK DATASET deterministic-concurrency-20260827`, 291 inert lines `REC <index> id=<hash> metric=<n> state=nominal`, and three hidden lines `CANONICAL FACT ALPHA=478` (after record 14), `CANONICAL FACT BETA=788` (after 145) and `CANONICAL FACT GAMMA=426` (after 276). It ends with:

```text
Retrieve ALPHA, BETA, and GAMMA from the canonical fact lines.
Compute CHECKSUM = ALPHA + 2*BETA + 3*GAMMA.
Call submit_context_check exactly once with the three values and CHECKSUM.
Do not answer in prose.
```

- Tool: `submit_context_check` with integer `alpha`, `beta`, `gamma`, `checksum`, all required, `additionalProperties: false`.
- Expected answer: `alpha=478 beta=788 gamma=426 checksum=3332`, since 478 + 2 x 788 + 3 x 426 = 478 + 1576 + 1278 = 3332.
- Request settings recorded in every `needle.json` (Observed, `f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/needle.json`): temperature 0.0, seed 275001, `tool_choice` auto, `chat_template_kwargs` `{"thinking": true, "reasoning_effort": "max"}`, `max_tokens` 4096, prompt 17,397 characters (8,192 prompt tokens per run), `prompt_sha256` `3a1eccf0ec1f204631e65b68eea5fee8b320332dd7f56231cc8c73ae29cf3685`.
- One scout request with `max_tokens=1` warms the prefix cache first; measured requests then reuse the prefill (Observed, `methodology.prefill` in the same file).

Scoring labels (Observed, `methodology.correctness`):

| Label | Meaning |
|---|---|
| EXACT | exactly one call with alpha 478, beta 788, gamma 426, checksum 3332 |
| NEAR_MISS | checksum 3330 with the right facts |
| WRONG_SUM | another checksum |
| WRONG_FACTS | a wrong retrieved value |
| FAIL | a missing, repeated or malformed call |

Server requirement: tool calling must be on (`--enable-auto-tool-choice` and `--tool-call-parser glm47` in our profile). "With a plain answer line instead, GLM-5.3-Flash computes the sum step by step (`2054 + 1278`) and passed 500/500 in every configuration" (Reported, README).

## Why 3330 against 3332 works as an alarm

- The requests are greedy and identical. A correct, deterministic stack would give the same answer 500 times. Every wrong answer comes from numerical differences in the serving stack tipping a near tie, not from sampling: "every wrong answer comes from the serving stack's numerics tipping the model's near-tie on the last digit of 478 + 1576 + 1278 (3332 vs 3330)" (Reported, code comment).
- The near tie is specific to this model: DeepSeek V4 and V4.1 Flash score 500/500 (Reported, README). So it ranks GLM-5.3-Flash configurations; it says nothing about other models.
- In every result we have, all wrong answers were NEAR_MISS (Observed, `score_counts` in every file below). The probe isolates one failure mode, which keeps it cheap to read.
- It moves with the changes that hurt this model: W4A4 MoE activations, PTQ weights without QAD, a missing SwiGLU clamp (Reported, README table and `ARQUITETURA.md §10.4` item 1; Observed, SGLang arms below).
- gsm8k with 96 problems did not separate the same arms: 94/96 to 96/96 on the fork, 95/96 on the SGLang NVFP4 arm that failed the needle (Observed below). It stays in the gate as a coarse reasoning check.
- Even a good stack slips sometimes (3 in 500 for the reference), because batch composition changes the order of floating point reductions (Reported, README: "Higher concurrency adds batch-composition noise"). That is why the gate is statistical.

Side observation (Observed, `completion_tokens` in `all_summary`): the fork answered in 99 tokens on average (p50 99), SGLang NVFP4 `1d00738` in 192 (p50 188). Why the SGLang arm generated twice as many tokens is Unknown.

## The gate

Decided 2026-11-12 (`ARQUITETURA.md §29.5`), implemented in `bench/summarize.py` and tested in `bench/test_summarize.py`:

- Each arm runs 500 needle requests at C8, 120 at C16 and the 96 gsm8k problems (`run_benchmark.sh`, `NEEDLE_RUNS=500`).
- `python3 bench/summarize.py --price <USD_per_hour> --needle-ref 3/500 <result_dirs>` marks each arm `ok` or `FAIL`. FAIL means the arm's error count is worse than the reference 3/500 at p < 0.05 in a one-sided Fisher exact test.
- `run_benchmark.sh` stops before speed and agent levels when the gate fails (`STOP_ON_GATE_FAIL=1`, the default); `GATE_ONLY=1` runs only the gate.

Why not 120/120: the reference itself erred 3 in 500, so a zero-error rule rejects good arms by chance; telling 0% from 0.8% takes about a thousand runs per arm (`ARQUITETURA.md §29.4`, §29.5).

## Reference table from the probe's authors

Reported, `llm-inference-bench` README, "GLM-5.3-Flash TP4 with MTP, 4x RTX PRO 6000 Max-Q, Karmic Kraken beta, 500 requests per cell":

| Checkpoint and MoE activations | Wrong at C8 | Wrong at C30 |
|---|---|---|
| QAD (HF main), b12x W4A4 (profile default) | 6.0% | 9.0% |
| QAD, b12x W4A16 (BF16 router weights) | 0% | 0% |
| QAD, b12x W4A16 + `B12X_W4A16_FP32_TOPK_WEIGHTS=1` | 0% | 0% |
| pre-QAD `46aaae8a`, b12x W4A16 (BF16 router weights) | 18.0% | 23.2% |

This is why our profile forces A16 and FP32 top-k weights.

## Every needle result we have

All wrong answers below are NEAR_MISS (3330). Observed in the listed files. Runs are single unless the directory name says `rep`.

| Directory under `f3/resultados/` | Stack | C8 exact / attempted | C16 exact / attempted |
|---|---|---|---|
| `rtx-20261105/r1-needle.json` | Fork, Nebius R1, DCP4 | 120 / 120 | not run |
| `b300-20261105/r2-needle-r2.json` | Upstream vLLM 0.32.0, B300, `nvidia/GLM-5.3-Flash-NVFP4`, MTP3 | 108 / 120 | not run |
| `vast-20261111/vllm/vast-vllm-r1` | Fork, host 157204, DCP4 | 120 / 120 | 120 / 120 |
| `vast-20261111/vllm/vast-vllm-r1-rep2` | Fork, host 157204, DCP4 (the 3/500 reference) | 497 / 500 | 120 / 120 |
| `vast-20261111/vllm/vast-vllm-dcp1` | Fork, host 157204, DCP1 | 117 / 120 | 119 / 120 |
| `vast-20261112/vllm/vast-vllm-dcp1-rep` | Fork, host 48294, DCP1 | 500 / 500 | 120 / 120 |
| `vast-20261111/sglang/vast-sglang-nvfp4` | SGLang, NVIDIA NVFP4 rev `09b04e5e`, W4A4 | 94 / 120 | 99 / 120 |
| `vast-20261111/sglang/vast-sglang-nvfp4-semspec` | same, no speculation | 109 / 120 | 104 / 120 |
| `vast-20261111/sglang/vast-sglang-nvfp4-1d00738` | SGLang, NVIDIA NVFP4 rev `1d00738`, W4A4 | 440 / 500 | 101 / 120 |
| `vast-20261111/sglang/vast-sglang-nvfp4-marlin` | same, Marlin W4A16 MoE | 468 / 500 | 115 / 120 |
| `vast-20261111/sglang/vast-sglang-nvfp4-marlin-limpo` | same, Marlin, no speculation, FP32 SSM state | 478 / 500 | 110 / 120 |
| `vast-20261111/sglang/vast-sglang-ormandj` | SGLang, `ormandj` W4A16 checkpoint | 119 / 120 | 120 / 120 |
| `vast-20261111/sglang/vast-sglang-ormandj-portao1` | same, repeat | 117 / 120 | 120 / 120 |

SGLang FP8 (base checkpoint) results are in `ARQUITETURA.md §29.4` and §29.5: 4 wrong in 240 at C8, 0 in 240 at C16 (current values in `docs/README.md`), 4/480 overall against the fork's reference (p = 0.72). The copies of `vast-vllm-dcp1-rep` files directly under `vast-20261112/vllm/` are duplicates.

Fisher results quoted in the journal (Reported from `ARQUITETURA.md §29.5`, computed by us): SGLang NVFP4 arms against the reference from p = 2·10⁻¹⁵ to 1·10⁻⁴; W4A4 against Marlin W4A16, 60/500 against 32/500, p = 0.003; speculation and SSM dtype, p = 0.21.

## gsm8k

Profile `gsm8k`, 96 items selected from 1,319 (`gsm8k_test`, `dataset_sha256` `3730d312f6e3440559ace48831e51066acaca737f6eabec99bccb9e4b3c39d14`), C8, temperature 0, `max_tokens` 131072. Scoring: "the last number on the final answer line ... must exactly match the reference final number" with a Wilson 95% interval (Observed, `metadata` and `methodology` of `gsm8k.json`).

| Directory | Correct / 96 | Wilson 95% |
|---|---|---|
| `vast-20261111/vllm/vast-vllm-r1` | 94 | 0.927 to 0.994 |
| `vast-20261111/vllm/vast-vllm-r1-rep2` | 96 | 0.962 to 1.000 |
| `vast-20261111/vllm/vast-vllm-dcp1` | 95 | 0.943 to 0.998 |
| `vast-20261112/vllm/vast-vllm-dcp1-rep` | 96 | 0.962 to 1.000 |
| SGLang arms (`nvfp4`, `nvfp4-1d00738`, `nvfp4-marlin`, `nvfp4-marlin-limpo`, `ormandj`, `ormandj-portao1`) | 95 each | 0.943 to 0.998 |
| `vast-20261111/sglang/vast-sglang-nvfp4-semspec` | 94 | 0.927 to 0.994 |

The intervals overlap everywhere. gsm8k at 96 cannot rank arms; it only catches gross breakage (Inferred).

Examples with the raw JSON: `../examples/needle-pass-and-fail.md` and `../examples/gsm8k-excerpt.md`.
