# Networking and EFA on G7e

What Elastic Fabric Adapter (EFA) is, how it is set up on G7e according to AWS, what it could enable for us (KV transfer between replicas, prefill/decode disaggregation) and why phases 1 to 3 do not use it.

Labels: Reported (AWS page, URL and read date), Observed (our measurement or read), Inferred (reasoning shown), Unknown.

## Decision for phases 1 to 3

No EFA. Phase 1 and 2 use one instance; the replica's 4 GPUs talk over PCIe inside it, so EFA carries nothing. Phase 3 puts two replicas behind the llm-d router over plain TCP (HTTP requests and, in the precise mode, KV events); it needs no RDMA. Why:

- P/D disaggregation is not in the first design (decided, docs/04 §5, `CLAUDE.md`). On the mini test model, 1 prefill + 1 decode over NIXL/TCP smoothed TPOT and cut throughput by about 46% against two aggregated replicas (Observed on the mini, §9.2, `f3/resultados/pd-20261105/`). Nothing was tested on the real model.
- vLLM documentation says "disaggregated prefill DOES NOT improve throughput" (Reported in docs/04 §5.2).
- With about 96% prefix reuse per agent turn, new prefill per turn is small (Observed on the mini and in the Vast runs: cache 96.5% to 97.2% in the agent levels, `f3/resultados/vast-20261111/resumo.md`), which favours prefilling on the decode replica (Inferred, docs/04 §5.2).
- EFA adds work (an EFA-enabled AMI or DLAMI, the self-referencing security group, network-card layout, NCCL/NIXL plugin checks) that buys nothing until a cross-instance KV path is in the design (Inferred).

When EFA comes back: if phase 4 shows the RAM KV tier pays off and a shared or peer KV tier between replicas is proposed, or if a P/D experiment is approved. Both need their own decision record.

## What EFA is

Reported, EFA user guide `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html`, read 2026-11-12:

- A network device that bypasses the kernel through Libfabric, with the Scalable Reliable Datagram (SRD) protocol for "low-latency, reliable transport".
- Supported libraries: NCCL 2.4.2 and later, NIXL 1.0.0 and later ("NIXL integrates with Libfabric 1.21.0 and later"), Open MPI 4.1 and later, Intel MPI 2019 Update 5 and later, DeepEP v2.
- Interface kinds: ENA (IP only), EFA with ENA (IP plus EFA device), EFA-only (EFA device only; cannot be the primary interface).
- EFA is free: "available as an optional Amazon EC2 networking feature that you can enable on any supported instance at no additional cost".

Limitations that matter for a cell design (same page):

- "EFA traffic can't cross Availability Zones or VPCs." Normal IP traffic on the ENA side of an EFA interface still can.
- "EFA traffic is not routable."
- One EFA per network card on instance types with several cards.

### G7e support

Reported, EFA user guide, Nitro v6 (EFA v4) table, read 2026-11-12:

| Size | RDMA read | RDMA write | Accelerator Data Transfer (GPUDirect RDMA) | Accelerator Command Initiation (GPUDirect Async) |
|---|---|---|---|---|
| `g7e.8xlarge` | yes | yes | no | no |
| `g7e.12xlarge` | yes | yes | yes | yes |
| `g7e.24xlarge` | yes | yes | yes | yes |
| `g7e.48xlarge` | yes | yes | yes | yes |

Network cards: 2 on `g7e.24xlarge`, 4 on `g7e.48xlarge` (Reported, instance types spec). So at most 2 and 4 EFA devices (Inferred from "one EFA per network card"; matches the API read of 2026-11-04 in `NOTAS.md`, Observed).

The G7e product page says up to 1,600 Gbps "with EFA and cluster placement groups", and GPUDirect RDMA "with EFAv4 in EC2 UltraClusters" (Reported, `https://aws.amazon.com/ec2/instance-types/g7e/`, read 2026-11-12). How the 800 Gbps of a `g7e.24xlarge` splits between its 2 cards and between EFA and IP traffic is not documented for G7e (Unknown); AWS documents such splits only for P5, P6-B200, P6e-GB200 and P6-B300.

A known DLAMI issue: multinode workloads may see errors on `g7e.8xlarge`; AWS suggests `g7e.12xlarge` (Reported, DLAMI Ubuntu 24.04 page, read 2026-11-12). Not our size.

## Setup steps, if EFA is ever used

Reported, `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start-nccl.html` and `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-acc-inst-types.html`, read 2026-11-12. Not run by us.

1. Security group: inbound and outbound "All traffic" with the security group itself as source and destination. AWS: "The self-referencing inbound and outbound rules ... are mandatory for EFA to function. Without these rules, EFA traffic between instances will be blocked and NCCL communication will fail." Keep SSH restricted to one address; the AWS example opens SSH to any IPv4 and labels it "for testing purposes only".
2. Subnet: required; "If you do not select a subnet, you can't enable the instance for EFA."
3. Network interfaces on a multi-card type: primary interface on network card 0, device 0 as ENA; EFA-only on card 0 device 1; for each other card, EFA-only on device 0 (and optionally ENA on device 1). In the launch template API this is `InterfaceType=interface` and `InterfaceType=efa-only`. In the Terraform launch template resource, `interface_type = "efa"` creates EFA with ENA (Reported, `https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/launch_template.html.markdown`, read 2026-11-12); whether the provider accepts `efa-only` was not confirmed in that page (Unknown; check the provider changelog before writing it).
4. Placement: a cluster placement group is recommended, "not an absolute requirement". It places instances in one AZ. Capacity Blocks do not support placement groups (Reported, Capacity Blocks page), but Capacity Blocks do not offer G7e anyway (see `quotas-and-purchase.md`).
5. Software: the DLAMI base GPU image already ships EFA installer 1.51.0, aws-ofi-nccl 1.22.0, libfabric 2.7.0amzn2.0 and GDRCopy (Reported, DLAMI 20261027 release notes). On a plain OS, the AWS steps install the open driver, GDRCopy, then `efa_installer.sh -y --mpi=openmpi5`, which places Libfabric in `/opt/amazon/efa`, the aws-ofi-nccl plugin in `/opt/amazon/ofi-nccl` and Open MPI in `/opt/amazon/openmpi`.
6. Check: `fi_info -p efa -t FI_EP_RDM` lists the EFA interfaces. With NCCL, the log line `NET/OFI Selected Provider is efa` confirms EFA carries the traffic.
7. Containers: the fork image does not contain the EFA user-space stack as far as we know (Unknown; list `/opt/amazon` inside the image). AWS has a page for installing EFA inside a container (`efa-installer-containers.md`, not read).

## What EFA could enable for us

All Inferred or Hypothesis; nothing tested.

| Use | Mechanism | Our evidence | Status |
|---|---|---|---|
| P/D disaggregation across instances | vLLM KV connector over NIXL with Libfabric/EFA instead of UCX/TCP | Mini model: works over TCP, 46% less throughput (§9.2); on Nebius RTX VMs there was no RDMA and llm-d calls NIXL over TCP "extremely slow, for local development" (Reported, docs/04 §5.2) | Out of the first design |
| Peer KV sharing between replicas (llm-d `p2p-kv-cache-sharing`, LMCache P2P) | LMCache transfer channel between engines; depends on precise routing | LMCache P2P does not require RDMA; `mooncake_te` uses TCP by default (docs/04 table, §16.3) | Off until per-flow TCP bandwidth is measured |
| Shared KV tier on FSx for Lustre with GPUDirect Storage | GDS over EFA to the file system | FSx documents up to 1,200 Gbps per client with "EFA with GDS" (Reported, `storage-for-weights.md`) | Not evaluated |
| Expert parallelism across instances | DeepEP v2 over EFA | The replica is TP4 inside one instance | Not relevant to the decided replica |

Why EFA matters more on AWS than it did on Nebius: the Nebius RTX VMs had no RDMA, which is why P2P KV transfer and P/D were ruled out there (docs/06). On G7e that platform limit is gone (Reported), so the remaining reasons against P/D are the measured throughput cost and the untested real model.

## Plain networking in phases 1 to 3

- The fork's server scripts set `NCCL_IB_DISABLE=1`, `NCCL_NET_PLUGIN=none` and `NCCL_P2P_LEVEL=SYS` (Observed, `bench/server-vllm-dcp1.sh`): NCCL is configured for one host with PCIe peer access and no network plugin. Using EFA for anything would mean changing these, which reruns the gate (rule 2).
- Phase 1 and 2: the harness runs on the same instance as the server, against `localhost:8000`. No inbound port needs to be open. Use SSM Session Manager or SSH from one address (see `security-and-cost-guardrails.md`).
- Phase 3: the router (llm-d EPP plus Envoy, standalone, file discovery, Reported in LMCache PR 5307 validation, §25.1) can run on one of the GPU instances or on a small CPU instance in the same VPC and AZ. Replica-to-router traffic is HTTP on the private network; allow port 8000 from the router's security group only. KV events in the precise mode are ZMQ on a port set in the vLLM flags (see the `llm-d-routing` skill; the port is not fixed here).
- Keep both replicas in one AZ: no cross-AZ data charges and lower latency (Inferred). Which AZ has two G7e available at once is Unknown until launch.
