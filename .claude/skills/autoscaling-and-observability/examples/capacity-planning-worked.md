# Worked example: replicas, floor and triggers for 1,000 users

A step-by-step calculation from measured capacity to a scheduled floor and reactive triggers. The measured inputs are labelled; the demand inputs are the Base row of the `capacity-and-cost` skill, which are mostly Hypothesis. The result is illustrative: it shows the method, not a commitment. Redo it with phase 2 capacity and phase 0 telemetry.

## Inputs

| Input | Value | Label and source |
|---|---|---|
| Capacity per replica `C` | 24 agent sessions inside the SLO, DCP1 | Observed, one run, Vast host 157204 (`f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/agentes-24.json`); the two-run rule is not yet met |
| Users `U` | 1,000 | phase 1 scale (§18.6) |
| Demand factors d, h, s | 0.40, 0.50, 1.3 | Base row, mix of Reported and Hypothesis (capacity-and-cost skill) |
| Share of time in the loop `φ` | 0.41 | Inferred: Weka 0.256 corrected for a GLM request taking about 2 times Claude's (b = 2, §24.2) |
| Streams per looping session `f` | 1.15 | Observed on the Weka corpus (§24.1) |
| Price of one replica | US$ 16.57/h, `g7e.24xlarge` on-demand list, `us-east-1` | Observed on 2026-11-04 (docs/06), not re-checked |
| Lead time `L` | 21 to 23 min cold; 8 to 12 min target with seeded caches | Observed on Nebius (§17.2); target Inferred; AWS Unknown |

One agent in the harness keeps one request in flight almost all the time (client in-flight mean 23.1 of 24, Observed), so `C` is counted in concurrent streams.

## Step 1: streams at peak

```
L_loop = U x d x h x s x φ = 1000 x 0.40 x 0.50 x 1.3 x 0.41 = 106.6 looping sessions
S      = L_loop x f        = 106.6 x 1.15                     = 122.6 concurrent streams
```

## Step 2: replicas at peak

```
working replicas = ceil(S / C) = ceil(122.6 / 24) = ceil(5.11) = 6
plus N+1         = 1
peak floor       = 7 replicas = 7 g7e.24xlarge
```

At 6 working replicas the average load is 122.6 / 6 = 20.4 streams per replica, 85% of `C`. Poisson margin is not added here; the capacity-and-cost skill adds it for the fleet table.

## Step 3: cost of two schedules

```
24x7 at 7 replicas:          7 x 16.57 x 730 h                      = US$ 84,673 per month
scheduled floor:             7 replicas for 10 h x 22 workdays (220 h)
                             2 replicas for the other 510 h
                             (7 x 220 + 2 x 510) x 16.57 = 2,560 x 16.57 = US$ 42,419 per month
```

The scheduled shape mirrors the §20.1 usage pilot (10 h per workday). It halves the bill, and it is only possible because the floor is planned: reactive scaling alone would meet the morning ramp with replicas that serve 8 to 23 min later.

## Step 4: when to launch

```
peak start (first user load at full curve)   09:00
floor reached (15 to 20 min before, §18.3)    08:40 to 08:45
launch time = floor time minus L              08:17 (cold, L = 23 min) or 08:28 (seeded, L = 12 min)
```

In the illustrative ScaledObject (`keda-scaledobject.illustrative.yaml`) this is the cron trigger window. On plain EC2 it is an Auto Scaling group scheduled action at the launch time.

## Step 5: reactive trigger

```
trigger = C - r x L
```

`r` is the p95 growth of streams per replica per minute during the morning ramp, measured from gateway telemetry. With no telemetry, `r` is Unknown; start at `0.75 x C = 18`. Example values (illustrative, not measured):

| r (streams per replica per min) | L (min) | trigger |
|---|---|---|
| 0.3 | 10 | 24 - 3 = 21 |
| 0.3 | 23 | 24 - 6.9 = 17.1 |
| 0.6 | 10 | 24 - 6 = 18 |

A longer lead time lowers the trigger, which means more idle headroom paid for. Cutting `L` from 23 to 10 min (seeded JIT cache, image in a regional registry, `instanttensor`) raises the usable load per replica as much as a faster engine would.

## Step 6: sanity checks against measured data

- The KV ceiling does not bind at this load: DCP1 at 24 streams peaked at 0.73 KV usage (Observed). With DCP4 KV never passed 0.28, but DCP4 capacity is 16 or less, so the same demand needs `ceil(122.6 / 16) + 1 = 9` replicas (Inferred).
- A sub-agent burst of 51 (llm-d p90 fan-out, Reported) lands on a cell of 6 working replicas with 6 x 32 = 192 slots (`max-num-seqs` 32). At 20.4 streams per replica there are about 11.6 free slots per replica, 70 in the cell. The burst fits in the cell but not in one replica, so the router must spread it (llm-d-routing skill, decision 7). Inferred.
- Sessions per US$/h at peak: 122.6 / (7 x 16.57) = 1.06; the DCP1 replica alone is 24 / 16.57 = 1.45 (docs/06). The gap is the N+1 replica and the headroom below `C`.
