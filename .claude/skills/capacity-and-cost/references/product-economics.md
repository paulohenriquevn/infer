# Product economics: cost per user, the API comparison, and what "unlimited" costs

Read this when someone asks what a user costs, what to charge, or whether the Z.ai API is cheaper than self-hosting. Sources: `ARQUITETURA.md §18.2`, `§19`, `§20`, and the 10k report (project research note "Arquitetura para 10 mil usuários", not published; the figures used are copied here). Fleet costs come from `fleet-recalculation.md`.

## 1. The product decision

The product sells unlimited tokens at a fixed monthly price per user (Paulo's decision, §19; `docs/01`). The decision criterion is a known cost per user inside the SLO, not cost per token. We do not try to beat the API on cost per token: at the modeled demand the API is cheaper (section 4).

## 2. Cost per user

```
cost_per_user_month = monthly_fleet_cost / U
selling_price       = cost_per_user_month / (1 - gross_margin)
```

### Stale figures (do not quote as current)

§19.1 at Nebius list, 40 streams per replica, f = 1.3, phi at Claude latency (Inferred there):

| Scenario | VMs | US$ per user per month | Price at 30% margin | Price at 50% margin |
|---|---|---|---|---|
| Base | 15 | 15.8 | 15.8 / 0.7 = 22.6 | 31.6 |
| High (Anthropic anchor) | 24 | 25.2 | 36.0 | 25.2 / 0.5 = 50.4 |
| Stress (all factors high) | 75 | 78.8 | 112.6 | 157.6 |

### Current provisional figures (Inferred, from `fleet-recalculation.md`)

Base demand, b = 2, 10,000 users, 730 h per month:

| Capacity per replica | Nebius list | AWS EC2 Instance SP 3yr | AWS on-demand |
|---|---|---|---|
| 24 (DCP1, one run) | US$ 35.74 | US$ 35.54 | US$ 82.26 |
| 8 (DCP4, one run) | US$ 106.17 | US$ 105.05 | US$ 243.16 |

At 30% gross margin the DCP1 Nebius figure gives a price of 35.74 / 0.7 = US$ 51.06 per user per month (Inferred). Reference plans with limits (Reported, §19.1): Z.ai Lite US$ 18, Pro US$ 72, Max US$ 160; Claude Max US$ 200.

## 3. Unit cost of self-hosting at full use

Self-host at 100% utilization, Nebius list (US$ 7.20 per replica-hour), no SLO, DCP4 R1 constants (Inferred, 10k report §1):

- Output: 7.2 / (1,425 tok/s x 3,600) x 10^6 = US$ 1.40 per 1M tokens.
- New input: 7.2 / (4,100 tok/s x 3,600) x 10^6 = US$ 0.49 per 1M tokens.

The two do not add up: prefill and decode share the replica.

## 4. The API

Z.ai list price for GLM-5.3-Flash, US$ per 1M tokens (https://docs.z.ai/guides/overview/pricing, read 2026-11-12):

| Item | Price |
|---|---|
| Input | 0.15 |
| Cached input | 0.03 |
| Cached input storage | free for a limited time |
| Output | 0.50 |

Same page: GLM-5.3 at 1.4 / 0.26 / 4.4 and GLM-5.3-FlashX at 0.37 / 0.075 / 1.25 (input, cached input, output). These match the 10k report's values of 2026-11-05. The 10k report also mentions a 50% off-peak discount (14:00 to 18:00 UTC+8); the pricing page read on 2026-11-12 does not show it, so it is Unknown.

Cached input is 68% of the API bill in a typical agent step, and almost free when self-hosted (10k report §1).

The Z.ai coding plan forbids use as a product backend (§18.2), so the comparison is with the metered API.

### Break-even utilization (10k report Table 2, Inferred there)

Utilization at which self-hosting costs the same as the API per session-hour:

| Call weight | Sessions per replica assumed | Self-host at 100%, US$ per session-hour | API, US$ per session-hour (100K context) | Break-even | With 120K cached context |
|---|---|---|---|---|---|
| Low (P 8,500, O 4,000) | 25 | 0.288 | 0.223 | 129% (API always wins) | 113% |
| Base (P 4,000, O 1,500) | 40 | 0.180 | 0.295 | 61% | 52% |
| High (P 1,100, O 690) | 80 | 0.090 | 0.315 | 29% | 24% |

A fleet sized for one time zone's peak runs at 20% to 34% average utilization, 15% to 18% after margin and N+1 (§18.2). These rows assumed 25, 40 and 80 sessions per replica; with 24 measured (DCP1) the base row's self-host cost becomes 7.2 / 24 = US$ 0.30 per session-hour, about equal to the API at 100% utilization (Inferred).

### Fleet against API at scale (10k report Table 1, stale capacity)

| Users and scenario | Streams | Nebius fleet, US$ k per month (load / total) | Z.ai API, US$ k per month | Fleet over API |
|---|---|---|---|---|
| 1,000, base | 85 | 21.0 / 31.5 | 5.1 | 6.2x |
| 10,000, low | 166 | 31.5 / 42.0 | 14.2 | 3.0x |
| 10,000, base | 845 | 126.1 / 157.7 | 50.6 | 3.1x |
| 10,000, high (Anthropic anchor) | 1,460 | 210.2 / 252.3 | 87.4 | 2.9x |
| 10,000, stress | 4,608 | 651.7 / 788.4 | 229.8 | 3.4x |

With 24 per replica instead of 40, the fleet column grows; the API column does not. Inferred: the gap widens.

## 5. Under unlimited tokens the API is an uncapped bill

Per loop-hour (§19.1): fleet US$ 0.18 at 100% utilization (7.2 / 40, inherits the 40 assumption; US$ 0.30 with 24), API US$ 0.295 in the base case. A user who loops 15, 88 or 300 hours per month costs US$ 4.4, 26 or 88 per month on the API. A fixed price on top of the API loses money on heavy users; the fleet's cost is fixed and its risk is the SLO instead.

## 6. When self-hosting wins

Only with GPUs 33% to 43% cheaper than Nebius list, very good caching, users spread across time zones, or for reasons other than cost: data residency, the API's concurrency limit (not published, Unknown), control of quantization and parser (§18.2). A 3-year EC2 Instance Savings Plan prices a G7e replica at the Nebius list (`providers.md`), so it does not reach the 33% by itself.

## 7. Controls "unlimited" still needs

From §19.3 and §20:

- Per-user cap on simultaneous streams: 2 in the MVP (Hypothesis). Without it demand drifts to the stress row (4,608 streams).
- Fair share at peak: the scheduler keeps one user from taking a replica.
- Acceptable-use policy, one key per user, anomaly detection.

## 8. Open product questions (Paulo, §19.5)

- Per-user stream cap: 2, 3 or 4.
- Single price or tiers.
- Whether background agents are inside "unlimited".
- Definition of "user" (registered, MAU, DAU, seat).
