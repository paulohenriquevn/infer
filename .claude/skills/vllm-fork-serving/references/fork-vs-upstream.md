# The local-inference-lab fork against upstream vLLM

What the fork adds, where upstream stands, how far apart they are, and how to recheck it. Decision 1 of `../SKILL.md` (use the fork) rests on this file.

Labels: Observed (path or command we ran), Reported (named source, URL, read 2026-11-12), Inferred, Hypothesis, Unknown. GitHub facts marked "GitHub API, 2026-11-12" come from `gh api` calls listed at the end; they are Reported (GitHub states them) and reproducible.

## What we run

| Item | Value | Source |
|---|---|---|
| Image | `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` | Observed, launch scripts |
| Image digest | `sha256:c14295c214f6126f0fc362f3e6073933a2125de9fc35b938e43842a5dcc40e38` | Observed, project research notes, not published (version manifest written when the image was extracted) |
| vLLM in the image | `0.1.dev21830+g8244d1c44` | Observed, server log `Initializing a V1 LLM engine (v0.1.dev21830+g8244d1c44)` |
| Fork commit | `8244d1c44348ae8a5bbfc9f1b607021652283ed4`, 2026-10-15, "Merge pull request #1031 ...", tip of branch `dev/karmic-kraken` (no commits after it on 2026-11-12) | GitHub API, 2026-11-12 |
| FlashInfer (contains b12x) | `0.7.1+lil.cu134.sm120.g6023d031be8e`, commit `6023d031be8e32b4b8a749dbb5d17d7d246b939b`, branch `canon/kk-flashinfer-main-csf3` of `local-inference-lab/flashinfer` | Observed, project research notes, not published |
| LMCache | `0.5.3.dev453+lil.cu134.g8ef537d6481b`, commit `8ef537d6481b0d7c93277118ffcc6bf7e68d1b22` (2026-10-11, merge of fork PR #112 `fix/mp-preemption-resume-load`) of `local-inference-lab/LMCache` | Observed, log banner and research notes; commit confirmed by GitHub API |
| Other packages | torch `2.14.0a0+4fdf77b940.nv26.8`, triton `3.8.0+git4c7e62b7.nv26.8`, InstantTensor 0.1.9, nvidia-cutlass-dsl 4.6.2, transformers 5.15.0, xgrammar 0.2.6, safetensors 0.8.0 | Observed, project research notes, not published |

## What the fork adds

| Feature | Fork | Upstream status | Evidence |
|---|---|---|---|
| B12X kernels: sparse MLA attention, MoE (W4A16, A4 prefill), dense GEMM, KDA, mHC | Yes, through FlashInfer `experimental/b12x` | Upstream `main` now has `vllm/v1/attention/backends/b12x.py` and merged b12x PRs since August 2026 (for example #53326 on 2026-08-25, #59604 on 2026-10-13, #63012 on 2026-11-04, #64765 "Use the b12x package shipped with flashinfer-python" on 2026-11-12). Upstream v0.32.0 had none (Observed, §10.3). How much of the fork's b12x path upstream covers is Unknown | GitHub API, 2026-11-12; `ARQUITETURA.md §10.3` |
| B12X PCIe one-shot all-reduce (`VLLM_ENABLE_PCIE_ALLREDUCE`) | Yes | No hit for `VLLM_ENABLE_PCIE_ALLREDUCE` in GitHub code search of `vllm-project/vllm` on 2026-11-12 (code search can lag) | GitHub search |
| Prefill lanes: `--prefill-compute-share`, `--max-parallel-prefills` | Yes (fork `vllm/config/scheduler.py`) | Not on the upstream engine args page; no code search hit | upstream docs, GitHub search |
| `--prefill-schedule-interval` | Yes | Now in the upstream engine args page ("Only admit prefill once every N engine steps", default 1). Upstream v0.32.0 did not have it (§10.3) | `https://docs.vllm.ai/en/latest/configuration/engine_args.html`, read 2026-11-12 |
| `--recurrent-checkpoint-policy`, `prefix_cache_retention_interval` | Yes (fork `vllm/config/cache.py`) | Not on the upstream engine args page | upstream docs |
| GLM-5.3 split cache pages (`VLLM_GLM53_SPLIT_TARGET_BLOCK_SIZE`) | Yes | Unknown | fork `vllm/platforms/interface.py` |
| GLM-5.3 KDA path `vllm/models/glm5next/nvidia/kda.py` (B12X recover-SSM, gate side stream), FlashKDA with an SM120 patch | Yes | Absent from v0.33.0 (§26.5). Open upstream PR #66551 "[GLM-5.3-Flash] KDA RecoverSSM with the deferred verify" | `ARQUITETURA.md §26.5`; GitHub search |
| DCP for this model with sparse MLA and the C4 indexer gather (`VLLM_B12X_MLA_CKV_GATHER`) | Yes | Upstream has generic DCP (`--decode-context-parallel-size`, `--dcp-comm-backend`); for GLM-5.3 sparse MLA, Unknown. The vLLM GLM-5.3-Flash recipe does not mention DCP | upstream docs; recipe |
| CSF-compressed NVFP4 scales | Yes | Open upstream PR #64753 "Keep CSF-compressed NVFP4 expert scales resident on B12X"; NVIDIA's FP4-Local card says "upstream vLLM support for this format has not yet landed" | GitHub search; `https://huggingface.co/nvidia/GLM-5.3-Flash-FP4-Local` |
| LMCache fork with its own DCP (`dcp_size`, per-rank fragments) and `LMCacheRecurrentCheckpointConnector` | Separate process | Upstream LMCache differs; details in the `kv-cache-tiers` skill | Observed, image extraction (§25.1), server log |
| Launcher `runtime.launcher` with `--print-command` and model presets | Image only | n/a | Observed, `bench/server-vllm-lmcache-direct.sh` |
| 129 change records in `.lil/changes/` | Yes | n/a | Observed at `8244d1c` (§23.3); GitHub tree count 129 on 2026-11-12 |

Upstream also has, and we use: MTP speculative decoding, DCP, `--max-num-batched-tokens`, `--load-format instanttensor`, `--mamba-cache-mode` (deprecated for v0.34.0 upstream) (Reported, upstream docs; Observed for v0.32.0 in §10.3).

### Upstream PRs worth watching

Reported, GitHub search of `vllm-project/vllm`, 2026-11-12. State at that date.

| PR | Title | State |
|---|---|---|
| #62424 | [Rust Frontend] Add native GLM-5.3 / GLM-5.3-Flash chat rendering | merged 2026-10-30 (the recipe requires it) |
| #64765 | [Misc] Use the b12x package shipped with flashinfer-python | merged 2026-11-12 |
| #64767 | [Quantization] Load ModelOpt NVFP4 W4A16 token embeddings in mixed-precision checkpoints | merged 2026-11-11 |
| #64753 | [Quantization][MoE] Keep CSF-compressed NVFP4 expert scales resident on B12X | open |
| #62376 | [Bugfix][Attention] Accept split KV blocks in the b12x backend | open |
| #65208 | [Kernel] Add opt-in NVFP4 activations for long prefills to b12x NVFP4 W4A16 linears | open |
| #66551 | [GLM-5.3-Flash] KDA RecoverSSM with the deferred verify | open |
| #63387 | [Perf][Spec Decode][GLM-5.3] Specialized GLM-5.3 MTP drafter, with a post-forward CUDA graph | open |
| #66828 | [Model] Enable pipeline parallelism for GLM-5.3-Flash | open |
| #61243 | [HiSparse] GLM-5.3-Flash support | open |
| #48003 | [Bugfix] Fix corrupted output with FlashInfer + decode context parallelism | open |

Inferred: upstream is absorbing the b12x and CSF pieces. When #64753, #62376 and a PCIe all-reduce land upstream, re-evaluate running upstream vLLM with the QAD checkpoint. Until then the fork is the only stack that passed our gate.

## Distance from upstream

GitHub API compare, 2026-11-12 (Reported):

| Comparison | Fork ahead | Fork behind |
|---|---|---|
| `8244d1c44` against upstream `main` | 409 | 3,797 |
| against tag `v0.33.0rc3` (2026-11-02) | 409 | 2,439 |
| against tag `v0.32.0` (2026-10-18) | 409 | 1,512 |
| Merge base | `0f8fa53acf43a9a6a7a1f7e6b196950c78cd6d7a`, 2026-09-16 | |

The journal's counts (3,304 behind `main` on 2026-11-05 in §13.3; 3,222 in §22.1; 2,439 behind `v0.33.0` in §26.5) were taken on different dates and references (`docs/README.md`, contradictions table). Two findings from this recount:

- The 2,439 of §26.5 matches `v0.33.0rc3` exactly.
- The fork's default branch `main` is stale: its tip `47ccf6c` dates from 2026-08-30 and is 3,222 commits behind `8244d1c44`. Hypothesis: the §22.1 count of 3,222 compared the image commit with the fork's own `main`, not with upstream.

## Maintenance risk

- Volunteer maintainers. On 2026-11-12 the fork repository reports 320 open issues plus pull requests (GitHub API `open_issues_count`); §13.3 counted 316 issues on the fork and 128 on b12x.
- `local-inference-lab/b12x` is archived: "b12x has moved to FlashInfer", merged in FlashInfer #5767, commit `fc8fdc17f702371302a0ea780c604b099b927196` (Reported, `https://github.com/local-inference-lab/b12x`, read 2026-11-12). Kernel bugs now go to FlashInfer.
- B12X targets SM120. Another GPU generation loses the speed gain (§13.3).
- Porting an upstream scheduler or cache feature means redoing work in the files where the fork diverges most; FlashState was estimated at about 5 thousand lines (effort of weeks is a Hypothesis, §26.5).
- Every fork update is a rebase plus requalification through the gate (§22.1).
- The image repository `local-inference-lab/blackwell-llm-docker` declares no licence (GitHub API `license` null, 2026-11-12); the fork itself is Apache-2.0.

Conditions for using the fork (§13.3): pin image digest, vLLM commit and checkpoint revision; mirror the image in our registry; rebuild once from source on a CPU VM (not done); gate every change; clear the licences.

## How to recheck

All read-only, no credentials beyond a GitHub token (`gh auth status`):

```bash
# image commit, its date and branch tip
gh api repos/local-inference-lab/vllm/commits/8244d1c44 --jq '[.sha,.commit.author.date]|@tsv'
gh api 'repos/local-inference-lab/vllm/branches/dev%2Fkarmic-kraken' --jq '.commit.sha'
# distance from upstream main and from a release tag
gh api 'repos/local-inference-lab/vllm/compare/vllm-project:vllm:main...local-inference-lab:vllm:8244d1c44' \
  --jq '[.ahead_by,.behind_by,.merge_base_commit.sha]|@tsv'
gh api 'repos/local-inference-lab/vllm/compare/vllm-project:vllm:v0.33.0rc3...local-inference-lab:vllm:8244d1c44' \
  --jq '[.ahead_by,.behind_by]|@tsv'
# upstream progress on b12x and GLM-5.3
gh search prs --repo vllm-project/vllm b12x --merged --limit 20
gh search prs --repo vllm-project/vllm "GLM-5.3" --limit 20
# fork change records at the image commit
gh api 'repos/local-inference-lab/vllm/git/trees/8244d1c44348ae8a5bbfc9f1b607021652283ed4?recursive=1' \
  --jq '[.tree[]|select(.path|startswith(".lil/changes/"))]|length'
```

On 2026-11-12 these printed: `8244d1c44348ae8a5bbfc9f1b607021652283ed4 2026-10-15T15:50:07Z`; `8244d1c44348...` as branch tip; `409 3797 0f8fa53...`; `409 2439`; 129 change records (Observed).

To read what a fork env var or flag does, fetch the file at the image commit, for example:

```bash
gh api -H 'Accept: application/vnd.github.raw' \
  'repos/local-inference-lab/vllm/contents/vllm/envs.py?ref=8244d1c44348ae8a5bbfc9f1b607021652283ed4' | grep -n -B4 '"VLLM_ENABLE_PCIE_ALLREDUCE"'
```
