# Sessions inside the SLO per US$/h, per provider

Use this when you compare providers on the primary metric. Capacity is Observed on one Vast host (157204) and the per-provider rows assume every provider's hosts perform like it, which nobody has tested (Hypothesis). Prices are Reported on public pages and APIs, read on the dates shown. Each cell is `sessions per replica / US$ per replica-hour` (Inferred, arithmetic in the cell).

Capacity inputs:

- DCP1, 24 agents: one run, host 157204, TTFT p95 4.93 s (`f3/resultados/vast-20261111/vllm/vast-vllm-dcp1`).
- DCP4, 16 agents: passed in run 1 (4.77 s), failed in run 2 (5.20 s).
- DCP4, 8 agents: one run, a 420 s level of run 1 (`vast-vllm-r1/agentes-8.json`, same file as in `agentes-7min/`).

| Provider, offer (date read) | US$ per replica-hour | DCP1, 24 | DCP4, 16 | DCP4, 8 |
|---|---|---|---|---|
| Vast host 157204 (2026-11-11) | 5.61 | 24 / 5.61 = 4.28 (Observed, `summarize.py`) | 16 / 5.61 = 2.85 (Observed, run 1) | 8 / 5.61 = 1.43 |
| Vast cheapest Server Edition offer, reliability above 0.95, Florida (2026-11-12) | 5.33 | 4.50 | 3.00 | 1.50 |
| AWS `g7e.24xlarge` EC2 Instance SP 3yr all upfront, `us-east-1` (2026-11-12) | 6.23113 | 3.85 | 2.57 | 1.28 |
| AWS `g7e.24xlarge` EC2 Instance SP 3yr no upfront (2026-11-12) | 7.15917 | 3.35 | 2.23 | 1.12 |
| Nebius list, 8-GPU VM 14.40 / 2 (2026-11-12) | 7.20 | 3.33 | 2.22 | 1.11 |
| AWS `g7e.24xlarge` Compute SP 3yr no upfront (2026-11-12) | 9.66488 | 2.48 | 1.66 | 0.83 |
| AWS `g7e.24xlarge` EC2 Instance SP 1yr no upfront (2026-11-12) | 10.44046 | 2.30 | 1.53 | 0.77 |
| AWS `g7e.24xlarge` Compute SP 1yr no upfront (2026-11-12) | 13.05058 | 1.84 | 1.23 | 0.61 |
| AWS `g7e.24xlarge` on-demand, `us-east-1` (2026-11-12) | 16.57216 | 1.45 | 0.97 | 0.48 |
| AWS `g7e.24xlarge` on-demand, Europe (Spain) (2026-11-12) | 17.46268 | 1.37 | 0.92 | 0.46 |
| AWS `g7e.24xlarge` on-demand, EU (Frankfurt) (2026-11-12) | 28.18177 | 0.85 | 0.57 | 0.28 |

How to read it:

- Profile matters more than provider: DCP1 against DCP4 at 8 is 3 times on every row.
- AWS on-demand delivers about a third of the metric of Vast 157204 (1.45 against 4.28); a 3-year EC2 Instance Savings Plan brings it to the Nebius list level.
- The Vast rows are for measurement and bursts only (provider policy in `../references/providers.md`), and the Florida offer has not been qualified.
- Never compare these with the 12.3 sessions per US$/h of §12.4: that is 88.7 sessions of 262,144 tokens that fit in HBM divided by US$ 7.20, with no speed check and no SLO.

Reproduce one cell from a run directory:

```bash
cd bench
python3 summarize.py --price 7.15917 --needle-ref 3/500 <path>/vast-vllm-dcp1   # AWS SP 3yr price, DCP1 run
```

`summarize.py` prints `Sessions per US$/h` in its first table; it is 0 when the run fails the quality gate.
