---
description: Qualify a GPU host before measuring or reserving it (topology, P2P, driver, all-reduce, C32 decode)
argument-hint: <ssh target or instance id>
---

Qualify the host `$ARGUMENTS` for the GLM-5.3-Flash replica. Load the `inference-benchmarking` and `vllm-fork-serving` skills first.

Steps, in order. Stop at the first failure and report it.

1. Record the host facts in a new result directory: `nvidia-smi` (GPU model and edition, driver), `nvidia-smi topo -m`, `nvidia-smi topo -p2p r`, CPU model, RAM, free disk and its read speed, provider, location, hourly price and the date.
2. Fail if `topo -p2p r` is not OK between all 4 GPUs. Why: the B12X PCIe all-reduce needs P2P; without it decode drops several times (docs/02).
3. Start the production profile and check the server log for the KV cache size line and `Using B12X PCIe all-reduce`. Fail if either is missing.
4. Run the short decode test at C32. Fail below 1,400 tok/s. Why: host 48294 delivered 296 tok/s at C32 with the same software, against 1,578 on host 157204 (ARQUITETURA.md §29.10).
5. Report: pass or fail, each value with its evidence label, the result path, and whether the instance is still running (and its cost per hour). Do not run the agent levels or the quality gate here.

Starting an instance costs money: confirm before creating one.
