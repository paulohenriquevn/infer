#!/usr/bin/env python3
"""Closed-loop load of cold, long prompts against one or more targets (round-robin). Runs INSIDE the cluster.
Each request has a unique prompt (random IDs, no cache) and a fixed output length; measures TTFT, TPOT and throughput."""
import argparse, json, random, statistics as st, time, urllib.request, concurrent.futures as cf, itertools, threading

def one(url, prompt, n_out, model="mini"):
    body = json.dumps({"model": model, "prompt": prompt, "max_tokens": n_out, "temperature": 0,
                       "ignore_eos": True, "stream": True}).encode()
    req = urllib.request.Request(url + "/v1/completions", data=body, headers={"Content-Type": "application/json"})
    t0 = time.time(); ttft = None; n = 0
    with urllib.request.urlopen(req, timeout=900) as r:
        for l in r:
            if l.startswith(b"data:") and b"[DONE]" not in l:
                try:
                    j = json.loads(l[5:])
                    if not j["choices"] or j["choices"][0].get("text") is None: continue
                except Exception: continue
                if ttft is None: ttft = time.time() - t0
                n += 1
    tot = time.time() - t0
    return ttft, tot, n

def q(v, p): v = sorted(v); return v[min(len(v) - 1, int(len(v) * p))]

if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("--targets", required=True); a.add_argument("--label", default="x")
    a.add_argument("--concurrency", type=int, default=16); a.add_argument("--requests", type=int, default=64)
    a.add_argument("--prompt", type=int, default=17408); a.add_argument("--output-tokens", type=int, default=128)
    a.add_argument("--seed", type=int, default=1); a.add_argument("--model", default="mini"); a.add_argument("--same-prompt", action="store_true"); a.add_argument("--out", default="/tmp/pd.json")
    a = a.parse_args()
    targets = itertools.cycle(a.targets.split(",")); lock = threading.Lock()
    rng = random.Random(a.seed)
    prompts = [[rng.randint(1000, 150000) for _ in range(a.prompt)] for _ in range(a.requests)]
    if a.same_prompt: prompts = [prompts[0]] * a.requests
    t0 = time.time(); res = []; failures = 0
    def task(i):
        with lock: u = next(targets)
        return one(u, prompts[i], a.output_tokens, a.model)
    with cf.ThreadPoolExecutor(a.concurrency) as ex:
        futs = [ex.submit(task, i) for i in range(a.requests)]
        for f in futs:
            try: res.append(f.result())
            except Exception as e: failures += 1
    dur = time.time() - t0
    ok = [r for r in res if r[0] is not None and r[2] > 1]
    ttft = [r[0] for r in ok]; tpot = [(r[1] - r[0]) / (r[2] - 1) for r in ok]
    s = dict(label=a.label, concurrency=a.concurrency, requests=a.requests, ok=len(ok), failures=failures, prompt=a.prompt, output_tokens=a.output_tokens,
             duration_s=round(dur, 1), req_s=round(len(ok) / dur, 2), output_tok_s=round(sum(r[2] for r in ok) / dur),
             prompt_tok_s=round(len(ok) * a.prompt / dur),
             ttft_p50=round(q(ttft, .5), 3), ttft_p95=round(q(ttft, .95), 3), ttft_max=round(max(ttft), 3),
             tpot_p50_ms=round(1000 * q(tpot, .5), 1), tpot_p95_ms=round(1000 * q(tpot, .95), 1))
    print(json.dumps(s)); json.dump(s, open(a.out, "w"))
