# Sizing calculation for one `g7e.24xlarge`

Step-by-step arithmetic behind `../references/tiers-and-sizing.md`. The inputs are measured or reported values with their source in the comments; every output is Inferred. Nothing here ran on AWS. The two reserve values (124 and 224 GiB for the OS and processes) are illustrative, not measured; replace them with the resident memory you read on a running server.

Inputs:

| Input | Value | Source |
|---|---|---|
| KV bytes per token | 39.05 GiB / 4,807,959 tokens | Observed, §9.3, 1 B300 |
| KDA state per sequence | 0.15 GB | Inferred, §2 |
| Prefill rate cold / under decode | 10,300 / 4,100 tok/s | Observed, R1, §12.2 |
| Fixed cost per hit | 0.33 s | Reported, GLM-5.3 LMCache paper, §17.4 |
| HBM pool DCP1 / DCP4 | 6,789,052 / about 23.1 million tokens | Observed, §29.6 |
| Host RAM `g7e.24xlarge` | 1,024 GiB | Reported, AWS instance table, `docs/06-aws-implementation-plan.md` |

Script (run with `python3 sizing.py`):

```python
GiB = 2**30
kv_bytes_per_token = 39.05 * GiB / 4_807_959      # §9.3, 1 B300
kda_state_gb = 0.15                               # §2, per sequence
cold_rate, under_decode_rate = 10_300, 4_100      # tok/s, R1 §12.2
fixed_cost_s = 0.33                               # per hit, GLM-5.3 LMCache paper
print(f"KV per token: {kv_bytes_per_token:,.0f} bytes")

def session_gb(tokens, per_token=kv_bytes_per_token):
    return tokens * per_token / 1e9 + kda_state_gb

for ctx in (100_000, 262_144):
    print(f"session {ctx:,} tokens: {session_gb(ctx):.2f} GB (20 KB/token: {session_gb(ctx, 20_000):.2f} GB)")

host_ram_gib = 1024
for reserve_gib in (124, 224):
    l1_gib = host_ram_gib - reserve_gib
    l1_gb = l1_gib * GiB / 1e9
    print(f"reserve {reserve_gib} GiB -> L1 {l1_gib} GiB = {l1_gb:.0f} GB:",
          ", ".join(f"{ctx//1000}K: {l1_gb/session_gb(ctx):.0f} sessions" for ctx in (100_000, 262_144)),
          f"| 256K at 20 KB/token: {l1_gb/session_gb(262_144, 20_000):.0f}")

hbm_dcp1, hbm_dcp4 = 6_789_052, 23_100_000
for name, pool in (("DCP1", hbm_dcp1), ("DCP4", hbm_dcp4)):
    print(f"HBM {name}: {pool/100_000:.0f} active sessions of 100K, {pool/262_144:.1f} of 256K")

print(f"break-even bandwidth cold: {kv_bytes_per_token*cold_rate/1e9:.3f} GB/s = {kv_bytes_per_token*cold_rate*8/1e9:.2f} Gbps")
print(f"break-even bandwidth under decode: {kv_bytes_per_token*under_decode_rate/1e9:.3f} GB/s")
print(f"min restored length with {fixed_cost_s} s fixed cost: cold {fixed_cost_s*cold_rate:,.0f}, under decode {fixed_cost_s*under_decode_rate:,.0f} tokens")
for ctx in (100_000, 262_144):
    print(f"recompute {ctx:,}: cold {ctx/cold_rate:.1f} s, under decode {ctx/under_decode_rate:.1f} s")
print(f"rtx6kpro 1M restored in 0.855 s -> {1_000_000*kv_bytes_per_token/0.855/1e9:.1f} GB/s effective (if 1M tokens at our bytes/token)")
for bw in (5, 10):
    for ctx in (100_000, 262_144):
        print(f"restore {ctx:,} at {bw} GB/s + {fixed_cost_s} s: {fixed_cost_s + session_gb(ctx)/bw:.2f} s")
fail = 64*262_144
print(f"failover 64 x 256K: {fail:,} tokens, {fail/cold_rate/60:.1f} min cold")
```

Output (exact):

```
KV per token: 8,721 bytes
session 100,000 tokens: 1.02 GB (20 KB/token: 2.15 GB)
session 262,144 tokens: 2.44 GB (20 KB/token: 5.39 GB)
reserve 124 GiB -> L1 900 GiB = 966 GB: 100K: 945 sessions, 262K: 397 sessions | 256K at 20 KB/token: 179
reserve 224 GiB -> L1 800 GiB = 859 GB: 100K: 840 sessions, 262K: 353 sessions | 256K at 20 KB/token: 159
HBM DCP1: 68 active sessions of 100K, 25.9 of 256K
HBM DCP4: 231 active sessions of 100K, 88.1 of 256K
break-even bandwidth cold: 0.090 GB/s = 0.72 Gbps
break-even bandwidth under decode: 0.036 GB/s
min restored length with 0.33 s fixed cost: cold 3,399, under decode 1,353 tokens
recompute 100,000: cold 9.7 s, under decode 24.4 s
recompute 262,144: cold 25.5 s, under decode 63.9 s
rtx6kpro 1M restored in 0.855 s -> 10.2 GB/s effective (if 1M tokens at our bytes/token)
restore 100,000 at 5 GB/s + 0.33 s: 0.53 s
restore 262,144 at 5 GB/s + 0.33 s: 0.82 s
restore 100,000 at 10 GB/s + 0.33 s: 0.43 s
restore 262,144 at 10 GB/s + 0.33 s: 0.57 s
failover 64 x 256K: 16,777,216 tokens, 27.1 min cold
```

Reading it:

1. A session costs about 1 GB per 100K tokens of context plus its KDA state.
2. With DCP1, HBM holds about 68 sessions of 100K, already more than the 24 the SLO allowed (one run). HBM is the limit only when idle sessions stay in it.
3. An 800 to 900 GiB L1 holds about 840 to 945 idle sessions of 100K, or 350 to 400 of 256K.
4. Any link above 0.09 GB/s beats cold prefill, so bandwidth is not the constraint; the fixed cost per hit (prompts under about 3.4K tokens lose) and the wait for HBM are.
5. The 10.2 GB/s line only converts the rtx6kpro restore time into bandwidth under our bytes per token; it is not a measurement of ours.
6. A cell failover of 64 sessions of 256K is about 27 min of cold prefill on one replica.
