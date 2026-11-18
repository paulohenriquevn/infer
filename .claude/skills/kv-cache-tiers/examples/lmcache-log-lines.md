# LMCache log lines from the real run

Exact lines from the LMCache arm of the §29.8 run, results archive: `f3/resultados/vast-20261111/vllm/vast-vllm-lmcache/servidor.log` (Portuguese file name; today the harness writes `server.log`). DCP4, KV pool cut to 5 GiB per GPU, L1 200 GB, 48 agents. ANSI color codes removed; long lines trimmed with `...`. Use them to recognise a healthy start and to count restore outcomes on your own runs.

Strip colors before grepping:

```bash
sed 's/\x1b\[[0-9;]*m//g' server.log > server.clean.log
```

## 1. LMCache server start (before vLLM)

```
[2026-11-12 01:46:37,428] LMCache INFO: torch_dev=StubCPUDevice(device_type=cpu), torch_device_type=cpu (_device_detect.py:312:lmcache.v1.platform._device_detect)
| |   |  \/  |  / ___|__ _  ___| |__   ___      LMCache v0.5.3.dev453+lil.cu134.g8ef537d6481b
[2026-11-12 01:46:40,917] LMCache INFO: Starting LMCache HTTP server on http://127.0.0.1:18001 (http_server.py:262:lmcache.v1.multiprocess.http_server)
[2026-11-12 01:46:40,929] LMCache INFO: Starting LMCache HTTP server... (accelerator available: False) (http_server.py:77:lmcache.v1.multiprocess.http_server)
[2026-11-12 01:46:40,933] LMCache INFO: OTel MeterProvider initialised with Prometheus fallback (standalone metrics HTTP server disabled; /metrics must be exposed by the caller), resource={... 'service.instance.id': 'glm53-flash-8000', ...}
[2026-11-12 01:46:40,933] LMCache INFO: Checking if shm capacity is larger than L1 request (server.py:486:lmcache.v1.multiprocess.server)
[2026-11-12 01:46:40,934] LMCache INFO: Starting L1EvictionController... (eviction_controller.py:68:...)
[2026-11-12 01:46:40,934] LMCache INFO: Starting L2EvictionController... (eviction_controller.py:902:...)
[2026-11-12 01:46:40,935] LMCache INFO: Starting StoreController... (store_controller.py:398:...)
[2026-11-12 01:46:40,935] LMCache INFO: Starting PrefetchController... (prefetch_controller.py:633:...)
[2026-11-12 01:46:40,935] LMCache INFO: Using blake3 hash function (token_hasher.py:79:lmcache.v1.multiprocess.token_hasher)
[2026-11-12 01:46:40,936] LMCache INFO: TokenHasher initialized: chunk_size=4096, hash_algorithm=blake3 (token_hasher.py:67:lmcache.v1.multiprocess.token_hasher)
[2026-11-12 01:46:40,937] LMCache INFO: Supported transfer mode: engine_driven (server.py:306:lmcache.v1.multiprocess.server)
[2026-11-12 01:46:40,943] LMCache INFO: LMCache ZMQ cache server is running on tcp://127.0.0.1:18000 (server.py:552:lmcache.v1.multiprocess.server)
[2026-11-12 01:46:40,964] LMCache INFO:  - Total free size: 204800.000000 MB (tensor_memory_allocator.py:306:lmcache.v1.memory_management)
```

What each tells you (Observed unless labelled):

- `torch_dev=StubCPUDevice` and `accelerator available: False`: the LMCache server process runs on CPU and takes no GPU memory in this mode. This answers the open risk about lmcache-driven sidecars using GPU memory, for this image and profile.
- `Supported transfer mode: engine_driven`: the image runs engine-driven mode (the vLLM workers move KV), not lmcache-driven.
- Ports: ZMQ 18000 and HTTP 18001 for a vLLM API on port 8000; `service.instance.id` is `glm53-flash-8000`. The fork derives LMCache ports from the API port (§17.2), so a second engine on another port gets its own server.
- `chunk_size=4096`: the token hasher chunk under DCP4 with 1,024-token split pages. Final chunk 4,096 is Inferred (LMCache takes `--chunk-size` as a minimum and rounds to the LCM of group spans, project research notes; 4,096 is a multiple of 1,024).
- `Total free size: 204800.000000 MB`: the L1 allocator sees the full 200 GB at start. Whether the pages are touched lazily is Unknown from this line.
- `Checking if shm capacity is larger than L1 request`: the server checks `/dev/shm` against the L1 size at start.
- `/metrics must be exposed by the caller`: LMCache does not open its own metrics port here. Where its metrics end up (vLLM's `/metrics` or nowhere) is Unknown; list `/metrics` on a running server.

## 2. vLLM side: connector and profile

From the `non-default args` line of the API server (trimmed):

```
'block_size': 256, ... 'kv_cache_memory_bytes': 5368709120, 'kv_cache_dtype': 'fp8', 'enable_prefix_caching': True, 'recurrent_checkpoint_policy': 'request_boundaries', 'mamba_cache_mode': 'align', 'max_num_batched_tokens': 4096, ... 'max_num_seqs': 32, 'enable_chunked_prefill': True, 'prefill_compute_share': 0.4, ...
'kv_transfer_config': KVTransferConfig(kv_connector='LMCacheRecurrentCheckpointConnector', engine_id='f27b499f-...', kv_buffer_device='cuda', kv_buffer_size=1000000000.0, kv_role='kv_both', kv_rank=None, kv_parallel_size=1, kv_ip='127.0.0.1', kv_port=14579, kv_connector_extra_config={'lmcache.mp.host': '127.0.0.1', 'lmcache.mp.port': 18000, 'lmcache.mp.mp_transfer_mode': 'engine_driven', 'lmcache.mp.checkpoint_identity': {'target_revision': 'c754ffbc...', 'draft_revision': 'c754ffbc...', 'source_revision': 'b08fccfc...'}}, kv_connector_module_path='lmcache.integration.vllm.recurrent_checkpoint_connector', enable_permute_local_kv=False, kv_load_failure_policy='recompute')
```

Observed facts in this line that change earlier advice:

- `kv_load_failure_policy='recompute'` is already set by the image launcher in `CACHE_MODE=lmcache`. The journal's "set `recompute`, the default is `fail`" (§17.5) is already satisfied for this image.
- `lmcache.mp.checkpoint_identity` carries target, draft and source revision hashes: the connector keys cache entries by weight revision, which is part of the cache identity key §17.5 asks for.
- `kv_role='kv_both'`: the same engine stores and loads.

Other lines:

```
(Worker_TP0_DCP0 pid=105080) WARNING 11-12 01:48:39 [interface.py:900] Using split GLM-5.3 cache pages: target block size 1024 tokens, recurrent-state block size 1024 tokens.
(EngineCore pid=105057) INFO 11-12 01:48:58 [kv_cache_utils.py:2850] GPU KV cache size: 2,589,816 tokens, Maximum concurrency for 1,048,576 tokens per request: 2.47x
(Worker_TP0_DCP0 pid=105080) INFO 11-12 01:49:29 [factory.py:62] Creating v1 connector with name: LMCacheRecurrentCheckpointConnector and engine_id: f27b499f-b689-48d0-afd3-4cab3df196d1
(Worker_TP0_DCP0 pid=105080) LMCache INFO: SHM pinned=True for shm_name=lmcache_l1_pool_lmcache-glm53-flash-8000-18000 (shm.py:157:lmcache.v1.multiprocess.transfer_context.shm)
(EngineCore pid=105057) INFO 11-12 01:52:14 [kv_cache_manager.py:298] Request-boundary recurrent checkpoint caching is enabled. Supported chat requests retain leading instructions, the complete prompt, and the response endpoint.
```

The control arm (`CACHE_MODE=vram`) printed `target block size 2048 tokens` and `GPU KV cache size: 2,519,262 tokens` instead. All four DCP workers pin the same shm segment, consistent with one LMCache server per engine.

## 3. Restores

Counting command:

```bash
grep 'checkpoint_scheduler' server.clean.log \
 | sed -E 's/[0-9]+ tokens/N tokens/; s/request [^ ]+/request R/; s/\([0-9]+ free.*//; s/after waiting [0-9]+ s/after waiting X s/; s/waited [0-9]+ s/waited X s/; s/after [0-9.]+ s/after X s/; s/^.*LMCache INFO: //' \
 | sort | uniq -c | sort -rn
```

Real output (§29.8 run):

```
     90 Recurrent checkpoint restore of N tokens for request R is waiting for GPU capacity 
     74 Recurrent checkpoint restore of N tokens for request R has waited X s for GPU capacity 
     62 Recurrent checkpoint restore of N tokens for request R starts after waiting X s for capacity (checkpoint_scheduler.py:422:lmcache.integration.vllm.checkpoint_scheduler)
      4 Recurrent checkpoint of N tokens selected for request R is no longer cached; looking up its prefix again (checkpoint_scheduler.py:299:lmcache.integration.vllm.checkpoint_scheduler)
      1 Recurrent checkpoint restore of N tokens failed for request R on ranks [] after X s; recomputing its prompt (checkpoint_scheduler.py:727:lmcache.integration.vllm.checkpoint_scheduler)
```

One example of each:

```
[2026-11-12 02:04:00,348] LMCache INFO: Recurrent checkpoint restore of 45955 tokens for request cmpl-b07a10e23010bafb-0-9e431585 is waiting for GPU capacity (489 free blocks; the checkpoint needs 20 plus execution headroom) (checkpoint_scheduler.py:955:...)
[2026-11-12 02:04:30,399] LMCache INFO: Recurrent checkpoint restore of 97903 tokens for request cmpl-9b3c0615b7172199-0-977b6c44 has waited 30 s for GPU capacity (44 free blocks; the checkpoint needs 32 plus execution headroom) (checkpoint_scheduler.py:964:...)
[2026-11-12 02:04:31,105] LMCache INFO: Recurrent checkpoint restore of 97903 tokens for request cmpl-9b3c0615b7172199-0-977b6c44 starts after waiting 31 s for capacity (checkpoint_scheduler.py:422:...)
[2026-11-12 02:04:00,390] LMCache INFO: Recurrent checkpoint of 67184 tokens selected for request cmpl-81a8f383219cf5fd-0-8cd98cf2 is no longer cached; looking up its prefix again (checkpoint_scheduler.py:299:...)
[2026-11-12 02:03:40,016] LMCache INFO: Recurrent checkpoint restore of 77706 tokens failed for request cmpl-9886c21685dfd82a-0-83c4e5d3 on ranks [] after 2.0 s; recomputing its prompt (checkpoint_scheduler.py:727:...)
[2026-11-12 02:16:21,532] LMCache INFO: Recurrent checkpoint restore of 94194 tokens for request cmpl-9f5a9832522fe6ca-0-9fc69a9f has waited 185 s for GPU capacity (182 free blocks; the checkpoint needs 31 plus execution headroom) (checkpoint_scheduler.py:964:...)
```

The failed restore belongs to the request that the API server had aborted two seconds earlier:

```
(APIServer pid=104410) WARNING 11-12 02:03:38 [stall_diagnostics.py:197] Request cmpl-9886c21685dfd82a-0 aborted after 600.01 s (arrived 01:53:38.693), ...
```

so this "failure" is the client's 600 s timeout, not a broken L1 entry (Inferred from the matching request ID).

Wait time before `starts after waiting`, seconds (count in parentheses), all 62 restores: 31, 35 (4), 36, 38 (9), 40, 42 (8), 43, 44, 45, 47 (7), 48, 49, 50, 51, 52, 59 (2), 85 (3), 107 (5), 133 (3), 158, 159, 166, 189 (3), 193, 203, 204, 212. Every restore waited at least 31 s.

Reading the "waiting" lines: 489 free blocks and a need of 20 still waits, so the limit is the "execution headroom" term, not the checkpoint size. Its definition is Unknown (read `checkpoint_scheduler.py` in the image, around line 955).

## 4. Engine stats with the external hit rate

```
(APIServer pid=104410) INFO 11-12 01:55:56 [loggers.py:315] Engine 000: Avg prompt throughput: 6516.5 tokens/s, Avg generation throughput: 149.1 tokens/s, Running: 4 reqs, Waiting: 44 reqs, Deferred: 39 reqs, GPU KV cache usage: 26.5%, Prefix cache hit rate: 0.0%, External prefix cache hit rate: 0.0%
(APIServer pid=104410) INFO 11-12 02:16:06 [loggers.py:315] Engine 000: Avg prompt throughput: 0.0 tokens/s, Avg generation throughput: 369.2 tokens/s, Running: 8 reqs, Waiting: 35 reqs, Deferred: 11 reqs, GPU KV cache usage: 66.7%, Prefix cache hit rate: 0.0%, External prefix cache hit rate: 42.6%
(APIServer pid=104410) INFO 11-12 02:17:46 [loggers.py:315] Engine 000: Avg prompt throughput: 5454.3 tokens/s, Avg generation throughput: 6.9 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 0.0%, External prefix cache hit rate: 56.8%
```

`External prefix cache hit rate` is the LMCache share; `Prefix cache hit rate` is HBM. `Deferred` appears only with the connector; its meaning (requests held back while a load is pending) is Inferred from the name and not checked in the code. The control arm prints the same line without `Deferred` and without the external rate.
