# Fleet recalculation (provisional)

Read this before you quote a fleet size, a replica count or a monthly cost for N users. It replaces the §18.1 table with current inputs and shows every step. Everything here is **Inferred** and **provisional**: the capacity inputs are single runs, and b (our request time over Claude's) is Unknown. The script that produced every number is `../examples/fleet_model.py`; the full grid is `../examples/fleet-model.csv`.

## 1. Inputs and their status

| Input | Value used | Status |
|---|---|---|
| U | 10,000 | product target |
| d, h, s | 0.40, 0.50, 1.3 (base); low and high in the CSV | Reported plus Hypothesis (`demand-model.md`) |
| phi at Claude latency | 0.256 | Observed on Weka (§24.1) |
| b | 1, 2, 2.5, 3 | Unknown; 2 is the §24.2 estimate |
| f | 1.15 | Observed on Weka (1.146) |
| Sessions inside the SLO per replica | 24 (vLLM DCP1) and 8 (vLLM DCP4); 16 shown for DCP4 run 1 | **24 is one run** (host 157204, 0.07 s margin); **8 is one run** (a 420 s level of DCP4 run 1, never repeated); 16 passed once and failed once |
| Prices | see table in section 4 | Observed on public price pages, read 2026-11-12 |
| Hours per month | 730 | convention of §18.1 |

## 2. Method (from §18.1 and the 10k report)

```
phi'           = b x phi / (b x phi + (1 - phi))
L              = U x d x h x s x phi'
S              = L x f
replicas_raw   = S / sessions_per_replica          one harness agent is treated as one stream
poisson_margin = 1 + 3 / sqrt(L)                   three standard deviations of a Poisson count
replicas       = ceil(replicas_raw x poisson_margin)
load_machines  = ceil(replicas / replicas_per_machine)
spare_machines = ceil(load_machines / 5)           one N+1 machine per 5 loaded
monthly_cost   = (load_machines + spare_machines) x price_per_machine_hour x 730
```

The spare rule `ceil(load / 5)` is read off the old table rows (1 load gives 2 total, 2 give 3, 12 give 15, 20 give 24, 62 give 75), Inferred.

Mapping harness agents to streams (Inferred, the only mapping the docs use, never measured): a harness agent thinks 0 to 3 s, so it is close to a stream that never leaves the loop. Two things the harness does not generate are left out: correlated sub-agent bursts (Weka group median 16, p99 175 requests, against 32 slots per replica) and GLM's real output length.

### Check: reproduce the old base row first

`python3 fleet_model.py --check` runs the method with the §18.1 inputs (phi 0.25, b = 1, f = 1.3, 40 per replica, Nebius at US$ 14.40 per 8-GPU VM):

```
S = 10,000 x 0.40 x 0.50 x 1.3 x 0.25 x 1.3 = 845
replicas_raw = 845 / 40 = 21.1;  margin = 1 + 3 / sqrt(650) = 1.118;  21.1 x 1.118 = 23.6 -> 24 replicas
24 / 2 = 12 load VMs;  ceil(12 / 5) = 3 spare;  15 VMs;  15 x 14.40 x 730 = US$ 157,680 per month
```

Output: `old base row reproduced: 845.0 streams, 15 VMs, US$ 157680`. That matches the 10k report Table 1 (12 / 15 VMs, US$ 157.7k). If your version of the method does not reproduce it, fix the method before changing inputs.

## 3. Worked example: base demand, b = 2, DCP1, AWS on-demand

```
phi'  = 2 x 0.256 / (2 x 0.256 + 0.744) = 0.512 / 1.256 = 0.4076
L     = 10,000 x 0.40 x 0.50 x 1.3 x 0.4076 = 1,059.9
S     = 1,059.9 x 1.15 = 1,218.9
raw   = 1,218.9 / 24 = 50.79
margin = 1 + 3 / sqrt(1,059.9) = 1 + 3 / 32.56 = 1.0921
replicas = ceil(50.79 x 1.0921) = ceil(55.47) = 56
g7e.24xlarge (1 replica each): load 56, spare ceil(56 / 5) = 12, total 68
cost  = 68 x 16.57216 x 730 = US$ 822,642 per month = US$ 82.26 per user
```

Same replicas on Nebius 8-GPU VMs (2 replicas each): load 28, spare 6, 34 VMs, 34 x 14.40 x 730 = US$ 357,408 per month (US$ 35.74 per user).

## 4. Results at base demand (10,000 users)

Monthly cost in US$ thousands, total machines in parentheses. AWS rows use `g7e.24xlarge` (one replica per instance); `g7e.48xlarge` gives the same or 1% more because of rounding (CSV).

### DCP1, 24 sessions per replica (one run)

| b | L | S | Replicas | AWS on-demand 16.57/h | AWS EC2 Instance SP 1yr 10.44/h | AWS EC2 Instance SP 3yr 7.16/h | Nebius list 14.40 per 8-GPU VM |
|---|---|---|---|---|---|---|---|
| 1 | 665.6 | 765.4 | 36 | 532.3 (44) | 335.3 (44) | 230.0 (44) | 231.3 (22) |
| 2 | 1,059.9 | 1,218.9 | 56 | 822.6 (68) | 518.3 (68) | 355.4 (68) | 357.4 (34) |
| 3 | 1,320.6 | 1,518.7 | 69 | 1,004.1 (83) | 632.6 (83) | 433.8 (83) | 441.5 (42) |

### DCP4, 8 sessions per replica (one run)

| b | Replicas | AWS on-demand | AWS SP 1yr | AWS SP 3yr | Nebius list |
|---|---|---|---|---|---|
| 1 | 107 | 1,560.6 (129) | 983.2 (129) | 674.2 (129) | 683.3 (65) |
| 2 | 167 | 2,431.6 (201) | 1,531.9 (201) | 1,050.5 (201) | 1,061.7 (101) |
| 3 | 206 | 3,000.2 (248) | 1,890.1 (248) | 1,296.1 (248) | 1,303.5 (124) |

### DCP4, 16 sessions per replica (passed once, failed once), b = 2

84 replicas: AWS on-demand US$ 1,221.9k (101 instances), Nebius US$ 536.1k (51 VMs).

### Per user per month at b = 2

| Capacity | AWS on-demand | AWS SP 3yr | Nebius list |
|---|---|---|---|
| 24 (DCP1) | US$ 82.26 | US$ 35.54 | US$ 35.74 |
| 8 (DCP4) | US$ 243.16 | US$ 105.05 | US$ 106.17 |

Compare with the stale US$ 15.8 per user of §19.1 (40 per replica, b = 1, f = 1.3, Nebius list): the corrections multiply it by 2.3 (DCP1 on Nebius) to 15 (DCP4 on AWS on-demand).

## 5. What the table says (Inferred)

- Capacity per replica is the largest lever left: 24 against 8 is a 3 times difference in fleet cost. Confirming DCP1 at 24 in a second run (`docs/06` phase 2) is worth more than any price negotiation.
- b moves the fleet by 1.6 to 2.0 times between 1 and 3. EK9 is the second most valuable measurement.
- An EC2 Instance Savings Plan of 3 years brings AWS to the Nebius list price per replica (7.16 against 7.20 per replica-hour). A 1-year plan is 45% above Nebius per replica. The commitment is per hour for the term, so it only pays for the base load, not for N+1 or bursts kept off (Inferred from the Savings Plans model).
- Nebius cannot host the base: the "full" quota tier allows 32 GPUs per region in 3 regions, 12 VMs (10k report §3), against 34 VMs at b = 2 with DCP1.
- At base demand every combination costs more than the Z.ai API did in the old table (US$ 50.6k per month at 845 streams). See `product-economics.md`.

## 6. Limits of this recalculation

- Single runs on one Vast host. AWS and Nebius hosts have not been measured; their capacity per replica is assumed equal to host 157204 (Hypothesis).
- The Poisson margin covers independent arrivals only; correlated sub-agent bursts from several users are outside it (10k report §4).
- The growth unit is a cell of 3 working machines plus 1 N+1, with at least 2 machines per cell (§17.3, §18.3). The table rounds per machine, not per cell; rounding to cells adds up to 3 machines.
- Reactive autoscaling cannot cover a 21 to 23 min cold start, so a scheduled floor 15 to 20 min before the peak is part of the cost (§18.3). The table prices a fleet on 24 h a day; a fleet that scales down off-peak costs less, by an amount not modelled here.
- The per-user cap on simultaneous streams (2 in the MVP, Hypothesis) is not modelled. Without it, demand drifts to the stress row.

## 7. How to redo it when an input changes

1. Edit the constants at the top of `../examples/fleet_model.py` (`PRICES`, `CAPACITIES`, `DEMAND`, `PHI_WEKA`, `F_WEKA`), with the read date in each price's `source`.
2. `python3 fleet_model.py --check` must still print the old base row.
3. `python3 fleet_model.py > fleet-model.csv`.
4. Update the tables above and the date in this file. Label every number Inferred, and list which inputs are still single runs or Hypothesis.
