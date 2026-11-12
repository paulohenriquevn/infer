# KV per session, step by step

A worked calculation for one coding-agent session of 256K tokens, first with the planning rule, then against the fork's real log. All arithmetic is Inferred from the inputs named in each step. Derivations: `../references/architecture.md`.

## Inputs

| Input | Value | Source |
|---|---|---|
| Context of one session | 262,144 tokens (256K) | the SLO sizing case (`docs/01-product-demand-and-slo.md`) |
| MLA plus indexer KV, whole model | 8.7 KB per token | Observed on B300 (8,721 B), `ARQUITETURA.md §9.3`, §2 correction note; current value in `docs/README.md` |
| KDA state per sequence | 147,619,840 B, about 0.15 GB | Inferred from `config.json` (34 layers, 64 heads, head dim 128, fp32 state, conv kernel 4) |
| Fork, max-request cost per GPU, DCP1 | 7,582,924,800 B for 1,048,576 tokens | Observed, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/servidor-direto.log` |
| Fork, max-request cost per GPU, DCP4 | 2,231,725,056 B for 1,048,576 tokens | Observed, `f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/servidor-direto.log` |
| Fork KV token budget | 6,789,052 (DCP1), 22,954,769 (DCP4) | same logs |

## Step 1. Planning rule

```text
KV  = 262,144 tokens x 8,721 B          = 2,286,157,824 B   = 2.29 GB
KDA = 34 x (64 x 128 x 128 x 4 + 3 x 3 x 64 x 128 x 2)
    = 34 x (4,194,304 + 147,456)        =   147,619,840 B   = 0.15 GB
Session total                           ≈ 2.43 GB
```

This is the "2.3 GB of KV plus 0.15 GB of KDA state" in the model skill and in `docs/README.md`.

## Step 2. Fork bytes per token per GPU

```text
DCP1: 7,582,924,800 / 1,048,576 = 7,231.6 B per token, on each of the 4 GPUs
DCP4: 2,231,725,056 / 1,048,576 = 2,128.3 B per token, on each GPU (a quarter of the tokens each)
      2,128.3 x 4               = 8,513   B per token across the replica
```

The fork's max-request cost already includes the per-request recurrent state spread over 1M tokens, because the logged concurrency equals available memory divided by it (45.76 GiB / 7,582,924,800 B = 6.48, logged 6.47x).

## Step 3. One 256K session on the fork

```text
DCP1: 262,144 x 7,231.6 = 1.90 GB on every GPU   (4 copies, 7.6 GB of HBM for one session)
DCP4: 262,144 x 2,128.3 = 0.56 GB on every GPU   (2.23 GB of HBM for one session)
```

## Step 4. How many 256K sessions fit in HBM

```text
DCP1:  6,789,052 / 262,144 = 25.9 sessions   (log: 6.47x for 1M tokens, x 4 = 25.9)
DCP4: 22,954,769 / 262,144 = 87.6 sessions   (log: 21.89x for 1M tokens, x 4 = 87.6)
```

## Step 5. Check against the SLO case

The DCP1 run held 24 agents inside the SLO with about 100K tokens each (`ARQUITETURA.md §29.8`):

```text
24 sessions x 100,000 tokens = 2.4 million tokens  <  6,789,052 budget  (35% of the pool)
```

Inferred: at 24 agents the DCP1 limit was decode speed, not KV. With 256K sessions the same pool would cap at 25 sessions before speed mattered.

## Common mistakes this example prevents

- Adding 4 x 45.76 GiB as one pool under DCP1. Each GPU holds the whole session; the pool is 6.79 million tokens, not 4 times that.
- Using the superseded 1.62 GB per 256K session (`ARQUITETURA.md §2`, first table). It under-counts by about 1.5 times.
- Planning with a formula and skipping the log. After any change to the profile, recompute from `GPU KV cache size` and the max-request cost line (`kv-log-lines-dcp1-dcp4.md`).
