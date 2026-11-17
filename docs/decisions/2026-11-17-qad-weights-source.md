# QAD weights source: the NVIDIA copy

Date: 2026-11-17. Status: decided.

## Context

Every quality and speed result for the serving profile used `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be`. That repository is under the Local Inference Lab License 1.0: no reupload (mirrors and container registries included), an attribution notice at the top of the main page of any service that runs the model, automatic termination on breach, Kentucky law (Observed, `LICENSE`, read 2026-11-17).

NVIDIA publishes `nvidia/GLM-5.3-Flash-FP4-Local`. At revision `f83de1b0169cc3376a25563da66e3fc077e53591` its runtime files are identical to `dec48abd33`: the 36 `.safetensors` shards (LFS sha256), `config.json`, `model.safetensors.index.json`, tokenizer files, `chat_template.jinja`, `generation_config.json` and `processor_config.json`. Only `README.md` and the licence files differ (Observed, Hugging Face API, 2026-11-17).

## Options

| Option | For | Against |
|---|---|---|
| Keep the LIL copy | No change | Reupload ban blocks a private S3 mirror or AMI snapshot as worded; mandatory notice on the product page; termination without cure |
| NVIDIA copy at `f83de1b016` | NVIDIA Open Model Agreement: commercial use stated, perpetual and irrevocable grant, no reupload ban, no service-page notice, termination only on litigation against the work (Observed, agreement text, release date April 2, 2026, terms version March 9, 2026) | Broad indemnity of NVIDIA against third-party claims from our use and outputs; Delaware law, Santa Clara courts; the same bytes were first published by LIL under its own licence |

## Decision

Download the QAD weights from `nvidia/GLM-5.3-Flash-FP4-Local` at revision `f83de1b0169cc3376a25563da66e3fc077e53591`. The `bench/` server and host preparation scripts and the AWS bootstrap draft use it.

## Why

The licence fits a hosted service for about 10,000 developers with fewer operational constraints, and the files that run are byte for byte the ones that passed the quality gate, so the gate result carries over without a new run (Inferred from the file comparison). Decided by the project owner on the recommendation in the research report of 2026-11-17.

## Conditions

1. Phase 1 checks the sha256 of every downloaded shard against the list for `dec48abd33` (`06-aws-implementation-plan.md`, phase 1, criterion 6).
2. Legal review before production: the indemnity clause, and which licence binds bytes that LIL published on 2026-10-07 and NVIDIA on 2026-10-14, both uploaded by the same author.
3. A different NVIDIA revision is a different checkpoint and goes through the gate. The current `main` (`76348ddb2b`) already holds different weights (QAD2).

## What would make us revisit it

Legal review rejecting the indemnity or the provenance, a change to the NVIDIA repository's licence, or phase 2 choosing the QAD2 weights.
