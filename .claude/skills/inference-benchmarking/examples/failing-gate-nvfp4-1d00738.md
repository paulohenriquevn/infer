# A real failing quality gate: SGLang with NVIDIA's NVFP4 checkpoint `1d00738`

Use this when a needle result fails and you need to see what a real failure looks like, how `summarize.py` and `run_benchmark.sh` react, and how to judge a gate-only directory. Everything here is Observed in `f3/resultados/vast-20261111/sglang/vast-sglang-nvfp4-1d00738/` (real model, one run, Vast host 157204, 2026-11-11) unless marked.

Files in the directory use the Portuguese names written before the translation (`motor.txt`, `servidor.sh`, `servidor.log`, `tempo-pronto.txt`).

## Configuration

- Engine: SGLang, image `ghcr.io/ormandj/sglang-glm53-flash-sm120:v0.6.1`.
- Checkpoint: `nvidia/GLM-5.3-Flash-NVFP4` at revision `1d00738...` (the arm name; `prepare_host.sh` pins `1d00738646...`).
- MoE backend: `--moe-runner-backend flashinfer_cutlass` (W4A4, activations in FP4).
- Server ready in 861 s (`tempo-pronto.txt`: `pronto em 861 s`).

## Raw counts

```
needle.json      {'attempted': 500, 'correct': 440, 'wrong': 60, 'near_miss': 60, 'wrong_facts': 0, 'wrong_checksum': 0, 'fail': 0, 'correct_rate': 0.88}
needle-c16.json  {'attempted': 120, 'correct': 101, 'wrong': 19, 'near_miss': 19, 'wrong_facts': 0, 'wrong_checksum': 0, 'fail': 0, 'correct_rate': 0.8416666666666667}
gsm8k.json       {'attempted': 96, 'correct': 95, 'wrong': 1, ...}
```

A wrong run, from `wrong_runs[0]`:

```
"final_answer": "submit_context_check({\"alpha\": 478, \"beta\": 788, \"checksum\": 3330, \"gamma\": 426})"
"score_detail": "checksum 3330, expected 3332"
```

All 79 wrong answers are `near_miss`: the model found the right facts (478, 788, 426) and slipped on the last digit of `478 + 2*788 + 3*426 = 3332`. That is the numerical signature the profile is built to detect.

## Judge it with the gate code

The directory has no `agents-<N>.json` (the arm was stopped after the gate), so `summarize.py` refuses it:

```
$ python3 summarize.py --price 5.61 .../vast-sglang-nvfp4-1d00738
FileNotFoundError: .../vast-sglang-nvfp4-1d00738: no agents-<N>.json files
```

Use the gate functions directly (run from `bench/`):

```bash
D=f3/resultados/vast-20261111/sglang/vast-sglang-nvfp4-1d00738   # path to the archived directory
python3 -c "
import json, summarize as s
for f in ('needle.json', 'needle-c16.json'):
    x = json.load(open('$D/' + f))['selected_summary']
    e = x['attempted'] - x['correct']
    print(f, e, x['attempted'], s.fisher_one_sided(e, x['attempted'], 3, 500))
"
```

Output:

```
needle.json 60 500 8.213516205912623e-16
needle-c16.json 19 120 7.537846756162206e-12
```

Both p-values are far below 0.05. The arm fails the gate.

What `run_benchmark.sh` would do on this directory with the current code: the check after the gate computes `all(passes_needle(...))` on both files, prints `FAIL on needle-checksum ...` and exits 5 because `STOP_ON_GATE_FAIL` defaults to 1. This run predates the Fisher gate and went on to the speed step, which is why `decode.json` exists.

## What else the directory shows

- gsm8k 95 of 96: arithmetic in reasoning looks fine while the needle checksum fails 12% of the time. gsm8k alone would have passed this arm. That is why gsm8k never gates and the needle does.
- `decode.json`: C1 161.2, C8 633.8, C16 530.6 tok/s; the C32 cell is `-4.0` with `failure_reason` `scheduler isolation metrics disappeared after C=32 ctx=0: expected sglang:num_running_reqs and sglang:num_queue_reqs`. A negative `aggregate_tps` is a failure marker, not a speed.

## The diagnosis that followed

From `ARQUITETURA.md §29.5`, each arm one run on the same host (raw counts Observed in each directory; p-values Inferred with `fisher_one_sided` against 3/500):

| Arm | Change | C8 | C16 | Verdict |
|---|---|---|---|---|
| `nvfp4` | revision `09b04e5e`, W4A4 | 26/120 wrong, p = 5.8e-17 | 21/120 | fail |
| `nvfp4-1d00738` (this one) | revision `1d00738`, W4A4 | 60/500, p = 8.2e-16 | 19/120, p = 7.5e-12 | fail |
| `nvfp4-marlin` | W4A16 MoE (Marlin) | 32/500, p = 1.4e-7 | 5/120, p = 0.0086 | fail |
| `nvfp4-marlin-limpo` | Marlin, no speculation, SSM FP32 | 22/500, p = 6.6e-5 | 10/120, p = 9.0e-6 | fail |

Reading (Inferred, §29.5): moving MoE activations from FP4 to 16 bits halves the error, and removing speculation and FP32 SSM state does not close the gap. The checkpoint itself carries most of the error, consistent with the upstream bench's table where only a QAD checkpoint reaches 0% (Reported, §29.4). Decision: SGLang with NVIDIA's NVFP4 is out; vLLM with the QAD checkpoint is the engine (`docs/03`).
