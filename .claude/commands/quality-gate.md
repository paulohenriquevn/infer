---
description: Run and judge the quality gate (needle-checksum + gsm8k, one-sided Fisher vs 3/500) for a serving configuration
argument-hint: <result directory or configuration name>
---

Run or judge the quality gate for `$ARGUMENTS`. Load the `inference-benchmarking` and `glm53-flash-model` skills first.

1. If no result exists yet, run the gate with the harness (`GATE_ONLY=1 bench/run_benchmark.sh`; it runs 500 needle runs at C8 by default, 120 at C16 and 96 gsm8k questions, and prints `FAIL` or `OK: gate only`). With `STOP_ON_GATE_FAIL=1` it stops on the same one-sided Fisher test as `summarize.py` (`NEEDLE_REF`, default 3/500). The host must have passed `/qualify-host`.
2. Judge a directory that also has agent levels with `python3 bench/summarize.py --price <US$/h> --needle-ref 3/500 <dir>` (`--price` is required; `summarize.py` refuses a directory without `agents-*.json`, or `agentes-*.json` in directories written before the translation). For a gate-only directory, the `run_benchmark.sh` verdict and `summarize.fisher_one_sided(errors, attempts, 3, 500)` (run from `bench/`) give the p-value. gsm8k is read by hand against the reference.
3. Report: errors/attempts for each needle level, the Fisher p-value, gsm8k score, verdict, result path, host, driver, date. Quote the typical wrong answer when there are errors (the known slip is 3330 instead of 3332).
4. A failed gate ends the evaluation of that configuration. Do not report its speed numbers as usable.
