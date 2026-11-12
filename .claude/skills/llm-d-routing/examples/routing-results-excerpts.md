# Routing test results on the mini model

Real excerpts from the mini routing runs of 2026-11-05 on Nebius (2 replicas of `glm5next` mini, 1 RTX PRO 6000 each, vLLM 0.32.0, llm-d `v1.0.0`). All numbers are Observed (mini): they show mechanisms, not capacity of the real model. Result files keep the Portuguese names and keys of the time: `afinidade` is affinity, `so-carga` is load only, `rot21` is the 21-group routing test, `rajada51` is the burst of 51, `linhas` are rows, `grupo` is group, `mesma_do_primeiro` means "same replica as the first request of the group", `comp` is computed prompt tokens.

## 1. Serial routing test, 21 groups x 3 repetitions

Prefix 17,408 tokens (2 blocks of 8,704) plus a 512-token question. Source: `f3/resultados/exp-20261105/rot21-afinidade.resumo.json`:

```json
{
 "modo": "roteamento",
 "requisicoes": 63,
 "repeticoes_na_mesma_replica_pct": 100.0,
 "hit_pct_repeticoes": 97.1,
 "hit_pct_primeiras": 0.0,
 "primeiras_por_replica": {
  "10.81.17.30": 11,
  "10.81.3.231": 10
 },
 "ttft_repeticao_p50": 0.042
}
```

Load only, `rot21-so-carga.resumo.json`:

```json
{
 "modo": "roteamento",
 "requisicoes": 63,
 "repeticoes_na_mesma_replica_pct": 52.4,
 "hit_pct_repeticoes": 55.5,
 "hit_pct_primeiras": 0.0,
 "primeiras_por_replica": {
  "10.81.17.30": 12,
  "10.81.3.231": 9
 },
 "ttft_repeticao_p50": 0.048
}
```

Group 0, all three repetitions, from `rot21-afinidade.json` and `rot21-so-carga.json` (`linhas`):

```json
{"grupo": 0, "rep": 0, "pod": "10.81.17.30", "mesma_do_primeiro": true, "hit": 0.0, "comp": 17920.0, "ttft": 0.17792415618896484}
{"grupo": 0, "rep": 1, "pod": "10.81.17.30", "mesma_do_primeiro": true, "hit": 17408.0, "comp": 512.0, "ttft": 0.044040679931640625}
{"grupo": 0, "rep": 2, "pod": "10.81.17.30", "mesma_do_primeiro": true, "hit": 17408.0, "comp": 512.0, "ttft": 0.04296302795410156}
```

```json
{"grupo": 0, "rep": 0, "pod": "10.81.3.231", "mesma_do_primeiro": true, "hit": 0.0, "comp": 17920.0, "ttft": 0.16951751708984375}
{"grupo": 0, "rep": 1, "pod": "10.81.17.30", "mesma_do_primeiro": false, "hit": 0.0, "comp": 17920.0, "ttft": 0.15213966369628906}
{"grupo": 0, "rep": 2, "pod": "10.81.3.231", "mesma_do_primeiro": true, "hit": 17408.0, "comp": 512.0, "ttft": 0.047945261001586914}
```

Reading: with affinity both repetitions hit the 17,408 cached tokens and compute only the 512-token question. With load only, repetition 1 went to the other replica and recomputed all 17,920 tokens. 97.1% is the ceiling: 17,408 / 17,920.

## 2. Burst of 51, three runs per mode

`sessions.py burst` sends one request to warm a replica, then 51 in parallel with the same prefix. Sources: `rajada51-afinidade-r1..r3.resumo.json` and `rajada51-so-carga-r1..r3.resumo.json`. Run 1 of each mode:

```json
{
 "modo": "rajada",
 "n": 51,
 "requisicoes_por_replica": {
  "10.81.108.195": 27,
  "10.81.59.159": 24
 },
 "hit_pct": 93.3,
 "ttft_p50": 0.499,
 "ttft_max": 0.918
}
```

Load only, run 3 (`rajada51-so-carga-r3.resumo.json`):

```json
{
 "modo": "rajada",
 "n": 51,
 "requisicoes_por_replica": {
  "10.81.108.195": 24,
  "10.81.59.159": 27
 },
 "hit_pct": 93.3,
 "ttft_p50": 0.494,
 "ttft_max": 0.963
}
```

All six runs:

| Run | Split | Hit % | TTFT p50 (s) | TTFT max (s) |
|---|---|---|---|---|
| affinity r1 | 27 / 24 | 93.3 | 0.499 | 0.918 |
| affinity r2 | 27 / 24 | 93.3 | 0.523 | 1.002 |
| affinity r3 | 27 / 24 | 93.3 | 0.522 | 0.889 |
| load only r1 | 25 / 26 | 93.3 | 0.492 | 1.044 |
| load only r2 | 25 / 26 | 93.3 | 0.490 | 0.989 |
| load only r3 | 24 / 27 | 93.3 | 0.494 | 0.963 |

The unrepeated first run, `rajada51-afinidade.resumo.json`, had TTFT p50 0.942 s and max 2.16 s; it ran right after the replicas started and is a cold-start artefact (§9.1). Affinity did not pile all 51 on the warm replica: the split stayed near half. Which rule spread it (affinity filter penalty or token load) was not logged.

## 3. Warmed A/B at 3 requests per second

`inference-perf` 0.7.0, constant 3 req/s for 80 s, 60 groups x 4 prompts, 17,500-token system prompt, 512-token question, 128 output tokens (`router/bench/inference-perf.yaml`), a warm-up discarded before each mode. Source: `f3/resultados/ab-aquecido-20261105/resumo-ab-aquecido.json`:

```json
{
 "afinidade": {
  "req": 240,
  "hit_pct": 69.7,
  "comp": 1311296,
  "ttft_p50": 0.135,
  "ttft_p95": 0.271,
  "ttft_p99": 0.324,
  "ttft_max": 0.387,
  "acima_2s": 0,
  "tok_s": 54425,
  "goodput": 100.0
 },
 "so-carga": {
  "req": 240,
  "hit_pct": 50.7,
  "comp": 2129472,
  "ttft_p50": 0.174,
  "ttft_p95": 0.272,
  "ttft_p99": 0.304,
  "ttft_max": 0.315,
  "acima_2s": 0,
  "tok_s": 54387,
  "goodput": 100.0
 }
}
```

The hit share is computed from `vllm:prompt_tokens_by_source_total` scraped before and after each mode (`afinidade/metricas-antes.txt`, `metricas-depois.txt`). Two of the raw lines after the affinity mode, one replica:

```text
vllm:prompt_tokens_by_source_total{engine="0",model_name="mini",source="local_compute"} 1.122396e+06
vllm:prompt_tokens_by_source_total{engine="0",model_name="mini",source="local_cache_hit"} 1.618944e+06
```

Reading: affinity computed 38% fewer prompt tokens (1,311,296 against 2,129,472) and cut TTFT p50 by 22%; throughput (`tok_s`) was the same, because 3 req/s did not saturate either mode. This shows the cache effect, not capacity (§9.1).
