# `pd_bench` results: R1 interference and the mini P/D test

`router/pd/pd_bench.py` is our closed-loop load generator for cold, long prompts. Each request has a unique prompt of random token IDs (no cache unless `--same-prompt`), a fixed output, and streaming; it prints one JSON line. Files written before the translation use Portuguese field names: `concorrencia` (concurrency), `requisicoes` (requests), `falhas` (failures), `saida` (output tokens), `duracao_s`, `tok_saida_s` (output tok/s), `tok_prompt_s` (prompt tok/s). With MTP, `tpot_*_ms` is per streaming chunk (about 2.6 tokens), not per token (§12.2).

## R1: real model, TP4 + DCP4 + MTP3 on 4 RTX PRO 6000 (Nebius, 2026-11-05)

Results archive: `f3/resultados/rtx-20261105/r1-suite.jsonl`. One run per row. Exact lines, trimmed to the rows that matter:

```
{"label": "frio-8k", "concorrencia": 1, "requisicoes": 3, "ok": 3, "falhas": 0, "prompt": 8192, "saida": 16, "duracao_s": 3.0, "req_s": 1.0, "tok_saida_s": 8, "tok_prompt_s": 8208, "ttft_p50": 0.829, "ttft_p95": 0.871, "ttft_max": 0.871, "tpot_p50_ms": 21.3, "tpot_p95_ms": 25.0}
{"label": "frio-32k", "concorrencia": 1, "requisicoes": 3, "ok": 3, "falhas": 0, "prompt": 32768, "saida": 16, "duracao_s": 9.8, "req_s": 0.31, "tok_saida_s": 2, "tok_prompt_s": 10009, "ttft_p50": 3.173, "ttft_p95": 3.176, "ttft_max": 3.176, "tpot_p50_ms": 19.4, "tpot_p95_ms": 22.6}
{"label": "decode-c4", "concorrencia": 4, "requisicoes": 8, "ok": 8, "falhas": 0, "prompt": 8192, "saida": 256, "duracao_s": 16.9, "req_s": 0.47, "tok_saida_s": 34, "tok_prompt_s": 3875, "ttft_p50": 3.677, "ttft_p95": 6.2, "ttft_max": 6.2, "tpot_p50_ms": 59.0, "tpot_p95_ms": 64.4}
{"label": "decode-c16", "concorrencia": 16, "requisicoes": 32, "ok": 32, "falhas": 0, "prompt": 8192, "saida": 256, "duracao_s": 63.6, "req_s": 0.5, "tok_saida_s": 37, "tok_prompt_s": 4123, "ttft_p50": 25.881, "ttft_p95": 28.627, "ttft_max": 30.536, "tpot_p50_ms": 59.9, "tpot_p95_ms": 66.8}
{"label": "frio-128k", "concorrencia": 1, "requisicoes": 2, "ok": 2, "falhas": 0, "prompt": 131072, "saida": 16, "duracao_s": 25.3, "req_s": 0.08, "tok_saida_s": 0, "tok_prompt_s": 10364, "ttft_p50": 12.603, "ttft_p95": 12.603, "ttft_max": 12.603, "tpot_p50_ms": 18.6, "tpot_p95_ms": 18.6}
{"label": "quente-128k", "concorrencia": 1, "requisicoes": 3, "ok": 3, "falhas": 0, "prompt": 131072, "saida": 16, "duracao_s": 0.8, "req_s": 3.77, "tok_saida_s": 26, "tok_prompt_s": 493560, "ttft_p50": 0.14, "ttft_p95": 0.163, "ttft_max": 0.163, "tpot_p50_ms": 19.3, "tpot_p95_ms": 19.7}
{"label": "frio-256k", "concorrencia": 1, "requisicoes": 2, "ok": 2, "falhas": 0, "prompt": 260000, "saida": 16, "duracao_s": 50.1, "req_s": 0.04, "tok_saida_s": 0, "tok_prompt_s": 10381, "ttft_p50": 25.165, "ttft_p95": 25.165, "ttft_max": 25.165, "tpot_p50_ms": 4.1, "tpot_p95_ms": 4.1}
{"label": "decode-c32", "concorrencia": 32, "requisicoes": 64, "ok": 64, "falhas": 0, "prompt": 8192, "saida": 256, "duracao_s": 125.5, "req_s": 0.51, "tok_saida_s": 38, "tok_prompt_s": 4179, "ttft_p50": 56.07, "ttft_p95": 57.827, "ttft_max": 61.979, "tpot_p50_ms": 59.0, "tpot_p95_ms": 65.7}
{"label": "longo-c8-128k", "concorrencia": 8, "requisicoes": 8, "ok": 8, "falhas": 0, "prompt": 131072, "saida": 64, "duracao_s": 101.8, "req_s": 0.08, "tok_saida_s": 2, "tok_prompt_s": 10298, "ttft_p50": 63.248, "ttft_p95": 101.368, "ttft_max": 101.368, "tpot_p50_ms": 39.6, "tpot_p95_ms": 58.8}
```

What each row proves:

- `frio-*`: cold prefill rate, about 10.0k to 10.4k tok/s from 32K to 256K.
- `quente-128k`: a full prefix-cache hit of 128K costs 0.14 s.
- `decode-c16` and `decode-c32`: with decode active, prompt throughput is 4,123 and 4,179 tok/s, the 40% share (`--prefill-compute-share 0.4`), and cold 8K prompts wait 26 s and 56 s at the median because one lane serves them.
- `longo-c8-128k`: eight 128K prompts together. TTFT p50 63 s, p95 101 s, and decode held 39.6 ms per chunk, about 15 ms per token (39.6 / 2.6). The fork protects decode and pays in TTFT.

## Mini P/D against a matched aggregated control (Nebius, 2026-11-05)

Mini model (random weights, 2 full-attention layers), upstream vLLM 0.32.0, 1 RTX PRO 6000 per replica, NIXL over TCP. Prompts 17,408 cold unique tokens, output 128. Results archive: `f3/resultados/pd-20261105/`. One run per cell, warm-up discarded (`*-aquec.json` are the warm-ups). Observed on the mini.

Exact files:

```
agg-c8.json  {"label": "agg-c8", "concorrencia": 8, "requisicoes": 32, "ok": 32, "falhas": 0, "prompt": 17408, "saida": 128, "duracao_s": 3.8, "req_s": 8.39, "tok_saida_s": 998, "tok_prompt_s": 146094, "ttft_p50": 0.21, "ttft_p95": 0.5, "ttft_max": 0.513, "tpot_p50_ms": 4.9, "tpot_p95_ms": 8.2}
pd-c8.json   {"label": "pd-c8", "concorrencia": 8, "requisicoes": 32, "ok": 32, "falhas": 0, "prompt": 17408, "saida": 128, "duracao_s": 6.4, "req_s": 5.01, "tok_saida_s": 570, "tok_prompt_s": 87216, "ttft_p50": 1.277, "ttft_p95": 1.924, "ttft_max": 2.099, "tpot_p50_ms": 3.1, "tpot_p95_ms": 3.5}
agg-c32.json {"label": "agg-c32", "concorrencia": 32, "requisicoes": 128, "ok": 128, "falhas": 0, "prompt": 17408, "saida": 128, "duracao_s": 10.0, "req_s": 12.81, "tok_saida_s": 1559, "tok_prompt_s": 223018, "ttft_p50": 0.342, "ttft_p95": 1.62, "ttft_max": 1.827, "tpot_p50_ms": 14.1, "tpot_p95_ms": 32.5}
pd-c32.json  {"label": "pd-c32", "concorrencia": 32, "requisicoes": 128, "ok": 128, "falhas": 0, "prompt": 17408, "saida": 128, "duracao_s": 18.4, "req_s": 6.94, "tok_saida_s": 740, "tok_prompt_s": 120789, "ttft_p50": 3.499, "ttft_p95": 6.035, "ttft_max": 6.867, "tpot_p50_ms": 4.4, "tpot_p95_ms": 19.3}
```

Table:

| | Aggregated c8 | P/D 1P1D c8 | Aggregated c32 | P/D 1P1D c32 |
|---|---|---|---|---|
| Requests per second | 8.39 | 5.01 | 12.81 | 6.94 |
| TTFT p50 / p95 | 0.21 / 0.50 s | 1.28 / 1.92 s | 0.34 / 1.62 s | 3.50 / 6.04 s |
| TPOT p50 / p95 | 4.9 / 8.2 ms | 3.1 / 3.5 ms | 14.1 / 32.5 ms | 4.4 / 19.3 ms |
| Prompt tok/s | 146k | 87k | 223k | 121k |

The mini has no MTP, so TPOT here is per token.

Correctness check, `f3/resultados/pd-20261105-logprobs.txt` (exact, Portuguese):

```
prompt 0: PD vs agregado -> tokens iguais até 12/12, dif máx logprob nos iguais 0.0234 | agregado vs agregado com cache -> iguais até 0/12, dif 0.0 | 1º logprob PD -10.5944 agreg -10.5943
prompt 1: PD vs agregado -> tokens iguais até 4/12, dif máx logprob nos iguais 0.0235 | agregado vs agregado com cache -> iguais até 12/12, dif 0.0156 | 1º logprob PD -10.5313 agreg -10.5392
```

("PD vs aggregated: tokens equal up to 12/12, max logprob difference on equal tokens 0.0234 | aggregated vs aggregated with cache ...".) P/D differs from aggregated by the same order as cache on against cache off, so the KDA state transfer shows no error.

## How to run `pd_bench`

On the mini cluster (`router/pd/run_pdbench.sh` creates a pod in the namespace `llm-d-optimized-baseline`, mounts `pd_bench.py` from a ConfigMap and writes `$OUT/<name>.json`):

```bash
KUBECONFIG=<kubeconfig> bash router/pd/run_pdbench.sh pd-c8 --targets http://<proxy>:8000 --concurrency 8 --requests 32
```

Against a single server, run the script directly: `python3 router/pd/pd_bench.py --targets http://localhost:8000 --model GLM-5.3-Flash-NVFP4 --concurrency 16 --requests 32 --prompt 8192 --output-tokens 256 --label decode-c16`. The R1 rows above used labels and parameters visible in each line; the exact invocation used for R1 is not in the archive (Unknown).
