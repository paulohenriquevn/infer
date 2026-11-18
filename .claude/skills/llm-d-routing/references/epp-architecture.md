# EPP architecture and our configuration

What the llm-d Endpoint Picker (EPP) is, how a request moves through it, which plugin kinds exist, and what each line of our router values files does. Upstream facts are Reported from llm-d `v1.0.0` (local clone of `llm-d/llm-d` at tag `v1.0.0`, commit `378b42d18dabe0b9c4ced4e6f3670d93b52db08e`, and the pages below, read 2026-11-12). WebFetch returns pages through a summarizer, so prose from llm-d.ai is paraphrased; YAML quoted here comes from the local clone or our repository.

## Sources

| Source | URL |
|---|---|
| EPP overview | https://llm-d.ai/docs/architecture/router/epp |
| Scheduling (filters, scorers, pickers, profiles) | https://llm-d.ai/docs/architecture/router/scheduling |
| Configuration reference (`EndpointPickerConfig`) | https://llm-d.ai/docs/architecture/router/configuration |
| Request handling (parsers, admitters, request metrics) | https://llm-d.ai/docs/architecture/router/request-handling |
| InferencePool on llm-d | https://llm-d.ai/docs/architecture/router/inferencepool |
| InferencePool API (Gateway API Inference Extension, not versioned with llm-d) | https://gateway-api-inference-extension.sigs.k8s.io/api-types/inferencepool/ |
| Prefix-cache-aware routing | https://github.com/llm-d/llm-d/blob/v1.0.0/docs/architecture/kv-management/prefix-cache-aware-routing.md |
| llm-d-router release notes | https://raw.githubusercontent.com/llm-d/llm-d-router/v1.0.0/RELEASE-NOTES.md |
| Optimized-baseline router values | https://github.com/llm-d/llm-d/blob/v1.0.0/guides/optimized-baseline/router/optimized-baseline.values.yaml |
| Shared router recipe | https://github.com/llm-d/llm-d/blob/v1.0.0/guides/recipes/router/base.values.yaml |

The router repository was formerly called the Inference Scheduler; it is now `github.com/llm-d/llm-d-router` (Reported, its README).

## What the EPP is

- The EPP is the decision point of the llm-d router. It picks one model server for each request using KV-cache usage, prefix locality, queue depth and in-flight work, and it can hold requests in priority and fairness queues while the pool is saturated (Reported, EPP overview).
- It plugs into a proxy (Envoy, or agentgateway) through the Envoy external processing protocol (`ext_proc`) on gRPC port 9002. The EPP answers with the chosen endpoint in the header `x-gateway-destination-endpoint`; Envoy forwards to that address through an `ORIGINAL_DST` cluster (Reported, no-Kubernetes docs and `guides/no-kubernetes-deployment/router/envoy/envoy.yaml`).
- If you write the Envoy config yourself, request and response body modes must be `FULL_DUPLEX_STREAMED` (Reported, EPP overview; the shipped `envoy.yaml` sets both).
- On Kubernetes the set of candidate servers is an `InferencePool` (`inference.networking.k8s.io/v1`): a label selector, target ports, and an `endpointPickerRef` to the EPP service with `failureMode` `FailOpen` or `FailClose`. The pool, the EPP service and the pods share a namespace (Reported, InferencePool pages). The llm-d recipe sets `failureMode: "FailOpen"` (Observed in `guides/recipes/router/base.values.yaml`): if the EPP is down, Envoy still forwards, without affinity or flow control.
- Without Kubernetes the pool comes from a YAML file through the `file-discovery` plugin (`standalone-epp.md`).

## Request path

1. The client calls Envoy (port 8081 in the no-Kubernetes guide, port 80 on the Kubernetes service in our mini setup).
2. Envoy streams headers and body to the EPP over `ext_proc`.
3. A parser builds the internal request (`openai-parser`, `anthropic-parser` and `vllmhttp-parser` are defaults; `vllmgrpc-parser` must be declared). The request-handling page and the configuration page list different parser sets (Reported, both pages).
4. Flow control, when the `flowControl` feature gate is on, queues the request by priority band and fairness ID until the saturation detector says the pool has room (`cells-and-bursts.md`).
5. The scheduler runs the scheduling profile: filters remove endpoints, scorers give each remaining endpoint a score from 0 to 1 that is weighted and summed, a picker chooses. With no picker in a profile, `max-score-picker` is injected (Reported, configuration page).
6. Envoy forwards to the chosen endpoint. Response headers and body pass back through the EPP, which updates in-flight counters.
7. An asynchronous data layer scrapes each endpoint's `/metrics` (queue, running requests, KV usage) and feeds scorers and the saturation detector.

## Plugin kinds

| Kind | Role | Examples in v1.0.0 |
|---|---|---|
| Parser | turn the HTTP body into a request with prompt and model | `openai-parser`, `anthropic-parser`, `vllmhttp-parser`, `vllmgrpc-parser` |
| Admitter | admit or reject before scheduling | `latency-slo-admitter` |
| Data producer | compute per-request or per-endpoint attributes other plugins read | `approx-prefix-cache-producer`, `precise-prefix-cache-producer`, `inflight-load-producer`, `token-producer` |
| Filter | remove candidate endpoints | `prefix-cache-affinity-filter` |
| Scorer | score candidates from 0 to 1 | `token-load-scorer`, `prefix-cache-scorer`, `queue-scorer`, `kv-cache-utilization-scorer`, `load-aware-scorer`, `no-hit-lru-scorer` |
| Picker | choose among scored candidates | `max-score-picker` |
| Profile handler | run one or several profiles (for example prefill and decode) | `single-profile-handler` (default) |
| Flow control | saturation detector, fairness policy, ordering policy | `utilization-detector`, `concurrency-detector`, `global-strict-fairness-policy`, `fcfs-ordering-policy` |
| Data layer | endpoint discovery, metric sources and extractors | `file-discovery`, `metrics-data-source`, `core-metrics-extractor` |

Plugins carry a maturity level; Alpha plugins need `--allow-experimental-plugins=true` (Reported, release notes, PR 2073). `precise-prefix-cache-scorer` was removed; precise mode is now `precise-prefix-cache-producer` plus `prefix-cache-scorer` with `prefixMatchInfoProducerName: precise-prefix-cache-producer` (Reported, release notes, PR 2844).

## `EndpointPickerConfig` in one paragraph

`apiVersion: llm-d.ai/v1`, `kind: EndpointPickerConfig`, top-level keys `plugins`, `featureGates`, `requestHandler`, `flowControl`, `schedulingProfiles` and `dataLayer`. It is not a Kubernetes resource: the EPP reads it once at start from `--config-file` or `--config-text`, so a change needs an EPP restart. Each plugin has `type`, an optional `name` (defaults to the type) and `parameters`. Profiles list `pluginRef` and, for scorers, `weight` (default 1.0). Omitting `schedulingProfiles` creates a `default` profile with every plugin. `llm-d.ai/v1alpha1` still loads but is deprecated. `replicas` above 1 gives active-passive HA with leader election (Reported, configuration page).

## Our configuration, line by line

### `router/router-mini.values.yaml`

The last Helm layer, on top of `guides/recipes/router/base.values.yaml` and `guides/optimized-baseline/router/optimized-baseline.values.yaml`, deployed with `oci://ghcr.io/llm-d/charts/llm-d-router-standalone --version v1.0.0` (Observed in `router/bench/run_ab.sh`).

| Line | Meaning | Note |
|---|---|---|
| `router.epp.resources.requests.cpu: "2"`, `memory: 4Gi`, `limits.memory: 8Gi` | half the recipe's EPP request (cpu 4, 8Gi, limit 16Gi) | sized for 2 mini replicas; at our scale the EPP needs about 0.5 to 1 core per request per second (project research notes, not published) |
| `pluginsCustomConfig.optimized-baseline-plugins.yaml` | replaces the guide's plugin file under the same name, so the chart's `pluginsConfigFile: "optimized-baseline-plugins.yaml"` picks ours | the key must match the file name the guide selects |
| `approx-prefix-cache-producer` | builds the EPP's own prefix index: prompt split into blocks, rolling hash chain, LRU of which hashes were sent to which endpoint | learns only from its own routing decisions; never sees evictions |
| `blockSizeTokens: 8704` | block size of that index | 8,704 was the mini engine's attention block from `cache_config_info`. See "the block size comment" below |
| `maxPrefixTokensToMatch: 262144` | match up to 256K tokens of prefix | the README default is 131,072 (Reported); our context is 256K |
| `inflight-load-producer` | counts in-flight requests and tokens per endpoint | consumed by the filter, the scorer, the concurrency detector and the EPP metrics `llm_d_epp_inflight_requests` and `llm_d_epp_inflight_tokens` |
| `prefix-cache-affinity-filter` | keeps only endpoints that hold the prefix, unless their estimated TTFT exceeds the best other endpoint's by more than `maxTTFTPenaltyMs` | defaults `peakPrefillThroughput` 15928 and `maxTTFTPenaltyMs` 18000, not calibrated for us (`scorers-and-saturation.md`) |
| `token-load-scorer` | scores `1 - min(1, in-flight tokens / queueThresholdTokens)` | default `queueThresholdTokens` 4,194,304 (Reported) |
| `schedulingProfiles: default: filter, scorer` | filter first, then score; picker injected | same order as the guide |
| `proxy.resources` cpu 2, 2Gi, limit 8Gi | Envoy sidecar, half the recipe | Envoy runs `--concurrency 8` from the recipe; with a 2-CPU request that oversubscribes (Inferred) |

What we inherit from the recipe without overriding (Observed in the local clone): one EPP replica, `--v=2` logging, `failureMode: "FailOpen"`, Envoy flags `--log-level warn --concurrency 8 --drain-strategy immediate --drain-time-s 60`, OTEL tracing to `localhost:4317` at 10% sampling.

### `router/bench/router-no-prefix.values.yaml`

Variant B of the A/B: plugins `inflight-load-producer` and `token-load-scorer` only, profile `default` with the scorer. No prefix index at all, so placement follows load alone (Observed). This is the control for every affinity number in `../SKILL.md`.

### The block size comment

The values file says that with the plugin default "the EPP hashes do not match the real cache". The llm-d docs describe the approximate index differently: the EPP has no tokenizer, approximates tokens from characters, hashes its own blocks and keeps its own LRU of where it sent them (Reported, `prefix-cache-aware-routing.md` lines 21 to 23). The EPP never compares its hashes with the engine's. What the setting does change (Inferred):

- Match granularity. The index only credits whole blocks, and the engine only caches whole blocks. With an 8,704-token engine block and a 64-token EPP block the EPP would credit prefixes the engine cannot reuse.
- Index capacity accounting. `lruCapacityPerServer` counts blocks of this size, so it must be pool tokens divided by `blockSizeTokens`.

So the conclusion (set it to the engine block) holds; the stated reason does not. The values file is outside this skill and stays as it is.

## What the EPP does not do for us

- It does not see evictions in approximate mode, so it can keep routing a session to a replica that dropped its prefix.
- It loses its index on restart (llm-d-router #3784, 14 of 48 requests misrouted after a rollout; project research notes, not published) and, with flow control, its queues (Reported, flow-control page).
- With `FailOpen` an EPP outage silently turns routing into Envoy's default balancing.
