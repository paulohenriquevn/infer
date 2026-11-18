# Harness walkthrough: `run_benchmark.sh` and `llm_decode_bench.py`

Read this before you run the harness, change it, or read one of its output files by hand. Everything here is Observed in the code of this repository (`bench/run_benchmark.sh`, `bench/setup_bench.sh`, `bench/bench-exact-history-sglang.patch`) and in the patched upstream bench at commit `52216d70865a015b34689626d04a80b89c9dc45f` (file `llm_decode_bench.py`, version string `0.8.0` in every result file), unless a line says otherwise. Line numbers refer to `llm_decode_bench.py` with our patch applied.

## 1. Setup: the bench and the patch

`bench/setup_bench.sh` clones `https://github.com/local-inference-lab/llm-inference-bench.git` into `BENCH_DIR` (default `bench/llm-inference-bench`), checks out the pinned commit, verifies `HEAD`, runs `git apply --check` on the patch, applies it, and checks two markers: the string `return_token_ids` in `llm_decode_bench.py` and the file `tests/test_agent_exact_history.py`. Exit codes: 2 (patch missing or `BENCH_DIR` exists), 3 (wrong commit), 4 (patch does not apply), 5 (markers missing after apply).

| Variable | Default | Effect |
|---|---|---|
| `BENCH_DIR` | `bench/llm-inference-bench` | clone target; must not exist |
| `BENCH_REPO_URL` | the GitHub URL above | upstream |
| `BENCH_COMMIT` | `52216d70865a015b34689626d04a80b89c9dc45f` | pinned commit |

Why the code is cloned and not copied: the upstream repository has no licence file (`bench/README.md`).

The bench needs `httpx` and `rich` (`pip install httpx rich`). Its patch test runs without a GPU: `cd $BENCH_DIR && python3 -m pytest -q tests/test_agent_exact_history.py` (5 tests).

### What the exact-history patch changes and why

The agents scenario appends the model's own output to the next turn, so the next request shares the whole previous request as a prefix and the server's prefix cache can reuse it. Upstream, only vLLM got exact output token IDs: the request set `logprobs=1` and `return_tokens_as_token_ids=True`, and the bench parsed `token_id:123` strings from the logprobs. For every other engine it appended random tokens of the same count (`exact = ctx.engine == ENGINE_VLLM and ...`).

Random tokens break the cache at the point where the response starts. On SGLang every turn would then re-prefill the response plus the tool block, while vLLM re-prefilled only the tool block. An A/B between engines would measure the harness, not the cache (docstring of `tests/test_agent_exact_history.py`).

The patch (113 lines, `bench/bench-exact-history-sglang.patch`):

1. `sched_payload`: on SGLang, sends `return_token_ids: true` instead of the logprobs fields. SGLang streams each chunk's new IDs in `choices[].token_ids`.
2. New `sched_exact_history(ctx)`: true when the engine is vLLM or SGLang and the prompt factory is in `token_ids` mode (the server answered `POST /tokenize`).
3. `sched_chunk_token_ids`: reads `choices[].token_ids` first, then falls back to the vLLM logprobs form.
4. `sched_run_agents` uses `sched_exact_history`.
5. Adds `tests/test_agent_exact_history.py` (payload on both engines, chunk parsing on both, exact history only with token-ID prompts).

`run_benchmark.sh` refuses to run if `return_token_ids` is not in the bench file: `the bench at $BENCH lacks the SGLang exact-history patch` (exit 1). The flag `exact_history` in every `agents-<N>.json` (`scheduler.scenarios[0].metrics.exact_history`) tells you whether a run had it: it is `true` in all vLLM runs of `f3/resultados/vast-20261111/vllm/`.

## 2. `run_benchmark.sh` step by step

The script `cd`s into its own directory (`bench/`), so relative paths in `OUT`, `SERVER_SCRIPT` and `BENCH_DIR` resolve from `bench/`.

### Step 0: validation

- `ENGINE`, `IMAGE`, `SERVER_SCRIPT` are required (`${VAR:?}`).
- `ENGINE` must be `vllm` or `sglang`; `LAUNCH_MODE` must be `docker` or `direct` (exit 1 otherwise).
- `SERVER_SCRIPT` must exist; `BENCH` must exist and contain `return_token_ids`.
- Writes `engine.txt` and copies the server script to `$OUT/server.sh`. The run executes `$OUT/server.sh`, not the original, so the copy is exactly what ran.

### Step 1: host record (`host.txt`)

One `nvidia-smi --query-gpu=index,name,driver_version,persistence_mode,power.limit,clocks.max.sm,pcie.link.gen.current,pcie.link.width.current --format=csv`, the `RegistryDwords` line of `/proc/driver/nvidia/params` (driver P2P override), and `nvidia-smi topo -m`.

Pitfall: `pcie.link.gen.current` is read at idle and shows `1` on host 157204 (Observed, `vast-vllm-dcp1/host.txt`), because idle GPUs drop the link speed. Read the maximum link generation from `nvidia-smi --query-gpu=pcie.link.gen.max` under load, as `f3/resultados/vast-20261112/vllm/host-diagnostico.txt` did (Gen 5, x16).

### Step 2: server start and readiness

`run_benchmark.sh` calls `$OUT/server.sh` with `NAME GPUS PORT IMAGE LAUNCH_MODE PIDFILE LOGFILE` in the environment and stores its stdout in `server-id.txt` (container ID in Docker mode, PID in direct mode). A `trap stop_server EXIT` stops the server when the script exits for any reason.

Every 10 s the loop:

1. copies the log to `$OUT/server.log` (`docker logs`, or a copy of `server-direct.log` in direct mode);
2. exits 2 if the container or process is not running (`FAILURE: server <state>`, last 40 lines printed);
3. exits 3 if the log matches `Traceback|CUDA out of memory|OutOfMemoryError|Engine core initialization failed|Scheduler hit an exception|Received sigquit`;
4. breaks when `curl -sf http://localhost:$PORT/v1/models` succeeds;
5. exits 4 after `READY_TIMEOUT` seconds (default 3600).

Then it writes `ready-time.txt` (`ready in <s> s`) and tries `GET /get_server_info` into `server-info.json` (SGLang serves it; on vLLM the file may be empty or absent).

### Step 3: quality gate (skipped with `AGENTS_ONLY=1`)

| Call | Output | Parameters |
|---|---|---|
| needle-checksum at C8 | `needle.json`, `needle.log` | `--test-profile needle-checksum --profile-runs ${NEEDLE_RUNS:-500} --profile-concurrency 8` |
| needle-checksum at C16 | `needle-c16.json`, `needle-c16.log` | `--profile-runs 120 --profile-concurrency 16` (fixed) |
| gsm8k | `gsm8k.json`, `gsm8k.log` | `--test-profile gsm8k --profile-runs 96 --profile-concurrency 8` |

The C16 run exists because SGLang's EAGLE NaN (#49881) appears when the batch fills the largest decode CUDA graph (comment in the script).

Then the script imports `summarize` and computes `all(passes_needle(...))` on `needle.json` and `needle-c16.json` against `NeedleReference.from_text("${NEEDLE_REF:-3/500}")`. If that is false and `STOP_ON_GATE_FAIL=1`, it prints `FAIL on needle-checksum ...` and exits 5. gsm8k never stops the run. With `GATE_ONLY=1` it exits 0 after the gate (`OK: gate only in $OUT`).

### Step 4: speed (skipped with `AGENTS_ONLY=1`)

| Call | Output | Parameters |
|---|---|---|
| decode | `decode.json`, `decode.log` | `--concurrency 1,8,16,32 --contexts 0 --duration 30 --max-tokens 8192 --skip-prefill` |
| prefill | `prefill.json`, `prefill.log` | `--prefill-only --standalone-prefill --prefill-contexts 8k,32k,128k,256k` |

Observed gap: every `prefill.json` in the archive has only the 8K, 32K and 128K cells; 256K is requested and absent (`f3/resultados/vast-20261111/vllm/*/prefill.json`). The log does not say why. Unknown; read `prefill.log` and the bench's prefill context capping before relying on a 256K cell.

### Step 5: agent levels

For each `n:dur` in `AGENT_LEVELS` (validated as two integers, exit 1 otherwise):

```bash
"$PY" "$BENCH" --port "$PORT" --scheduler agents --sched-agents "$n" --sched-agents-duration "$dur" \
  --sched-agent-start "$AGENT_START" --sched-agent-tool "$AGENT_TOOL" \
  --sched-agent-response "$AGENT_RESPONSE" --sched-agent-think "$AGENT_THINK" \
  --sched-seed "$n" --output "$OUT/agents-$n.json"
```

A level that exits non-zero appends `agents-<n> exited with code <c> (see log)` to `warnings.txt` and the loop continues. The seed equals the level size, so level 24 always uses seed 24. Finally the script collects the log again and prints `OK: $OUT`.

## 3. Environment variables (complete)

| Variable | Default | Read by | Effect |
|---|---|---|---|
| `ENGINE` | required | step 0 | `vllm` or `sglang`; written to `engine.txt` |
| `IMAGE` | required | step 0, server script | container image; recorded in `host.txt` |
| `SERVER_SCRIPT` | required | step 0 | launch script, copied to `server.sh` |
| `LAUNCH_MODE` | `docker` | steps 2 | `direct` when the shell already runs inside the image (Vast.ai) |
| `GPUS` | `0,1,2,3` | server script | GPU list |
| `PORT` | `8000` | all | server port |
| `NAME` | `glm53-cmp-<engine>` | step 2 | Docker container name |
| `BENCH_DIR` | `llm-inference-bench` | step 0 | used only to build `BENCH` |
| `BENCH` | `$BENCH_DIR/llm_decode_bench.py` | all bench calls | patched bench |
| `PY` | `python3` | all bench calls | interpreter with `httpx` and `rich` |
| `READY_TIMEOUT` | `3600` | step 2 | seconds before exit 4 |
| `OUT` | `results/<YYYYmmdd-HHMM>-<engine>` | all | result directory; a rerun with the same `OUT` overwrites files |
| `NEEDLE_RUNS` | `500` | step 3 | needle runs at C8 (120 before 2026-11-12) |
| `NEEDLE_REF` | `3/500` | step 3 | reference for the Fisher test |
| `STOP_ON_GATE_FAIL` | `1` | step 3 | exit 5 when the needle fails |
| `GATE_ONLY` | `0` | step 3 | `1` exits after the gate |
| `AGENTS_ONLY` | `0` | steps 3, 4 | `1` skips gate and speed |
| `AGENT_LEVELS` | `8:600 16:900 32:1500` | step 5 | `agents:seconds` list; set to empty to run none (the script uses `${AGENT_LEVELS-...}`, so an empty value is kept) |
| `AGENT_START` | `40k-100k` | step 5 | start context per agent |
| `AGENT_TOOL` | `1k-6k` | step 5 | tool-result tokens appended per turn |
| `AGENT_RESPONSE` | `300-4000` | step 5 | `max_tokens` per turn |
| `AGENT_THINK` | `0-3` | step 5 | seconds of think time between turns |

Server scripts read their own variables (`MODEL_DIR`, `CACHE_DIR`, `ADAPTIVE_CONFIG`, `NO_SPECULATIVE`, `MOE_RUNNER_BACKEND`, `MAX_TOTAL_TOKENS`, `MAMBA_SSM_DTYPE`, `MAX_RUNNING_REQUESTS`, `MAX_MAMBA_CACHE_SIZE` on SGLang; `CACHE_MODE`, `DCP`, `KV_CACHE_BYTES`, `LMCACHE_L1_GB` on the LMCache launcher). Each script lists its own at the top; the `vllm-fork-serving` skill covers the vLLM ones.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | finished (`OK: $OUT` or `OK: gate only`) |
| 1 | bad input (engine, mode, script, bench, patch, level syntax) |
| 2 | server process or container died before ready |
| 3 | error pattern in the server log before ready |
| 4 | not ready within `READY_TIMEOUT` |
| 5 | needle gate failed with `STOP_ON_GATE_FAIL=1` |

A failure inside one agent level does not change the exit code; check `warnings.txt`.

## 4. Output files and their schemas

Names in the left column are the current ones. Directories written before the translation (all of `f3/resultados/`) use the Portuguese names in parentheses: `motor.txt`, `servidor.sh`, `servidor.log`, `servidor-direto.log`, `servidor-id.txt`, `servidor.pid`, `tempo-pronto.txt`, `agentes-<N>.json`, `avisos.txt`.

| File | Written by | Content |
|---|---|---|
| `engine.txt` (`motor.txt`) | step 0 | `vllm` or `sglang` |
| `server.sh` (`servidor.sh`) | step 0 | the exact launch script |
| `host.txt` | step 1 | date, engine, image, GPU query, `RegistryDwords`, `topo -m` |
| `server-id.txt`, `server.pid` | step 2 | container ID or PID |
| `server-direct.log` | server (direct mode) | raw server output |
| `server.log` (`servidor.log`) | step 2, end | server log copy |
| `ready-time.txt` (`tempo-pronto.txt`) | step 2 | `ready in 260 s` (DCP1 on host 157204) |
| `server-info.json` | step 2 | `/get_server_info` if served |
| `needle.json`, `needle-c16.json`, `gsm8k.json` | step 3 | profile results, schema below |
| `decode.json`, `prefill.json` | step 4 | speed results, schema below |
| `agents-<N>.json` (`agentes-<N>.json`) | step 5 | scheduler result, schema below |
| `*.log` | each bench call | console output of the call; the progress lines of an interrupted level are only here |
| `warnings.txt` (`avisos.txt`) | step 5 | one line per failed level |

### `needle.json`, `needle-c16.json`, `gsm8k.json` (mode `completion_stats`)

Top-level keys (Observed, `vast-vllm-dcp1/needle.json`): `metadata`, `nvidia_p2p_override`, `p2pmark`, `amd_fabric`, `prefill_scout`, `selected_concurrency`, `selected_summary`, `all_summary`, `level_summaries`, `accuracy`, `category_summaries`, `wrong_runs`, `hardware_run_summary`, `runs`, `methodology`.

| Field | Meaning | Example (DCP1, host 157204) |
|---|---|---|
| `metadata.test_profile` | profile name | `needle-checksum` |
| `metadata.requested_runs`, `fixed_concurrency` | what was asked | `120`, `8` |
| `metadata.max_tokens` | per request | `4096` (needle), `131072` (gsm8k) |
| `selected_summary.attempted`, `correct`, `wrong` | the counts `summarize.py` uses | `120`, `117`, `3` |
| `selected_summary.near_miss` | answers with checksum 3330 and the right facts | `3` |
| `selected_summary.wrong_facts`, `wrong_checksum`, `fail` | other failure classes | `0` |
| `selected_summary.correct_rate` | fraction | `0.975` |
| `wrong_runs[]` | each wrong run with `final_answer`, `score_label`, `score_detail` | `submit_context_check({"alpha": 478, "beta": 788, "checksum": 3330, "gamma": 426})`, `near_miss`, `checksum 3330, expected 3332` |
| `accuracy` | gsm8k only: `accuracy`, `wilson95_low`, `wilson95_high` | `0.9896`, `0.9433`, `0.9982` |
| `hardware_run_summary` | GPU power, utilisation, PCIe during the run | `power_total_avg_w 936.99` |
| `nvidia_p2p_override.effective` | whether the driver P2P override is active | `false` on host 157204 (P2P worked without it) |

The needle profile text (`metadata.test_profile_description`) says: an 8K-token synthetic dataset hides three values, the model must submit `ALPHA + 2*BETA + 3*GAMMA = 3332` through one tool call, the same prompt is sent at temperature 0, and wrong answers measure "how often the serving stack's numerics tip the model's near-tie on the last digit (NEAR_MISS = 3330)". Before the measured runs one `max_tokens=1` scout request warms the prefix cache (`methodology.prefill`).

`summarize.py` reads only `selected_summary.attempted` and `selected_summary.correct`.

### `decode.json` and `prefill.json`

Top-level keys: `metadata`, `startup_diagnostics`, `nvidia_p2p_override`, `p2pmark`, `amd_fabric`, `hardware_run_summary`, `event_log`, `prefill`, `results`, `summary_table`, `burst_results`, `burst_summary_table`, `mixed_prefill`, `methodology`.

Decode: `results[]` has one entry per concurrency. The aggregate tok/s used for host qualification is `results[i].aggregate_tps` (also `summary_table["0"]["<concurrency>"]`). Other fields: `per_request_avg_tps`, `ttft_avg`, `ttft_p50`, `client_output_tokens`, `server_output_tokens`, `measurement_seconds`, `failure_reason`.

```
vast-vllm-dcp1/decode.json  summary_table: {"0": {"1": 154.48208507538416, "8": 696.2636953380463,
                                                  "16": 1072.5578492819543, "32": 1580.305306316327}}
```

Prefill: `prefill["<tokens>"]` with `ttft_seconds`, `tok_per_sec`, `prompt_tokens`, `samples`, `method` (`client`). DCP1 on host 157204: 8K 0.966 s, 32K 3.543 s, 128K 14.389 s (8,957 tok/s). These are cold single-request prefills with no decode running.

### `agents-<N>.json`

See `examples/agents-24-json-explained.md` for a field-by-field reading of a real file. Structure:

```
metadata      version, mode "scheduler", timestamp, argv, settings (seed, agents, agents_duration,
              agent_start/tool/response/think as [lo, hi]), model, engine
server        max_model_len, version, kv_tokens, kv_tokens_source, max_running, prompt_mode ("token_ids"),
              local_command.options (server flags read from the process)
scheduler.scenarios[0]
  scenario "agents", status "pass"|"fail", checks[]
  metrics     agents, start_context, context_cap, exact_history, turns_ok, turn_errors, timeouts, resets,
              wall_s, decode_tok_s, turn_ttft_s{count,p50,p90,p99,max,mean}, turn_s{...}, max_context,
              cached_pct_usage, windows[], turn_log[], error_kinds, error_samples
  headline    turns_ok, decode_tok_s, turn_ttft_p50_s, turn_ttft_p99_s, max_context
  server      /metrics deltas: max_running, max_waiting, max_kv_usage_pct, preemptions, prefix_hit_pct,
              compute_seconds, histograms (ttft, inter_token_latency, e2e, queue_time, prefill_time)
  client      sent, completed, errors, aborted, tokens
  timeseries  one /metrics sample every 2 s
scheduler.verdict, methodology
```

`summarize.py` reads `scheduler.scenarios[*]` with `scenario == "agents"` (exactly one), and inside it only `metrics.turn_errors`, `metrics.agents` and `metrics.turn_log`.

Pitfall: the bench's own `status` and `turn_ttft_s` cover every turn including the cold queue. `turn_ttft_s.p99` was 346.9 s on the DCP1 24-agent level that passed the SLO at 4.93 s (Observed). Never quote the bench headline as the SLO number.

## 5. How the agents scenario works (`sched_run_agents`, line 20780)

Inputs come from `--sched-agents`, `--sched-agents-duration`, `--sched-agent-start`, `--sched-agent-tool`, `--sched-agent-response`, `--sched-agent-think` and `--sched-seed` (defaults in the bench: 8 agents, 600 s, start `40k-100k` within half the model length or KV pool, tool `1k-6k`, response `300-4000`, think `0-3`, seed 7).

1. **Context cap.** `cap = ctx.fit(10**9, response_hi) - tool_hi`: the largest prompt that fits the model length and the KV pool (`fit`, line 20205: `min(max_model_len, kv_tokens) - max_tokens - 16`). DCP1 run: `context_cap` 1,038,416 with `max_model_len` 1,048,576. If `cap < 2048` the scenario is skipped.
2. **Exact history.** `exact = sched_exact_history(ctx)`. If false, the run notes that responses are appended as random tokens.
3. **Agent start.** Agents are spawned 2 s apart (`run.sleep(2.0)` between spawns). Each has its own RNG seeded with `"<seed>:agent:<index>:<arm>:<round>"`, draws a start length in the start range and builds a prompt of that many token IDs.
4. **Turn loop**, while the deadline is not reached:
   - draws `max_tokens` from the response range;
   - if `length + max_tokens + tool_hi > cap`, counts a `reset` and starts a new conversation from a fresh start context;
   - sends the whole conversation as a streaming `/v1/completions` request (`ignore_eos`, continuous usage stats), recording send time, first-token time, end time, `prompt_tokens`, `cached_tokens` (from `usage.prompt_tokens_details.cached_tokens`), `completion_tokens`;
   - on error: sleeps 5 s and retries with the same conversation;
   - on success: appends the exact output token IDs (or random tokens of the same count) plus a block of random tool tokens drawn from the tool range;
   - sleeps a think time drawn from the think range.
5. **End of level.** At the deadline a `halt` event is set: every request still streaming is closed and marked `stopped`, and a remote abort is sent. Tasks get 30 s of grace, then are cancelled (marked `aborted`). Those turns carry no `cached_tokens` and are dropped by `summarize.py`.

What is random and what is fixed: the seed fixes lengths, think times and timing per agent. Prompt content comes from a generator seeded with a fresh UUID per invocation (`SchedulerPromptFactory`, line 19925), so a second run with the same seed never hits the first run's prefix cache. Two runs of one level replay the same workload shape on a cold cache.

What the scenario does not model: sub-agent fan-out, human pauses, real tool outputs, real GLM output lengths (the response length is forced by `max_tokens` with `ignore_eos`). It is close to one continuous stream per agent (`docs/01`).

Server-side limit: our vLLM profile runs `--max-num-seqs 32`, so levels above 32 only add queueing (comment in `run_benchmark.sh`).

## 6. Durations: how long a level must be

All agents start within `2 x (N - 1)` seconds with 40K to 100K tokens of cold context, and their first prefills queue. Steady state starts when the last agent finishes turn 0. Observed steady-state starts on host 157204:

| Arm, level | Level duration | Steady state from | Steady turns |
|---|---|---|---|
| DCP4 run 1, 8 agents | 420 s | 167 s | 65 |
| DCP4 run 1, 16 agents | 900 s | 416 s | 159 |
| DCP4 run 1, 32 agents | 1,500 s | 724 s | 325 |
| DCP1, 16 agents | 900 s | 380 s | 212 |
| DCP1, 24 agents | 1,200 s | 470 s | 326 |
| DCP4 run 2, 24 agents | 1,200 s | 491 s | 268 |

Rule of thumb (Inferred from the table): budget about 20 to 26 s of cold queue per agent and at least 7 more minutes of steady state. The DCP1 run used `24:1200`, not the `24:900` that `docs/06` phase 2 suggests; keep the duration the same across runs you compare.

The DCP4 run 1 directory mixes two attempts: `agentes-8.json` and `agentes-24.json` are byte-identical to the files in `vast-vllm-r1/agentes-7min/` (the first attempt, 420 s per level, timestamps 17:57 and 18:12), while `agentes-16.json` and `agentes-32.json` come from the second attempt (900 s and 1,500 s). Level 24 of that attempt never reached steady state (20 of 24 agents finished turn 0), so `summarize.py` reports it as `short sample`.
