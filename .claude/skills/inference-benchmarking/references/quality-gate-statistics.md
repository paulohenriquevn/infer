# Quality gate statistics: the one-sided Fisher test on needle-checksum

Read this when you judge a needle result, choose `NEEDLE_RUNS`, change `--needle-ref`, or need to explain why 120/120 was dropped. The code is Observed in `bench/summarize.py` (`fisher_one_sided`, `passes_needle`, `NEEDLE_ALPHA = 0.05`). Every p-value and power figure here was computed on 2026-11-12 with that function and exact binomial sums (Inferred: arithmetic, reproducible with the snippet in section 6). The decision to use this test is `ARQUITETURA.md §29.5` (2026-11-12).

## 1. What is being tested

needle-checksum sends the same 8K-token prompt at temperature 0. The model must find three numbers and submit `ALPHA + 2*BETA + 3*GAMMA = 3332`. Wrong answers are almost all `near_miss`: right facts, checksum 3330 (Observed: every wrong run in the archive has `score_label` `near_miss`, `wrong_facts` 0). The upstream README calls it "the model's known last-digit slip" and uses it as an alarm for numerical changes such as MoE activation precision (Reported, §29.4). Since the prompt is fixed and greedy, an error rate measures how often the serving stack's numerics (batch composition, kernel choice, quantization) tip a near tie, not sampling noise.

The C16 file exists to catch failures that only show with a fuller batch (SGLang EAGLE NaN #49881, comment in `run_benchmark.sh`).

## 2. The test

Let the arm have `e` errors in `n` runs and the reference `r` errors in `m` runs (default `3/500`, vLLM DCP4 run 2, `f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/needle.json`). Condition on the total `k = e + r` errors in `N = n + m` runs. Under the null hypothesis that both have the same error rate, the arm's error count is hypergeometric:

```
P(X = x) = C(n, x) C(m, k - x) / C(N, k)
p = P(X >= e) = sum_{x = e}^{min(k, n)} C(n, x) C(m, k - x) / C(N, k)
```

That is `fisher_one_sided(e, n, r, m)`. The arm fails when `p < 0.05`.

Why one-sided: we only want to stop configurations that err more than the reference. An arm that errs less must never fail (test `test_needle_passes_when_errors_are_below_reference`: 0/500 passes).

Why Fisher and not a z-test: the counts are tiny (3 errors in the reference). Normal approximations are poor below about 5 expected events per cell; Fisher is exact.

Why the reference is a fixed observed count and not a nominal rate: the reference is itself a measurement with its own noise (the exact 95% Clopper-Pearson interval for 3/500 is 0.12% to 1.74%, Inferred). Conditioning on both counts carries that uncertainty into the verdict.

Every needle file is tested separately (`needle.json` and each `needle-c*.json`) against the same reference, and the arm passes only if all pass. Runs are not pooled by the code.

## 3. Why not 120/120 any more

The §27.4 gate was "zero errors in 120". At the reference rate of 0.6%, a configuration as good as the reference comes out clean in 120 runs with probability `0.994^120 = 0.49` (Inferred). Half of good arms would fail by chance. Observed cases: SGLang FP8 went 117/120 then 119/120 on two runs of the same server (§29.1); vLLM DCP1 went 117/120 at C8 on host 157204, then 500/500 on host 48294. And 120/120 cannot rank two good arms: telling 0% from 0.8% needs on the order of a thousand runs per arm (§29.4).

## 4. Why 500 runs, and what 500 runs can and cannot see

`NEEDLE_RUNS` defaults to 500 in `run_benchmark.sh` and `vast.sh` since 2026-11-12. The C16 file stays at 120.

### 4.1 Critical error counts

Smallest error count that fails against `3/500` (Inferred, computed with `fisher_one_sided`):

| Runs in the arm | Fails at this many errors or more | Error rate at the threshold |
|---|---|---|
| 120 | 4 | 3.3% |
| 240 | 6 | 2.5% |
| 500 | 10 | 2.0% |
| 620 | 12 | 1.9% |
| 1,000 | 18 | 1.8% |
| 2,000 | 34 | 1.7% |
| 5,000 | 80 | 1.6% |

### 4.2 Power: can it tell 0.6% from 2%?

Probability that an arm fails the gate, by its true error rate, with the reference fixed at 3/500 (Inferred, exact binomial sums over the arm's error count):

| Arm runs | True 0.6% (as good as reference) | 0.8% | 1% | 2% | 4% |
|---|---|---|---|---|---|
| 120 | 0.6% | 1.6% | 3.3% | 22% | 71% |
| 240 | 0.35% | 1.3% | 3.5% | 35% | 92% |
| 500 | 0.11% | 0.8% | 3.1% | 54% | 99.6% |
| 620 | 0.05% | 0.5% | 2.4% | 59% | 99.9% |
| 1,000 | 0.01% | 0.2% | 1.4% | 71% | 100% |
| 2,000 | 0.00% | | | 85% | |
| 5,000 | 0.00% | | | 98% | |

Reading:

- At 500 runs a good arm almost never fails (0.11%), so the gate does not waste money on false alarms. That is what the 120/120 rule got wrong.
- At 500 runs an arm with a true 2% error rate (3.3 times the reference) fails only 54% of the time. 500 runs separate "broken" (the SGLang NVFP4 arms at 4% to 12%, all caught with p below 1e-4) from "good", and they do not reliably catch a mild regression to 2%.
- Power grows slowly past 1,000 runs because the reference has only 500 runs: its own noise becomes the limit. To reach about 80% power against 2% you need a larger reference too. With both arms measured at the same size and both random (true 0.6% against 2%), power is 53% at 500 runs each, 73% at 750, 85% at 1,000 and 96% at 1,500 (Inferred, summed over the reference's binomial distribution with the critical value recomputed for each reference count).
- The real false-fail rate with a random reference is higher than with a fixed one: 1.5% at 500 each, 2.6% at 1,000, 3.1% at 1,500, still below the nominal 5% (Fisher is conservative on discrete counts).

Rule of thumb (Inferred): 500 runs is a pass or fail screen for gross numerical breakage. To claim that two good configurations differ, run about 1,000 to 1,500 per arm and remeasure the reference with the same count on the same host.

### 4.3 How long 500 runs take

DCP1 on host 157204 ran 120 needle requests at C8 in about 20 s (`hardware_run_summary.duration_seconds` 19.8, Observed), so 500 runs take about 85 s at that speed (Inferred). The cost is negligible next to the agent levels.

## 5. Worked p-values on our real results

One-sided p against 3/500 (Inferred with `fisher_one_sided`). Raw counts are Observed in each `needle*.json` (`selected_summary`). The journal's §29.5 table gives two-sided p-values on some of these; the conclusions do not change.

| Arm and file | Errors / runs | One-sided p | Verdict |
|---|---|---|---|
| vLLM DCP4 run 2, C8 (the reference itself) | 3 / 500 | 0.66 | pass |
| vLLM DCP4 run 1, C8 and C16 | 0 / 120, 0 / 120 | 1 | pass |
| vLLM DCP1 run 1 (157204), C8 | 3 / 120 | 0.090 | pass |
| vLLM DCP1 run 1, C16 | 1 / 120 | 0.58 | pass |
| vLLM DCP1 run 2 (48294), C8 and C16 | 0 / 500, 0 / 120 | 1 | pass |
| vLLM DCP1 pooled by hand, C8 | 3 / 620 | 0.75 | pass |
| SGLang FP8 `ormandj`, C8 | 1 / 120 | 0.58 | pass (printed `REPROVA` in the 2026-11-11 `resumo.md` under the old rule) |
| SGLang FP8 `ormandj-portao1`, C8 | 3 / 120 | 0.090 | pass |
| SGLang FP8 pooled by hand, C8 | 4 / 240 | 0.16 | pass |
| SGLang NVFP4 `09b04e5e`, C8 | 26 / 120 | 5.8e-17 | fail |
| SGLang NVFP4 `1d00738`, MoE W4A4, C8 | 60 / 500 | 8.2e-16 | fail |
| same, C16 | 19 / 120 | 7.5e-12 | fail |
| same, MoE Marlin W4A16, C8 | 32 / 500 | 1.4e-7 | fail |
| same, C16 | 5 / 120 | 0.0086 | fail |
| same, Marlin, no speculation, SSM FP32 (`nvfp4-marlin-limpo`), C8 | 22 / 500 | 6.6e-5 | fail |
| same, C16 | 10 / 120 | 9.0e-6 | fail |

The closest call is DCP1 run 1 at 3/120 (p = 0.090): passing, with 120 runs that cannot say much. The 500/500 of run 2 settles it for DCP1 under this gate.

## 6. Reproduce the numbers

```bash
cd bench
python3 -c "import summarize as s; print(s.fisher_one_sided(3, 120, 3, 500))"     # 0.0901...
python3 - <<'EOF'
import summarize as s
from math import lgamma, log, exp
def pmf(n, k, p): return exp(lgamma(n+1)-lgamma(k+1)-lgamma(n-k+1)+k*log(p)+(n-k)*log(1-p))
def crit(n, r=3, m=500): return next(e for e in range(n+1) if s.fisher_one_sided(e, n, r, m) < 0.05)
for n in (120, 500, 1000):
    c = crit(n)
    print(n, c, sum(pmf(n, k, 0.02) for k in range(c, n+1)))   # power against a true 2%
EOF
```

## 7. When to change the reference

Keep `--needle-ref 3/500` unless a new reference arm is measured with at least 500 runs on a qualified host, with the production image and checkpoint. Say so in the report and pass the new value explicitly. A different checkpoint revision or MoE backend changes the numerics and needs its own reference (the upstream table gives 0% with W4A16, 6% to 9% with W4A4 and 18% to 23% for a checkpoint before QAD; Reported in the llm-inference-bench README via §29.4).
