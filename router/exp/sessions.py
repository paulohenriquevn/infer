#!/usr/bin/env python3
"""Long-session client, running INSIDE the cluster. Talks to the EPP (router) on /v1/completions.

Modes:
  routing  serial; for each request, finds which replica served it from the delta of the vLLM metrics.
           Measures whether repeats of a prefix go back to the same replica (router correctness).
  cyclic   S sessions visited in cyclic order for T passes (worst case for LRU when the working set
           exceeds the KV pool capacity). Measures cache hits and TTFT per pass.
  burst    N concurrent requests with the SAME prefix (tests whether the router spreads or stacks them).
Prompts are lists of random token IDs (no tokenizer), seeded for reproducibility.
"""
import argparse, json, random, re, statistics as st, sys, time, urllib.request, concurrent.futures as cf

EPP = "http://optimized-baseline-epp:80"
BLOCK = 8704

def ids(n, seed):
    r = random.Random(seed)
    return [r.randint(1000, 150000) for _ in range(n)]

def stream(prompt, max_tokens=16):
    body = json.dumps({"model": "mini", "prompt": prompt, "max_tokens": max_tokens, "temperature": 0,
                       "ignore_eos": True, "stream": True}).encode()
    req = urllib.request.Request(EPP + "/v1/completions", data=body, headers={"Content-Type": "application/json"})
    t0 = time.time(); ttft = None
    with urllib.request.urlopen(req, timeout=600) as r:
        for line in r:
            if ttft is None and line.startswith(b"data:") and b"[DONE]" not in line:
                ttft = time.time() - t0
    return ttft, time.time() - t0

def pods(base_ips):
    return base_ips

def scrape(ip):
    txt = urllib.request.urlopen(f"http://{ip}:8000/metrics", timeout=30).read().decode()
    out = {"hit": 0.0, "comp": 0.0, "ext": 0.0}
    for l in txt.splitlines():
        m = re.match(r'vllm:prompt_tokens_by_source_total\{.*source="(\w+)"\} ([0-9.e+]+)', l)
        if m and m.group(1) == "local_cache_hit": out["hit"] = float(m.group(2))
        if m and m.group(1) == "local_compute": out["comp"] = float(m.group(2))
        if m and m.group(1) == "external_kv_transfer": out["ext"] = float(m.group(2))
    return out

def snap(ips):
    return {ip: scrape(ip) for ip in ips}

def delta(a, b):
    return {ip: {k: b[ip][k] - a[ip][k] for k in b[ip]} for ip in b}

def mode_routing(a, ips):
    G, R, P = a.groups, a.repetitions, a.prefix
    rows = []; first = {}
    for r in range(R):
        for g in range(G):
            prompt = ids(P, 1000 + g) + ids(a.question, 5000 + g * 100 + r)
            before = snap(ips); ttft, tot = stream(prompt); after = snap(ips)
            d = delta(before, after)
            pod = max(d, key=lambda ip: d[ip]["hit"] + d[ip]["comp"])
            hit = sum(v["hit"] for v in d.values()); comp = sum(v["comp"] for v in d.values())
            if r == 0: first[g] = pod
            rows.append(dict(group=g, rep=r, pod=pod, same_as_first=(pod == first[g]), hit=hit, comp=comp, ttft=ttft))
    rep = [l for l in rows if l["rep"] > 0]
    res = dict(mode="routing", requests=len(rows),
               repeats_on_same_replica_pct=round(100 * sum(l["same_as_first"] for l in rep) / len(rep), 1),
               hit_pct_repeats=round(100 * sum(l["hit"] for l in rep) / sum(l["hit"] + l["comp"] for l in rep), 1),
               hit_pct_first=round(100 * sum(l["hit"] for l in rows if l["rep"] == 0) / sum(l["hit"] + l["comp"] for l in rows if l["rep"] == 0), 1),
               first_per_replica={ip: sum(1 for g in first if first[g] == ip) for ip in ips},
               ttft_repeat_p50=round(st.median(l["ttft"] for l in rep), 3))
    return res, rows

def mode_cyclic(a, ips):
    S, T, P = a.sessions, a.passes, a.prefix
    prefixes = [ids(P, 9000 + s) for s in range(S)]
    per_pass = []; ttfts = {}
    before_all = snap(ips)
    with cf.ThreadPoolExecutor(a.concurrency) as ex:
        for t in range(T):
            prev = snap(ips); t0 = time.time()
            futs = [ex.submit(stream, prefixes[s] + ids(a.question, 20000 + t * 1000 + s)) for s in range(S)]
            tt = [f.result()[0] for f in futs]
            d = delta(prev, snap(ips))
            hit = sum(v["hit"] for v in d.values()); comp = sum(v["comp"] for v in d.values()); ext = sum(v["ext"] for v in d.values())
            ttfts[t] = tt
            per_pass.append(dict(pass_index=t + 1, hit_pct=round(100 * hit / (hit + comp + ext), 1), external_pct=round(100 * ext / (hit + comp + ext), 1), computed_tokens=int(comp),
                                 ttft_p50=round(st.median(tt), 3), ttft_p95=round(sorted(tt)[int(len(tt) * .95) - 1], 3),
                                 ttft_max=round(max(tt), 3), duration_s=round(time.time() - t0, 1)))
    return dict(mode="cyclic", sessions=S, prefix_tokens=P, passes=per_pass,
                per_replica={ip: {k: int(v) for k, v in d_.items()} for ip, d_ in delta(before_all, snap(ips)).items()}), None

def mode_burst(a, ips):
    prompt0 = ids(a.prefix, 777)
    stream(prompt0 + ids(a.question, 1), 1)          # warms one replica
    prev = snap(ips)
    with cf.ThreadPoolExecutor(a.burst) as ex:
        futs = [ex.submit(stream, prompt0 + ids(a.question, 100 + i)) for i in range(a.burst)]
        tt = [f.result()[0] for f in futs]
    d = delta(prev, snap(ips))
    return dict(mode="burst", n=a.burst, requests_per_replica={ip: round((v["hit"] + v["comp"]) / (a.prefix + a.question)) for ip, v in d.items()},
                hit_pct=round(100 * sum(v["hit"] for v in d.values()) / sum(v["hit"] + v["comp"] for v in d.values()), 1),
                ttft_p50=round(st.median(tt), 3), ttft_max=round(max(tt), 3)), None

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["routing", "cyclic", "burst"])
    p.add_argument("--pods", required=True, help="comma-separated replica IPs")
    p.add_argument("--prefix", type=int, default=17408)
    p.add_argument("--question", type=int, default=512)
    p.add_argument("--groups", type=int, default=20)
    p.add_argument("--repetitions", type=int, default=3)
    p.add_argument("--sessions", type=int, default=48)
    p.add_argument("--passes", type=int, default=3)
    p.add_argument("--concurrency", type=int, default=4)
    p.add_argument("--burst", type=int, default=8)
    p.add_argument("--output", default="/workspace/result.json")
    a = p.parse_args(); ips = a.pods.split(",")
    res, rows = {"routing": mode_routing, "cyclic": mode_cyclic, "burst": mode_burst}[a.mode](a, ips)
    print(json.dumps(res, indent=1))
    json.dump({"summary": res, "rows": rows}, open(a.output, "w"), indent=1)
