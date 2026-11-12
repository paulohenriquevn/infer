# Vast.ai workflow: `bench/vast/vast.sh` end to end

Read this before renting a Vast.ai machine for a measurement. Everything here costs money: get Paulo's approval before `create`, and check that no instance is left at the end. Code facts are Observed in `bench/vast/vast.sh` and `bench/vast/prepare_host.sh`; host facts are Observed in `f3/resultados/vast-20261111/` and `f3/resultados/vast-20261112/` and in `ARQUITETURA.md §28` and `§29`.

## 1. How Vast differs from a VM

- A Vast instance is a container of the image you choose. There is no Docker inside and no access to the host driver or kernel modules (§28.1). So the server runs directly (`LAUNCH_MODE=direct`), the driver is whatever the host has, and the P2P override cannot be set.
- One instance per engine. To compare two engines on the same 4 GPUs, stop (not destroy) the first instance and create the second on the same `machine_id` (`create sglang same-machine`). Only do this when the machine's free disk holds both images and checkpoints; otherwise destroy the first.
- Offers disappear within minutes; the first offer chosen in §28.3 was rented by someone else during account setup.
- Hosts with the same listing can differ by 5 times in decode (section 6).

## 2. Prerequisites on your machine

- `vastai` CLI logged in; an SSH key registered on Vast (`SSH_KEY`, default `~/.ssh/id_ed25519`).
- `bench/setup_bench.sh` already run (`send` refuses without `$BENCH_DIR/llm_decode_bench.py`).
- For the `nvfp4*` SGLang arms only: `ORMANDJ_V050_DIR` pointing to a directory with `glm53-adaptive.json` from the ormandj/sglang-glm53-flash-sm120 v0.5.0 release (not shipped; licence not checked).

| Variable | Default | Used by |
|---|---|---|
| `SSH_KEY` | `$HOME/.ssh/id_ed25519` | every SSH and rsync |
| `BENCH_DIR` | `bench/llm-inference-bench` | `send` |
| `RESULTS_DIR` | `results/` at the repository root | `fetch` |
| `RUN_SUFFIX` | empty | `run`: output directory `results/vast-<engine>-<arm>-<suffix>` |
| `DISK_GB` | 260 (vllm), 420 (sglang) | `create` (`DISK_GB=60` to validate without a checkpoint) |
| `SGLANG_IMAGE` | `ghcr.io/ormandj/sglang-glm53-flash-sm120:v0.6.1` | image for `sglang` |
| `CHECKPOINT` | `fp8` | `prepare` on SGLang: `fp8`, `nvfp4`, `nvfp4-1d00738` |
| `SKIP_CHECKPOINT` | `0` | `prepare`: `1` checks only that the engine binary exists |
| `ORMANDJ_V050_DIR` | unset | `send` |
| `AGENT_LEVELS`, `AGENTS_ONLY`, `NEEDLE_RUNS`, `STOP_ON_GATE_FAIL` | `8:600 16:900 32:1500`, `0`, `500`, `1` | forwarded by `run` |
| `AGENT_THINK`, `KV_CACHE_BYTES` | per arm | LMCache arms |

The vLLM image is fixed in the script: `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016`. State lives in `bench/vast/state/` (`<engine>.id`, `machine.id`, `<engine>.create.json`).

## 3. Choosing an offer

`vast.sh` does not choose an offer. You pick an offer ID by hand, and `create` checks it against the list of 4-GPU RTX PRO 6000 offers.

Criteria used so far (§28.3, §29.9):

- 4x RTX PRO 6000; Server Edition preferred (`gpu_name=RTX_PRO_6000_S`; `_WS` is the Workstation card, a different power envelope);
- disk of at least 800 GB if both engines must fit; 260 GB is enough for vLLM alone (image plus 178 GB checkpoint plus JIT caches);
- RAM of at least 400 GB (SGLang HiCache used 160 GB; LMCache L1 used 200 GB);
- reliability of at least 0.95;
- price up to US$ 7/h;
- record the machine ID and price with the date in the results, since a different machine changes the numbers.

What the criteria do not catch: host 48294 met all of them (datacenter, reliability 0.965, US$ 7.03/h) and was 5 times slower. Qualification after `prepare` is the real filter (section 6).

To look at offers without renting, the public search API answers without login (Observed on 2026-11-12 12:18 UTC):

```bash
q='{"gpu_name":{"in":["RTX PRO 6000 S","RTX PRO 6000 WS"]},"num_gpus":{"eq":4},"rentable":{"eq":true},"type":"on-demand"}'
curl -s -G 'https://console.vast.ai/api/v0/bundles/' --data-urlencode "q=$q" | \
  python3 -c "import json,sys;[print(o['id'],o['machine_id'],o['gpu_name'],round(o['dph_total'],2),o['reliability2'],o['driver_version'],o['geolocation']) for o in json.load(sys.stdin)['offers']]"
```

That read returned 10 offers of 4 GPUs from US$ 3.20/h (Workstation, reliability 0.69) to US$ 14.67/h; Server Edition offers with reliability above 0.95 started at US$ 5.33/h (Florida, driver 580.178.04) (Reported by the Vast API). Note the driver column: the image expects 615.65.02 or newer (§25.1), and only some hosts run a 6xx driver.

## 4. Commands, step by step

All from `bench/vast/` on your machine.

### `create <engine> <offer_id|same-machine>`

1. With `same-machine`, reads `state/machine.id` and searches `machine_id=<id> num_gpus=4 rentable=true`; stops if the machine has no 4 free GPUs.
2. Lists `RTX_PRO_6000_S` and `RTX_PRO_6000_WS` 4-GPU offers and finds the ID locally, because the CLI does not filter by `id=` (§28.2). Prints `offer <id>: 4x <gpu> US$ <price>/h, machine <m>, free disk <GB> GB` and saves `machine.id`.
3. `vastai create instance <offer> --image <image> --disk <GB> --ssh --direct --label infer-<engine> --raw`, asserts `success`, stores `new_contract` in `state/<engine>.id`.

Billing starts here.

### `wait <engine>`

Polls `vastai show instance` every 30 s for up to 120 tries (60 min), printing `actual_status` and `status_msg`. Done when the status starts with `running` and `ssh true` works. `status_msg` is null while the image downloads; the script tolerates it (§28.2). This is the only command that retries SSH.

### `send <engine>`

`rsync -az --delete` of `bench/` (without `.git`, `results`, `state`, `__pycache__`, `llm-inference-bench`) to `/workspace/infer/bench/`, and of `BENCH_DIR` to `/workspace/infer/llm-inference-bench/`; optionally the ormandj file. Ends by checking `return_token_ids` in the remote bench (`bench with patch: ok`).

### `prepare <engine>`

Runs `prepare_host.sh` in the background (`setsid -f nohup`, log `/workspace/infer/logs/prepare-<engine>.log`). Inside the instance, idempotent:

1. Host record to `/workspace/infer/host-<engine>/host.txt`: `nvidia-smi`, `topo -m`, `topo -p2p r`, `RegistryDwords`, `nproc`, `free -g`, `df -h /`.
2. Bench venv at `/workspace/infer/bench-venv` with `--system-site-packages` (so the P2P test uses the image's torch without touching the engine's Python), `httpx`, `rich`, and `huggingface_hub[hf_xet]>=0.34` with `--ignore-installed` (the image already ships `huggingface_hub`, and without the flag pip did not create the `hf` executable, §28.2).
3. Checkpoint: vLLM downloads `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at `dec48abd33efa73c3bb7c95b74eee10cad34f9be` into the HF cache; SGLang downloads by `CHECKPOINT` into `/workspace/infer/models/<dir>`.
4. All-reduce microbenchmark across the 4 GPUs: `llm_decode_bench.py --p2pmark-only --p2pmark-max-gpus 4 --p2pmark-mode allreduce` into `p2pmark-4gpu.txt`.

Last line of the log: `PREPARE OK: <engine>`. Download speed on host 157204 was 10.5 Gbit/s; the 178 GB checkpoint took about 2.5 min (§28.2).

### `run <engine> <arm>`

Starts `run_benchmark.sh` in the background with `LAUNCH_MODE=direct`, the venv Python, the remote bench, the image, `OUT=results/vast-<engine>-<arm>[-<RUN_SUFFIX>]`, and the forwarded variables. Log: `/workspace/infer/logs/run-<arm>.log`.

| Arm | Server script and overrides |
|---|---|
| `vllm/r1` | `server-vllm-direct.sh` (DCP4) |
| `vllm/dcp1`, `vllm/dcp1-rep` | `server-vllm-dcp1-direct.sh` |
| `vllm/r1-rep` | DCP4, `AGENTS_ONLY=1` |
| `vllm/lmcache`, `vllm/lmcache-control` | `server-vllm-lmcache-direct.sh`, DCP4, `AGENTS_ONLY=1`, `AGENT_THINK=20-60`, `CACHE_MODE=lmcache` or `vram` |
| `vllm/lmcache-dcp1`, `vllm/lmcache-dcp1-control` | same launcher, `DCP=1`, `KV_CACHE_BYTES=30064771072` (28 GiB, about 3.5M tokens), `AGENT_THINK=60-100` |
| `sglang/ormandj` | `server-sglang.sh`, FP8 |
| `sglang/nvfp4`, `nvfp4-1d00738` | `server-sglang-nvfp4.sh`, checkpoint `09b04e5e` or `1d00738` |
| `sglang/nvfp4-marlin` | `MOE_RUNNER_BACKEND=marlin MAX_TOTAL_TOKENS=2097152` |
| `sglang/nvfp4-marlin-clean`, `nvfp4-fp32ssm`, `nvfp4-nospec` | `GATE_ONLY=1` diagnostics |

Arms renamed in the translation: `lmcache-controle`, `lmcache-dcp1-controle`, `nvfp4-marlin-limpo`, `nvfp4-semspec`; archive directories keep the old names.

Second run of the same arm: `RUN_SUFFIX=2 AGENTS_ONLY=1 AGENT_LEVELS="16:900 24:1200" bash vast.sh run vllm dcp1-rep`. Without `RUN_SUFFIX` the second run overwrites the first directory.

### `status <engine>`

Prints status, US$/h and disk usage from the API, the last 5 lines of every remote log, the remote `bench/results` listing and GPU utilisation and memory. Use it to watch a run; it does not retry SSH.

### `fetch <engine>`

`rsync` of the remote `bench/results/`, `host-<engine>` and `logs` to `$RESULTS_DIR/vast-<YYYYmmdd>/<engine>/`. The date is your local date at fetch time, not the run date: a run that started on 2026-11-11 and was fetched after midnight lands in `vast-20261112/`.

### `stop <engine>` and `destroy <engine>`

`stop` keeps the disk (storage is still billed). `destroy` runs `vastai destroy instance -y <id>` and forgets the ID only if the output has a line starting with `destroying instance`, because `vastai destroy` without `-y` asks for confirmation and an `Aborted.` answer also exits 0 (§28.2). Always `fetch` before `destroy`.

## 5. Cost control

- Know the price before `create` (`create` prints it). Battery costs so far: the validation of §28.2 took 23 min, about US$ 2; the full engine comparison of §29 on host 157204 cost about US$ 16 (§29).
- Size the run before starting it. One vLLM arm with gate, speed and levels `16:900 24:1200`: server start about 4 to 9 min (201 s warm, 511 s cold JIT cache on host 157204), gate about 2 min with 500 needle runs (Inferred from section 4.3 of `quality-gate-statistics.md`), speed about 4 min, agents about 35 min. About 50 min, or about US$ 5 at US$ 5.61/h (Inferred).
- Destroy as soon as `fetch` is done; check `vastai show instances` shows nothing. §29.9 and §29.10 each end with "no active instance" and the remaining credit.
- Wait loops: never use `pgrep -f <name>` inside an `ssh` whose own command line contains `<name>`; it matches itself. That bug kept an 8-GPU Nebius VM on for 6 h 8 min with no result, about US$ 88 (§25.3). Never write `a && b || c` as an if-else: `c` runs when `b` fails, not only when `a` fails (§25.3).
- Prepaid credit and reserved instances are locked to one host (Reported by Vast support, 2026-11-12). Never reserve a host that has not passed qualification.

## 6. Qualify the host before measuring

Right after `prepare`, before `run`:

1. Read `host-<engine>/host.txt`: driver version, `topo -p2p r` all `OK`, GPU0 NUMA placement.
2. Read `p2pmark-4gpu.txt`: small all-reduce sizes (256 B to 2 KiB) should be near 9 us with the custom PCIe path.
3. After the server is up, run C32 decode for 30 s and discard the host below 1,400 tok/s with the DCP1 profile (field `results[].aggregate_tps` of the decode JSON):

```bash
python3 /workspace/infer/llm-inference-bench/llm_decode_bench.py --port 8000 --concurrency 32 --contexts 0 \
  --duration 30 --max-tokens 8192 --skip-prefill --output /workspace/infer/qual-c32.json
python3 -c "import json;print([round(r['aggregate_tps']) for r in json.load(open('/workspace/infer/qual-c32.json'))['results']])"
```

### Lessons of host 157204 (Nevada, the good host)

Observed, §28.2 and the files under `f3/resultados/vast-20261111/vllm/`:

- Offer 60186106, machine 157204, 4x RTX PRO 6000 Blackwell Server Edition, US$ 5.61/h (read 2026-11-11), driver 615.71.09, power limit 600 W.
- P2P enabled between all 4 GPUs without the driver override (`nvidia_p2p_override.effective` false in every result file).
- Asymmetric topology: GPU0 on NUMA node 0, GPUs 1 to 3 on node 1; all GPU0 traffic crosses sockets (`SYS` in `topo -m`).
- Small all-reduce 8.4 to 9.3 us with the custom PCIe path (256 B to 2 KiB, `p2pmark-4gpu.txt`), against 32.1 to 57.4 us on Nebius R1 where the override was not in effect. C1 decode was 22% higher than on R1 (causal link Inferred, §29.2).
- Server ready in 201 s (DCP4, warm cache) and 260 s (DCP1); 511 s with a cold kernel cache.
- C32 decode 1,580 tok/s (DCP1), 1,279 and 1,288 (DCP4, two runs).

### Lessons of host 48294 (Texas, the failed host)

Observed, §29.10 and `f3/resultados/vast-20261112/vllm/`:

- Datacenter host, reliability 0.965, US$ 7.03/h (read 2026-11-12), same "4x RTX PRO 6000 Server Edition" listing, same image, checkpoint, profile and harness.
- Driver 580.95.05, older than the 615.65.02 the image expects. Nebius R1 ran 580.173 and reached 1,425 tok/s at C32, so the driver alone does not explain the loss (Inferred, §29.10).
- The p2pmark already looked worse before any server started: custom all-reduce 13.8 to 21.7 us at 256 B to 2 KiB, against 8.4 to 9.3 us on 157204, and NCCL won at 2 KiB (`host-vllm/p2pmark-4gpu.txt`). Inferred: a p2pmark clearly slower than 157204 is an early warning worth checking before paying for the checkpoint and server start.
- Server ready in 1,084 s, against 260 s.
- Decode 108 / 299 / 351 / 298 tok/s at C1 / C8 / C16 / C32 (`decode.json`). Cold prefill 869 tok/s at 8K against 8,490 on 157204, ten times slower.
- At 16 agents the server never ran more than 6 requests at once, with up to 15 waiting and at most 11.1% of KV used (`scheduler.scenarios[0].server` of `vast-vllm-dcp1-rep/agentes-16.json`; §29.10 describes the same state as 2 or 3 running and 21 queued, read from the progress log). 11 turns failed with `ReadTimeout` and `summarize.py` returns `short sample` with 11 errors (only 5 of 16 agents finished turn 0). The 24-agent level was interrupted and left only a log (`agents 809s in flight 24, done 12, errors 18 | running 2 waiting 22 | KV 2%`).
- During the agents, GPUs drew about 116 W each at PCIe Gen 5 x16 with SM clocks around 2,350 MHz (`host-diagnostico.txt`): idle GPUs. Host CPU: 2x Xeon 6767P, 256 threads, 4 NUMA nodes, load average 8.5 to 12.4.
- Quality was normal: needle 500/500 and 120/120, gsm8k 96/96. Quality numbers from a slow host are valid; speed numbers are not.
- Cause Unknown. Hypothesis: something outside the GPUs (another tenant on the 8-GPU host, CPU or memory). What would discriminate: `nvidia-smi dmon` during decode, CPU steal and memory bandwidth on the host, and the same p2pmark on another machine with driver 580.

The worked qualification failure is in `examples/host-48294-qualification-failure.md`.

## 7. Troubleshooting

| Symptom | Cause seen | Action |
|---|---|---|
| `offer <id> is no longer available` | rented by someone else | pick another offer |
| `wait` prints `None` status for minutes | image still downloading | keep waiting; 60 min cap |
| SSH drops during `status` or `send` | Vast SSH proxies drop often; `rssh` does not retry | rerun the command; long work runs under `setsid -f` and survives |
| a remote command holds the SSH session | old `setsid nohup ... &` form | the script uses `setsid -f` since §29.3 |
| `hf: command not found` in the venv | pip skipped the console script | `prepare_host.sh` installs with `--ignore-installed` |
| `run_benchmark.sh` exit 5 | needle failed the Fisher test | read `needle.log`; set `STOP_ON_GATE_FAIL=0` only for a diagnostic run |
| an agent level missing from `results` | level interrupted; the bench writes only finished scenarios | let it finish, size `AGENT_LEVELS` so it does; the log keeps the progress lines |
| `destruction not confirmed` | CLI did not print `destroying instance` | check `vastai show instances` and destroy by hand |
