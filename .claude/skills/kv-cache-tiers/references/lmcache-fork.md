# The fork's LMCache: launcher, server, connector, configuration

How LMCache runs inside the fork image we use, which settings we can see and which we cannot, how it differs from upstream LMCache docs and from the older community script, and what that means for TTLs, lazy L1, failure policy and events. Read this before changing `CACHE_MODE=lmcache` settings, before quoting an LMCache doc as if it described our image, and when a log line needs explaining.

Sources: the LMCache arm `servidor.log` of the §29.8 run (`f3/resultados/vast-20261111/vllm/vast-vllm-lmcache/`, Observed), `bench/server-vllm-lmcache-direct.sh`, the community script `f3/rtx6kpro/models/glm-5.3-flash/build/serve-glm53-flash-lmcache.sh` (rtx6kpro snapshot at commit `082ab180`, 2026-11-05), the project research notes (not published), and the upstream docs and PRs read on 2026-11-12 (Reported, URL given). Upstream LMCache doc pages show no version number, so treat every doc default as "current upstream", not as our build.

## Versions

| Component | Version | Label |
|---|---|---|
| Image | `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` | Observed |
| LMCache in the image | `v0.5.3.dev453+lil.cu134.g8ef537d6481b`, dated 2026-10-11 | Observed in the server banner; date from extraction, §25.1 |
| Upstream releases around it | v0.5.6 released 2026-10-14; v0.5.7rc4 2026-11-03 | Reported, project research notes |

The image's LMCache has its own history. Of the upstream PRs checked, only #4679 (MP mode DCP compatibility, merged 2026-08-26) is an ancestor; #4834, #4936, #5042, #5076 and #5307 are not (Observed by extraction, §25.1). So a feature that upstream release notes list for v0.5.6 may be missing or implemented differently in our build. Things v0.5.6 lists that matter to us (Reported, `https://github.com/LMCache/LMCache/releases/tag/v0.5.6` via the project research notes): `--session-ttl-seconds` (#5457), GLM-5.3-Flash support (#5042), "Don't store MTP's speculative scratch block as a Mamba state" (#5004), no engine crash on a failed multi-group load (#5469), KV events from the MP connector (#5076, #5307), removal of `pickle` from IPC descriptors (#5644), and `/run_script` disabled by default (#5129). Our server log lists a `run_script_api` HTTP module at start (Observed); the HTTP server binds to 127.0.0.1 only (Observed), so keep it that way.

## How it starts

Our script (`bench/server-vllm-lmcache-direct.sh`) runs the image launcher:

```bash
cd /opt/lil
python3 -m runtime.launcher --profile glm53-flash --hardware rtx-pro-6000-pcie \
  --env DCP=<1|4> --env CACHE_MODE=lmcache --env NCCL_NET_PLUGIN=none \
  --env LMCACHE_L1_GB=<GB> --env LMCACHE_L2_ENABLED=0 --kv-cache-memory-bytes <bytes>
```

The launcher starts the LMCache MP server first, then vLLM, and supervises both. It refuses `--print-command` in this mode because there are two processes (Observed, §29.8). Killing the launcher PID stops both, according to the script comment; we never verified that no LMCache process survives (`pgrep -af lmcache` after the stop).

What the launcher chose in our run, read from the logs (Observed):

| Setting | Value | Log evidence |
|---|---|---|
| Server process device | CPU only | `torch_dev=StubCPUDevice`, `accelerator available: False` |
| Transfer mode | `engine_driven` | `Supported transfer mode: engine_driven`; connector extra config `lmcache.mp.mp_transfer_mode: engine_driven` |
| Ports | ZMQ 18000, HTTP 18001, for vLLM on 8000 | `tcp://127.0.0.1:18000`, `http://127.0.0.1:18001` |
| Instance name | `glm53-flash-8000` | OTel `service.instance.id` |
| Chunk size | 4096 tokens (DCP4) | `TokenHasher initialized: chunk_size=4096, hash_algorithm=blake3` |
| L1 | 200 GB in shared memory, pinned | `Total free size: 204800.000000 MB`; `SHM pinned=True for shm_name=lmcache_l1_pool_lmcache-glm53-flash-8000-18000` |
| Transfer path | workers `ptr`, server `tensor` | `multi_layer_block_kv_transfer mode: ptr` / `tensor` |
| Connector | `LMCacheRecurrentCheckpointConnector`, module `lmcache.integration.vllm.recurrent_checkpoint_connector`, `kv_role='kv_both'`, `kv_buffer_size=1e9` | `non-default args` |
| Cache identity | `lmcache.mp.checkpoint_identity` with target, draft and source revision hashes | `non-default args` |
| Load failure policy | `kv_load_failure_policy='recompute'` | `non-default args` |
| vLLM split pages | 1,024 tokens (2,048 without LMCache) | `Using split GLM-5.3 cache pages` |
| Recurrent policy | `request_boundaries` | `Request-boundary recurrent checkpoint caching is enabled` |
| Background threads | session cleanup every 60 s; worker reaper every 30 s | `SessionManager-cleanup-thread ... interval=60.0s`, `lmcache-mp-worker-reaper ... interval=30.0s` |
| Metrics | no LMCache metrics port | `standalone metrics HTTP server disabled; /metrics must be exposed by the caller` |

Exact lines are in `../examples/lmcache-log-lines.md`.

Not visible in the log, so Unknown for our image: eviction policy, `--l1-use-lazy` and `--l1-init-size-gb`, `--l1-read-ttl-seconds`, `--l1-write-ttl-seconds`, session TTL, `--separate-object-groups`, `--max-workers`. To read them, list the LMCache server's command line on a running container (`ps -o args= -p "$(pgrep -f 'lmcache server' | head -1)"`), or query the HTTP `config_api` module on port 18001 (the module is listed at start; its route is Unknown).

## The older community script, for comparison

The KV report and §17.5 read `serve-glm53-flash-lmcache.sh` from the rtx6kpro wiki (a jovian-judgement era image, lock `r27`). Its MP server command (exact, trimmed):

```bash
lmcache_server=(
  /opt/venv/bin/lmcache server
  --instance-id "${LMCACHE_INSTANCE_ID:-glm53-jovian-judgement-lmcache}"
  ...
  --chunk-size "${chunk_size}"                 # LMCACHE_CHUNK_SIZE, default 4096
  ...
  --hash-algorithm blake3
  --supported-transfer-mode "${transfer_mode}" # LMCACHE_TRANSFER_MODE, default lmcache_driven
  --separate-object-groups
  --l1-size-gb "${LMCACHE_L1_SIZE_GB:-64}"
  --l1-use-lazy
  --l1-init-size-gb "${LMCACHE_L1_INIT_SIZE_GB:-2}"
  --eviction-policy LRU
  ...
)
```

Other parts of that script: it refuses to start unless `/dev/shm` is at least `LMCACHE_MIN_SHM_GIB` (default 96) GiB; L2 is on by default (`LMCACHE_L2_ENABLED:-1`) with an `fs_native` adapter at `/lmcache-l2`, 512 GB, LRU at watermark 0.8; the connector is `LMCacheMPConnector`; it passes `--prefix-cache-retention-interval "${chunk_size}"` to vLLM; it sets no TTL and no `kv_load_failure_policy`.

Differences from what our image did (Observed in our log against the script text):

| Item | Community script | Our image launcher |
|---|---|---|
| Transfer mode | `lmcache_driven` by default | `engine_driven` |
| Connector | `LMCacheMPConnector` | `LMCacheRecurrentCheckpointConnector` |
| `kv_load_failure_policy` | not set (vLLM default `fail`) | `recompute` |
| Ports | MP 5555, HTTP 8085, Prometheus 9095 | ZMQ 18000, HTTP 18001, no metrics port |
| L2 | on by default | we pass `LMCACHE_L2_ENABLED=0` |
| Env names | `LMCACHE_L1_SIZE_GB`, `LMCACHE_L1_INIT_SIZE_GB` | `LMCACHE_L1_GB` (our script) |

So the journal's advice "set `kv_load_failure_policy: recompute`, the default is `fail`" (§17.5) and "the fork runs lazy L1 with a 2 GB init" (KV report correction 16) describe the community script, not our image. The first is already satisfied in our image. The second is Unknown for our image.

## Upstream MP server configuration (Reported)

From `https://docs.lmcache.ai/mp/configuration.html` and `https://docs.lmcache.ai/cli/server.html`, read 2026-11-12, upstream current:

| Flag | Default | Note |
|---|---|---|
| `--chunk-size` | 256 | minimum; "the vLLM MP connector may raise it" |
| `--l1-size-gb` | none | required without `--l1-manager` |
| `--l1-init-size-gb` | 20 | initial allocation when lazy |
| `--l1-use-lazy` | True | lazy growth up to `--l1-size-gb` |
| `--l1-read-ttl-seconds` / `--l1-write-ttl-seconds` | 300 / 600 | per-object lock lifetimes |
| `--eviction-policy` | required | LRU, ARC, IsolatedLRU, noop; watermark 0.8, ratio 0.2 |
| `--hash-algorithm` | blake3 | |
| `--separate-object-groups` | False | "Required for Mamba / linear-attention hybrids" |
| `--kv-event-log-size` | 32768 | 0 disables the event stream |
| `--supported-transfer-mode` | `lmcache_driven` | the architecture page says `auto`; the two pages disagree |
| `--max-gpu-workers` | inherits `--max-workers` (1) | deployment guide: at least the number of vLLM instances |
| `--prometheus-port`, `--http-port` | 9090, 8080 | |
| `--p2p-advertise-url` | "" (off) | P2P "also requires `--coordinator-url`" |

`--session-ttl-seconds` is not on that page; it came with #5457 in v0.5.6 (Reported, project research notes). Its default of 600 appears only in the Kimi K3 recipe.

The deployment guide (`https://docs.lmcache.ai/mp/deployment.html`) runs one server per node shared by the vLLM pods and says to give L1 "as much CPU memory as available after accounting for the OS and vLLM". We keep one server per engine instead (decision 4 of the skill); our image starts one per vLLM instance anyway.

### TTLs under deep queues

The Kimi K3 recipe (TP8 + DCP8, 8 MI355X, agentic trace at c70) says: "Under deep queues a request can wait many minutes between its lookup and its retrieve. Raise `--l1-read-ttl-seconds` and `--session-ttl-seconds` above that delay (7200 here); with the defaults (300 / 600) the prefetch read locks expire before the retrieve, which fails with `KEY_NOT_READABLE` and is reported to vLLM as `invalid_block_ids`, fatal for a hybrid model with several KV cache groups" (Reported, `https://docs.lmcache.ai/recipes/kimi_k3.html`, quoted in the project research notes). The same recipe asks for `--l1-init-size-gb` equal to `--l1-size-gb`, because a large lazy L1 stalls mappings for minutes.

In §29.8 restores waited up to 212 s, under the 300 s default (Observed), and `KEY_NOT_READABLE` did not appear in the log (Observed: zero matches). The risk stays for longer queues. How to pass TTLs through the image launcher is Unknown.

### Liveness settings

Heartbeat every 10 s (`lmcache.mp.heartbeat_interval`), worker reaped after 120 s (`--worker-reap-timeout-seconds`), registration grace 3600 s (`--worker-registration-grace-seconds`) (Reported, project research notes). Our log shows the reaper thread running every 30 s (Observed); the timeout values in our build are Unknown.

## Upstream in-process (legacy) pages, digested

These pages carry the banner "documents the behavior of LMCache's in-process mode (deprecated)". Our image does not use that mode; the keys below do not apply to it. They matter only when reading older guides, including the llm-d tiered-cache guide (Reported, read 2026-11-12):

- Configuration reference (`https://docs.lmcache.ai/api_reference/configurations.html`): `chunk_size` 256, `local_cpu` true, `max_local_cpu_size` 5.0 GB, `local_disk`, `remote_url`, `enable_p2p` false (needs `enable_controller`), `enable_controller` false, `cache_policy` LRU, `save_decode_cache` false. P/D keys: `enable_pd`, `transfer_channel` (for example `"nixl"`), `pd_role`, `pd_buffer_size`, `pd_buffer_device`, `nixl_backends` `["UCX"]`. "environment variables are ignored when a configuration file is present".
- CPU offloading (`https://docs.lmcache.ai/kv_cache/storage_backends/cpu_ram.html`): `max_local_cpu_size` must be above 0; LRU; hugepages are incompatible with `enable_p2p` and `shm_name`; example warm TTFT about 6.5 s to about 0.15 s.
- P2P (`https://docs.lmcache.ai/kv_cache/p2p_sharing.html`): needs the controller (`lmcache_controller` with pull, reply and heartbeat ports) and `transfer_channel: "nixl"`; without RDMA set `UCX_TLS=tcp`. Example mean TTFT 2.286 s to 1.036 s on one host, hardware not stated.
- KV events (`https://docs.lmcache.ai/production/kv_cache_events.html`): needs vLLM 0.13.0 or later and LMCache 0.3.11 or later, `enable_kv_events: true`, and vLLM `--kv-events-config` with the zmq publisher. The page documents only `BlockStored` with `medium='CPU'`. With several workers a non-default `pre_caching_hash_algorithm` is needed or the same store produces duplicate events. See `kv-events.md`.
- Controller: in MP mode the equivalent is the coordinator (`--coordinator-url`, heartbeat interval 5), and the coordinator is required for P2P (Reported, `https://docs.lmcache.ai/cli/server.html`).

## Restore mechanics seen in our log

- 420 `Prefetch request completed (L1+L2)` lines: 20 to 37 keys each, all retained, all from L1 (0 from L2), 1.3 ms minimum, 4.5 ms median, 9.0 ms p90, 415.8 ms maximum (Observed). The prefetch from host memory is fast. Why there are 420 prefetches for 62 restores (per rank, repeated lookups or both) is Unknown.
- The restore itself waits for HBM: `waiting for GPU capacity (489 free blocks; the checkpoint needs 20 plus execution headroom)` (Observed). "Execution headroom" is defined in `checkpoint_scheduler.py` inside the image (around line 955); not read yet (Unknown).
- One restore "failed ... on ranks [] after 2.0 s; recomputing its prompt", two seconds after the API server aborted that request at 600 s (Observed). With `kv_load_failure_policy='recompute'` the engine recomputed instead of failing.

## Open items for this component

1. Read the server command line and the HTTP config on a running container: TTLs, lazy L1, eviction policy, `--separate-object-groups`.
2. Find how the launcher accepts LMCache settings beyond `LMCACHE_L1_GB` and `LMCACHE_L2_ENABLED` (its source is in `/opt/lil` inside the image).
3. Read "execution headroom" in `checkpoint_scheduler.py`.
4. Confirm whether any upstream fix after #4679 was cherry-picked (search the package for `BlockRemoved`, see `kv-events.md`).
