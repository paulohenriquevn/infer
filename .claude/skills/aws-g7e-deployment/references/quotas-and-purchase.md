# Quotas and purchase models for G7e

How the vCPU quota for G7e works and how to request it, what each purchase model offers for G7e as read on 2026-11-12, and the prices recorded on 2026-11-04. Use the `capacity-and-cost` skill for sessions per US$/h and fleet sizing; this file covers the AWS mechanics.

Labels: Reported (URL and read date), Observed (our read of the account or the API, source given), Inferred (reasoning shown), Unknown.

## Recorded prices

Observed on 2026-11-04 in the AWS Price List API, `us-east-1`, Linux, On-Demand (`NOTAS.md`, outside this repository; not rechecked since):

| Size | GPUs | vCPU | US$/h | US$ per GPU-hour |
|---|---|---|---|---|
| `g7e.2xlarge` | 1 | 8 | 3.36 | 3.36 |
| `g7e.12xlarge` | 2 | 48 | 8.29 | 4.15 |
| `g7e.24xlarge` | 4 | 96 | 16.57 | 4.14 |
| `g7e.48xlarge` | 8 | 192 | 33.14 | 4.14 |

The public On-Demand pricing page does not carry G7e rates in its text (Reported, `https://aws.amazon.com/ec2/pricing/on-demand/`, read 2026-11-12: rates load dynamically). Read the current price before every launch with the Price List API (`aws pricing get-products --service-code AmazonEC2 --region us-east-1 --filters ...`; the Pricing API endpoint is in `us-east-1`) or the AWS Pricing Calculator, and write it down with the date. Prices differ by region (Unknown outside `us-east-1`).

Comparison (Inferred, same prices): 16.57 / 5.61 = about 3 times Vast host 157204; 16.57 / 7.20 = 2.3 times Nebius list for 4 GPUs. With 24 sessions per replica (DCP1, one run), 24 / 16.57 = 1.45 sessions per US$/h against 4.28 on 157204.

## Quota mechanics

Reported, `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-on-demand-instances.html` and `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-limits.html`, read 2026-11-12:

- On-Demand quotas are per account and per region, counted in vCPUs of running instances, "regardless of the instance type". Each quota covers one or more families.
- "Running On-Demand G and VT instances": quota code `L-DB2E81BA`, default 0, adjustable.
- "All G and VT Spot Instance Requests": quota code `L-3819A6DF`, default 0, adjustable.
- Pending, stopping, stopped and hibernated instances do not count. "Capacity Reservations count toward your On-Demand Instance quotas, even if they are unused."
- AWS "automatically increases your On-Demand Instance quotas based on your usage", but a new account starts at 0 for G and VT.
- Instances in a Capacity Block "don't count against your On-Demand Instances limits" (Reported, Capacity Blocks page).

Whether G7e counts against the G and VT quota: the quota name covers G instances and AWS lists no separate G7e quota (Reported, same table), so yes (Inferred). Our 2026-11-04 note had it as Inferred by analogy; this table is the stronger evidence, but a launch is the only confirmation.

vCPUs needed:

| Plan | vCPUs |
|---|---|
| Phase 1 and 2, one `g7e.24xlarge` | 96 |
| Phase 3, two `g7e.24xlarge` | 192 |
| Phase 3, one `g7e.48xlarge` | 192 |
| Phase 3, two `g7e.24xlarge` plus a spare for a failed launch | 288 (Inferred) |
| 10k report target, 3 to 15 `g7e.48xlarge` | 576 to 2,880 (10k report §9) |

Our account state (Observed on 2026-11-04, `NOTAS.md`): G and VT On-Demand and Spot were 0 in `us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`, `eu-central-1` and `sa-east-1`. Requests opened that day, both `PENDING`: On-Demand 96 vCPUs and Spot 48 vCPUs, in `us-east-1`. An earlier P On-Demand request (16 vCPUs, opened 2026-10-02) was closed on 2026-10-12 with the quota still 0; the reason is only in the Support Center. Request IDs and case IDs stay out of this repository.

How to request (Reported, Service Quotas links on the pages above):

1. Service Quotas console, region selected, service "Amazon Elastic Compute Cloud (Amazon EC2)", quota "Running On-Demand G and VT instances", "Request increase at account level", value in vCPUs.
2. CLI equivalent: `aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-DB2E81BA --desired-value 96 --region <region>`. Check status with `aws service-quotas list-requested-service-quota-change-history-by-quota --service-code ec2 --quota-code L-DB2E81BA`.
3. A quota request does not cost money, but it is an account change: confirm with Paulo first (project rule).
4. Record in the phase notes: date opened, value, region, status, date closed. Not the request ID.

Lead time: Unknown. Our only data point is a P request closed after 10 days without an increase.

Quota is not capacity: an approved quota does not guarantee that a zone has a free `g7e.24xlarge` at launch time (Inferred; on Nebius a quota of several VMs still failed with "Not enough resources", 10k report §3). An `InsufficientInstanceCapacity` error means trying another zone or later.

## Purchase models for G7e

Read on 2026-11-12. "Offered for G7e" comes from the G7e announcements; mechanics from the AWS guides.

| Model | Offered for G7e | Discount | Commitment | Capacity guarantee | Fit for us |
|---|---|---|---|---|---|
| On-Demand | Yes (Reported, GA and regions announcements) | none; billed per second, 60 s minimum (Reported, On-Demand page) | none | none | Phases 1 to 4 |
| On-Demand Capacity Reservation, immediate | Yes for any type with matching attributes (Reported, Capacity Reservations page; G7e not named) | none by itself; combinable with Savings Plans | none; cancel any time | yes, in one AZ | When a launch keeps failing for capacity |
| Future-dated Capacity Reservation | G family allowed (Reported: "C, G, I, M, R, T, U, and X"); minimum 32 vCPUs | none | commitment duration chosen at request; cancellation charge may apply | yes, from the start date | Phase 5 if launches are unreliable |
| Compute Savings Plans | applies to any EC2 usage (Reported) | "up to 66%" off On-Demand | 1 or 3 years, US$/h | no | After phase 2, if a fleet is decided |
| EC2 Instance Savings Plans | Savings Plans offered for G7e (Reported, announcements) | "up to 72%" | 1 or 3 years, one family in one region | no | Same; locks the family and region |
| Capacity Blocks for ML | No: the supported list on 2026-11-12 is P6-B300, P6-B200, P5, P5e, P5en, P4d, P4de, Trn1, Trn2 (Reported) | n/a | reserved block, no cancellation | yes | Not available |
| Spot | Yes (Reported, announcements); quota `L-3819A6DF` | variable | none | no; two-minute interruption notice | Not for serving |

Sources: `https://aws.amazon.com/about-aws/whats-new/2026/01/amazon-g7e-instances-generally-available/`, `https://aws.amazon.com/about-aws/whats-new/2026/07/amazon-g7e-additional-regions/`, `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html`, `https://docs.aws.amazon.com/savingsplans/latest/userguide/plan-types.html`, `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-blocks.html`, `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html`, all read 2026-11-12.

The G7e rate under each Savings Plan is Unknown: the "up to" figures are family-wide maxima, not G7e rates. Read them in the Savings Plans pricing pages or Cost Explorer recommendations before any commitment, and quote the rate with its date.

### Why On-Demand for phases 1 to 4

- Runs are short and the instance is destroyed after each (docs/06).
- At list price AWS is the most expensive provider we measured, so nothing is committed until a discounted price is read and the host passes qualification (Inferred from the table above).
- Capacity Blocks would be the natural fit for multi-day tests, but they do not offer G7e (Reported).

### Why not Spot for serving

- Spot gives "a warning that is issued two minutes before Amazon EC2 stops or terminates your Spot Instance" (Reported, interruption notices page). A replica needs minutes to start: 260 s on 157204 with the checkpoint already local (Observed), 21 to 23 min for a new Nebius VM end to end (§17.2).
- Instance store data does not survive a stop or termination (Reported), so an interrupted replica also loses the local checkpoint copy and the RAM KV tier.
- On Nebius, a spot B300 was preempted twice in about 75 min, each costing about 23 min of downtime (§9.3, Observed).
- Spot may suit the harness itself in a later phase (a test that can restart), but only after the quality and capacity numbers are settled (Inferred).

## Questions to ask AWS (10k report §9)

1. Approval of the G and VT On-Demand quota at 96, then 192 vCPUs, and lead time for 576 to 2,880.
2. The G7e rate under Compute and EC2 Instance Savings Plans, 1 and 3 years, in the chosen region.
3. Whether On-Demand Capacity Reservations and future-dated reservations for `g7e.24xlarge` and `g7e.48xlarge` are available in the zones that offer G7e.
4. Whether Capacity Blocks will add G7e.
