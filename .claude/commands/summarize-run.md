---
description: Summarize a benchmark result directory into an evidence-labelled report (SLO, sessions per US$/h, quality)
argument-hint: <result directory> [price per hour]
---

Summarize the benchmark results in `$ARGUMENTS`. Load the `inference-benchmarking` and `capacity-and-cost` skills first.

1. Run `python3 f3/sglang/resumir.py --preco <US$/h> --needle-ref 3/500 <dir>` (`--preco` is required; use the price actually charged and say when it was read) and read its output and the files it reads.
2. Report, in this order: quality verdict; highest agent level inside the SLO and which SLO term failed at the next level; TTFT p95 of cached steady-state turns and per-stream p50 at that level; sessions inside the SLO per US$/h with the arithmetic shown; host, driver, date, price and the date it was read; how many runs this configuration has.
3. Label every number (Observed with the file path; Inferred for derived numbers).
4. Compare with earlier runs only when both hosts passed qualification. If this result contradicts an earlier one, say which one is newer and add the contradiction to `docs/README.md`.
5. Never edit files in the result directory.
