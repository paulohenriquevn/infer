# Prefill/decode disaggregation

What P/D is, what we tested (a mini model, not the real one), why it is not in the first design, what would justify it, and the transfer options on AWS. Read this when someone proposes P/D, NIXL KV transfer, separate GPU types for prefill and decode, or EFA as a reason to revisit any of these.

## What it is

Aggregated serving runs prefill and decode on the same replica; a long prefill shares engine steps with every running decode. P/D splits them: a prefill replica computes the prompt KV, a connector moves that KV to a decode replica, and the decode replica generates. A proxy or router sends each request to both in turn.

Upstream vLLM states the goal plainly: "Disaggregated prefill DOES NOT improve throughput." The reasons it gives are tuning TTFT and ITL separately and "Controlling tail ITL" (Reported, `https://docs.vllm.ai/en/latest/features/disagg_prefill/`, latest docs, read 2026-11-12). The page lists connectors including `NixlConnector`, `LMCacheConnectorV1`, `MooncakeConnector`, `MultiConnector` and `OffloadingConnector`.

For us P/D has a hybrid-model twist: GLM-5.3-Flash has 11 MLA layers and 34 KDA layers, so the transfer must carry MLA KV plus the recurrent KDA state of each request (Inferred from the architecture, §2).

## The mini test (Nebius, 2026-11-05)

Setup, from `router/pd/pd.yaml` and `router/pd/proxy.yaml` (Observed):

| Item | Value |
|---|---|
| Model | "mini": GLM-5.3-Flash `config.json` at revision `46a050bec13002ad29ee795c16e61cf4fa3c4a9c` cut to 2 full-attention layers with random weights by `make_mini.py` (the script is not in this repository) |
| Engine | `vllm/vllm-openai:v0.32.0` (upstream, not the fork) |
| Topology | 1 prefill pod and 1 decode pod, 1 RTX PRO 6000 each, `toy_proxy_server.py` (vLLM's example proxy) on port 8192. Control: 2 aggregated replicas on the same 2 GPUs (§9.2) |
| Connector | `NixlConnector`, `kv_role` `kv_producer` on prefill and `kv_consumer` on decode |
| Engine flags | `--kv-cache-dtype fp8_ds_mla`, `--no-disable-hybrid-kv-cache-manager`, `--gpu-memory-utilization 0.5`, `--max-model-len 262144`; prefill also `--enforce-eager` |
| Environment | `VLLM_SSM_CONV_STATE_LAYOUT=DS`, `UCX_NET_DEVICES=eth0`, `UCX_TLS=tcp,cuda_copy`, `VLLM_NIXL_SIDE_CHANNEL_PORT=5557`, `VLLM_NIXL_SIDE_CHANNEL_HOST` from the pod IP |
| Shared memory | `/dev/shm` as a 16Gi memory `emptyDir` |
| Load | `pd_bench.py`, 17,408-token cold unique prompts, output 128, concurrency 8 and 32, one run per cell after a warm-up |

Two things the vLLM recipe got wrong on SM120 (Observed, §9.2): `VLLM_KV_CACHE_LAYOUT=HND` failed with `valid layouts: ['BLHNC']`, and UCX picked the RDMA device `mlx5_0` and failed, so we pinned `UCX_NET_DEVICES=eth0` and `UCX_TLS=tcp,cuda_copy`. The upstream NixlConnector page does not mention the HND/NHD layout (Reported absence, `https://docs.vllm.ai/en/latest/features/nixl_connector_usage/`, read 2026-11-12). Its default side-channel port is 5600 (Reported, same page); we used 5557.

Results (Observed on the mini, `f3/resultados/pd-20261105/`, full lines in `../examples/pd-bench-results.md`):

| | Aggregated c8 | P/D 1P1D c8 | Aggregated c32 | P/D 1P1D c32 |
|---|---|---|---|---|
| Requests per second | 8.39 | 5.01 | 12.81 | 6.94 |
| TTFT p50 / p95 | 0.21 / 0.50 s | 1.28 / 1.92 s | 0.34 / 1.62 s | 3.50 / 6.04 s |
| TPOT p50 / p95 | 4.9 / 8.2 ms | 3.1 / 3.5 ms | 14.1 / 32.5 ms | 4.4 / 19.3 ms |

Reading:

- Correctness held. P/D against aggregated differed by at most 0.0235 in logprob on matching tokens, the same order as cache on against cache off (Observed, `f3/resultados/pd-20261105-logprobs.txt`). The KDA state crossed the connector without visible error.
- TPOT got smoother (p95 32.5 to 19.3 ms at c32), which is what P/D is for.
- The KV really moved: the decode side computed 1 token and received 17,707 (and 40,299) tokens through `external_kv_transfer` (Observed, §9.2).
- Throughput fell about 46% at c32 (12.81 to 6.94 req/s) on the same 2 GPUs. The prefill GPU ran 121k prompt tok/s, the same per-GPU rate as aggregated, and the decode GPU was nearly idle (Observed, §9.2).
- TTFT rose 4 to 10 times. Where it went (two proxy hops, prefill in `--enforce-eager`, NIXL handshake, queue) is Unknown. A single request took 2.18 s in P/D against 1.63 s and 1.99 s aggregated (17.7k and 40.3k tokens), not growing with size (Observed, §9.2).
- The mini's decode costs almost nothing, so the mini shows the mechanism and the correctness, not the outcome on the real model (Inferred).
- 2P1D and other ratios were not tested.

## Why P/D is not first

1. Upstream says it does not improve throughput (Reported, above). Our cost per session depends on throughput at the SLO.
2. The fork already protects decode: with `--prefill-compute-share 0.4`, decode held about 15 ms per token while eight 128K prompts were prefilled on R1 (Observed, §12.2). Smoother ITL is the main thing P/D would buy.
3. A replica is already 4 GPUs (TP4); P/D at least doubles the smallest deployment (Inferred, §3).
4. P/D shrinks the KV pool on the decode side for the same GPU count, and our agent workload is KV-heavy (Inferred, doc 04 §5.2).
5. The llm-d GLM-5.2 gains on H200 came from CPU offload and MTP; their P/D numbers (3P1D) have no matched aggregated control (Reported, `https://llm-d.ai/blog/serving-glm-5-2-agentic-workloads-on-llm-d`, read 2026-11-12; doc 04 §5.2).
6. Nothing in our agent levels pointed to decode interference. Per-stream decode stayed in the SLO; levels failed on TTFT p95 of cold or queued prompts (Observed, `../examples/agent-levels.md`), which P/D makes worse, not better, unless prefill capacity is added.

## What would justify it

All of these, in order:

1. A measurement on the real model, with the fork's flags, that shows TPOT or ITL p95 above the SLO caused by long prefills, after a smaller `--max-num-batched-tokens` (2048 or 3072) was tried (Hypothesis, doc 04 §5.2).
2. NIXL (or another connector) working on the fork with GLM-5.3-Flash at TP4, including the KDA state and the `request_boundaries` checkpoints. Never tested (Unknown).
3. A P:D ratio sweep (1P1D, 2P1D, 1P2D) against a matched aggregated control on the same GPU count, priced in sessions per US$/h at the SLO.
4. Same GPU type for P and D first. Mixing SM120 and SM100 needs matching KV layouts (Hypothesis, untested, §3).

## Transfer options

| Transport | Status for us | Source |
|---|---|---|
| NIXL over UCX TCP | Worked on the mini, Nebius, no RDMA | Observed, §9.2 |
| NIXL over UCX RDMA | Not available on the Nebius RTX VMs (UCX failed on `mlx5_0`) | Observed, §9.2 |
| NIXL over libfabric on AWS EFA | Untested | see below |
| LMCache P2P or PD mode | Untested; LMCache does not document EFA | see below and `../../kv-cache-tiers/references/lmcache-fork.md` |

llm-d calls NIXL over TCP "extremely slow, for local development" (Reported, §3).

### AWS EFA and NIXL (Reported, read 2026-11-12)

- G7e: `g7e.12xlarge`, `.24xlarge` and `.48xlarge` support RDMA read and write and GPUDirect RDMA; `g7e.8xlarge` supports RDMA but not GPUDirect RDMA. EFA traffic "can't cross Availability Zones or VPCs" (`https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html`). Network: 400 Gbps on `.12xlarge`, 800 on `.24xlarge`, 1,600 on `.48xlarge` (`https://aws.amazon.com/ec2/instance-types/g7e/`).
- AWS supports EFA with NIXL 1.0.0 and later and libfabric 1.21.0 and later. The AWS guide builds NIXL with `-Dlibfabric_path=/opt/amazon/efa`, tests with `nixlbench --backend LIBFABRIC --initiator_seg_type VRAM`, and runs vLLM with `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both","kv_buffer_device":"cuda","kv_connector_extra_config":{"backends":["LIBFABRIC"]}}'` (`https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start-nixl.html`). Note that the vLLM NixlConnector page calls `kv_both` deprecated for this connector and recommends `kv_producer` and `kv_consumer`, as we used.
- The NIXL libfabric plugin says "GDR (GPU Direct RDMA) support is currently required" (`https://github.com/ai-dynamo/nixl/blob/main/src/plugins/libfabric/README.md`). With the table above, VRAM-to-VRAM transfer over EFA likely needs `g7e.12xlarge` or larger, which rules out `g7e.8xlarge` for P/D (Inferred, untested).
- llm-d: "UCX does not support EFA natively"; NIXL uses the libfabric backend on EFA (`https://llm-d.ai/docs/0.7/resources/rdma`).
- vLLM NixlConnector: `kv_load_failure_policy` defaults to `"fail"`; `"recompute"` recomputes failed blocks on the decode side and may degrade performance (`https://docs.vllm.ai/en/latest/features/nixl_connector_usage/`).

What EFA changes: it removes the "no RDMA" reason that made NIXL slow on Nebius. It does not touch reasons 1 to 6 above. Our target `g7e.24xlarge` is one 4-GPU replica, so P/D across two instances would also double the instance count (Inferred). Whether NIXL with libfabric works with the fork on SM120 is Unknown (`docs/06-aws-implementation-plan.md` open question 4).

### LMCache as the transfer layer

LMCache has a P/D mode in its legacy in-process configuration (`enable_pd`, `transfer_channel` such as `"nixl"`, `pd_role` sender or receiver, `nixl_backends` default `["UCX"]`) and a P2P path in MP mode (`--p2p-advertise-url`, `--p2p-transfer-engine nixl`, which "also requires `--coordinator-url`") (Reported, `https://docs.lmcache.ai/api_reference/configurations.html`, `https://docs.lmcache.ai/mp/configuration.html`, `https://docs.lmcache.ai/cli/server.html`). No LMCache page we read mentions EFA or libfabric (Reported absence). Our fork image runs LMCache in MP mode with `engine_driven` transfer only (Observed, `../../kv-cache-tiers/examples/lmcache-log-lines.md`).
