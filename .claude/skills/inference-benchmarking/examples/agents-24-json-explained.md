# An `agents-<N>.json` file read field by field

Use this when you open an agent-level result by hand, or when you need to know which field feeds which number. The file is `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/agentes-24.json` (Portuguese file name, written before the translation; the harness now writes `agents-24.json`). Real model, vLLM DCP1, Vast host 157204, one run, 2026-11-12 00:46 UTC. Every value below is Observed in that file; excerpts are quoted as Python reprs printed by `json.load`.

To print any part of it:

```bash
python3 -c "import json; d=json.load(open('agentes-24.json')); print(d['scheduler']['scenarios'][0]['metrics']['turn_log'][100])"
```

## Top level

Keys: `metadata`, `server`, `scheduler`, `methodology`.

## `metadata`: what was asked

```
version: '0.8.0'
timestamp: '2026-11-12T00:46:18'
argv: ['--port', '8000', '--scheduler', 'agents', '--sched-agents', '24', '--sched-agents-duration', '1200',
       '--sched-agent-start', '40k-100k', '--sched-agent-tool', '1k-6k', '--sched-agent-response', '300-4000',
       '--sched-agent-think', '0-3', '--sched-seed', '24', '--output', 'resultados/vast-vllm-dcp1/agentes-24.json']
settings: agent_start [40960, 102400], agent_tool [1024, 6144], agent_response [300, 4000],
          agent_think [0.0, 3.0], seed 24
```

| Field | Meaning | Check |
|---|---|---|
| `version` | bench version | `0.8.0` for the pinned commit |
| `argv` | exact command line | the duration (`1200`) and seed (`24` = level size) |
| `settings.agent_start` | start context in tokens; `40k` is 40,960 (k = 1,024) | equal across runs you compare |
| `settings.seed` | fixes lengths and timing, not prompt content | equal across runs of one level |

## `server`: what the bench read from the server

```
version: '0.1.dev21830+g8244d1c44'
max_model_len: 1048576
kv_tokens: 6789052   (kv_tokens_source: 'vllm kv_cache_size_tokens')
max_running: 32
prompt_mode: 'token_ids'
local_command.options: max-num-seqs 32, max-num-batched-tokens 4096, max-parallel-prefills 1,
                       prefill-compute-share 0.4, decode-context-parallel-size 1, ...
prefill_fairness: unavailable (HTTP 404, needs VLLM_SERVER_DEV_MODE=1)
```

| Field | Meaning |
|---|---|
| `version` | vLLM build string of the image; quote it in reports |
| `kv_tokens` | KV pool size in tokens. DCP1 has 6.79M; DCP4 run 2 had 22.95M (`vast-vllm-r1-rep2/agentes-24.json`). DCP4 shards KV across 4 GPUs, so it holds about 3.4 times more context and still serves fewer sessions |
| `max_running` | the server's `--max-num-seqs`; levels above it only add queueing |
| `prompt_mode` | `token_ids` means prompts were built with `/tokenize` and exact history was possible |
| `local_command.options` | the flags of the running process, read from `/proc`; compare with `server.sh` |

## `scheduler.scenarios[0]`: the result

```
scenario: 'agents', elapsed_s: 1203.6, status: 'pass'
checks: [every turn succeeded: '0 failed turns'; turns finished: '385 turns']
```

`status: 'pass'` is the bench's own check (no failed turn, some turns finished). It knows nothing about our SLO.

### `metrics`

```
turns_ok 385, turn_errors 0, timeouts 0, resets 0, wall_s 1201.9, decode_tok_s 730.3,
turn_ttft_s {count 385, p50 2.801, p90 74.993, p99 346.871, max 380.568, mean 26.213}
turn_s      {p50 47.759, p90 153.748, p99 379.865, max 425.843, mean 69.25}
max_context 219513, cached_pct_usage 93.3, exact_history True, context_cap 1038416
```

| Field | Meaning | Used by `summarize.py` |
|---|---|---|
| `turns_ok` | turns that finished, all phases | no |
| `turn_errors` | turns that errored, all phases | yes: any error fails the level |
| `timeouts`, `resets` | request timeouts; conversations restarted because they reached `context_cap` | no |
| `decode_tok_s` | output tokens of the whole level over its wall time (aggregate, including the cold phase) | no |
| `turn_ttft_s` | TTFT over every finished turn, including turn 0 and the cold queue | no. Its p99 of 346.9 s is the cold queue, not the SLO |
| `max_context` | longest conversation reached (219,513 tokens) | no |
| `cached_pct_usage` | cached share over every turn (93.3%) | no; `summarize.py` recomputes it on steady turns (97.2%) |
| `exact_history` | the model's real output tokens were appended | no, but required for a valid run |
| `context_cap` | largest prompt allowed before a reset | no |
| `turn_log` | one entry per turn | yes, the only input of the SLO logic |
| `windows` | 60 s windows | no; use them to see when the level settled |

### `metrics.turn_log`: one entry per turn

Turn 0 of agent 0, a cold prefill:

```
{'agent': 0, 'turn': 0, 'prompt_len': 86956, 'max_tokens': 948, 'send_s': 0.003, 'ttft_s': 9.971,
 'seconds': 19.064, 'prompt_tokens': 86956, 'cached_tokens': 0, 'completion_tokens': 948}
```

Entry 100, a steady-state turn:

```
{'agent': 10, 'turn': 4, 'prompt_len': 96777, 'max_tokens': 2972, 'send_s': 559.76, 'ttft_s': 1.438,
 'seconds': 58.607, 'prompt_tokens': 96777, 'cached_tokens': 95708, 'completion_tokens': 2972}
```

A turn cut by the end of the level:

```
{'agent': 7, 'turn': 11, 'prompt_len': 120164, 'max_tokens': 3766, 'send_s': 985.501, 'ttft_s': 3.433,
 'seconds': 214.509, 'prompt_tokens': 120164, 'cached_tokens': None, 'completion_tokens': 3754, 'stopped': True}
```

| Field | Meaning | What `summarize.py` does with it |
|---|---|---|
| `agent`, `turn` | who and which turn | turn 0 marks the cold phase; turns 1 and later can be steady |
| `prompt_len` | tokens the bench sent | none |
| `max_tokens` | response length forced for this turn (`ignore_eos`) | none |
| `send_s` | send time from the level start | steady state: kept only if `send_s >= ` the latest end of a turn 0 |
| `ttft_s` | time to first token | the SLO p95 |
| `seconds` | whole turn duration | per-stream speed is `completion_tokens / (seconds - ttft_s)` |
| `prompt_tokens`, `cached_tokens` | from the server's `usage` | cache % and recomputed tokens (`prompt_tokens - cached_tokens`) |
| `completion_tokens` | output tokens | per-stream speed |
| `stopped`, `aborted` | turn cut at the deadline | the turn is dropped |

Worked numbers for entry 100: recomputed tokens `96777 - 95708 = 1,069`, so 98.9% of the prompt came from cache. Per-stream speed `2972 / (58.607 - 1.438) = 52.0` tok/s, above the 30 tok/s target. TTFT 1.44 s, below 5 s.

Agent 0's turn 0 ended at `0.003 + 19.064 = 19.07` s, but the steady state of this level starts at 470 s: the last agent to finish turn 0 did so at 470 s (`summarize.py` output, Steady since). The agent sent at 0 s gets served first; agents spawned later queue behind 23 other prefills of 40K to 100K tokens.

This level has 24 stopped turns, one per agent.

### `metrics.windows`: 60 s buckets

First window and one near the end:

```
{'start_s': 0, 'turns': 2, 'turn_s_mean': 29.1, 'ttft_s_mean': 22.66, 'tok_s': 61.0, 'max_context': 86956,
 'running': '0-3', 'waiting_max': 22.0, 'kv_max_pct': 3.9, 'preemptions': 0.0, 'prefix_hit_pct': 0.0}
start_s 1140: turns 26, ttft_s_mean 2.85, tok_s 1055.4, running '21-24', waiting_max 1, kv_max_pct 72.6, prefix_hit_pct 97.9
```

Read: at the start 22 requests wait and nothing hits the prefix cache. At the end 21 to 24 run, at most one waits, KV peaks at 72.6% and 97.9% of prefill tokens hit the cache. A level that never reaches a window like the second is not in steady state.

### `server`: deltas of the server's `/metrics` over the level

```
max_running 24.0, max_waiting 23.0, max_kv_usage_pct 72.6, preemptions 0, prompt_tokens 48301690,
generation_tokens 877863, requests_finished 385, prefix_hit_pct 93.7,
compute_seconds decode 406.24 / prefill 361.46 (prefill_share 0.471),
histograms ttft {count 409, mean_s 24.8014, p50_s 2.8164, p90_s 54.6667, p99_s 567.2889}
```

- `preemptions 0` and `max_kv_usage_pct 72.6`: the KV pool was not the limit at 24 agents. TTFT was.
- `prefill_share 0.471`: almost half the GPU time went to prefill even with 93.7% prefix hits. Inferred: the 1K to 6K tool tokens per turn plus 24 cold starts are a large prefill load, and `--prefill-compute-share 0.4` and `--max-parallel-prefills 1` decide how it competes with decode.
- `histograms.ttft.count 409` counts every request including the 24 stopped ones (385 + 24).

### `client`

```
sent 409, completed 385, errors 0, aborted 0
```

`sent - completed = 24`: the stopped turns. `timeseries` holds 600 samples (one every 2 s).

## Same level, the numbers that matter

`summarize.py` on this directory gives, for level 24: steady since 470 s, 326 steady turns, TTFT p95 4.93 s, tok/s p50 55.3, cache 97.2%, recomputed p50 3,432 and p90 5,559, `pass`. Compare with the bench's own `turn_ttft_s.p99` of 346.9 s: the two describe different populations of turns.
