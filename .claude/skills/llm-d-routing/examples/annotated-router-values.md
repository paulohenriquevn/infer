# Annotated router values files

The two values files the mini routing tests ran with, quoted in full from this repository, with comments on what each line does and what changes for the real model. Line-by-line reference: `../references/epp-architecture.md`. Helm layering (Observed in `router/bench/run_ab.sh` and `router/exp/router_mode.sh`): `guides/recipes/router/base.values.yaml`, then `guides/optimized-baseline/router/optimized-baseline.values.yaml` from llm-d `v1.0.0`, then these files, with chart `oci://ghcr.io/llm-d/charts/llm-d-router-standalone --version v1.0.0`.

## Affinity: `router/router-mini.values.yaml`

```yaml
## Tweaks of the glm5next mini model over the optimized-baseline guide (llm-d v1.0.0).
## Last layer, after base.values.yaml and optimized-baseline.values.yaml.
## blockSizeTokens: the glm5next vLLM uses an attention block of 8704 tokens (vLLM metric "cache_config_info");
## with the plugin default, the EPP hashes do not match the real cache.
router:
  epp:
    resources:
      requests:
        cpu: "2"
        memory: 4Gi
      limits:
        memory: 8Gi
    pluginsCustomConfig:
      optimized-baseline-plugins.yaml: |
        apiVersion: llm-d.ai/v1
        kind: EndpointPickerConfig
        plugins:
        - type: approx-prefix-cache-producer
          parameters:
            blockSizeTokens: 8704
            maxPrefixTokensToMatch: 262144
        - type: inflight-load-producer
        - type: prefix-cache-affinity-filter
        - type: token-load-scorer
        schedulingProfiles:
        - name: default
          plugins:
          - pluginRef: prefix-cache-affinity-filter
          - pluginRef: token-load-scorer
  proxy:
    resources:
      requests:
        cpu: "2"
        memory: 2Gi
      limits:
        memory: 8Gi
```

Annotations:

| Line | What it does | For the real model |
|---|---|---|
| header comment on `blockSizeTokens` | states the reason for 8,704 | the reason is inaccurate: the approximate index never compares hashes with the engine; the value sets match granularity and LRU accounting (`../references/epp-architecture.md`) |
| `resources` (EPP) | cpu 2, 4Gi, limit 8Gi, below the recipe's cpu 4, 8Gi, 16Gi | use the recipe values or more; EPP CPU grows with req/s (project research notes, not published) |
| `optimized-baseline-plugins.yaml:` | overrides the guide's plugin file of the same name | keep the name |
| `approx-prefix-cache-producer` | EPP-local prefix index | keep; add `autoTune: false` and `lruCapacityPerServer` |
| `blockSizeTokens: 8704` | mini block from `cache_config_info` | 2,048 on the fork image, 1,024 with LMCache (Observed in server logs, `../references/scorers-and-saturation.md`) |
| `maxPrefixTokensToMatch: 262144` | match up to 256K tokens | keep for 256K sessions; the fork serves `--max-model-len 1048576`, so raise it if sessions go past 256K (Inferred) |
| `inflight-load-producer` | in-flight requests and tokens per endpoint | keep; also feeds the EPP autoscaling metrics |
| `prefix-cache-affinity-filter` | sticky to the prefix holder until the TTFT penalty | add `peakPrefillThroughput` from calibration and a chosen `maxTTFTPenaltyMs` |
| `token-load-scorer` | prefers endpoints with fewer uncached tokens in flight | default `queueThresholdTokens` 4,194,304; Unknown whether it fits |
| `schedulingProfiles` | filter, then scorer, picker injected | keep |
| `proxy.resources` | Envoy cpu 2, 2Gi | the recipe's Envoy runs `--concurrency 8`; match CPU to it (Inferred) |

What the real-model version would add, illustrative, not measured (values marked `<...>` are not known yet):

```yaml
        - type: approx-prefix-cache-producer
          parameters:
            autoTune: false
            blockSizeTokens: 2048              # fork log: "target block size 2048 tokens"
            maxPrefixTokensToMatch: 262144
            lruCapacityPerServer: 3315         # DCP1 pool 6,789,052 tokens / 2,048
        - type: inflight-load-producer
        - type: prefix-cache-affinity-filter
          parameters:
            peakPrefillThroughput: <calibrated, CHUNK_SIZE=4096>
            maxTTFTPenaltyMs: <chosen, see scorers-and-saturation.md>
        - type: token-load-scorer
```

## Load only: `router/bench/router-no-prefix.values.yaml`

```yaml
## Variant B of the A/B: load-only routing (no prefix affinity).
## Layer after router-mini.values.yaml.
router:
  epp:
    pluginsCustomConfig:
      optimized-baseline-plugins.yaml: |
        apiVersion: llm-d.ai/v1
        kind: EndpointPickerConfig
        plugins:
        - type: inflight-load-producer
        - type: token-load-scorer
        schedulingProfiles:
        - name: default
          plugins:
          - pluginRef: token-load-scorer
```

Annotations: the same file key replaces the whole plugin list, so no prefix producer and no filter exist in this mode. Requests go to the endpoint with the fewest uncached tokens in flight. Applied as a later `-f` layer, it keeps the resources from `router-mini.values.yaml`. It is the control arm for every affinity number; use it again on the real model.

## The test client's constants: `router/exp/sessions.py`

```python
EPP = "http://optimized-baseline-epp:80"
BLOCK = 8704
```

and `"model": "mini"` in the request body (line 22). On the real model the URL and the model name must change (Envoy or service URL, `GLM-5.3-Flash-NVFP4`). `BLOCK` is not used anywhere in the file (Observed); the prefix size comes from `--prefix`.
