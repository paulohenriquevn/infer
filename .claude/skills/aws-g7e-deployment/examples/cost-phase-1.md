# Phase 1 cost calculation

Inferred. Price is the On-Demand rate for `g7e.24xlarge` in `us-east-1` read on 2026-11-04 (US$ 16.57/h, AWS Price List API, Observed then and not rechecked). Durations come from runs on other providers; no AWS run exists yet. Recompute with the price read on the day of the run (runbook step 0.5).

## Inputs

| Input | Value | Source |
|---|---|---|
| Instance price | US$ 16.57/h | 2026-11-04 read (`references/quotas-and-purchase.md`) |
| Billing | per second, 60 s minimum | Reported, `https://aws.amazon.com/ec2/pricing/on-demand/`, read 2026-11-12 |
| gp3 storage | US$ 0.08 per GB-month (example rate on the pricing page, region not named) | Reported, `https://aws.amazon.com/ebs/pricing/`, read 2026-11-12 |
| Hours per month for storage | 730 | convention used by AWS pricing examples (Inferred) |
| Root plus cache volume | 300 + 200 GiB | `terraform-phase-1/variables.tf` defaults |

## Step durations

| Step | Minutes | Basis |
|---|---|---|
| Launch to SSM shell | 5 | Unknown on AWS; Nebius VM creation took 2 min (ARQUITETURA.md §17.2) |
| Image pull, 12.9 GB | 7.5 | Nebius (§17.2) |
| Weights from the Hub | 5.5 | Vast 157204, 5 min 31 s |
| Bench setup, host checks, microbenchmark | 10 | Inferred |
| Server start | 4.3 to 8.5 | 157204: 260 s, 511 s with a cold kernel cache (§29.1). The first AWS start has a cold cache, so use 8.5 |
| Gate, speed and two agent levels | 37 | 157204 DCP1: server ready about 00:26:20, agents-24 started 00:46:18 and ran 900 s, about 35 min; 500 needle runs instead of 120 add about 2 min (Inferred from the needle start 00:26:46 and gsm8k start 00:27:44) |
| Summarize, copy results, teardown | 10 | Inferred |

Sum: 5 + 7.5 + 5.5 + 10 + 8.5 + 37 + 10 = 83.5 min, about 1.4 h. Round to 1.5 h for the plan.

## Cost

| Scenario | Hours | Instance (h x 16.57) | EBS (500 GiB x 0.08 / 730 per hour) | Total |
|---|---|---|---|---|
| Smooth run | 1.5 | US$ 24.86 | US$ 0.08 | about US$ 25 |
| One retry (driver change, or a second start after a failed check) | 3 | US$ 49.71 | US$ 0.16 | about US$ 50 |
| Forgotten instance, stopped by the watchdog at 240 min | 4 | US$ 66.28 | US$ 0.22 | about US$ 66 |
| Forgotten instance without a watchdog, found the next morning | 16 | US$ 265.12 | US$ 0.88 | about US$ 266 |

EBS per hour: 500 x 0.08 / 730 = US$ 0.055/h (Inferred). The cache volume kept between phase 1 and phase 2 costs 200 x 0.08 = US$ 16 per month while detached.

Not included (Unknown, prices not read): data transfer in from ghcr.io and the Hub, S3 storage and requests for results, the Terraform state bucket, CloudWatch.

## Comparison with the reference run

Same harness on Vast 157204 at US$ 5.61/h: 39 min from server start to the last agent level (Observed timestamps), about US$ 3.65 for the bench part (Inferred: 0.65 h x 5.61). The AWS bench part alone (about 0.75 h with the 500-run needle) is about US$ 12.40 (Inferred). The rest of the AWS estimate is set-up time; on Vast the same set-up happened in `prepare_host.sh` and is left out of this comparison.
