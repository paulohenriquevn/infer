# A full write-up of a real run: vLLM DCP1 on host 157204

This is `references/result-writeup-template.md` filled in for `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1`. Use it as the model for a new write-up. Every value is Observed in the result directory or in `ARQUITETURA.md §28` and `§29`, except the p-values and margins (Inferred: arithmetic shown). The directory predates the translation, so its files use Portuguese names (`servidor.sh`, `servidor.log`, `tempo-pronto.txt`, `agentes-<N>.json`).

---

## vLLM DCP1: 24 sessions inside the SLO, one run

Evidence: Observed (real model). Runs: 1. Date of run: 2026-11-11 (UTC timestamps run into 2026-11-12).

### Configuration

- Engine and image: vLLM `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` (build `0.1.dev21830+g8244d1c44`).
- Checkpoint: `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be`.
- Profile: TP4, DCP1 (`--decode-context-parallel-size 1`), MTP with 3 speculative tokens, `--kv-cache-dtype fp8`, `--max-num-seqs 32`, `--max-num-batched-tokens 4096`, cache mode HBM only, `--enable-prompt-tokens-details`.
- Server script: `server-vllm-dcp1-direct.sh` (copied as `servidor.sh`).
- Harness: llm-inference-bench `52216d7` plus the exact-history patch; `exact_history` = true.

### Host

- Provider and machine: Vast.ai machine 157204 (offer 60186106), Nevada.
- GPU: 4x NVIDIA RTX PRO 6000 Blackwell Server Edition, power limit 600 W.
- Driver: 615.71.09. P2P `topo -p2p r`: all OK without the driver override. Log line present: `Using B12X PCIe all-reduce (algorithm=oneshot, one-shot max=86016, ...)`.
- Topology: GPU0 on NUMA node 0, GPUs 1 to 3 on node 1 (`SYS` between GPU0 and the others).
- Small all-reduce (p2pmark custom path): 9.1 us at 256 B, 9.3 at 512 B, 8.4 at 1 KiB, 9.1 at 2 KiB (NCCL 16.3, 15.9, 16.0, 34.1).
- C32 decode (qualification): 1,580 tok/s (threshold 1,400).
- Price: US$ 5.61/h for the 4-GPU instance, read 2026-11-11 from the Vast offer.

### Quality gate

- needle C8: 3/120 wrong, one-sided p vs 3/500 = 0.090.
- needle C16: 1/120 wrong, p = 0.58.
- gsm8k: 95/96.
- Verdict: ok. The run used 120 needle runs at C8 (the 500-run default came later).

### Speed

- Decode C1 / C8 / C16 / C32: 154.5 / 696.3 / 1,072.6 / 1,580.3 tok/s (`decode.json`, `results[].aggregate_tps`).
- Cold prefill 8K / 32K / 128K TTFT: 0.966 / 3.543 / 14.389 s (8,490 / 9,121 / 8,957 tok/s). The 256K cell was requested and is absent from `prefill.json`; cause Unknown.
- Server ready: 260 s (`tempo-pronto.txt`), kernel cache probably warm from the DCP4 arm run earlier on the same machine (Inferred: 201 s warm and 511 s cold were measured for DCP4, §28.2).

### Agent levels (summarize.py, steady-state cached turns)

| Agents | Duration (s) | Steady since (s) | Steady turns | Errors | TTFT p95 (s) | tok/s p50 | Cache % | SLO |
|---|---|---|---|---|---|---|---|---|
| 16 | 900 | 380 | 212 | 0 | 4.71 | 70.8 | 97.2 | pass |
| 24 | 1,200 | 470 | 326 | 0 | 4.93 | 55.3 | 97.2 | pass |

- Sessions inside the SLO: 24 (lower bound; next tested level: none, 32 was not run with DCP1).
- Margin to the SLO at 24: TTFT p95 4.93 s vs 5 s (0.07 s); tok/s p50 55.3 vs 30.
- Sessions per US$/h: 24 / 5.61 = 4.28.
- Bench aggregates at 24: `decode_tok_s` 730.3, KV peak 72.6%, 0 preemptions, prefill share of GPU time 0.471.

### Reproduction

- Result directory: `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1`.
- Harness command: the directory does not record the original invocation. `AGENT_LEVELS="16:900 24:1200" bash vast.sh run vllm dcp1` reproduces the levels today, with 500 needle runs instead of the 120 used then.
- Summary command: `python3 summarize.py --price 5.61 --needle-ref 3/500 f3/resultados/vast-20261111/vllm/vast-vllm-dcp1`.

### Caveats

- One run. DCP4 at 16 agents passed by 0.23 s in its first run and failed by 0.20 s in the second; a 0.07 s margin is inside that noise. Treat 24 as provisional.
- The second DCP1 run (`vast-20261112/vllm/vast-vllm-dcp1-rep`, host 48294) is not a replication: the host failed qualification (see `host-48294-qualification-failure.md`). Its quality numbers (needle 500/500 and 120/120, gsm8k 96/96) do count.
- Measured on one host with fast P2P. A host with slower all-reduce will give fewer sessions (Inferred from §29.2 and §29.10).
- The 24-agent level ran for 1,200 s; `docs/06` phase 2 prescribes `24:900`. Rerun with 1,200 s to compare like with like.
- What this result does not show: behaviour above 24 agents with DCP1, behaviour with real Claude Code traces (sub-agents, pauses), long-session tails above 220K tokens (max context reached 219,513), and AWS G7e numbers.
