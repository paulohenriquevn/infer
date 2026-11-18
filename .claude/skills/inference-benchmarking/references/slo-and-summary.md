# How `summarize.py` turns a result directory into a verdict

Read this when a `summarize.py` verdict surprises you, when you change the SLO logic, or when you need to defend a number in a review. Every rule below is Observed in `bench/summarize.py` (243 lines) and pinned by a test in `bench/test_summarize.py` (24 tests, no GPU: `cd bench && uvx pytest -q test_summarize.py`, 24 passed on 2026-11-12). The SLO targets themselves are Hypothesis adopted for the MVP (`ARQUITETURA.md §20`).

## 1. Command line

```
python3 summarize.py --price <US$/h> [--ttft-p95 5.0] [--tps-p50 30.0] [--min-turns 20]
                     [--needle-ref 3/500] [--json out.json] DIR [DIR ...]
```

| Option | Default | Notes |
|---|---|---|
| `--price` | required | US$ per hour of one 4-GPU replica on the machine where the run happened; must be positive (`ap.error`) |
| `--ttft-p95` | `5.0` | from `Slo.ttft_p95_s` |
| `--tps-p50` | `30.0` | from `Slo.tps_p50` |
| `--min-turns` | `20` | the `Slo` dataclass default is `1`; only the command line sets 20 |
| `--needle-ref` | `3/500` | parsed by `NeedleReference.from_text`; must match `\d+/\d+`, total above 0, errors not above total |
| `--json` | none | writes the full per-level summary (all fields of section 3) |

Each directory is summarized independently. Nothing pools runs: if you want two runs judged together, judge each and apply the two-run rule yourself.

## 2. Reading a directory (`summarize_engine`)

1. **Engine name.** First of `engine.txt`, `motor.txt` that exists; `FileNotFoundError` if neither (`read_engine`).
2. **Gate files.** `gate_ran = needle.json exists`. If `needle.json` exists but `gsm8k.json` does not, it raises `FileNotFoundError(... the gate did not finish)`. Every `needle-c*.json` in the directory is also loaded.
3. **Agent files.** `agents-*.json` and the legacy `agentes-*.json`; the level is the number in the name. The same level under both names raises `ValueError("level N appears twice")`. Test: `test_same_level_under_legacy_and_current_names_fails_loudly`; legacy names alone: `test_directory_with_legacy_portuguese_file_names_is_summarized`.
4. **One scenario per file.** `report["scheduler"]["scenarios"]` must hold exactly one entry with `scenario == "agents"`, else `ValueError`.
5. **No agent files.** `FileNotFoundError(... no agents-<N>.json files)`. A gate-only directory cannot be summarized; use the Fisher one-liner in `SKILL.md`.

## 3. Per-level evaluation (`evaluate_agents`)

Input: `scenario["metrics"]`, from which it reads `turn_log`, `turn_errors` and `agents`.

### 3.1 Cut turns are dropped

```python
interrupted = [t for t in log if t.get("stopped") or t.get("aborted")]
turns = [t for t in log if t.get("ttft_s") is not None and t.get("seconds")
         and not (t.get("stopped") or t.get("aborted"))]
```

Why: when the level's deadline arrives, the bench closes every open stream (`stopped`) or cancels it after 30 s of grace (`aborted`). Those turns have no `usage`, so no `cached_tokens`, and their duration is truncated. The DCP1 24-agent level had 24 stopped turns (one per agent, Observed). Test: `test_turn_interrupted_by_end_of_scenario_is_left_out_of_statistics`.

A turn without a first token (`ttft_s` is `None`) is also dropped here; an errored turn is counted through `turn_errors`, not through the log.

### 3.2 Steady state

```python
turn0_ends = [t["send_s"] + t["seconds"] for t in turns if t.get("turn", 0) == 0 and t.get("send_s") is not None]
agents = m.get("agents") or len({t.get("agent") for t in log})
if len(turn0_ends) < agents:      # some agent never finished turn 0
    steady_start = None; cached = []
else:
    steady_start = max(turn0_ends) if turn0_ends else 0.0
    cached = [t for t in turns if t.get("turn", 0) >= 1 and (t.get("send_s") or 0.0) >= steady_start]
```

- Only turns 1 and later count (turn 0 is a cold prefill of 40K to 100K tokens by design). Test: `test_first_turn_of_each_agent_is_left_out_of_cached_ttft`.
- Only turns **sent** after the last agent finished turn 0 count. Before that moment the cold prefills of other agents occupy the server, and any turn sent then waits behind them. Test: `test_turn_sent_before_last_first_turn_finished_is_left_out_of_steady_state` (agent 1 finishes turn 0 at 120 s; agent 0's turn sent at 30 s with 90 s TTFT is excluded; steady start 120).
- If any agent never finished turn 0, the whole level has zero steady turns. Test: `test_steady_state_does_not_start_if_some_agent_did_not_finish_turn_0`.

Why this rule exists (§29.3): in the first attempt with 7-minute levels no turn left the cold queue, and the 8-agent level failed with a TTFT p95 of 33 s that came from the simultaneous start, not from serving capacity. With 16 agents the cold queue lasted 416 s.

### 3.3 Cached tokens must be reported

```python
if cached and all(t.get("cached_tokens") is None for t in cached):
    raise MissingCacheReport(...)
cached = [dict(t, cached_tokens=t.get("cached_tokens") or 0) for t in cached]
```

- If no steady turn reports `cached_tokens`, the server was started without cache reporting and the cache columns would be fiction. The error message says to start SGLang with `--enable-cache-report` or vLLM with `--enable-prompt-tokens-details` (our vLLM scripts set the latter; it shows in `non-default args` as `'enable_prompt_tokens_details': True`). Test: `test_fails_loudly_when_server_does_not_report_cached_tokens`.
- If some turns report it and others do not, the missing ones count as 0. SGLang omits the field when nothing came from cache (every turn 0, and evicted prefixes); vLLM reports 0. Test: `test_turn_without_cached_tokens_counts_as_zero_when_server_reports_cache_on_others`.

### 3.4 Statistics

| Output | Formula | Test |
|---|---|---|
| `ttft_p95_s` | 95th percentile of `ttft_s` over steady cached turns | first-turn test above |
| `tps_p50` | median of `completion_tokens / (seconds - ttft_s)`, only for turns with `completion_tokens` and `seconds > ttft_s` | `test_stream_speed_discounts_ttft` (300 tokens in 10 s after the first token is 30 tok/s) |
| `recomputed_p50`, `recomputed_p90` | percentiles of `prompt_tokens - cached_tokens` | `test_recomputed_tokens_per_turn_are_prompt_minus_cache` |
| `cache_pct` | `100 x sum(cached_tokens) / sum(prompt_tokens)` | same test |
| `turns`, `interrupted`, `steady_turns`, `steady_start_s` | counts from 3.1 and 3.2 | steady-state tests |
| `errors` | `metrics.turn_errors` of the whole level | `test_level_fails_when_a_turn_errored` |
| `insufficient_sample` | `steady_turns < min_turns` | `test_level_without_enough_steady_state_does_not_pass` |

`percentile` is linear interpolation between closest ranks (`k = (n - 1) x p / 100`), the same as NumPy's default. With 326 steady turns the p95 sits between the 309th and 310th sorted values.

Note on `tps_p50`: it is the per-stream decode speed seen by one agent after its first token, including speculative decoding gains and any pauses the scheduler inserts. It is not the aggregate tok/s of the replica.

Note on `errors`: `turn_errors` counts every errored turn of the level, including the cold phase. One timeout during the cold queue fails the level. That is intended: §20 counts a stream cut or 5xx as an availability failure.

### 3.5 Pass rule

```python
passes = errors == 0 and not insufficient_sample and ttft_p95_s is not None and ttft_p95_s <= 5.0
         and tps_p50 is not None and tps_p50 >= 30.0
```

All comparisons are inclusive (`<=` and `>=`). Tests: `test_level_fails_when_a_turn_errored`, `test_level_fails_when_ttft_p95_exceeds_slo`, `test_level_without_enough_steady_state_does_not_pass`.

The printed verdict is `pass`, `short sample` (when `insufficient_sample`) or `fail`.

## 4. Sessions inside the SLO (`sessions_in_slo`)

```python
best = 0
for n in sorted(levels):
    if not levels[n]: break
    best = n
```

The largest N such that N and every smaller tested level pass. A level that passes after a failing one is ignored as noise. A `short sample` level counts as a failure here, so it also stops the count. Tests: `test_sessions_in_slo_stop_at_first_failing_level` (`{8: T, 16: T, 32: F, 48: T}` gives 16), `test_sessions_in_slo_zero_when_smallest_level_fails`.

Consequences:

- The count is a lower bound: the true limit lies between the last passing level and the next tested one (24 and 32 for DCP1).
- Testing only high levels can return 0 when the smallest one fails, even if a lower untested level would pass.

## 5. Quality gate inside the summary

- `needle_ok = all(passes_needle(n, ref) for n in [needle, *extras])` when `needle.json` exists, else `None`.
- `passes_needle`: fails if `attempted <= 0`; otherwise compares `errors = attempted - correct` with the reference by the one-sided Fisher test and passes when `p >= 0.05` (`NEEDLE_ALPHA`). Details and power: `quality-gate-statistics.md`.
- `sessions_per_usd_h = 0.0 if needle_ok is False else sessions / price`. An arm that fails the needle prints its sessions but scores zero per US$/h. Test: `test_engine_that_fails_needle_counts_zero_sessions_per_dollar`. The C16 file can fail an arm alone: `test_engine_fails_when_needle_at_16_concurrent_fails`.
- `needle_ok is None` (agents-only run): the table prints `gate not run here`, and the metric is computed as if it passed. Take the gate verdict from the first run of the same arm. Test: `test_agents_only_directory_is_summarized_with_gate_marked_as_not_run`.
- gsm8k is printed as a percentage and never gates. The manual rule is at least 94/96 (`docs/06` phase 1).

## 6. Output format

Two Markdown tables (see `examples/summarize-three-runs.md` for real output):

1. `| Engine | Needle | gsm8k | Sessions in SLO | Sessions per US$/h |`. Needle is the C8 accuracy plus `ok` or `FAIL` for the combined verdict of every needle file.
2. One row per level: `| Engine | Agents | Errors | Steady since (s) | Steady turns | TTFT p95 (s) | tok/s p50 per stream | Cache % | Recomputed p50 | Recomputed p90 | SLO |`.

Numbers use the English format (`1,279.0`). Reports and the journal written before 2026-11-12 use the Brazilian format (`1.279,0`) and Portuguese column names (`Sessões no SLO`, `passa`, `reprova`), as in `f3/resultados/vast-20261111/resumo.md`.

## 7. Known gaps in the logic

- The 5 s TTFT target applies to every steady cached turn; §20 scoped it to cached turns with up to 8K new tokens. Recomputed tokens per turn were 3,432 at p50 and 5,559 at p90 in the DCP1 24-agent level, so most turns are inside the §20 scope, but the tail is not filtered (`docs/README.md`, contradictions table).
- Steady state starts at the end of the slowest turn 0. One very slow agent shortens the measured window for all.
- The two-run rule and pooling across runs are manual.
- There is no confidence interval on `ttft_p95_s`. With 159 to 326 steady turns per level, the p95 rests on the top 8 to 16 turns; margins of 0.07 s (DCP1 at 24) or 0.23 s (DCP4 at 16) are inside run-to-run noise (DCP4 at 16 moved from 4.77 s to 5.20 s between runs, Observed).
