#!/usr/bin/env python3
"""Functional P/D check: the same prompt through the proxy (P/D) and straight to decode (aggregated); compares the output and the token sources.
Usage: pd_check.py <proxy URL> <prefill URL> <decode URL>"""
import json, random, re, sys, time, urllib.request
PROXY, PRE, DEC = sys.argv[1], sys.argv[2], sys.argv[3]
def post(base, prompt, n=48):
    body = json.dumps({"model": "mini", "prompt": prompt, "max_tokens": n, "temperature": 0, "ignore_eos": True}).encode()
    t0 = time.time()
    r = json.load(urllib.request.urlopen(urllib.request.Request(base + "/v1/completions", data=body, headers={"Content-Type": "application/json"}), timeout=600))
    return r["choices"][0]["text"], r["choices"][0].get("token_ids"), time.time() - t0
def src(base):
    t = urllib.request.urlopen(base + "/metrics", timeout=30).read().decode(); o = {}
    for l in t.splitlines():
        m = re.match(r'vllm:prompt_tokens_by_source_total\{.*source="(\w+)"\} ([0-9.e+]+)', l)
        if m: o[m.group(1)] = float(m.group(2))
    return o
rng = random.Random(7)
for n_prompt in (17408, 40000):
    prompt = [rng.randint(1000, 150000) for _ in range(n_prompt)] + [rng.randint(1000, 150000) for _ in range(300)]
    d0, p0 = src(DEC), src(PRE)
    txt_pd, _, t_pd = post(PROXY, prompt)
    d1, p1 = src(DEC), src(PRE)
    txt_ag, _, t_ag = post(DEC, prompt)
    d2 = src(DEC)
    f = lambda a, b: {k: int(b.get(k, 0) - a.get(k, 0)) for k in b}
    print(json.dumps(dict(prompt_tokens=len(prompt), same_output=(txt_pd == txt_ag), t_pd_s=round(t_pd, 2), t_aggregated_s=round(t_ag, 2),
          decode_sources_via_proxy=f(d0, d1), prefill_sources_via_proxy=f(p0, p1), decode_sources_direct=f(d1, d2), sample_pd=txt_pd[:40], sample_aggregated=txt_ag[:40])))
