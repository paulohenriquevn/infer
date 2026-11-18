# A host that failed qualification: Vast machine 48294

Use this when a run looks much slower than expected and you must decide whether the arm or the host is to blame. Files: `f3/resultados/vast-20261112/vllm/` (fetched after midnight, so under 2026-11-12; the run started on 2026-11-11). Real model, vLLM DCP1, same image, checkpoint, profile and harness as the 157204 run in `writeup-dcp1-run1.md`. One run. Values Observed in those files unless marked; the narrative is `ARQUITETURA.md §29.10`.

Legacy names in this directory: `tempo-pronto.txt`, `avisos.txt`, `agentes-16.json`, `agentes-24.log`.

## The listing looked fine

Datacenter host in Texas, reliability 0.965, "4x RTX PRO 6000 Server Edition", US$ 7.03/h (read 2026-11-12). It met every offer criterion in `references/vast-workflow.md`.

## Signal 1: before any server started

`host-vllm/p2pmark-4gpu.txt`, small all-reduce on the custom PCIe path against host 157204:

| Size | 48294 | 157204 |
|---|---|---|
| 256 B | 13.8 us | 9.1 us |
| 512 B | 16.7 us | 9.3 us |
| 1 KiB | 18.3 us | 8.4 us |
| 2 KiB | 21.7 us | 9.1 us |

Driver 580.95.05 (157204 runs 615.71.09; the image expects 615.65.02 or newer).

## Signal 2: server start

`tempo-pronto.txt`: ready in 1,084 s, against 260 s for the same arm on 157204.

## Signal 3: decode and prefill

`decode.json`, `results[].aggregate_tps`:

| Concurrency | 48294 | 157204 (DCP1) |
|---|---|---|
| 1 | 108.2 | 154.5 |
| 8 | 298.6 | 696.3 |
| 16 | 350.8 | 1,072.6 |
| 32 | 297.6 | 1,580.3 |

C32 is below C16 and 5.3 times below 157204. Cold prefill: 869 / 864 / 866 tok/s at 8K / 32K / 128K (128K took 148.8 s), against 8,490 to 9,121 tok/s on 157204.

## Signal 4: the agent levels

`summarize.py --price 7.03 --needle-ref 3/500 .../vast-vllm-dcp1-rep`: needle `100.0% ok`, gsm8k `100.0%`, 0 sessions. Level 16: 11 errors, 0 steady turns, `short sample`.

From `agentes-16.json`:

- 39 turns sent in 900 s, 12 finished, 11 errors, all `ReadTimeout` (`error_kinds {'timeout': 11}`).
- Only 5 of 16 agents finished turn 0, so no steady state.
- Server side: at most 6 requests running, up to 15 waiting, KV peak 11.1%. The server was starved, not full.
- `decode_tok_s` 29.9 for the whole level.

`avisos.txt`: `agentes-16 terminou com código 2 (ver log)` (Portuguese text of the old harness; now `agents-16 exited with code 2 (see log)`).

Level 24 has no JSON. `agentes-24.log` ends with:

```
agents 809s in flight 24, done 12, errors 18 | running 2 waiting 22 | KV 2%
```

## Signal 5: the GPUs were idle

`host-diagnostico.txt`, read during the agent level:

```
index, pcie.link.gen.max, pcie.link.gen.current, pcie.link.width.max, clocks.current.sm [MHz], temperature.gpu, power.draw [W]
0, 5, 5, 16, 2347 MHz, 30, 115.88 W
1, 5, 5, 16, 2370 MHz, 30, 116.04 W
2, 5, 5, 16, 2362 MHz, 29, 119.53 W
3, 5, 5, 16, 2362 MHz, 30, 119.01 W
256
Model name:                           Intel(R) Xeon(R) 6767P
Socket(s):                            2
NUMA node(s):                         4
 10:51:19 up 1 day, 21:02,  0 user,  load average: 8.54, 10.90, 12.35
```

PCIe at Gen 5 x16 and SM clocks high, but about 116 W per GPU out of 600 W: the GPUs wait for something.

## What was not wrong

Quality: needle 500/500 at C8 and 120/120 at C16, gsm8k 96/96. A slow host does not corrupt numerics. These counts are valid evidence for the DCP1 quality gate.

## Verdict and what to do

- Host rejected: C32 297.6 tok/s against the 1,400 threshold. Its speed and capacity numbers are excluded from every comparison.
- Cause: Unknown. The driver alone does not explain it (Nebius R1 on driver 580.173 reached 1,425 tok/s at C32, §29.10). Hypothesis: contention outside the GPUs (another tenant on an 8-GPU host, CPU, memory or PCIe root complex). To discriminate: `nvidia-smi dmon` during decode, CPU steal and memory bandwidth, and the same p2pmark on another 580-driver host.
- Cost of finding out late: the gate, the speed step and the agent levels all ran and were paid for before anyone read the decode number. The qualification step now comes right after the server is up, and the p2pmark of `prepare` is read before starting the server.
- Process rule from this case (§29.10): prepaid credit and reserved instances are locked to one host, so never reserve a host that has not passed qualification.
