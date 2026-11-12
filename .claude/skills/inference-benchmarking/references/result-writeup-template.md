# Writing up a benchmark result

Read this before you write a benchmark number into `docs/`, a decision record, a PR description or a message that someone will use to decide. A filled-in example for a real run is `examples/writeup-dcp1-run1.md`.

Why a fixed template: the project revised its capacity numbers three times (§18.1, §24.3, §29.6) and found mixed-attempt directories, single runs quoted as capacity and prices without dates. Every field below exists because its absence caused one of those.

## Template

Copy it, fill every field, and write `Unknown` (with how to find out) where you do not have the value. Do not drop a field.

```markdown
## <arm name>: <one-line result>

Evidence: Observed (real model) | Observed (mini) | Inferred. Runs: <1 | 2>. Date of run: <YYYY-MM-DD>.

### Configuration
- Engine and image: <engine> `<image:tag>` (build `<version string from server.log>`)
- Checkpoint: `<repo>` at revision `<sha>`
- Profile: TP<n>, DCP<n>, MTP<k>, KV cache dtype <fp8>, `--max-num-seqs <n>`, cache mode <HBM only | LMCache L1 <GB>>
- Server script: `<server-*.sh>` (copied as `server.sh` in the result directory)
- Harness: llm-inference-bench `52216d7` + exact-history patch; `exact_history` = <true|false>

### Host
- Provider and machine: <Vast machine ID | AWS instance type and ID | Nebius VM>, region or location
- GPU: <4x RTX PRO 6000 Blackwell Server Edition>, power limit <W>
- Driver: <version>; P2P `topo -p2p r`: <all OK | ...>; `Using B12X PCIe all-reduce` in log: <yes | no>
- Small all-reduce (p2pmark, 256 B to 2 KiB): <us range>
- C32 decode (qualification): <tok/s> (threshold 1,400 with DCP1)
- Price: US$ <x>/h per replica, read <YYYY-MM-DD> from <source>

### Quality gate
- needle C8: <errors>/<runs>, one-sided p vs 3/500 = <p>
- needle C16: <errors>/<runs>, p = <p>
- gsm8k: <correct>/96 (manual threshold 94/96)
- Verdict: <ok | FAIL | gate not run here (agents-only; gate from <dir>)>

### Speed
- Decode C1 / C8 / C16 / C32: <tok/s> (`decode.json`, `results[].aggregate_tps`)
- Cold prefill 8K / 32K / 128K TTFT: <s>
- Server ready: <s> (`ready-time.txt`), kernel cache <warm | cold>

### Agent levels (summarize.py, steady-state cached turns)
| Agents | Duration (s) | Steady since (s) | Steady turns | Errors | TTFT p95 (s) | tok/s p50 | Cache % | SLO |
|---|---|---|---|---|---|---|---|---|

- Sessions inside the SLO: <N> (lower bound; next tested level <M>)
- Margin to the SLO at N: TTFT p95 <x> s vs 5 s; tok/s p50 <y> vs 30
- Sessions per US$/h: <N / price>

### Reproduction
- Result directory: `<path>` (archive: `f3/resultados/...`)
- Harness command: `<env vars> bash run_benchmark.sh` or `bash vast.sh run <engine> <arm>`
- Summary command: `python3 summarize.py --price <x> --needle-ref 3/500 <dir>`

### Caveats
- <single run | mixed attempts in directory | host not qualified | levels interrupted | ...>
- What this result does not show: <...>
```

## Field rules and why

| Field | Rule | Why |
|---|---|---|
| Evidence label | Observed only for numbers read from a result file; say real model or mini | The random-weight mini model gave routing results that do not transfer to speed or capacity |
| Runs | Write 1 or 2. Never call a single run "guaranteed" or "capacity" without the words "one run" | DCP4 at 16 agents passed with 0.23 s margin, then failed at 5.20 s (§29.6) |
| Image build | The version string from `server.log` (`0.1.dev21830+g8244d1c44` for `karmic-kraken-20261016`) | Tags can move; the build string identifies the binary |
| Checkpoint revision | Full SHA | NVIDIA's NVFP4 revisions `09b04e5e` and `1d00738` gave 22% and 12% needle errors on the same engine (§29.5) |
| `exact_history` | From `agents-<N>.json` | Without it, SGLang runs lose cache on every turn and the A/B measures the harness |
| Driver, P2P, all-reduce, C32 | All four, every host | Host 48294 had the same listing and was 5 times slower (§29.10); 157204's fast all-reduce is the likely reason for its 22% better C1 than Nebius R1 (Inferred, §29.2) |
| Price with date and source | Price of the machine where it ran, per 4-GPU replica | The metric divides by it; prices move (Nebius list rose 17% to 21% on H100 and B300 on 2026-10-01, Reported in the 10k report) |
| needle p-values | Each file separately, one-sided, against the stated reference | `summarize.py` judges each file; pooled numbers must be labelled as pooled |
| gsm8k | Raw count | `summarize.py` does not gate on it |
| Decode field | `aggregate_tps` | It is the field the qualification rule uses |
| Duration per level | From `metadata.settings.agents_duration` | A 420 s level and a 1,200 s level are not the same test; `vast-vllm-r1/` mixes both |
| Steady since, steady turns | Always | A level with few steady turns has a p95 resting on a handful of turns |
| Sessions in SLO | Say "lower bound" and the next tested level | Only 8, 16, 24 and 32 were tested |
| Margin | Absolute seconds to the 5 s target | Margins under about 0.5 s did not reproduce |
| Directory and command | Both | Lets a reviewer rerun `summarize.py` and get the same table |

## Where results go

- Raw result directories: `results/` (ignored by git), then the published results archive. Never commit result files to this repository.
- Consolidated numbers: `docs/03-serving-engine-and-benchmarks.md` (engine and profile), `docs/05-capacity-cost-and-providers.md` (per-provider economics). When a new number supersedes an old one, add a row to the contradictions table in `docs/README.md`.
- Capacity per replica feeds the fleet model of the `capacity-and-cost` skill. Pass both runs and the price date.

## Wording

- Put the number and its context in the same sentence: "vLLM DCP1, 24 agents inside the SLO, TTFT p95 4.93 s, one run (Observed (real), Vast host 157204, Nevada, driver 615.71.09, 2026-11-11, US$ 5.61/h, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1`)".
- Use "sessions inside the SLO per US$/h" for the primary metric. Never compare it with the 12.3 sessions per US$/h of §12.4, which counts HBM capacity without an SLO.
- English number format (`1,580`). When quoting the journal or `resumo.md`, convert `1.279,0` to `1,279.0` and say the source used the Brazilian format.
- No em or en dashes; run `python3 .claude/tools/lint_prose.py <file>` before saving.
