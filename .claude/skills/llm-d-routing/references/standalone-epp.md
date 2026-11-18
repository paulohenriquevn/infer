# Running the EPP outside Kubernetes

How to run the llm-d EPP, Envoy and vLLM replicas on plain hosts with file-based endpoint discovery, what LMCache PR #5307 did and did not validate, and what we would run on plain EC2 in phases 1 to 3 of `docs/06-aws-implementation-plan.md`. We have never run the EPP outside Kubernetes; everything here is Reported or Inferred.

## Sources (read 2026-11-12)

| Source | URL |
|---|---|
| llm-d no-Kubernetes guide, `v1.0.0` | https://github.com/llm-d/llm-d/tree/v1.0.0/guides/no-kubernetes-deployment |
| llm-d no-Kubernetes architecture page | https://github.com/llm-d/llm-d/blob/v1.0.0/docs/infrastructure/no-kubernetes-deployment.md |
| Blog "No Kubernetes? No Problem" (parity caveats) | https://llm-d.ai/blog/running-llm-d-without-kubernetes |
| `file-discovery` plugin source | https://github.com/llm-d/llm-d-router/blob/main/pkg/epp/framework/plugins/datalayer/discovery/file/plugin.go |
| LMCache PR #5307 | https://github.com/LMCache/LMCache/pull/5307 |

The guide and the architecture page were read in the local clone at tag `v1.0.0` (commit `378b42d18dabe0b9c4ced4e6f3670d93b52db08e`); the blog and the plugin source were not opened.

## What PR #5307 validated, and what it did not

PR #5307 "[MP] Stream CPU KV events for eviction-aware routing" (merged 2026-10-12) makes LMCache publish `BlockStored` and `BlockRemoved` for its CPU tier. Its validation text says (Reported, PR body):

> unmodified EPP `b16fa8db`, Envoy `v1.33.2`, native vLLM HTTP servers, file discovery, and speculative indexing disabled

and "6/6 correct routes with full hits; all 11 routing and 7 event-accounting checks passed", on Qwen2.5-7B, two replicas at TP 2, unsalted `sha256_cbor` hashes, chunk 16, 2 GiB L1, vLLM `0.27.2rc1.dev111+g44fc57d7b`. `b16fa8db` is an `llm-d/llm-d-router` commit of 2026-09-22 (Inferred from the SHA; not checked against a tag).

The PR contains no EPP config, Envoy config, endpoints file or command lines. It proves that the no-Kubernetes topology works with precise routing on a small model; it is not a setup guide. The setup below comes from the llm-d guide, which is the real source.

## The topology

```
client -> Envoy listener :8081
       -> ext_proc gRPC :9002 (EPP picks endpoint, sets header)
       -> ORIGINAL_DST cluster
       -> reads x-gateway-destination-endpoint from EPP response
       -> <address>:<port> of the vLLM worker chosen by the EPP
```

Quoted from `docs/infrastructure/no-kubernetes-deployment.md`. The EPP scrapes each worker's `/metrics` itself, so it needs network access to every worker IP.

## The three files

`router/epp/config.yaml` (excerpt, local clone):

```yaml
plugins:
  - name: file-discovery
    type: file-discovery
    parameters:
      path: /etc/epp/endpoints.yaml  # EPP must have network access to all worker IPs for metrics scraping
      watchFile: true
...
  - name: metrics-source
    type: metrics-data-source
  - name: metrics-extractor
    type: core-metrics-extractor
...
dataLayer:
  injectDefaults: false
  discovery:
    endpoints:
      pluginRef: file-discovery
  sources:
    - pluginRef: metrics-source
      extractors:
        - pluginRef: metrics-extractor
```

`router/epp/endpoints.yaml` (local clone):

```yaml
# Each entry must use a literal IPv4 address (the plugin does not resolve
# hostnames). Replace the addresses below with your vLLM workers.
...
endpoints:
  - name: vllm-0
    address: 127.0.0.1
    port: "8000"
    labels:
      model: Qwen/Qwen3-32B
```

`router/envoy/envoy.yaml`: admin on `127.0.0.1:19000`, listener `0.0.0.0:8081`, route timeout and idle timeout 86400 s, `ext_proc` filter to cluster `ext_proc` (static `127.0.0.1:9002`, gRPC health check every 10 s) with all body modes `FULL_DUPLEX_STREAMED` and `message_timeout: 1000s`, and `original_destination_cluster` of type `ORIGINAL_DST` reading `x-gateway-destination-endpoint` (Observed in the local clone).

## Commands (from the guide)

Images: EPP `ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0` (from `guides/env.sh`), Envoy `docker.io/envoyproxy/envoy:distroless-v1.33.2`.

```bash
docker run -d --name epp --network host \
    -v /etc/epp:/etc/epp:ro \
    "${ROUTER_EPP_IMAGE}:${ROUTER_EPP_VERSION}" \
    --config-file=/etc/epp/config.yaml \
    --pool-name=file-discovery \
    --pool-namespace=default \
    --grpc-port=9002 \
    --grpc-health-port=9003 \
    --metrics-port=9090 \
    --secure-serving=false \
    --health-checking=true \
    --v=2

docker run -d --name envoy --network host \
    -v /etc/envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro \
    "${ENVOY_IMAGE}" \
    --service-node envoy-proxy \
    --log-level warn \
    --concurrency 8 \
    --drain-strategy immediate \
    --drain-time-s 60 \
    -c /etc/envoy/envoy.yaml
```

Notes from the guide (Reported):

- `--pool-name` and `--pool-namespace` are only labels on metrics and logs in this mode.
- Without `--health-checking=true` Envoy marks the EPP unhealthy and reaches it only through panic routing.
- Change the pool by atomic rename (`mv endpoints.yaml.tmp endpoints.yaml`); the EPP logs `endpoints file changed, reloading`.
- Verify with `curl -s http://127.0.0.1:19000/clusters | grep '^ext_proc.*health_flags'` (expect healthy) and `curl -s http://127.0.0.1:9090/metrics | head`.

## Limits

- Out of scope without Kubernetes: `InferenceObjective`-driven flow control, the `InferenceModelRewrite` model-name rewriter, and `PodMonitor`-based metric discovery. Scoring, prefix affinity, saturation-based admission and EPP metrics work (Reported, architecture page). Whether flow control with priority bands defined only in the config file works is Unknown; the guide does not show it.
- Endpoint addresses must be literal IPv4. On EC2 that means private IPs written by whatever launches the instances.
- No autoscaling: something else must add instances and rewrite `endpoints.yaml`.
- One EPP, no leader election, index and queues lost on restart. A second EPP behind the same Envoy would build an independent index (Inferred).
- The guide's plugin set is the older scorer mix (`queue-scorer` 2, `kv-cache-utilization-scorer` 2, `prefix-cache-scorer` 3, `no-hit-lru-scorer` 2), although its comment says it "mirrors" optimized-baseline. The optimized-baseline guide in the same release uses `approx-prefix-cache-producer`, `inflight-load-producer`, `prefix-cache-affinity-filter` and `token-load-scorer` (Observed in both files). Routing would not be identical to what we tested on the mini.
- `/metrics` on 9090 is open with `--secure-serving=false`; keep it on the private network.

## What we would run on plain EC2 (phases 1 to 3)

Inferred design, not tested:

| Piece | Where | Setting |
|---|---|---|
| vLLM fork | one per `g7e.24xlarge` | image `karmic-kraken-20261016`, profile from `vllm-fork-serving`; port 8000 on the private IP |
| EPP | a small CPU instance in the same subnet, or on one GPU host for phase 3 | `v1.0.0` image, flags above, our plugin set (`../examples/standalone-ec2.illustrative.yaml`) |
| Envoy | same host as the EPP | the guide's `envoy.yaml` unchanged; port 8081 behind the gateway |
| `endpoints.yaml` | EPP host | written by the launch script after each replica answers `/health`, atomic rename |
| Prometheus | same host or a monitoring instance | static targets: EPP 9090, each replica 8000 |

Changes to the guide we would make, each with its reason:

1. Replace the scorer mix with our tested plugin set, and set `blockSizeTokens` to the fork's block (2,048, `scorers-and-saturation.md`), `autoTune: false` and `lruCapacityPerServer` from the pool.
2. Keep `file-discovery`, `metrics-data-source` and `core-metrics-extractor` exactly as in the guide (`injectDefaults: false` means nothing else is added).
3. Add a replica to `endpoints.yaml` only after its warm-up finished, and remove it before draining (`autoscaling-and-observability` skill, scale-in procedure).
4. Phase 3 acceptance (`docs/06`): rerun the 21 x 3 test and the burst of 51 through Envoy on 8081. `router/exp/sessions.py` already takes the replica IPs with `--pods` and scrapes `http://<ip>:8000/metrics`; only the constant `EPP = "http://optimized-baseline-epp:80"` and the model name `"mini"` in the request body need changing, to the Envoy URL and the served model name (`GLM-5.3-Flash-NVFP4`); `BLOCK = 8704` is unused. `run_exp.sh` wraps it in `kubectl` and is not needed on EC2 (Observed in code).
