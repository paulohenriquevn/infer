# Demand model: from registered users to concurrent streams at peak

Read this when you need peak demand for a user count, when you change a demand factor, or when someone questions where 845 streams came from. Sources are `ARQUITETURA.md §18`, `§24` and the project research note "Arquitetura para 10 mil usuários" (the 10k report, not published; the facts used are copied here). Every result in this file is Inferred unless marked.

## 1. The formula

```
L  = U x d x h x s x phi        looping sessions at peak
S  = L x f                      concurrent streams at peak
```

| Symbol | Meaning |
|---|---|
| U | registered users |
| d | share of registered users active on a workday |
| h | share of active users engaged during the peak hour |
| s | open sessions per engaged user |
| phi | share of session time the agent is in its loop (sending requests), not waiting for the human |
| f | streams per looping session (sub-agents running at the same time) |

A stream is one agent call in its cycle. A looping session is a session whose agent is working right now.

## 2. Factor values and their support

| Factor | Low | Base | High | Label and source |
|---|---|---|---|---|
| U | | 10,000 | | product target (§19) |
| d | 0.25 | 0.40 | 0.60 | Reported (Jellyfish; Anthropic usage data) for daily use, plus Hypothesis for the monthly active share |
| h | 0.35 | 0.50 | 0.60 | Hypothesis, no direct source |
| s | 1.1 | 1.3 | 1.6 | Reported (Jellyfish); high is Hypothesis |
| phi | 0.15 | 0.25 | 0.40 | Reported (TraceLab, Copilot), Hypothesis anchored on them |
| f | 1.15 | 1.3 | 2.0 | Reported (Copilot median 1.15); base and high Hypothesis |

All factors at one level, U = 10,000 (Inferred):

| Scenario | L | S |
|---|---|---|
| Low | 10,000 x 0.25 x 0.35 x 1.1 x 0.15 = 144.4 | 144.4 x 1.15 = 166 |
| Base | 10,000 x 0.40 x 0.50 x 1.3 x 0.25 = 650 | 650 x 1.3 = 845 |
| All high | 10,000 x 0.60 x 0.60 x 1.6 x 0.40 = 2,304 | 2,304 x 2.0 = 4,608 |

The low row equals the 10k report's "10,000, low" row (166 streams) and the all-high row its "stress" row (4,608 streams, 116 replicas at 40 per replica). The report's "high" row (1,460 streams, 24 VMs) is not a factor combination: it is the Anthropic token anchor of section 6.

## 3. Corrections from the Weka corpus (§24)

The Weka corpus has 393 sessions and 98,827 requests of Claude Code users (Observed by us on the public dataset, §24.1).

| Quantity | Old | Weka | Effect |
|---|---|---|---|
| f | 1.3 | 1.146 (mean) | 12% fewer streams per looping session |
| phi | 0.25 | 0.256 at Claude latency | about the same |
| New tokens per request P | | 3,702 mean | prefill load per turn |
| Prefix hit | | 98.31% | supports a cache-heavy design |
| Loop pause | | 5 s | think time between requests |

Weka caveats (§24.1): it keeps sessions with at least 20 requests, samples "top" sessions and caps sub-agent groups at 10, so it leans to heavy users and tends to overestimate load per user. Sub-agent group size has median 16 and p99 175 requests, against 32 slots per replica: correlated bursts are outside the Poisson margin.

## 4. Correcting phi for our latency

phi was measured on Claude, where a request takes 12.3 s on average (Weka). The loop share grows when each request takes longer, because the human pause stays the same and the loop time stretches. With b = our request time / Claude's request time:

```
phi' = b x phi / (b x phi + (1 - phi))
```

A GLM request on our engine takes about 25 s: `P / 4,100 + O / 44.5 = 0.9 + 24.2` s with the DCP4 R1 constants (prefill 4,100 tok/s, per-stream decode 44.5 tok/s) and Weka's Claude output length as O (§24.2). So b is about 2.

| b | phi' (phi = 0.256) | L grows by |
|---|---|---|
| 1 | 0.256 | 1.00 |
| 2 | 0.512 / 1.256 = 0.4076 | 1.59 |
| 2.5 | 0.640 / 1.384 = 0.4624 | 1.81 |
| 3 | 0.768 / 1.512 = 0.5079 | 1.98 |

b is Unknown until EK9 measures a real agent on GLM (`completion_tokens`, `reasoning_tokens` and time per request). GLM's output per call is Unknown; Weka's O counts Claude tokens. DCP1's faster per-stream decode (55 to 71 tok/s p50 at 16 to 24 agents, Observed) lowers b; reasoning tokens raise it.

Current base (Inferred): `L = 10,000 x 0.40 x 0.50 x 1.3 x 0.4076 = 1,059.9` and `S = 1,059.9 x 1.15 = 1,218.9` at b = 2.

## 5. Which factor moves the fleet most

Ratio of fleet size between the high and low value of one factor, others at base (10k report, §18.5):

| Factor | Swing |
|---|---|
| Call weight (P and O) | 3.2x |
| phi | 2.7x |
| d | 2.4x |
| h | 1.7x |
| f | 1.7x |
| s | 1.45x |

h has no source at all and phi rests on two sources that differ by an order of magnitude on median human pause. No public source gives the ratio of registered users to looping sessions at peak.

## 6. Cross-checks from other angles

From the 10k report (Inferred there from the sources named; copied here as anchors, not as inputs):

| Anchor | How it was built | Streams at peak for 10,000 users |
|---|---|---|
| Anthropic rate limits | 10K to 15K TPM and 0.25 to 0.35 RPM per user for organisations above 500 users, filled at peak; a provisioning ceiling with slack by construction | 1,445 to 2,023 |
| Anthropic tokens | about 25M tokens per active day, converted from US$ 13 per active day at the Sonnet cache price; an upper bound, not a measured value; the report's "high" planning row | 1,460 |
| Copilot | 14M prompt tokens per user per week, a casual population; a floor | 230 |

The base of section 2 implies about 14.8M tokens per active day, between the TraceLab floor (about 7.5M) and the Anthropic ceiling (10k report).

The corrected base (1,219 at b = 2) sits between the floor and the token anchor.

## 7. What is still Hypothesis

- d, h, s for our users: the first month of gateway telemetry is the planned source (§18.6, §19.4).
- The definition of "user" (registered, MAU, DAU, seat) and of a looping session (§18.7). Changing it changes d by itself.
- b and GLM output length (EK9).
- How one harness agent maps to demand streams (see `fleet-recalculation.md`, section 2).
