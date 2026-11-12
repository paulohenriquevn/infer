# KV events: BlockStored, BlockRemoved and the router

What vLLM and LMCache publish when KV is stored or evicted, which upstream PRs added the CPU-tier events and in what state they are, whether our image has them, and how the llm-d indexer consumes them. Read this before switching the router from approximate to precise prefix-cache routing, before setting `lruCapacityPerServer`, or when a new image arrives.

Short answer for today: our image's LMCache can announce stores but not CPU evictions, our router runs the approximate mode that reads no events, and precise routing with GLM-5.3-Flash (recurrent state, DCP) is untested anywhere we know of. Keep the approximate mode.

## The vLLM event model (Reported)

`--kv-events-config` (`KVEventsConfig`, `https://docs.vllm.ai/en/latest/api/vllm/config/kv_events/`, latest docs, read 2026-11-12):

| Field | Default |
|---|---|
| `enable_kv_cache_events` | False |
| `publisher` | resolves to `zmq` when events are on |
| `endpoint` | `tcp://*:5557` |
| `replay_endpoint` | None |
| `buffer_steps` | 10000 ("The number of steps to cache for replay endpoint") |
| `hwm`, `max_queue_size` | 100000 |
| `topic` | empty |

Event types (`https://docs.vllm.ai/en/latest/examples/features/kv_events/`, read 2026-11-12), sent in an `EventBatch(ts, events)`:

- `BlockStored`: `block_hashes`, `parent_block_hash`, `token_ids`, `block_size`, `lora_id` (deprecated for `lora_name`), `medium`, `lora_name`, `extra_keys`, `group_idx`, `kv_cache_spec_kind`, `kv_cache_spec_sliding_window`, `locality`, `session_id`, `lookahead_token_ids`.
- `BlockRemoved`: `block_hashes`, `medium`, `group_idx`, `locality`.
- `AllBlocksCleared`: no fields.

Our fork image predates some of these fields; which ones it emits is Unknown. Our servers never set `--kv-events-config` (Observed: absent from both server scripts and from `non-default args`).

## LMCache events: PR history (Reported, read on GitHub 2026-11-12)

| PR | What it does | State |
|---|---|---|
| #5076 "publish MP connector KV events" | completed MP stores become vLLM `BlockStored`; "It does not publish `BlockRemoved` or `AllBlocksCleared` for MP host-cache eviction" | merged 2026-09-18 |
| #5307 "[MP] Stream CPU KV events for eviction-aware routing" | the MP server streams L1 store and removal events to vLLM workers over persistent subscriptions (gRPC server streaming, or ZMQ with acks); workers publish `BlockStored` and `BlockRemoved` with `medium="CPU"` through vLLM's event pipeline; server keeps 32,768 records by default; `--kv-event-log-size=0` or `lmcache.mp.kv_event_stream=false` turns it off | merged 2026-10-12 |
| #6119 "Gate CPU KV events on committed chunk residency" | announce a CPU chunk only when a committed L1 copy exists for every required rank and group object; one Removed event when the last copy of a required object goes | merged 2026-11-02 |
| #6122 "Move vLLM KV event subscriptions to the scheduler" | subscriptions, heartbeat identity and buffering move to `LMCacheMPSchedulerAdapter`; worker subscriptions and TP aggregation removed; "No MP RPC schema change" | merged 2026-11-11 |
| #6564 "Honor identity tags and TP-replicated groups in committed KV residency" | fixes `is_committed()` for identity-tagged objects and TP-replicated groups, which previously required every rank | open, opened 2026-11-11 |
| #5695 "Withdraw a CPU KV event only when one of its objects has no copy left" | tracked L1 copies per key so `BlockRemoved` fires only when no copy is left | closed without merge 2026-11-09, in favour of #5778 |

URLs: `https://github.com/LMCache/LMCache/pull/<number>`.

Limits the PR authors state:

- #5307: "Router placements can therefore remain stale until stepping resumes" (no events while the engine is idle); "This PR covers CPU/L1 events." Its llm-d end-to-end test routed 6 of 6 correctly and saw 3,000 L1 chunk reads after GPU eviction. The skill's earlier reading adds: validated with Qwen2.5-7B, chunk size 16, no DCP, no recurrent state, no salted hashes (Reported, §25.1).
- #6119: "Legacy routing still assumes one unsalted parallel setup per model and full-attention groups"; the salted-identity issue "remains open"; "Full GPU router E2E is not claimed."
- #6122: idle publication needs a companion vLLM change. On the pre-rebase head, 10 of 10 requests routed to the CPU-resident replica for both Dynamo and llm-d, idle eviction 96 to 182 ms ("not a latency SLA"); GPU tests were not rerun after the rebase.
- #6564: "Internal namespace isolation does not provide router-side tag isolation on the legacy wire." No GPU or router end-to-end test.

For GLM-5.3-Flash that means: TP-replicated groups (MLA without DCP) and identity-tagged objects (our connector sets `lmcache.mp.checkpoint_identity`) are exactly what #6564 fixes, and it is not merged. Even an upstream build from today would need #6564 before events can be trusted for our layout (Inferred).

## Our image

- The image's LMCache contains `BlockStored` in one file and no `BlockRemoved` (Observed by extraction, §25.1).
- Its build is dated 2026-10-11, one day before #5307 merged, and #5307 is not an ancestor (Observed, §25.1). So no CPU eviction events.
- Inferred consequence: a precise llm-d indexer fed by this image would learn about CPU stores and never about CPU evictions, so it would keep routing to replicas whose L1 entries are gone.

Repeat the check on every new image:

```bash
LMC=$(python3 -c 'import lmcache, os; print(os.path.dirname(lmcache.__file__))')
grep -rl 'BlockStored' "$LMC"; grep -rl 'BlockRemoved' "$LMC"
grep -rl 'kv_event_stream\|take_events\|CommittedKVResidency' "$LMC"   # markers of #5307, #6122, #6119
python3 -c 'import importlib.metadata as m; print(m.version("lmcache"))'
```

The marker strings come from the PR descriptions above (Reported); a match is a hint, not proof that the full PR is present.

## How llm-d consumes events (Reported, read 2026-11-12)

The KV-cache indexer moved from `llm-d/llm-d-kv-cache` into `llm-d-router` (`https://github.com/llm-d/llm-d-kv-cache-manager`, now served as `llm-d/llm-d-kv-cache`).

- Transport: ZMQ, topic `kv@<pod-ip>:<port>@<model>`, payload a msgpack-encoded event batch (`https://github.com/llm-d/llm-d-kv-cache/blob/main/docs/architecture.md`).
- Keys: the indexer chains block keys from `hashSeed` plus model name, each key FNV-64a over CBOR of `[parentHash, tokenChunk, extra]`, tokens chunked by `blockSizeTokens` (default 16 in the indexer). Engine keys are bridged to request keys on ingest. For a CPU offload, the engine sends a `BlockStored` without tokens and the indexer reuses the existing engine-key mapping. The doc does not say what happens when the event block size differs from the configured one.
- Tiers: weights `gpu = 1.0`, `cpu = 0.8`; "the scorer takes the maximum weight" across tiers. `speculativeIndexing: true` adds predicted entries with a 2 s TTL. "Hybrid-attention-aware scoring is a work in progress" (`https://github.com/llm-d/llm-d/blob/main/docs/architecture/kv-management/kv-indexer.md`).
- Precise routing guide (`https://github.com/llm-d/llm-d/blob/main/guides/precise-prefix-cache-routing/README.md`): vLLM publishes on `tcp://*:5556` with topic `kv@$(POD_IP):$(POD_PORT)@<model>` and replay on 5559; vLLM `--block-size 64` matches `blockSizeTokens` 64; the router uses `precise-prefix-cache-producer` and `token-producer` (which calls vLLM `/v1/completions/render`). Caveats in the guide: run one router replica (the index is not HA-safe); "prefix-cache hits publish nothing", so blocks stored before the replay window stay unknown until evicted and stored again; "only full-attention cache groups are indexed"; vLLM keeps the last 10,000 event batches.
- Approximate mode (ours): the producer "splits the incoming prompt into fixed-size blocks (64 tokens by default, approximated as characters)" and reads no events (`https://github.com/llm-d/llm-d/blob/main/docs/architecture/kv-management/prefix-cache-aware-routing.md`).

What this means for GLM-5.3-Flash (Inferred): only the 11 MLA layers form a full-attention group, so the indexer would see MLA blocks and ignore the KDA recurrent state, while a hit on our replica needs both. Our split pages are 1,024 to 2,048 tokens and the LMCache chunk is 4,096, against the guide's 64-token blocks. Neither mismatch is covered by the docs.

## `lruCapacityPerServer` without events

The llm-d tiered-cache guide sets the CPU producer's capacity by hand because "vLLM does not report the size of its CPU tier": `lruCapacityPerServer = CPU tier bytes per pod / (64 x KV bytes per token)`; examples 300 GiB native offload gives 19,200 and LMCache 100 GiB x 2 ranks gives 12,800 (Reported, `https://github.com/llm-d/llm-d/blob/main/guides/tiered-prefix-cache/README.md`, read 2026-11-12). `autoTune` is not documented on the llm-d pages read on 2026-11-12. The skill's rule "`autoTune: false`, it ignores the offload tier" comes from llm-d-router #1650 (Reported, project research notes).

Applied to us with the guide's formula (Inferred, illustrative, not measured): 800 GiB of L1 at 8,721 bytes per token gives 858,993,459,200 / (64 x 8,721) = about 1.54 million blocks of 64 tokens. That only makes sense if the producer's block is 64 tokens; our router config's block unit is whatever `router-mini.values.yaml` sets (the mini used 8,704-token blocks with a default of 31,250, §4). Recompute the number in the router's own unit before using it.

## When to reconsider precise routing

All of:

1. An image whose LMCache has #5307, #6119, #6122 and #6564 (or equivalents), confirmed by the grep above.
2. A test with GLM-5.3-Flash, DCP and recurrent checkpoints where `BlockRemoved` with `medium="CPU"` arrives after an L1 eviction.
3. A router test where routing by events beats the approximate mode on prefix hit or TTFT p95, with the indexer handling the KDA group (or a documented reason that MLA-only indexing is enough).
