# Reproducing the routing tests on the real model

Commands to repeat the mini routing tests on GLM-5.3-Flash replicas (phase 3 of `docs/06-aws-implementation-plan.md`). Not run yet. The Kubernetes commands are the ones in this repository's scripts; the plain-EC2 commands are Inferred from `router/exp/sessions.py` and the llm-d no-Kubernetes guide (`../references/standalone-epp.md`). Every step that starts instances costs money and needs Paulo's go-ahead.

## Preconditions

1. Two replicas serving the same fork profile (`vllm-fork-serving` skill), each warmed and passing `/health`.
2. Each replica started with `VLLM_SERVER_DEV_MODE=1` so `POST /reset_prefix_cache` works (Observed in `router/vllm-mini-pool.yaml`; on the fork Unknown). Keep port 8000 private: dev mode exposes cache control.
3. The block size read from the server log of this image:

   ```bash
   grep -oE 'target block size [0-9]+ tokens' server.log | sort -u
   ```

   2,048 on `karmic-kraken-20261016` without LMCache (Observed, `../references/scorers-and-saturation.md`).
4. The replica attribution metric exists on the fork:

   ```bash
   curl -s http://<replica-ip>:8000/metrics | grep '^vllm:prompt_tokens_by_source_total'
   ```

   If it prints nothing, `sessions.py` cannot tell which replica served a request. Fall back to the deltas of `vllm:prefix_cache_hits_total` and `vllm:prompt_tokens_total`, which the fork exports (Observed through the harness); that needs a code change in `scrape()`.
5. The EPP config with the real block, `autoTune: false` and `lruCapacityPerServer` (`annotated-router-values.md`).

## Adapt the client

`router/exp/sessions.py` constants and model name (Observed in code):

```python
EPP = "http://optimized-baseline-epp:80"
BLOCK = 8704
...
    body = json.dumps({"model": "mini", "prompt": prompt, ...
```

Change the URL to Envoy (`http://<epp-host>:8081` on EC2) and the model to `GLM-5.3-Flash-NVFP4`. `BLOCK` is defined but not used by the code (Observed); set it to 2048 so the file documents the block it was run with. Choose the prefix as a whole number of blocks: the mini used 17,408 = 2 x 8,704; with 2,048-token blocks, `--prefix 18432` (9 blocks) plus `--question 512` keeps the same size class (Inferred).

## On Kubernetes (as the mini ran)

```bash
export KUBECONFIG=...   LLMD_DIR=/path/to/llm-d   # clone at tag v1.0.0
cd router/exp
bash router_mode.sh affinity
bash run_exp.sh rot21-affinity routing --groups 21 --repetitions 3 --prefix 18432
for r in 1 2 3; do
  bash run_exp.sh burst51-affinity-r$r burst --burst 51 --prefix 18432
  bash router_mode.sh affinity      # resets the prefix cache before the next run
done
bash router_mode.sh load-only
bash run_exp.sh rot21-load-only routing --groups 21 --repetitions 3 --prefix 18432
for r in 1 2 3; do
  bash run_exp.sh burst51-load-only-r$r burst --burst 51 --prefix 18432
  bash router_mode.sh load-only
done
```

`run_exp.sh` reads replica IPs from pods labelled `app=vllm-mini` in namespace `llm-d-optimized-baseline`; relabel or edit for the real pool. Re-running `router_mode.sh` performs a `helm upgrade` and an EPP rollout, which also clears the EPP index; that is the reset the mini runs used.

## On plain EC2 (Inferred, not run)

```bash
EPP_HOST=10.0.0.5; R1=10.0.0.10; R2=10.0.0.11
reset() { for ip in $R1 $R2; do curl -s -X POST http://$ip:8000/reset_prefix_cache -o /dev/null -w "reset $ip: %{http_code}\n"; done; }

# affinity mode: EPP started with the affinity config
reset
mkdir -p results
python3 router/exp/sessions.py routing --pods $R1,$R2 --groups 21 --repetitions 3 \
  --prefix 18432 --output results/rot21-affinity.json
for r in 1 2 3; do
  reset; docker restart epp        # the approximate index must be cleared too
  python3 router/exp/sessions.py burst --pods $R1,$R2 --burst 51 --prefix 18432 \
    --output results/burst51-affinity-r$r.json
done
# load-only mode: restart the EPP with the no-prefix config, then repeat
```

The EPP reads its config only at start, so switching modes is a restart with another `--config-file`.

## What to record and accept

From `docs/06` phase 3: the same-replica share and the cache share against its ceiling (prefix / (prefix + question)) for the 21 x 3 test in both modes, and the burst of 51 with no errors and the per-replica split. Also record, for the real model only:

- TTFT p50 and max per burst run, three runs per mode, first run after start discarded.
- EPP metrics before and after: `llm_d_epp_prefix_cache_affinity_filter_decisions_total` by outcome (explains the burst split, which the mini did not log).
- The server log line with the block size, and the image tag.

Test the mini never ran and the real model needs: the `cyclic` mode with a working set larger than the pool, default against fixed `lruCapacityPerServer`:

```bash
python3 router/exp/sessions.py cyclic --pods $R1,$R2 --sessions 48 --passes 3 --concurrency 4 --prefix 18432
```

Size `--sessions` so that sessions x prefix exceeds the pool of both replicas (DCP1: 6,789,052 tokens each, so more than about 740 sessions of 18,432 tokens; Inferred).
