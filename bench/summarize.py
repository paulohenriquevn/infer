#!/usr/bin/env python3
"""Summary of the engine comparison (SGLang x vLLM) on the same 4 RTX VM.

Usage: python3 summarize.py --price 7.20 results/<date>-vllm results/<date>-sglang
Each directory comes from run_benchmark.sh: engine.txt, needle.json (and needle-c16.json), gsm8k.json and
agents-<N>.json (agents scenario of llm_decode_bench with N concurrent agents). Directories written before
the harness was translated use motor.txt and agentes-<N>.json; both spellings are read.

Primary metric (docs/01-product-demand-and-slo.md, "SLO and primary metric"): the largest N of agents at
which that level and every smaller one meet the SLO, divided by the replica price per hour. SLO per level:
zero turn errors, TTFT p95 of cached turns (turn >= 1) up to 5 s and per-stream speed p50 (output tokens
after the first, per second) of at least 30 tok/s.

Quality gate (docs/03-serving-engine-and-benchmarks.md, "Quality gate procedure"): each needle is compared
with the reference (default: vLLM with DCP4, 3 errors in 500) by a one-sided Fisher exact test; it fails
with p < 0.05.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from math import comb
from pathlib import Path


class MissingCacheReport(Exception):
    """The server did not report prompt_tokens_details.cached_tokens."""


@dataclass(frozen=True)
class Slo:
    ttft_p95_s: float = 5.0
    tps_p50: float = 30.0
    min_turns: int = 1   # cached steady-state turns below this: insufficient sample


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(v) - 1)
    return v[f] + (v[c] - v[f]) * (k - f)


def evaluate_agents(scenario: dict, slo: Slo) -> dict:
    m = scenario["metrics"]
    log = m.get("turn_log", [])
    # a turn cut by the end of the level (stopped) or aborted did not finish: it has no usage and does not count
    interrupted = [t for t in log if t.get("stopped") or t.get("aborted")]
    turns = [t for t in log if t.get("ttft_s") is not None and t.get("seconds")
             and not (t.get("stopped") or t.get("aborted"))]
    # Steady state: only turns sent after the last agent finished turn 0. Before that, the cold
    # prefills of every agent (40K to 100K tokens each) queue together, which is an artifact of the
    # scenario's simultaneous start, not of real use.
    turn0_ends = [t["send_s"] + t["seconds"] for t in turns if t.get("turn", 0) == 0 and t.get("send_s") is not None]
    agents = m.get("agents") or len({t.get("agent") for t in log})
    if len(turn0_ends) < agents:
        steady_start = None   # some agent did not even finish turn 0: the whole level was still a cold queue
        cached = []
    else:
        steady_start = max(turn0_ends) if turn0_ends else 0.0
        cached = [t for t in turns if t.get("turn", 0) >= 1 and (t.get("send_s") or 0.0) >= steady_start]
    # SGLang omits cached_tokens when nothing came from the cache (always on turn 0, and when the
    # prefix was evicted); vLLM reports 0. A level where no turn reports it means the server
    # was started without cache reporting, and its numbers cannot be trusted.
    if cached and all(t.get("cached_tokens") is None for t in cached):
        raise MissingCacheReport(
            f"none of {len(cached)} cached turns has cached_tokens; start SGLang with "
            "--enable-cache-report or vLLM with --enable-prompt-tokens-details")
    cached = [dict(t, cached_tokens=t.get("cached_tokens") or 0) for t in cached]
    ttft = [t["ttft_s"] for t in cached]
    tps = [t["completion_tokens"] / (t["seconds"] - t["ttft_s"])
           for t in cached if t.get("completion_tokens") and t["seconds"] > t["ttft_s"]]
    recomputed = [t["prompt_tokens"] - t["cached_tokens"] for t in cached]
    prompt = sum(t["prompt_tokens"] for t in cached)
    cache = sum(t["cached_tokens"] for t in cached)
    r = {
        "turns": len(turns),
        "interrupted": len(interrupted),
        "steady_turns": len(cached),
        "steady_start_s": steady_start,
        "insufficient_sample": len(cached) < slo.min_turns,
        "errors": m.get("turn_errors", 0),
        "ttft_p95_s": percentile(ttft, 95),
        "tps_p50": percentile(tps, 50),
        "recomputed_p50": percentile(recomputed, 50),
        "recomputed_p90": percentile(recomputed, 90),
        "cache_pct": 100 * cache / prompt if prompt else None,
    }
    r["passes"] = (r["errors"] == 0 and not r["insufficient_sample"] and r["ttft_p95_s"] is not None and r["ttft_p95_s"] <= slo.ttft_p95_s
                   and r["tps_p50"] is not None and r["tps_p50"] >= slo.tps_p50)
    return r


def sessions_in_slo(levels: dict[int, bool]) -> int:
    """Largest N that passes with every smaller level passing; a level that passes after another
    one failed is noise and does not count."""
    best = 0
    for n in sorted(levels):
        if not levels[n]:
            break
        best = n
    return best


NEEDLE_ALPHA = 0.05


@dataclass(frozen=True)
class NeedleReference:
    errors: int
    total: int

    @classmethod
    def from_text(cls, text: str) -> "NeedleReference":
        m = re.fullmatch(r"(\d+)/(\d+)", text.strip())
        if not m or int(m.group(2)) == 0 or int(m.group(1)) > int(m.group(2)):
            raise ValueError(f"needle reference must be errors/total, e.g. 3/500: {text!r}")
        return cls(int(m.group(1)), int(m.group(2)))


def fisher_one_sided(errors: int, total: int, ref_errors: int, ref_total: int) -> float:
    """P of at least `errors` errors in `total` runs if the error rate were the reference's."""
    k, n = errors + ref_errors, total + ref_total
    return sum(comb(total, x) * comb(ref_total, k - x) for x in range(errors, min(k, total) + 1)) / comb(n, k)


def passes_needle(needle: dict, ref: NeedleReference) -> bool:
    s = needle["selected_summary"]
    if s["attempted"] <= 0:
        return False
    errors = s["attempted"] - s["correct"]
    return fisher_one_sided(errors, s["attempted"], ref.errors, ref.total) >= NEEDLE_ALPHA


def accuracy_pct(result: dict) -> float:
    s = result["selected_summary"]
    return 100 * s["correct"] / s["attempted"] if s["attempted"] else 0.0


# Output file names: current first, then the Portuguese names written before the harness was translated.
ENGINE_FILES = ("engine.txt", "motor.txt")
AGENTS_FILE_PATTERNS = (("agents-*.json", r"agents-(\d+)\.json$"), ("agentes-*.json", r"agentes-(\d+)\.json$"))


def read_engine(directory: Path) -> str:
    for name in ENGINE_FILES:
        f = directory / name
        if f.exists():
            return f.read_text().strip()
    raise FileNotFoundError(f"{directory}: none of {', '.join(ENGINE_FILES)} found")


def agents_level_files(directory: Path) -> dict[int, Path]:
    files: dict[int, Path] = {}
    for glob, pattern in AGENTS_FILE_PATTERNS:
        for f in sorted(directory.glob(glob)):
            n = int(re.search(pattern, f.name).group(1))
            if n in files:
                raise ValueError(f"{directory}: level {n} appears twice ({files[n].name} and {f.name})")
            files[n] = f
    return files


def summarize_engine(directory: Path, slo: Slo, price: float, ref: NeedleReference) -> dict:
    engine = read_engine(directory)
    # A run with AGENTS_ONLY=1 skips the gate: its directory has no needle.json or gsm8k.json.
    # The gate verdict is then None ("not run here") and must come from the first run of the same arm.
    gate_ran = (directory / "needle.json").exists()
    if gate_ran and not (directory / "gsm8k.json").exists():
        raise FileNotFoundError(f"{directory}: needle.json present but gsm8k.json missing; the gate did not finish")
    needle = json.loads((directory / "needle.json").read_text()) if gate_ran else None
    extras = [json.loads(f.read_text()) for f in sorted(directory.glob("needle-c*.json"))]
    gsm8k = json.loads((directory / "gsm8k.json").read_text()) if gate_ran else None
    levels = {}
    for n, path in sorted(agents_level_files(directory).items()):
        report = json.loads(path.read_text())
        scenarios = [c for c in report["scheduler"]["scenarios"] if c["scenario"] == "agents"]
        if len(scenarios) != 1:
            raise ValueError(f"{path}: expected one agents scenario, found {len(scenarios)}")
        levels[n] = evaluate_agents(scenarios[0], slo)
    if not levels:
        raise FileNotFoundError(f"{directory}: no agents-<N>.json files")
    sessions = sessions_in_slo({n: r["passes"] for n, r in levels.items()})
    needle_ok = all(passes_needle(n, ref) for n in [needle, *extras]) if gate_ran else None
    return {
        "engine": engine, "directory": str(directory),
        "needle_ok": needle_ok, "needle_pct": accuracy_pct(needle) if gate_ran else None,
        "gsm8k_pct": accuracy_pct(gsm8k) if gate_ran else None,
        # an arm that fails the quality gate serves wrong answers: its sessions do not count
        "levels": levels, "sessions_in_slo": sessions, "sessions_per_usd_h": 0.0 if needle_ok is False else sessions / price,
    }


def fmt(x, digits=1):
    # English number format (1,279.0). Reports written before 2026-11-12 used the Brazilian one (1.279,0).
    return "n/a" if x is None else f"{x:,.{digits}f}"


def table(summaries: list[dict]) -> str:
    lines = ["| Engine | Needle | gsm8k | Sessions in SLO | Sessions per US$/h |", "|---|---|---|---|---|"]
    for r in summaries:
        lines.append(f"| {r['engine']} | {'gate not run here' if r['needle_ok'] is None else fmt(r['needle_pct']) + '% ' + ('ok' if r['needle_ok'] else 'FAIL')} | "
                     f"{fmt(r['gsm8k_pct'])}{'%' if r['gsm8k_pct'] is not None else ''} | {r['sessions_in_slo']} | {fmt(r['sessions_per_usd_h'], 2)} |")
    lines += ["", "| Engine | Agents | Errors | Steady since (s) | Steady turns | TTFT p95 (s) | tok/s p50 per stream | Cache % | Recomputed p50 | Recomputed p90 | SLO |",
              "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in summaries:
        for n, a in sorted(r["levels"].items()):
            lines.append(f"| {r['engine']} | {n} | {a['errors']} | {fmt(a['steady_start_s'], 0)} | {a['steady_turns']} | {fmt(a['ttft_p95_s'], 2)} | {fmt(a['tps_p50'])} | "
                         f"{fmt(a['cache_pct'])} | {fmt(a['recomputed_p50'], 0)} | {fmt(a['recomputed_p90'], 0)} | "
                         f"{'pass' if a['passes'] else ('short sample' if a['insufficient_sample'] else 'fail')} |")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--price", type=float, required=True, help="US$ per hour of the replica (4 RTX)")
    ap.add_argument("--ttft-p95", type=float, default=Slo.ttft_p95_s)
    ap.add_argument("--tps-p50", type=float, default=Slo.tps_p50)
    ap.add_argument("--min-turns", type=int, default=20,
                    help="cached steady-state turns required per level (default 20)")
    ap.add_argument("--needle-ref", type=NeedleReference.from_text, default=NeedleReference(3, 500),
                    help="errors/total of the needle reference (default 3/500, vLLM with DCP4)")
    ap.add_argument("--json", type=Path, help="write the full summary as JSON")
    ap.add_argument("directories", nargs="+", type=Path)
    a = ap.parse_args(argv)
    if a.price <= 0:
        ap.error("--price must be positive")
    slo = Slo(a.ttft_p95, a.tps_p50, a.min_turns)
    summaries = [summarize_engine(d, slo, a.price, a.needle_ref) for d in a.directories]
    print(table(summaries))
    if a.json:
        a.json.write_text(json.dumps(summaries, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
