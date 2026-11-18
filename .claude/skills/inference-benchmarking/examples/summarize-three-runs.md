# Real `summarize.py` output on three runs

Use this to know what a normal summary looks like, and to practise reading one. The three directories are vLLM on Vast host 157204 (Nevada, 4x RTX PRO 6000 Server Edition, driver 615.71.09, US$ 5.61/h read 2026-11-11). Real model GLM-5.3-Flash QAD NVFP4, image `karmic-kraken-20261016`, TP4 with MTP3. Every table is Observed: the command was run on 2026-11-12 from `bench/` against the archive, and the output is pasted unchanged.

The archive directories were written before the translation, so their files carry the Portuguese names (`motor.txt`, `agentes-<N>.json`). `summarize.py` reads both name sets.

## Command

```bash
cd bench
python3 summarize.py --price 5.61 --needle-ref 3/500 <dir>
```

## Run A: DCP1, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1` (one run on this host)

```
| Engine | Needle | gsm8k | Sessions in SLO | Sessions per US$/h |
|---|---|---|---|---|
| vllm | 97.5% ok | 99.0% | 24 | 4.28 |

| Engine | Agents | Errors | Steady since (s) | Steady turns | TTFT p95 (s) | tok/s p50 per stream | Cache % | Recomputed p50 | Recomputed p90 | SLO |
|---|---|---|---|---|---|---|---|---|---|---|
| vllm | 16 | 0 | 380 | 212 | 4.71 | 70.8 | 97.2 | 3,566 | 5,804 | pass |
| vllm | 24 | 0 | 470 | 326 | 4.93 | 55.3 | 97.2 | 3,432 | 5,559 | pass |
```

How to read it:

- `97.5% ok`: 117 of 120 needle runs right at C8; `ok` means every needle file passed the Fisher test against 3/500 (C8 p = 0.090, C16 1/120 p = 0.58).
- `99.0%`: gsm8k 95 of 96. Printed, not gated.
- `24` sessions: both tested levels pass. The true limit is between 24 and the next level never tested here (32). Lower bound.
- `4.28` = 24 / 5.61.
- Level 24: steady state starts at 470 s of a 1,200 s level, leaving 326 cached turns. TTFT p95 4.93 s is 0.07 s below the target: a thin margin.
- Cache 97.2% and about 3,400 recomputed tokens per turn at p50: the prefix cache holds each agent's history and only the new tool block is prefilled.

## Run B: DCP4 run 1, `f3/resultados/vast-20261111/vllm/vast-vllm-r1`

```
| Engine | Needle | gsm8k | Sessions in SLO | Sessions per US$/h |
|---|---|---|---|---|
| vllm | 100.0% ok | 97.9% | 16 | 2.85 |

| Engine | Agents | Errors | Steady since (s) | Steady turns | TTFT p95 (s) | tok/s p50 per stream | Cache % | Recomputed p50 | Recomputed p90 | SLO |
|---|---|---|---|---|---|---|---|---|---|---|
| vllm | 8 | 0 | 167 | 65 | 3.37 | 90.3 | 96.5 | 3,219 | 5,272 | pass |
| vllm | 16 | 0 | 416 | 159 | 4.77 | 57.2 | 96.9 | 3,731 | 5,840 | pass |
| vllm | 24 | 0 | n/a | 0 | n/a | n/a | n/a | n/a | n/a | short sample |
| vllm | 32 | 0 | 724 | 325 | 6.08 | 37.7 | 96.8 | 3,705 | 5,785 | fail |
```

How to read it:

- Levels 8 and 24 come from a different attempt than 16 and 32. `agentes-8.json` and `agentes-24.json` are byte-identical to the files in `vast-vllm-r1/agentes-7min/` (420 s levels); 16 and 32 ran for 900 s and 1,500 s. Check `metadata.settings.agents_duration` of each file before trusting a row.
- Level 24 is `short sample` because only 20 of 24 agents finished turn 0 in 420 s, so no steady state existed. The journal and `docs/03` describe DCP4 at 24 agents as "not measured"; strictly it was attempted for 7 minutes and gave no usable sample.
- Level 32 fails on TTFT (6.08 s) with per-stream speed still above 30 tok/s: DCP4 runs out of queueing headroom before it runs out of decode speed.
- `16` sessions: 8 and 16 pass; 24 stops the count.

## Run C: DCP4 run 2, `f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2`

```
| Engine | Needle | gsm8k | Sessions in SLO | Sessions per US$/h |
|---|---|---|---|---|
| vllm | 99.4% ok | 100.0% | 0 | 0.00 |

| Engine | Agents | Errors | Steady since (s) | Steady turns | TTFT p95 (s) | tok/s p50 per stream | Cache % | Recomputed p50 | Recomputed p90 | SLO |
|---|---|---|---|---|---|---|---|---|---|---|
| vllm | 16 | 0 | 390 | 178 | 5.20 | 57.8 | 97.0 | 3,715 | 5,814 | fail |
| vllm | 24 | 0 | 491 | 268 | 5.97 | 47.1 | 97.0 | 3,314 | 5,445 | fail |
```

How to read it:

- `0` sessions: level 16 is the smallest level tested and it fails, so the count is zero. Level 8 was not rerun, so this run says nothing about 8 agents.
- Same arm, same host, same seed as run B, and level 16 moved from 4.77 s (pass) to 5.20 s (fail). That is why one run is never enough and why the skill reports DCP4 as 8 sessions (Inferred: the only level that passed in every run where it was tested, with one run at 8).
- `99.4%`: 497 of 500 needle runs. This file is the 3/500 reference of the Fisher test.

## The three runs side by side

| Arm | Run | Level 16 TTFT p95 | Level 24 TTFT p95 | Sessions | Sessions per US$/h at 5.61 |
|---|---|---|---|---|---|
| DCP1 | A | 4.71 s | 4.93 s | 24 | 4.28 |
| DCP4 | B | 4.77 s | no steady state | 16 | 2.85 |
| DCP4 | C | 5.20 s | 5.97 s | 0 | 0.00 |

Conclusion recorded in `ARQUITETURA.md §29.6`: DCP1 is the profile, at 24 sessions from one run, pending a second run on a qualified host. The second DCP1 run (host 48294) failed for host reasons, see `host-48294-qualification-failure.md`.
