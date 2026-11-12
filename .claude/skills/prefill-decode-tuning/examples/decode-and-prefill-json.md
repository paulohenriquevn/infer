# Excerpts of `decode.json` and `prefill.json`

Real files written by `run_benchmark.sh` (bench `llm_decode_bench.py` v0.8.0) on Vast.ai host 157204, vLLM fork DCP4, 2026-11-11. Results archive: `f3/resultados/vast-20261111/vllm/vast-vllm-r1/`. One run. Values are copied exactly; whole blocks are trimmed with `...`.

## How they were produced

```bash
$PY $BENCH --port 8000 --concurrency 1,8,16,32 --contexts 0 --duration 30 --max-tokens 8192 --skip-prefill --output decode.json
$PY $BENCH --port 8000 --prefill-only --standalone-prefill --prefill-contexts 8k,32k,128k,256k --output prefill.json
```

The archived `prefill.json` holds 8K, 32K and 128K only.

## `decode.json`

Top-level keys: `metadata`, `startup_diagnostics`, `nvidia_p2p_override`, `p2pmark`, `amd_fabric`, `hardware_run_summary`, `event_log`, `prefill`, `results`, `summary_table`, `burst_results`, `burst_summary_table`, `mixed_prefill`, `methodology`.

`summary_table` (aggregate output tok/s by context, then concurrency):

```json
{
"0": {
"1": 145.60454866677688,
"8": 598.8427169931705,
"16": 910.3087330051723,
"32": 1279.146281975702
}
}
```

One cell of `results[]`, concurrency 32 (selected keys):

```json
{
  "concurrency": 32,
  "context_tokens": 0,
  "measurement_seconds": 29.959044,
  "client_output_tokens": 38322,
  "server_output_tokens": 38396,
  "aggregate_source": "openai_continuous_usage",
  "aggregate_tps": 1279.146281975702,
  "output_tps_per_user_p50": 40.0536406901101,
  "ttft_p50": 0.5076956104894634,
  "inter_token_latency_p50": 0.024966525650585568,
  "chunk_inter_token_latency_p50": 0.06968982290935496
}
```

MTP acceptance per cell, same file (`server_spec_accept_length`, Observed): 2.657 (C1), 2.589 (C8), 2.618 (C16), 2.643 (C32). DCP1 on the same host (`vast-vllm-dcp1/decode.json`): 2.489, 2.643, 2.632, 2.628.

How to use the fields:

- `aggregate_tps` is the number in every decode table of the journal and the docs.
- `output_tps_per_user_p50` is per stream; 40.1 at C32 on DCP4 and 50.1 on DCP1. The capacity formula uses 44.5 from R1.
- `inter_token_latency_p50` is per token. `chunk_inter_token_latency_p50` is per streaming chunk; with MTP3 a chunk carries about 2.6 tokens.
- `server_spec_accept_length` is the MTP mean accepted length per step; a drop below about 2.5 on a new image or checkpoint is a signal to re-check MTP (Inferred from the values above, no threshold in the sources).

## `prefill.json`

`metadata.prefill_mode` is `standalone_cold` and `metadata.standalone_prefill` is `true`. The 128K entry of the `prefill` block:

```json
"131072": {
  "ttft_seconds": 15.993,
  "prefill_seconds": 15.993,
  "tok_per_sec": 8057.0,
  "client_ttft_seconds": 15.993,
  "client_tok_per_sec": 8057.0,
  "prompt_tokens": 128854,
  "samples": 1,
  "method": "client",
  ...
  "hardware_summary": {
    "gpu_util_avg_pct": 99.86,
    "power_total_avg_w": 894.48,
    "vram_used_avg_pct": 97.52,
    "pcie_rx_avg_mb_s": 65253.71,
    ...
  }
}
```

All three lengths on this run: 8K 1.071 s (7,655 tok/s, 7 samples), 32K 3.897 s (8,293 tok/s, 3 samples), 128K 15.993 s (8,057 tok/s, 1 sample). `server_validation.method` is empty in all three, so these are client-side times only.

## Failing case: the 5 times slower host

Same profile on Vast.ai host 48294, 2026-11-12 (`f3/resultados/vast-20261112/vllm/`), Observed:

```
decode summary_table {'0': {'1': 108.21611012048743, '8': 298.6232354486349, '16': 350.7962459587102, '32': 297.5953272964876}}
prefill 8192   9.437 s   869.0 tok/s
prefill 32768  37.423 s  864.0 tok/s
prefill 131072 148.843 s 866.0 tok/s
```

C32 decode is 297.6 against 1,580.3 on host 157204 with the same DCP1 profile, and prefill is 10 times slower, while MTP acceptance stays at 2.56 to 2.81. That rules out a speculation problem and points at the host (cause Unknown, §29.10). The qualification rule: run C32 decode for about 5 minutes after the server is up and discard the host below 1,400 tok/s with DCP1.
