# The §29.8 LMCache experiment and the corrected test

Our only real-model run of the LMCache RAM tier: design, configuration, numbers, logs, why both arms collapsed, and the corrected test with exact commands.

Read this before running any LMCache test, before quoting a number from §29.8, or when someone proposes the RAM tier as a way to serve more concurrent sessions.

Source: `ARQUITETURA.md` §29.8 and §29.9, `docs/04-kv-cache-routing-and-disaggregation.md` §3, and the raw files in the results archive: `f3/resultados/vast-20261111/vllm/vast-vllm-lmcache/` (LMCache arm) and `.../vast-vllm-lmcache-controle/` (control arm; `controle` is Portuguese for control). The files use the names of that time: `agentes-48.json`, `servidor.log`, `servidor.sh`, `tempo-pronto.txt`, `avisos.txt`. All numbers are Observed in those files unless labelled otherwise. One run per arm.

## Design as run

| Item | Value | Where it is recorded |
|---|---|---|
| Host | Vast.ai host 157204, 4 RTX PRO 6000 Server Edition, US$ 5.61/h | §29 |
| Image | `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` (vLLM `0.1.dev21830+g8244d1c44`, LMCache `v0.5.3.dev453+lil.cu134.g8ef537d6481b`) | `servidor.log` banners |
| Server script | `servidor.sh` = today's `bench/server-vllm-lmcache-direct.sh` with `DCP=4` hard-coded | `servidor.sh` in each arm |
| Launch | `python3 -m runtime.launcher --profile glm53-flash --hardware rtx-pro-6000-pcie --env DCP=4 --env CACHE_MODE=<lmcache or vram> --env NCCL_NET_PLUGIN=none [--env LMCACHE_L1_GB=200 --env LMCACHE_L2_ENABLED=0] --kv-cache-memory-bytes 5368709120` | `servidor.sh` |
| KV pool | 5 GiB per GPU: 2,589,816 tokens (LMCache arm), 2,519,262 tokens (control) | `GPU KV cache size` in each `servidor.log` |
| L1 | 200 GB in `/dev/shm`; allocator reported `Total free size: 204800.000000 MB` at start | LMCache arm log |
| Agents | 48, `agents_duration` 1,500 s, `agent_start` 40,960 to 102,400, `agent_think` 20 to 60 s, `request_timeout` 600 s | `agentes-48.json` `metadata.settings` |
| Server ready | 351 s (LMCache arm), 290 s (control) | `tempo-pronto.txt` |
| Order | control first (log from 01:26), LMCache second (log from 01:46) | timestamps in `servidor.log` |

Uncontrolled difference between the arms (Observed, found on 2026-11-12): the LMCache arm ran with split cache pages of 1,024 tokens (`Using split GLM-5.3 cache pages: target block size 1024 tokens`), the control with 2,048. The image launcher picks it; why it changes with `CACHE_MODE` is Unknown. A corrected test must record it for both arms.

## Results

| | HBM only (control) | LMCache |
|---|---|---|
| Duration | 1,076 s, interrupted by us | 1,520 s (`elapsed_s` 1530.0) |
| Turns completed / timed out | 42 / 24 (from the bench log) | 118 / 21 (`turns_ok`, `timeouts`) |
| Prefix cache share of later turns | 0% | 65.6% (`cached_tokens` over `prompt_tokens` of turns after the first) |
| TTFT of completed turns | minutes | p50 379.9 s, p90 489.6 s, p99 578.3 s (all turns); §29.8 gives 391 s / 502 s for cached turns |
| Requests running on the server | about 2 | about 4 (2 to 8 in the bench log) |
| Requests waiting | 44 to 45 | 32 to 44 |

Control arm, last lines of `agentes-48.log` (exact):

```
  agents:  1060s in flight 45, done 42, errors 24 | running 1 waiting 44 | KV 9%
| gen 99 tok/s
  agents:  1076s in flight 47, done 42, errors 24 | running 2 waiting 45 | KV 
14% | gen 73 tok/s

Interrupted; saving the scenarios finished so far.
```

The control `agentes-48.json` has no scenario: the bench writes only finished scenarios (§29.9 item 3). Its numbers come from the log.

LMCache arm, end of `agentes-48.log` (exact):

```
  agents: FAIL turns_ok 118, decode_tok_s 165, turn_ttft_p50_s 379.89, 
turn_ttft_p99_s 578.33, max_context 113,950, failed: every turn succeeded (21 
failed turns)
```

## What the LMCache log shows

Counts of the checkpoint scheduler lines in the LMCache arm's `servidor.log` (Observed, extraction in `../examples/lmcache-log-lines.md`):

| Line | Count |
|---|---|
| `Recurrent checkpoint restore of N tokens ... is waiting for GPU capacity` | 90 |
| `... has waited X s for GPU capacity` (repeated every 30 s or so while waiting) | 74 |
| `... starts after waiting X s for capacity` | 62 |
| `Recurrent checkpoint of N tokens selected ... is no longer cached; looking up its prefix again` | 4 |
| `Recurrent checkpoint restore of N tokens failed ... after 2.0 s; recomputing its prompt` | 1 |

Waits before a restore started ranged from 31 s to 212 s; the longest "has waited" line is 185 s. §29.8 states that 9 restores gave up after 133 to 185 s and recomputed. We could not find a log line that says a restore gave up; the "has waited" values 134, 159, 164, 166 and 185 s are the closest match. Treat "9 gave up" as the journal's reading, not a count we can reproduce from the log (found on 2026-11-12).

`vLLM` engine stats (`Engine 000:` lines every 10 s) report `External prefix cache hit rate`, which rose from 0.0% to 56.8% at the end, while `Prefix cache hit rate` (HBM) stayed at 0.0%.

## Why both arms collapsed

What §29.8 says: the design counted on think time to keep about 23 agents active; with turns queued for minutes, queue time became activity, all 48 sessions competed for HBM, and both arms collapsed. The run measures overload, not the TTFT of a restore.

What the files add (Inferred from Observed numbers, 2026-11-12):

1. The level never left its cold phase. The 48 first turns carried 3,468,499 cold prompt tokens. The engine stats show `Avg prompt throughput` between about 5k and 12k tok/s in 10 s windows while prompts were being prefilled, against 10.3k tok/s cold and 4.1k tok/s under decode on R1, so the cold phase alone needs about 5 to 14 min. Agents start 2 s apart, so the 48th first turn waits behind about 47 cold prefills.
2. The client timeout is 600 s (`request_timeout` in the JSON). 20 of the 48 first turns timed out in the LMCache arm (24 errors in the control). An agent that times out sleeps 5 s and sends the same prompt again, still cold, so the queue never drains.
3. HBM was not the first limit. The control arm ran with 1 or 2 requests and 9% to 14% KV usage while 44 waited; the queue was the single prefill lane (`--max-parallel-prefills 1`) working through cold prompts. Restores in the LMCache arm then waited for GPU capacity with hundreds of free blocks (`489 free blocks; the checkpoint needs 20 plus execution headroom`), so what they waited for is the "execution headroom" term, whose definition we have not read (Unknown).
4. The last successful first turn of the LMCache arm ended at 669 s. Only after that do turns with think time exist, and the level ended at 1,500 s.

So the run tested the cold first-turn queue under a 600 s timeout more than the RAM tier. The one thing it does show about LMCache: 62 restores happened, cached share reached 65.6% against 0%, and restored KV must return to HBM before the request runs.

## The corrected test

Goal (§29.8, §29.9 item 2, `docs/06-aws-implementation-plan.md` phase 4): TTFT of a turn whose KV was evicted from HBM and comes back from L1, without a queue, LMCache against HBM only, DCP1.

Conditions it must meet:

1. Steady state with idle sessions. Active sessions fit in HBM; idle ones do not and get evicted. With DCP1 and `KV_CACHE_BYTES=30064771072` (28 GiB per GPU, about 3.5 million tokens per the comment in `bench/vast/vast.sh`), 48 agents of 60K to 120K tokens hold about 4 to 6 million tokens in total, more than the pool, while about 24 or fewer are active at once (Inferred).
2. No cold-phase timeouts. The cold phase for 48 agents is about 48 x 25 s = 20 min at the rate measured on Vast (comment in `bench/run_benchmark.sh`). `run_benchmark.sh` does not pass `--sched-request-timeout`, so the bench default of 600 s applies and the late first turns time out exactly as in §29.8. Either run the bench directly with a longer timeout (below) or accept that `summarize.py` drops those agents.
3. Long think time. `AGENT_THINK=60-100` (the arms' default) keeps most sessions idle.
4. Same server profile in both arms, including the split page size. Write both arms' `GPU KV cache size` and `split GLM-5.3 cache pages` lines into the report.
5. Never interrupt a level.

### On Vast.ai (renting costs money; get approval first)

```bash
cd bench/vast
bash vast.sh create vllm <offer_id>
bash vast.sh wait vllm && bash vast.sh send vllm && bash vast.sh prepare vllm
AGENT_LEVELS="48:2700" bash vast.sh run vllm lmcache-dcp1
# after it finishes, on the same instance
AGENT_LEVELS="48:2700" bash vast.sh run vllm lmcache-dcp1-control
bash vast.sh status vllm
bash vast.sh fetch vllm && bash vast.sh destroy vllm
```

2,700 s is our choice (Inferred: 20 min of cold phase plus about 25 min of steady state); the sources fix no duration. Use the same value in both arms. These commands keep the 600 s timeout.

### On AWS or any host, inside the fork container, with a longer timeout

`run_benchmark.sh` with `AGENTS_ONLY=1` starts the server, then runs one bench command per level. To change the timeout, start the server with the same script and run the bench line yourself, adding `--sched-request-timeout`:

```bash
cd bench
PIDFILE=srv.pid LOGFILE=results/lmcache-dcp1/server.log CACHE_MODE=lmcache DCP=1 LMCACHE_L1_GB=200 \
  KV_CACHE_BYTES=30064771072 bash server-vllm-lmcache-direct.sh
# wait until curl -s localhost:8000/v1/models answers, then:
$PY $BENCH --port 8000 --scheduler agents --sched-agents 48 --sched-agents-duration 2700 \
  --sched-agent-start 40k-100k --sched-agent-tool 1k-6k --sched-agent-response 300-4000 \
  --sched-agent-think 60-100 --sched-seed 48 --sched-request-timeout 1800 \
  --output results/lmcache-dcp1/agents-48.json > results/lmcache-dcp1/agents-48.log 2>&1
kill "$(cat srv.pid)"          # what run_benchmark.sh stop_server does; the script comment says the PID stops vLLM and LMCache together
# control: same three steps with CACHE_MODE=vram and results/lmcache-dcp1-control/
```

The bench flags are the ones `run_benchmark.sh` passes (lines for level runs), plus `--sched-request-timeout` (bench default 600). `$PY` and `$BENCH` as in `bench/README.md`. Run the quality gate once on the same server profile first (`GATE_ONLY=1`). Check with `pgrep -af lmcache` after the kill that no LMCache process is left; the script relies on `setsid` for that and we never verified it.

### Acceptance (phase 4) and what to report

1. Both arms write `agents-48.json`.
2. Per arm: HBM prefix hit and external (LMCache) hit from the `Engine 000:` lines, TTFT p95 of cached steady-state turns from `summarize.py`, counts of `waiting for GPU capacity`, `starts after waiting` and `recomputing its prompt` lines.
3. Read `Running:` and `Waiting:` from the engine stats during steady state. If more than about 24 requests ran at once, or `Waiting:` stayed above a few, the test repeated the overload and its TTFT is not used.
4. Decision rule: keep the LMCache tier if its arm has a lower TTFT p95 than HBM only, with no more turn errors.

Extra numbers worth taking from the same run: restore time per turn (time between `starts after waiting` and the first token of that request, joined on the request ID), and L1 usage (`df -h /dev/shm`) at the end.
